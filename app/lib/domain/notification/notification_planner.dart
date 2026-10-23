/// 通知排程的纯计算层：把展开出的槽位变成"要排哪几条通知"。
///
/// 这一层不调任何平台 API，输出是 [PlannedNotification] 列表。
/// 好处是：滚动窗口、免打扰顺延、催办去重、已完成剔除这些**最容易出错**
/// 的地方全部可以单测；平台的 `zonedSchedule` 只负责照着清单发。
library;

import '../model/local_date.dart';
import '../model/local_time.dart';
import '../scheduling/scheduler.dart';
import 'notification_ids.dart';
import 'window_policy.dart';

/// 一条待排的通知。
final class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.taskId,
    required this.date,
    required this.slotIndex,
    required this.kind,
    required this.at,
    required this.title,
    required this.body,
  });

  final int id;
  final String taskId;

  /// 槽位归属的疗程日（不是触发日）。
  final LocalDate date;
  final int slotIndex;

  final ReminderKind kind;

  /// 实际触发时刻（已含免打扰顺延，可能跨天）。
  final LocalDateTimeRef at;

  final String title;
  final String body;

  @override
  String toString() => 'Plan(#$id ${kind.name} $taskId $date#$slotIndex @ $at)';
}

/// 排程时的输入：哪些槽位已经处理过。
final class PlannedFilters {
  const PlannedFilters({
    this.doneKeys = const {},
    this.quietHours,
    this.remindersEnabled = true,
    this.followupDelayMinutes = 15,
    this.followupEnabled = true,
  });

  /// 已完成/已"没做"/已补卡的槽位键，格式 `taskId|epochDay|index`。
  ///
  /// 已结案的槽位**不再排任何通知**——这是"打了卡还催"的唯一根治办法。
  final Set<String> doneKeys;

  /// 免打扰时段；null = 不限制。
  final QuietHours? quietHours;

  /// 全局提醒开关。
  final bool remindersEnabled;

  /// 二次催办延迟（分钟）。需求里定的是 15 分钟。
  final int followupDelayMinutes;

  /// 是否排二次催办。
  ///
  /// 单独一个开关而不是"把延迟设成 0"：0 分钟意味着"跟到点提醒同一时刻"，
  /// 系统会在同一秒弹两条，用户看到的是重复通知而不是催办。
  final bool followupEnabled;

  /// 槽位键（与 [Slot.key] 一致）。
  static String keyOf(String taskId, LocalDate date, int index) =>
      '$taskId|${date.epochDay}|$index';
}

/// 把槽位列表排成通知列表。
abstract final class NotificationPlanner {
  /// 生成通知清单。
  ///
  /// [expanded] 是 [Scheduler.expand] 的结果，必须已按 [Slot.dueAt] 排好序。
  /// [now] 用于剔除已经过去的时刻——给系统排一条过去时间的通知会被立即弹出，
  /// 用户刚打开 App 就挨一顿轰炸，属于经典事故。
  static List<PlannedNotification> plan({
    required List<Slot> expanded,
    required Map<String, ({String taskName, String memberName})> labels,
    required LocalDateTimeRef now,
    PlannedFilters filters = const PlannedFilters(),
  }) {
    if (!filters.remindersEnabled) {
      return const [];
    }

    final out = <PlannedNotification>[];
    final quiet = filters.quietHours;

    for (final slot in expanded) {
      final key = PlannedFilters.keyOf(slot.taskId, slot.date, slot.index);
      if (filters.doneKeys.contains(key)) {
        continue;
      }
      // 提醒关闭的项目：labels 里没有它，说明不该排（见 repo 层组装）。
      final label = labels[slot.taskId];
      if (label == null) {
        continue;
      }

      // ---- 到点提醒 ----
      final at = _applyQuietHours(slot.dueAt, quiet);
      if (at.compareTo(now) > 0) {
        out.add(
          PlannedNotification(
            id: NotificationIds.due(slot.taskId, slot.date, slot.index),
            taskId: slot.taskId,
            date: slot.date,
            slotIndex: slot.index,
            kind: ReminderKind.due,
            at: at,
            title: label.taskName,
            body: label.memberName,
          ),
        );
      }

      // ---- 15 分钟催办 ----
      //
      // 只给"当天还没结束"的槽位排催办会漏掉跨午夜的，所以这里不做日期判断，
      // 只按真实时刻加偏移。
      if (!filters.followupEnabled) {
        continue;
      }
      final fu = _shiftMinutes(at, filters.followupDelayMinutes);
      final fuQuiet = _applyQuietHours(fu, quiet);
      // 免打扰把催办顺延到免打扰结束后，若顺延后已经过了**到点提醒**很久
      // （比如顺延到了第二天早上），这条催办就失去意义了——提醒本身已经到了早上。
      // 判定标准：催办必须严格晚于到点提醒，否则不排。
      if (fuQuiet.compareTo(at) > 0 && fuQuiet.compareTo(now) > 0) {
        out.add(
          PlannedNotification(
            id: NotificationIds.followup(slot.taskId, slot.date, slot.index),
            taskId: slot.taskId,
            date: slot.date,
            slotIndex: slot.index,
            kind: ReminderKind.followup,
            at: fuQuiet,
            title: label.taskName,
            body: '${label.memberName} · 还没打卡',
          ),
        );
      }
    }

    out.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  /// 在 [maxCount] 内裁剪。
  ///
  /// ⚠️ iOS 只保留 64 条待处理通知，且超限时**挤掉最老的**——也就是今天的。
  /// 所以宁可少排几天，也不能让系统去挤：裁剪必须在提交前完成。
  static List<PlannedNotification> cap(
    List<PlannedNotification> planned,
    int maxCount,
  ) {
    if (maxCount <= 0) {
      return const [];
    }
    if (planned.length <= maxCount) {
      return planned;
    }
    // 已按时间排序，取最早的 N 条（最近的提醒最要紧）。
    return planned.sublist(0, maxCount);
  }

  static LocalDateTimeRef _shiftMinutes(LocalDateTimeRef at, int minutes) {
    // LocalDateTimeRef 的私有字段在这儿拿不到，用"日期 + 当天分钟"重算，
    // 跨天进位交给 fromDayAndMinute（内部用 floor 除法）。
    return LocalDateTimeRef.fromDayAndMinute(
      at.date,
      at.time.minuteOfDay + minutes,
    );
  }

  static LocalDateTimeRef _applyQuietHours(
    LocalDateTimeRef at,
    QuietHours? quiet,
  ) {
    if (quiet == null || quiet.isDisabled || !quiet.contains(at.time)) {
      return at;
    }
    final LocalTime shifted = quiet.shiftOutOf(at.time);
    // 跨午夜的免打扰（22:00-07:00）在 23:00 命中时，顺延目标是"次日 07:00"。
    final crossedMidnight = quiet.end.minuteOfDay <= quiet.start.minuteOfDay;
    return LocalDateTimeRef(
      crossedMidnight ? at.date.addDays(1) : at.date,
      shifted,
    );
  }
}
