/// 排程展开器：把"重复规则 × 时刻规则 × 疗程"折成未来一段时间的**具体时刻列表**。
///
/// 这是全项目唯一有真正算法复杂度的地方，也是所有提醒的来源。
/// 纯 Dart，无 Flutter 依赖，可以脱离模拟器单测（tech-stack §8 决策 4）。
///
/// ## 为什么必须先展开
/// iOS 只保留 64 条待处理通知（tech-stack §4.1），所以不能"到点再算"，只能
/// 提前把未来几天的槽位算出来、逐条 `zonedSchedule`。展开结果同时落库，
/// 提醒被点击时靠它反查"这到底是哪个项目的哪一次"。
library;

import '../model/course.dart';
import '../model/local_date.dart';
import '../model/local_time.dart';
import '../model/repeat_rule.dart';
import '../model/time_rule.dart';

/// 向下取整除法。
///
/// ⚠️ 不要用 `a ~/ b`：Dart 的 `~/` 与 `%` 对负数**向零截断**，
/// `-30 ~/ 1440 == 0`、`-30 % 1440 == -30`。跨午夜/饭前偏移全靠这个函数。
int floorDiv(int a, int b) => (a / b).floor();

/// 一个待做槽位：某项目在某天的第 n 次，应完成于 [dueAt]。
final class Slot implements Comparable<Slot> {
  const Slot({
    required this.taskId,
    required this.date,
    required this.index,
    required this.dueAt,
    required this.dueMinuteOfDay,
  });

  /// 所属打卡项目。展开器不关心项目内容，只带上 id 便于落库与反查。
  final String taskId;

  /// 这一天（本地日历日，不是"提醒落在哪一天"）。
  ///
  /// 例：宵夜后 60 分钟这种跨午夜的规则，`date` 仍是疗程当天，
  /// 而 `dueAt` 可能落在次日凌晨。统计按 `date` 归集，提醒按 `dueAt` 触发。
  final LocalDate date;

  /// 当天第几次（从 0 开始），用于通知 ID 推导。
  final int index;

  /// 应完成时刻（已含偏移，可能跨天）。
  final LocalDateTimeRef dueAt;

  /// 冗余存一份"当天第几分钟"，方便按天内顺序排序与展示。
  ///
  /// ⚠️ 跨午夜时这个值会 > 1439 或 < 0，见 [dueAt]。
  final int dueMinuteOfDay;

  /// 唯一键：`taskId|date|index`。
  String get key => '$taskId|${date.epochDay}|$index';

  @override
  int compareTo(Slot other) {
    final byTime = dueAt.compareTo(other.dueAt);
    if (byTime != 0) {
      return byTime;
    }
    return key.compareTo(other.key);
  }

  @override
  String toString() =>
      'Slot($taskId @ $date #$index → $dueAt)';
}

/// 一个"日期 + 时刻"，可跨天（不做时区换算，纯本地墙钟概念）。
final class LocalDateTimeRef implements Comparable<LocalDateTimeRef> {
  const LocalDateTimeRef(this.date, this.time);

  /// 从"疗程当天 + 当天第几分钟"构造，自动处理跨午夜进位。
  ///
  /// `minuteOfDay` 可以超出 0..1439（表示跨到次日）或为负（跨到前日）。
  /// ⚠️ 必须用 floor 除法：Dart 的 `~/` 对负数向零截断，会让"饭前"规则落错日期。
  factory LocalDateTimeRef.fromDayAndMinute(
    LocalDate date,
    int minuteOfDay,
  ) {
    final dayShift = floorDiv(minuteOfDay, 1440);
    final rem = minuteOfDay - dayShift * 1440;
    return LocalDateTimeRef(
      date.addDays(dayShift),
      LocalTime.fromMinuteOfDay(rem),
    );
  }

  final LocalDate date;
  final LocalTime time;

  /// 与 1970-01-01 00:00 的"墙钟分钟差"，用于跨天比较。
  int get _minutes => date.epochDay * 1440 + time.minuteOfDay;

  @override
  int compareTo(LocalDateTimeRef other) => _minutes.compareTo(other._minutes);

  @override
  bool operator ==(Object other) =>
      other is LocalDateTimeRef &&
      other.date == date &&
      other.time == time;

  @override
  int get hashCode => Object.hash(date, time);

  @override
  String toString() => '$date $time';
}

/// 展开器的输入：一个项目的排程配置。
final class ScheduleSpec {
  const ScheduleSpec({
    required this.taskId,
    required this.repeat,
    required this.time,
    required this.course,
    this.fromDate,
    this.enabled = true,
  });

  final String taskId;
  final RepeatRule repeat;
  final TimeRule time;
  final Course course;

  /// 规则生效日（含）。[LocalDate] 为空表示"一直有效"。
  ///
  /// 这是"改规则不影响历史"（需求 3.2.1）的实现关键：
  /// 编辑项目时把旧规则封存、新规则从今天起生效，历史照旧按旧规则算。
  final LocalDate? fromDate;

  /// 暂停 / 归档的项目直接不展开（需求 3.2.1 暂停语义）。
  final bool enabled;

  /// 某天是否可能产出槽位（不考虑时刻规则的跨天）。
  bool appliesOn(LocalDate day) {
    if (!enabled || !course.contains(day)) {
      return false;
    }
    if (fromDate != null && day.isBefore(fromDate!)) {
      return false;
    }
    return repeat.matches(day);
  }
}

/// 展开结果：有序槽位 + 诊断信息。
final class ExpansionResult {
  const ExpansionResult({required this.slots, required this.truncated});

  final List<Slot> slots;

  /// 是否因为超过 [maxSlots] 被截断。UI 可以据此提示"提醒只排到某天"。
  final bool truncated;
}

/// 排程展开器。
abstract final class Scheduler {
  /// 展开 [from, to]（闭区间）内的所有槽位。
  ///
  /// [maxSlots] 是硬上限：达到后立即停止，并在结果里标记 [ExpansionResult.truncated]。
  /// 应该给一个明显小于平台上限的值（iOS 64 条），由调用方决定窗口与上限的配合。
  static ExpansionResult expand({
    required List<ScheduleSpec> specs,
    required LocalDate from,
    required LocalDate to,
    int maxSlots = 512,
  }) {
    if (to.isBefore(from)) {
      return const ExpansionResult(slots: [], truncated: false);
    }

    final slots = <Slot>[];
    var truncated = false;

    // 第一步：按疗程日收集"应完成时刻"。
    //
    // 关键：偏移可能把时刻推到次日或前日（如 21:00 饭后 4 小时 → 次日 01:00）。
    // 所以这里先按 (疗程日, 越界分钟) 收集，第二步再折算成真实日期整体排序，
    // 这样"今天的宵夜药"和"明天凌晨的药"顺序才是对的。
    final pending = <({LocalDate day, int minute, String taskId})>[];
    var day = from;
    while (!day.isAfter(to)) {
      for (final spec in specs) {
        if (!spec.appliesOn(day)) {
          continue;
        }
        for (final m in spec.time.shiftedMinutesOn(day)) {
          if (pending.length >= maxSlots) {
            truncated = true;
            break;
          }
          pending.add((day: day, minute: m, taskId: spec.taskId));
        }
      }
      if (truncated) {
        break;
      }
      day = day.addDays(1);
    }

    // 第二步：按"真实触发时刻"排序后编号。
    //
    // 同一 (taskId, 疗程日) 内的序号必须按时间递增，否则通知 ID 会随偏移抖动，
    // 已完成记录的 slot_index 会对不上。
    final expanded = pending
        .map(
          (p) => (
            ref: LocalDateTimeRef.fromDayAndMinute(p.day, p.minute),
            day: p.day,
            minute: p.minute,
            taskId: p.taskId,
          ),
        )
        .toList()
      ..sort((a, b) {
        final byTime = a.ref.compareTo(b.ref);
        if (byTime != 0) {
          return byTime;
        }
        final byTask = a.taskId.compareTo(b.taskId);
        if (byTask != 0) {
          return byTask;
        }
        return a.day.compareTo(b.day);
      });

    final indexByTaskDay = <String, int>{};
    for (final e in expanded) {
      final groupKey = '${e.taskId}|${e.day.epochDay}';
      final index = indexByTaskDay[groupKey] ?? 0;
      indexByTaskDay[groupKey] = index + 1;
      slots.add(
        Slot(
          taskId: e.taskId,
          date: e.day,
          index: index,
          dueAt: e.ref,
          dueMinuteOfDay: e.minute,
        ),
      );
    }

    slots.sort();
    return ExpansionResult(slots: slots, truncated: truncated);
  }

  /// 估算"平均每天几条"，用于滚动窗口自适应（tech-stack §4.2）。
  ///
  /// 只看 [sampleDays] 天的采样，不展开到 [to]，避免为估算做重活。
  static int estimateDailyCount(
    List<ScheduleSpec> specs, {
    required LocalDate from,
    int sampleDays = 7,
  }) {
    final result = expand(
      specs: specs,
      from: from,
      to: from.addDays(sampleDays - 1),
      maxSlots: 100000,
    );
    return (result.slots.length / sampleDays).ceil();
  }

  /// 计算滚动窗口应该覆盖到哪一天。
  ///
  /// 目标：尽量多排（减少"App 长期不开导致提醒耗尽"的风险），但不超过 [maxSlots]。
  /// 返回的是**建议的 to 日期**，调用方仍需按 [maxSlots] 兜底。
  static LocalDate suggestWindowEnd({
    required List<ScheduleSpec> specs,
    required LocalDate from,
    int maxSlots = 60,
    int maxDays = 7,
    int minDays = 3,
  }) {
    final daily = estimateDailyCount(specs, from: from);
    final days = daily <= 0
        ? maxDays
        : (maxSlots / daily).floor().clamp(minDays, maxDays);
    return from.addDays(days - 1);
  }
}
