/// 提醒的总调度：数据库 → 展开器 → 规划器 → 平台通知。
///
/// 这是整条链路唯一"知道所有事情"的地方，所以每个判断都写清楚理由，
/// 而不是散落在 UI 各处。调用时机由 [ReschedulePolicy] 决定：
/// 冷启动 / 回前台跨天 / 数据变更 / 改设置。
library;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/task.dart' as domain;
import '../../domain/notification/notification_ids.dart';
import '../../domain/notification/notification_planner.dart';
import '../../domain/notification/window_policy.dart';
import '../../domain/scheduling/scheduler.dart' as sched;
import '../db/app_database.dart';
import '../notifier/notification_service.dart';
import '../../app/test_clock.dart';

// 展开器的结果类型；`Slot` 与 drift 生成的行别名同名，所以显式收窄。
typedef _Slot = sched.Slot;

/// 设置项的键名（集中在这里，避免字符串散落）。
abstract final class SettingsKeys {
  static const String remindersEnabled = 'reminders.enabled';
  static const String quietStart = 'reminders.quietStart';
  static const String quietEnd = 'reminders.quietEnd';
  static const String followupMinutes = 'reminders.followupMinutes';
  static const String followupEnabled = 'reminders.followupEnabled';
  static const String lastScheduledFor = 'reminders.lastScheduledFor';
}

/// 一次重排的结果，供调试页与日志展示。
final class RescheduleResult {
  const RescheduleResult({
    required this.windowEnd,
    required this.slots,
    required this.planned,
    required this.scheduled,
    required this.truncated,
    required this.skippedReason,
  });

  const RescheduleResult.skipped(String reason)
    : windowEnd = null,
      slots = 0,
      planned = 0,
      scheduled = 0,
      truncated = false,
      skippedReason = reason;

  /// 窗口覆盖到哪一天。
  final LocalDate? windowEnd;

  /// 展开出的槽位数。
  final int slots;

  /// 规划出的通知数（裁剪前）。
  final int planned;

  /// 实际交给系统的条数（裁剪后）。
  final int scheduled;

  /// 是否因为条数上限被截断。
  final bool truncated;

  /// 没排的原因（权限没给 / 提醒全局关闭 / …）。
  final String? skippedReason;

  @override
  String toString() =>
      'Reschedule(window→$windowEnd, slots=$slots, planned=$planned, '
      'scheduled=$scheduled, truncated=$truncated, skip=$skippedReason)';
}

/// 重排器。
final class ReminderScheduler {
  ReminderScheduler({
    required AppDatabase db,
    required NotificationGateway notifications,
    this.policy = const WindowPolicy(),
  }) : _db = db,
       _notifications = notifications;

  final AppDatabase _db;
  final NotificationGateway _notifications;

  /// 窗口策略（上限天数与条数）。
  final WindowPolicy policy;

  /// 执行重排。
  ///
  /// [trigger] 决定要不要真跑（见 [ReschedulePolicy]）。
  Future<RescheduleResult> reschedule({
    required RescheduleTrigger trigger,
    LocalDate? todayOverride,
  }) async {
    final now = appNow();
    final today = todayOverride ?? LocalDate.fromDateTime(now);

    final lastRaw = await _db.getSetting(SettingsKeys.lastScheduledFor);
    final last = lastRaw == null ? null : LocalDate.parse(lastRaw);
    if (!ReschedulePolicy.shouldReschedule(
      trigger: trigger,
      today: today,
      lastScheduledFor: last ?? today.addDays(-999),
    )) {
      return const RescheduleResult.skipped('未跨天，跳过');
    }

    // ---- 读设置 ----
    final enabled =
        (await _db.getSetting(SettingsKeys.remindersEnabled)) != 'false';
    final quiet = await _readQuietHours();
    final followupMinutes = int.tryParse(
          await _db.getSetting(SettingsKeys.followupMinutes) ?? '',
        ) ??
        15;
    final followupEnabled =
        (await _db.getSetting(SettingsKeys.followupEnabled)) != 'false';

    if (!enabled) {
      await _notifications.cancelAll();
      await _db.setSetting(
        SettingsKeys.lastScheduledFor,
        today.toString(),
        nowMs: now.millisecondsSinceEpoch,
      );
      return const RescheduleResult.skipped('提醒已全局关闭');
    }

    final granted = await _notifications.hasPermission();
    if (!granted) {
      return const RescheduleResult.skipped('没有通知权限');
    }

    // ---- 组装排程输入 ----
    final tasks = await _db.listAllTasks();
    final members = {for (final m in await _db.listMembers()) m.id: m};

    // 只有 active + 开了提醒的项目才进排程。
    final live = tasks
        .where((t) => t.isLive && t.reminderEnabled)
        .toList(growable: false);

    final specs = [
      for (final t in live)
        sched.ScheduleSpec(
          taskId: t.id,
          repeat: t.repeat,
          time: t.time,
          course: t.course,
          // 规则生效日 = 创建日的次日：当天建的项目不追溯，
          // 但"今天下午建的药"当天就要提醒，所以用创建日而不是次日。
          fromDate: _effectiveFrom(t),
        ),
    ];

    final daily = sched.Scheduler.estimateDailyCount(specs, from: today);
    final windowEnd = policy.endFor(today, daily);

    // ---- 往前多展开到"本月 1 号" ----
    //
    // 为什么要往前展开：`slots` 表不只是通知的副产物，**统计和历史都靠它算
    // 分母**。只从今天往后展开的话，一个 20 号才打开一次 App 的用户，
    // 这个月前 19 天根本没有槽位——「统计 → 本月」永远是空的或只有个位数，
    // 而实际上他天天都在打卡。
    //
    // 往前展开出来的槽位**不进通知**（见下面 plannedAll 的 `from: today`），
    // 只落库当分母。已经打过卡的会经由 bySlot 匹配上，数字自然是对的。
    final historyStart = LocalDate(today.year, today.month, 1);
    final expandFrom = historyStart.isBefore(today) ? historyStart : today;

    final expansion = sched.Scheduler.expand(
      specs: specs,
      from: expandFrom,
      to: windowEnd,
      // 上限按槽位数算，真正的通知条数由规划器在最后一步裁剪。
      // 往前展开会多出最多 31 天，上限相应放宽——否则历史槽位会把
      // 未来的槽位挤掉，提醒反而变少。
      maxSlots: policy.maxScheduled + today.daysSince(historyStart) * daily,
    );

    // ---- 剔除已结案的槽位 ----
    final doneKeys = <String>{};
    if (expansion.slots.isNotEmpty) {
      final earliest = expansion.slots
          .map((s) => s.date)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final records = await _db.checkinsBetween(earliest, windowEnd);
      for (final c in records) {
        // 「没做」也算已结案：用户明确认了，就别再催。
        doneKeys.add(
          PlannedFilters.keyOf(c.taskId, c.date, c.slotIndex),
        );
      }
    }

    final labels = <String, ({String taskName, String memberName})>{
      for (final t in live)
        t.id: (
          taskName: t.name,
          memberName: members[t.memberId]?.name ?? '家人',
        ),
    };

    // 只有"今天及以后"该进通知。往月展开出来的槽位**只当分母**——
    // 用户不会希望今晚收到"3 月 3 日的降压药还没吃"。
    final upcoming = [
      for (final s in expansion.slots)
        if (!s.date.isBefore(today)) s,
    ];

    final plannedAll = NotificationPlanner.plan(
      expanded: upcoming,
      labels: labels,
      now: sched.LocalDateTimeRef(today, LocalTime(now.hour, now.minute)),
      filters: PlannedFilters(
        doneKeys: doneKeys,
        quietHours: quiet,
        remindersEnabled: enabled,
        followupDelayMinutes: followupMinutes,
        followupEnabled: followupEnabled,
      ),
    );

    final capped = NotificationPlanner.cap(plannedAll, policy.maxScheduled);

    // ---- 落库槽位 ----
    //
    // 分两段写，起点不同：
    //   历史段 [月初, 昨天]：只插入，不删除（`backfillSlots`）；
    //   未来段 [今天, 窗口末]：整段重灌（`replaceSlots`），因为规则可能
    //     改过，旧槽位要作废。删除**只在这个段内**发生，碰不到历史。
    final pastSlots = [
      for (final s in expansion.slots)
        if (s.date.isBefore(today)) s,
    ];
    await _db.backfillSlots(
      _toSlotsCompanions(pastSlots, const <PlannedNotification>[]),
    );
    await _db.replaceSlots(
      _toSlotsCompanions(
        [for (final s in expansion.slots) if (!s.date.isBefore(today)) s],
        capped,
      ),
      from: today,
      to: windowEnd,
      nowMs: now.millisecondsSinceEpoch,
    );

    // ---- 交给系统 ----
    final scheduled = await _notifications.applyPlan(capped);

    await _db.setSetting(
      SettingsKeys.lastScheduledFor,
      today.toString(),
      nowMs: now.millisecondsSinceEpoch,
    );

    final result = RescheduleResult(
      windowEnd: windowEnd,
      slots: expansion.slots.length,
      planned: plannedAll.length,
      scheduled: scheduled,
      truncated: expansion.truncated || capped.length < plannedAll.length,
      skippedReason: null,
    );
    debugPrint('[reminder] $result');
    return result;
  }

  /// 打卡后立即取消该槽位的提醒（不等下一次全量重排）。
  ///
  /// 这一步是"打了卡还催"的**直接解药**：全量重排在数据变更时才跑，
  /// 而用户刚点了"完成"，必须立刻静音。
  Future<void> cancelForCheckin({
    required String taskId,
    required LocalDate date,
    required int slotIndex,
  }) async {
    await _notifications.cancelSlot(
      taskId: taskId,
      date: date,
      slotIndex: slotIndex,
    );
  }

  /// 某个项目的规则从哪天起生效。
  ///
  /// `rulesEffectiveFrom` 为空时退回创建日——这样"今天新建的项目"
  /// 当天就能提醒，而不会被"次日生效"的保守策略吞掉一次。
  LocalDate? _effectiveFrom(domain.Task t) {
    final created = LocalDate.fromEpochDay(
      (t.createdAtMs / Duration.millisecondsPerDay).floor(),
    );
    return created;
  }

  Future<QuietHours?> _readQuietHours() async {
    final s = await _db.getSetting(SettingsKeys.quietStart);
    final e = await _db.getSetting(SettingsKeys.quietEnd);
    if (s == null || e == null || s == e) {
      return null;
    }
    return QuietHours(start: LocalTime.parse(s), end: LocalTime.parse(e));
  }

  /// 槽位落库。
  ///
  /// 只写"真的排了通知"的槽位吗？不是——槽位表是**展开器的结果**，
  /// 与通知条数无关。这里按展开结果全量写，提醒 ID 只对实际排上的填。
  List<SlotsCompanion> _toSlotsCompanions(
    List<_Slot> slots,
    List<PlannedNotification> planned,
  ) {
    final dueByKey = <String, int>{};
    final fuByKey = <String, int>{};
    for (final p in planned) {
      final key = PlannedFilters.keyOf(p.taskId, p.date, p.slotIndex);
      if (p.kind == ReminderKind.due) {
        dueByKey[key] = p.id;
      } else {
        fuByKey[key] = p.id;
      }
    }

    return [
      for (final s in slots)
        SlotsCompanion.insert(
          taskId: s.taskId,
          date: s.date,
          slotIndex: s.index,
          dueDate: s.dueAt.date,
          dueTime: s.dueAt.time,
          remindId: Value(
            dueByKey[PlannedFilters.keyOf(s.taskId, s.date, s.index)],
          ),
          followupId: Value(
            fuByKey[PlannedFilters.keyOf(s.taskId, s.date, s.index)],
          ),
        ),
    ];
  }
}

