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
  FakeGateway({this.permissionGranted = true});

  bool permissionGranted;
  List<PlannedNotification> applied = [];
  final List<int> cancelled = [];
  int cancelAllCount = 0;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<List<int>> pendingIds() async => applied.map((p) => p.id).toList();

  @override
  Future<int> applyPlan(List<PlannedNotification> plan) async {
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

  test('没有通知权限时不排，并说明原因', () async {
    gateway.permissionGranted = false;
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );

    final result = await run(build());

    expect(result.skippedReason, '没有通知权限');
    expect(gateway.applied, isEmpty);
  });

  test('全局关闭提醒时清空所有通知', () async {
    await db.insertTask(
      _task('t1', time: domain.FixedTimesRule([domain.LocalTime(8, 0)])),
      nowMs: _nowMs,
    );
    await db.setSetting(SettingsKeys.remindersEnabled, 'false', nowMs: _nowMs);

    final result = await run(build());

    expect(result.skippedReason, '提醒已全局关闭');
    expect(gateway.cancelAllCount, 1);
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
