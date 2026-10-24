import 'package:clock/clock.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/data/notifier/notification_service.dart';
import 'package:famdaily/data/repo_impl/reminder_scheduler.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/domain/notification/window_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的平台通知层：只记账，不碰系统。
final class FakeGateway implements NotificationGateway {
  FakeGateway({this.permissionGranted = true, this.exactGranted = true});

  bool permissionGranted;

  /// 精确闹钟权限（Android 12+ 的 SCHEDULE_EXACT_ALARM）。
  ///
  /// 单独一个开关是必要的：Android 14 起它默认不授予，而**它和通知权限
  /// 是两件事**——有通知权限但没这一项时，`exactAllowWhileIdle` 会全部抛错，
  /// 现象同样是"一条都收不到"。
  bool exactGranted;

  List<PlannedNotification> applied = [];
  final List<int> cancelled = [];
  int cancelAllCount = 0;

  /// 最近一次 applyPlan 用的是不是降级模式。
  bool lastAllowInexact = false;

  /// 用户点了几次「允许通知」。
  int requestCount = 0;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<bool> requestPermission() async {
    requestCount++;
    permissionGranted = true;
    return true;
  }

  @override
  Future<bool> canScheduleExact() async => exactGranted;

  @override
  Future<bool> requestExactAlarms() async {
    exactGranted = true;
    return true;
  }

  @override
  Future<List<int>> pendingIds() async => applied.map((p) => p.id).toList();

  @override
  Future<int> applyPlan(
    List<PlannedNotification> plan, {
    bool allowInexact = false,
  }) async {
    lastAllowInexact = allowInexact;
    applied = plan;
    return plan.length;
  }

  @override
  Future<void> cancelSlot({
    required String taskId,
    required domain.LocalDate date,
    required int slotIndex,
  }) async {
    cancelled.addAll([
      for (final p in applied)
        if (p.taskId == taskId && p.date == date && p.slotIndex == slotIndex)
          p.id,
    ]);
    applied = applied
        .where(
          (p) =>
              !(p.taskId == taskId &&
                  p.date == date &&
                  p.slotIndex == slotIndex),
        )
        .toList();
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
    applied = [];
  }
}

const _nowMs = 1740787200000; // 2025-03-01T00:00:00Z

domain.Member _member(String id, String name) => domain.Member(
  id: id,
  name: name,
  sortOrder: 0,
  createdAtMs: _nowMs,
  updatedAtMs: _nowMs,
);

domain.Task _task(
  String id, {
  required domain.TimeRule time,
  String memberId = 'm1',
  bool reminderEnabled = true,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: '吃药',
  repeat: const domain.RepeatRule(),
  time: time,
  course: domain.Course.none,
  status: domain.TaskStatus.active,
  reminderEnabled: reminderEnabled,
  createdAtMs: _nowMs,
  updatedAtMs: _nowMs,
);

void main() {
  late AppDatabase db;
  late FakeGateway gateway;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    gateway = FakeGateway();
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m1', '妈妈')),
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// 把"现在"钉在 2025-03-01 06:00，避免测试随真实时间漂移。
  Future<RescheduleResult> run(
    ReminderScheduler scheduler, {
    RescheduleTrigger trigger = RescheduleTrigger.appLaunch,
  }) {
    return withClock(
      Clock.fixed(DateTime(2025, 3, 1, 6, 0)),
      () => scheduler.reschedule(trigger: trigger),
    );
  }

  ReminderScheduler build() =>
      ReminderScheduler(db: db, notifications: gateway);

  test('一天三次的药：排出 3 个槽位、6 条通知（含催办）', () async {
    await db.insertTask(
      _task(
        't1',
        time: domain.MealTimesRule(
          anchors: [
            domain.MealAnchor.breakfast,
            domain.MealAnchor.lunch,
            domain.MealAnchor.dinner,
          ],
        ),
      ),
      nowMs: _nowMs,
    );

    final result = await run(build());

    expect(result.skippedReason, isNull);
    // 窗口覆盖 14 天（每天 3 条），但上限 56 条 → 18 个槽位 → 36 条通知
    expect(result.scheduled, greaterThan(0));
    expect(gateway.applied, hasLength(result.scheduled));
    expect(result.scheduled, lessThanOrEqualTo(56));
  });

  test('没有通知权限时不排通知，但槽位照落库', () async {
    gateway.permissionGranted = false;
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );

    final result = await run(build());

    expect(result.skippedReason, '没有通知权限，只记数据不提醒');
    expect(gateway.applied, isEmpty);
    // 槽位是统计的分母，不是通知的附赠品：拒绝了通知权限，
    // 统计数据一样得是对的。这条断言守的是"别把两者合成一个 early return"。
    expect(result.slots, greaterThan(0));
  });

  test('全局关闭提醒时清空所有通知', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await db.setSetting(SettingsKeys.remindersEnabled, 'false', nowMs: _nowMs);

    final result = await run(build());

    expect(result.skippedReason, '提醒已全局关闭，只记数据不提醒');
    expect(gateway.cancelAllCount, 1);
    // 关掉提醒不再"什么都不记"：槽位照样落库，统计不受影响。
    expect(result.slots, greaterThan(0));
  });

  test('提醒开关关闭的项目不进排程', () async {
    await db.insertTask(
      _task(
        't1',
        time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
        reminderEnabled: false,
      ),
      nowMs: _nowMs,
    );

    final result = await run(build());

    expect(result.slots, 0);
    expect(gateway.applied, isEmpty);
  });

  test('已打卡的槽位不再排通知', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    // 先把今天的打卡记上
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: domain.LocalDate(2025, 3, 1),
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _nowMs,
      ),
      nowMs: _nowMs,
    );

    await run(build());

    final todayOnes = gateway.applied.where(
      (p) => p.date == domain.LocalDate(2025, 3, 1),
    );
    expect(todayOnes, isEmpty, reason: '打卡后不该再提醒');
  });

  test('「没做」也算结案，不再催', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: domain.LocalDate(2025, 3, 1),
        slotIndex: 0,
        state: domain.CheckinState.skipped,
        doneAtMs: _nowMs,
      ),
      nowMs: _nowMs,
    );

    await run(build());

    expect(
      gateway.applied.where((p) => p.date == domain.LocalDate(2025, 3, 1)),
      isEmpty,
    );
  });

  test('同一天重复触发，第二次因未跨天被跳过', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await run(build());

    final second = await run(build(), trigger: RescheduleTrigger.resumed);

    expect(second.skippedReason, '未跨天，跳过');
  });

  test('数据变更会强制重排（不受"未跨天"限制）', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await run(build());

    final again = await run(build(), trigger: RescheduleTrigger.dataChanged);

    expect(again.skippedReason, isNull);
    expect(again.scheduled, greaterThan(0));
  });

  test('槽位落库，可用通知 ID 反查', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await run(build());

    expect(gateway.applied, isNotEmpty);
    final first = gateway.applied.first;
    final slot = await db.slotByNotificationId(first.id);
    expect(slot, isNotNull);
    expect(slot!.taskId, 't1');
    expect(slot.date, first.date);
    expect(slot.slotIndex, first.slotIndex);
  });

  test('免打扰：设置在 22:00-07:00，夜里的药被推到早上', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(23, 0)])),
      nowMs: _nowMs,
    );
    await db.setSetting(SettingsKeys.quietStart, '22:00', nowMs: _nowMs);
    await db.setSetting(SettingsKeys.quietEnd, '07:00', nowMs: _nowMs);

    await run(build());

    // 3/1 当天 23:00 的槽位会被推走；看所有提醒都不落在 22:00-07:00
    for (final p in gateway.applied) {
      final m = p.at.time.minuteOfDay;
      expect(m >= 22 * 60 || m < 7 * 60, isFalse, reason: '$p 落在免打扰时段');
    }
  });

  test('催办间隔可配置', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await db.setSetting(SettingsKeys.followupMinutes, '30', nowMs: _nowMs);

    await run(build());

    final due = gateway.applied.firstWhere((p) => p.id == gateway.applied.first.id);
    final fu = gateway.applied.firstWhere(
      (p) =>
          p.date == due.date &&
          p.slotIndex == due.slotIndex &&
          p.kind != due.kind,
    );
    expect(fu.at.time.minuteOfDay - due.at.time.minuteOfDay, 30);
  });

  test('打卡后立即取消该槽位通知，不等全量重排', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await run(build());
    final before = gateway.applied.length;
    expect(before, greaterThan(0));

    final target = gateway.applied.first;
    await build().cancelForCheckin(
      taskId: target.taskId,
      date: target.date,
      slotIndex: target.slotIndex,
    );

    expect(gateway.cancelled, isNotEmpty);
    expect(
      gateway.applied.where(
        (p) =>
            p.taskId == target.taskId &&
            p.date == target.date &&
            p.slotIndex == target.slotIndex,
      ),
      isEmpty,
    );
  });

  // -------------------------------------------------------------------
  // 统计分母：往月补齐
  //
  // 背景（用户报障）：历史 → 右上角「统计」→「本月」是空的。
  // 根因是重排只从"今天"往后展开槽位，而统计的分母就是槽位表：
  // 一个 20 号才打开一次 App 的人，本月前 19 天一条槽位都没有，
  // 于是"共 0 次该做"，完成率、准时率也就无从谈起。
  // -------------------------------------------------------------------

  group('往月补齐：统计的分母要覆盖整个本月', () {
    /// 钉在 3 月 20 日，看 3 月 1 日有没有槽位。
    Future<RescheduleResult> runOn(
      ReminderScheduler scheduler,
      DateTime moment, {
      RescheduleTrigger trigger = RescheduleTrigger.appLaunch,
    }) {
      return withClock(
        Clock.fixed(moment),
        () => scheduler.reschedule(trigger: trigger),
      );
    }

    test('3 月 20 日启动：3 月 1 日到今天的槽位全在', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      await runOn(build(), DateTime(2026, 3, 20, 9));

      final slots = await db.slotsBetween(
        domain.LocalDate(2026, 3, 1),
        domain.LocalDate(2026, 3, 20),
      );
      expect(
        slots.length,
        20,
        reason: '1 号到 20 号每天一次，应该是 20 条。只有 1 条 = 历史没补上',
      );
      expect(
        slots.map((s) => s.date).reduce((a, b) => a.isBefore(b) ? a : b),
        domain.LocalDate(2026, 3, 1),
        reason: '最早的那条必须是月初',
      );
    });

    test('补出来的历史槽位不进通知：今晚不会响「3 号的药没吃」', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      final result = await runOn(build(), DateTime(2026, 3, 20, 9));

      // 历史 19 天 + 未来若干天都可能落库，但通知只该覆盖今天及以后。
      expect(
        gateway.applied.every((p) => !p.date.isBefore(domain.LocalDate(2026, 3, 20))),
        isTrue,
        reason: '给过去的日期排通知，用户会莫名其妙收到一堆补卡提醒',
      );
      // 条数不该因为补历史而变多：一天一次、窗口内也就那么多。
      expect(result.scheduled, lessThanOrEqualTo(56));
    });

    test('已经打过卡的日子，分母和分子对得上', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );
      // 3 月 5 日打过卡（那时还没补历史槽位——模拟老数据）
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 5),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _nowMs,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _nowMs,
      );

      await runOn(build(), DateTime(2026, 3, 20, 9));

      final slots = await db.slotsBetween(
        domain.LocalDate(2026, 3, 1),
        domain.LocalDate(2026, 3, 20),
      );
      expect(
        slots.where((s) => s.date == domain.LocalDate(2026, 3, 5)),
        isNotEmpty,
        reason: '打过卡的那天也要有槽位，否则分子有、分母没有',
      );
    });

    test('同一天重排两次，未来槽位不会被第二次删掉', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );
      final scheduler = build();

      // 先排一次，拿到未来段的槽位。
      await runOn(scheduler, DateTime(2026, 3, 20, 9));
      final before = await db.slotsBetween(
        domain.LocalDate(2026, 3, 20),
        domain.LocalDate(2026, 4, 2),
      );
      expect(before, isNotEmpty);

      // 数据变更触发第二次重排（`shouldReschedule` 会放行）。
      await runOn(
        scheduler,
        DateTime(2026, 3, 20, 10),
        trigger: RescheduleTrigger.dataChanged,
      );

      final after = await db.slotsBetween(
        domain.LocalDate(2026, 3, 20),
        domain.LocalDate(2026, 4, 2),
      );
      expect(
        after.map((s) => '${s.taskId}|${s.date}|${s.slotIndex}').toSet(),
        before.map((s) => '${s.taskId}|${s.date}|${s.slotIndex}').toSet(),
        reason: '未来段的槽位是重灌的，集合应该一样；变少说明误删了',
      );
      // 历史段也在。
      expect(
        (await db.slotsBetween(
          domain.LocalDate(2026, 3, 1),
          domain.LocalDate(2026, 3, 19),
        )),
        hasLength(19),
      );
    });

  });

  // -------------------------------------------------------------------
  // 「要不要响」和「记不记分母」是两件事。
  //
  // 用户报障「重装了还是老行为，统计里没内容」，查下来就是这两件事被
  // 合成了一句 early return：没给通知权限 → 直接 skipped → 一句都不落库。
  // 于是拒绝通知的人，统计永远是空的，而他其实天天在打卡。
  // 更迷惑的是：那些天打过卡的记录在历史明细里看得见（历史读 checkins），
  // 统计里却什么都没有（统计的分母读 slots）。
  // -------------------------------------------------------------------

  group('没有通知权限，统计也不能是空的', () {
    Future<RescheduleResult> runAt(
      ReminderScheduler scheduler,
      DateTime moment,
    ) {
      return withClock(
        Clock.fixed(moment),
        () => scheduler.reschedule(trigger: RescheduleTrigger.appLaunch),
      );
    }

    test('拒绝通知权限后，本月的槽位照旧补齐', () async {
      gateway.permissionGranted = false;
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      final result = await runAt(build(), DateTime(2026, 3, 20, 9));

      // 一条通知都不该排出去。
      expect(gateway.applied, isEmpty);

      // 但分母要有：1 号到 20 号，20 条。
      final slots = await db.slotsBetween(
        domain.LocalDate(2026, 3, 1),
        domain.LocalDate(2026, 3, 20),
      );
      expect(
        slots,
        hasLength(20),
        reason: '没权限也要记数据。这里为 0，用户看到的就是「统计里没内容」',
      );
      // result.slots 是**整个展开窗口**的槽位数（含今天之后的），
      // 所以它比 20 大，这里只断言"确实展开了"。
      expect(result.slots, greaterThanOrEqualTo(20));
      expect(result.skippedReason, isNotNull, reason: '得让人知道为什么没提醒');
    });

    test('全局关掉提醒，槽位同样照旧落库', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );
      await db.setSetting(SettingsKeys.remindersEnabled, 'false', nowMs: _nowMs);

      await runAt(build(), DateTime(2026, 3, 20, 9));

      expect(
        await db.slotsBetween(
          domain.LocalDate(2026, 3, 1),
          domain.LocalDate(2026, 3, 20),
        ),
        hasLength(20),
        reason: '关掉提醒是「别叫我」，不是「别记我做没做」',
      );
      expect(gateway.applied, isEmpty);
    });

    test('没有精确闹钟权限时降级成不精确，而不是一条都不排', () async {
      // Android 14 起 SCHEDULE_EXACT_ALARM 默认不授予。此时如果还用
      // exactAllowWhileIdle，插件会逐条抛 exact_alarms_not_permitted，
      // 全被吞成日志 → 用户"从来没收到过提醒"。
      gateway.exactGranted = false;
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      final result = await runAt(build(), DateTime(2026, 3, 20, 9));

      expect(
        gateway.lastAllowInexact,
        isTrue,
        reason: '没精确闹钟权限就必须降级，硬用精确模式等于不提醒',
      );
      expect(result.scheduled, greaterThan(0), reason: '降级了也还是得排出去');
      expect(
        result.exactAlarmsMissing,
        isTrue,
        reason: '界面要能告诉用户"会响但可能不准时"',
      );
    });

    test('权限齐了就用精确模式，不白白降级', () async {
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      final result = await runAt(build(), DateTime(2026, 3, 20, 9));

      expect(gateway.lastAllowInexact, isFalse);
      expect(result.exactAlarmsMissing, isFalse);
      expect(result.permissionMissing, isFalse);
    });

    test('没有通知权限时，结果里要标出来（界面据此给「去开启」）', () async {
      gateway.permissionGranted = false;
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );

      final result = await runAt(build(), DateTime(2026, 3, 20, 9));

      expect(
        result.permissionMissing,
        isTrue,
        reason: '不标出来，用户只能猜"为什么它不响"',
      );
      expect(result.scheduled, 0);
      // 数据照记。
      expect(
        await db.slotsBetween(
          domain.LocalDate(2026, 3, 1),
          domain.LocalDate(2026, 3, 20),
        ),
        hasLength(20),
      );
    });

    test('后来给了权限，重排一次就能把提醒补上', () async {
      gateway.permissionGranted = false;
      await db.insertTask(
        _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
        nowMs: _nowMs,
      );
      final scheduler = build();
      await runAt(scheduler, DateTime(2026, 3, 20, 9));
      expect(gateway.applied, isEmpty);

      // 用户去系统设置里把通知打开了，回到 App。
      gateway.permissionGranted = true;
      final result = await withClock(
        Clock.fixed(DateTime(2026, 3, 20, 10)),
        () => scheduler.reschedule(trigger: RescheduleTrigger.resumed),
      );

      // resumed 在同一天会被 `shouldReschedule` 拦住，得靠数据变更放行。
      expect(result.skippedReason, '未跨天，跳过');

      await withClock(
        Clock.fixed(DateTime(2026, 3, 20, 10)),
        () =>
            scheduler.reschedule(trigger: RescheduleTrigger.dataChanged),
      );
      expect(
        gateway.applied,
        isNotEmpty,
        reason: '权限补上了，通知得能重新排出去',
      );
    });
  });

  test('条数上限：宁可少排几天，也绝不越过 56 条', () async {
    // 每 30 分钟一次，一天 20 次 —— 明显超过上限
    for (var i = 0; i < 3; i++) {
      await db.insertTask(
        _task(
          't$i',
          time: domain.FixedTimesRule([
            for (var h = 8; h < 18; h++) domain.LocalTime(h, 0),
          ]),
        ),
        nowMs: _nowMs,
      );
    }

    final result = await run(build());

    expect(result.scheduled, lessThanOrEqualTo(56));
    expect(result.truncated, isTrue);
  });
}
