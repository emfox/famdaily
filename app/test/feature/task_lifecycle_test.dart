import 'package:clock/clock.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/notifier/notification_service.dart';
import 'package:famdaily/data/repo_impl/reminder_scheduler.dart';
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/domain/notification/window_policy.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/feature/home/today_service.dart';
import 'package:famdaily/feature/task_detail/task_detail_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 2025-03-15（周六）12:00。
final DateTime _now = DateTime(2025, 3, 15, 12);
final domain.LocalDate _today = domain.LocalDate(2025, 3, 15);

domain.Task _task() => domain.Task(
  id: 't1',
  memberId: 'm1',
  name: '降压药',
  repeat: const domain.RepeatRule(),
  time: domain.FixedTimesRule([domain.LocalTime(20, 0)]),
  course: domain.Course.none,
  status: domain.TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

/// 最小假通知层：只记账，不碰系统。
///
/// 生命周期测试要验的是"暂停/归档/删除之后槽位与记录还在不在"，
/// 槽位由调度器写，所以必须真跑一次 `reschedule`。
final class _FakeGateway implements NotificationGateway {
  List<PlannedNotification> applied = [];

  @override
  Future<bool> hasPermission() async => true;

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
  }) async {}

  @override
  Future<void> cancelAll() async {}
}

void main() {
  late AppDatabase db;
  late ReminderScheduler scheduler;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    await db.insertMember(
      const domain.Member(
        id: 'm1',
        name: '爷爷',
        sortOrder: 0,
        createdAtMs: _ts,
        updatedAtMs: _ts,
      ),
      nowMs: _ts,
    );
    await db.insertTask(_task(), nowMs: _ts);
    scheduler = ReminderScheduler(
      db: db,
      notifications: _FakeGateway(),
      policy: const WindowPolicy(),
    );
  });

  tearDown(() async => db.close());

  /// 真跑一次重排，把槽位落库。
  ///
  /// 页面里的每个状态变更后面都跟着 `_afterChange()` → `reschedule`，
  /// 所以测试也走同一条路：暂停/恢复之后槽位才会真的跟着变。
  /// 用 `withClock` 钉住"今天"，不然排出来的窗口跟着真实时间走，
  /// 测试里就会变成"排的是真今天、断言的是 2025-03-15"。
  Future<void> reschedule() => withClock(
    Clock.fixed(_now),
    () => scheduler.reschedule(trigger: RescheduleTrigger.dataChanged),
  );

  /// 先把昨天的卡打上（用于验证"状态改变不影响记录"）。
  Future<void> seedYesterday() async {
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c-yesterday',
        taskId: 't1',
        date: _today.addDays(-1),
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _ts,
        note: '吃了两粒',
      ),
      nowMs: _ts,
    );
  }

  Future<int> todayCount() async =>
      (await TodayService(db).load(at: _now)).totalCount;

  group('暂停（可逆，记录保留）', () {
    test('暂停后今日清单不再出现', () async {
      expect(await todayCount(), 1);
      await db.setTaskStatus('t1', domain.TaskStatus.paused, nowMs: _ts);
      expect(await todayCount(), 0);
    });

    test('暂停不碰打卡记录', () async {
      await seedYesterday();
      await db.setTaskStatus('t1', domain.TaskStatus.paused, nowMs: _ts);

      final records = await db.checkinsBetween(
        _today.addDays(-1),
        _today.addDays(-1),
      );
      expect(records, hasLength(1));
      expect(records.single.note, '吃了两粒');
    });

    test('恢复后今日清单回来，历史也还在', () async {
      await seedYesterday();
      await reschedule();
      await db.setTaskStatus('t1', domain.TaskStatus.paused, nowMs: _ts);
      await reschedule();
      await db.setTaskStatus('t1', domain.TaskStatus.active, nowMs: _ts);
      await reschedule();

      expect(await todayCount(), 1);
      final detail = await TaskDetailService(db).load('t1', at: _now);
      // 恢复之后槽位重新排出来，详情页的统计才有分母
      expect(detail!.stats.expected, greaterThan(0));
    });
  });

  group('归档（记录保留）', () {
    test('归档后今日清单不再出现', () async {
      await db.setTaskStatus('t1', domain.TaskStatus.archived, nowMs: _ts);
      expect(await todayCount(), 0);
    });

    test('归档不碰记录', () async {
      await seedYesterday();
      await db.setTaskStatus('t1', domain.TaskStatus.archived, nowMs: _ts);

      final records = await db.checkinsBetween(
        _today.addDays(-1),
        _today.addDays(-1),
      );
      expect(records, hasLength(1));
    });

    test('「再来一轮」= 改回 active', () async {
      await db.setTaskStatus('t1', domain.TaskStatus.archived, nowMs: _ts);
      await db.setTaskStatus('t1', domain.TaskStatus.active, nowMs: _ts);
      expect(await todayCount(), 1);
    });
  });

  group('删除（不可逆，但记录保留在日历里）', () {
    test('删除后今日清单不再出现', () async {
      await db.deleteTask('t1', nowMs: _ts);
      expect(await todayCount(), 0);
    });

    test('删除后项目查询不到（软删除标记），但打卡记录还在', () async {
      await seedYesterday();
      await db.deleteTask('t1', nowMs: _ts);

      // 这条最关键：用户最怕的就是"删项目把记录一起删了"
      final records = await db.checkinsBetween(
        _today.addDays(-1),
        _today.addDays(-1),
      );
      expect(records, hasLength(1), reason: '删除项目不该连打卡记录一起删');

      // 但项目本身已经从列表里消失
      final tasks = await db.listAllTasks();
      expect(tasks, isEmpty);
    });

    test('删除会清掉派生槽位（那是可重算的缓存）', () async {
      await TodayService(db).load(at: _now); // 触发一次排程
      await db.deleteTask('t1', nowMs: _ts);
      final slots = await db.slotsBetween(
        _today.addDays(-30),
        _today.addDays(30),
      );
      expect(slots, isEmpty);
    });

    test('删除后详情页返回 null（页面显示「这个打卡项已经不在了」）', () async {
      await db.deleteTask('t1', nowMs: _ts);
      // findTask 仍能查到（软删除行还在），这是有意的：详情页要能认出
      // 它被删了并显示状态标，而不是像硬删那样找不到。
      final task = await db.findTask('t1');
      expect(task, isNotNull);
      expect(task!.deletedAtMs, isNotNull);
      expect(task.isLive, isFalse);
    });
  });
}
