import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/notification/notification_ids.dart';
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/domain/notification/window_policy.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// 快捷构造一个槽位。
Slot _slot(
  String taskId,
  int y,
  int m,
  int d,
  int hh,
  int mm, {
  int index = 0,
  int? rawMinute,
}) {
  final date = LocalDate(y, m, d);
  return Slot(
    taskId: taskId,
    date: date,
    index: index,
    dueAt: LocalDateTimeRef(date, LocalTime(hh, mm)),
    dueMinuteOfDay: rawMinute ?? hh * 60 + mm,
  );
}

void main() {
  group('NotificationIds', () {
    test('同一槽位同一类得到同一个 ID（重排幂等）', () {
      final a = NotificationIds.due('t1', LocalDate(2025, 3, 1), 0);
      final b = NotificationIds.due('t1', LocalDate(2025, 3, 1), 0);
      expect(a, b);
    });

    test('不同项目/日期/序号互不相同', () {
      final base = NotificationIds.due('t1', LocalDate(2025, 3, 1), 0);
      expect(NotificationIds.due('t2', LocalDate(2025, 3, 1), 0), isNot(base));
      expect(NotificationIds.due('t1', LocalDate(2025, 3, 2), 0), isNot(base));
      expect(NotificationIds.due('t1', LocalDate(2025, 3, 1), 1), isNot(base));
    });

    test('提醒与催办的 ID 落不同段，不会互相覆盖', () {
      final due = NotificationIds.due('t1', LocalDate(2025, 3, 1), 0);
      final fu = NotificationIds.followup('t1', LocalDate(2025, 3, 1), 0);
      expect(fu, isNot(due));
      expect(fu, greaterThan(due));
    });

    test('全部落在 int32 正数范围内（Android 只吃 int32）', () {
      for (var i = 0; i < 200; i++) {
        final due = NotificationIds.due('task-$i', LocalDate(2025, 1, 1), i % 5);
        final fu = NotificationIds.followup(
          'task-$i',
          LocalDate(2025, 1, 1),
          i % 5,
        );
        expect(due, greaterThan(0));
        expect(due, lessThanOrEqualTo(0x7FFFFFFF));
        expect(fu, greaterThan(0));
        expect(fu, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });

    test('大量任务+日期的组合碰撞率极低', () {
      // 1000 个任务 × 30 天：3 万条，碰撞超过千分之一就说明哈希选错了。
      final seen = <int>{};
      var total = 0;
      for (var t = 0; t < 1000; t++) {
        for (var d = 0; d < 30; d++) {
          seen.add(
            NotificationIds.due(
              'task-$t',
              LocalDate(2025, 1, 1).addDays(d),
              d % 3,
            ),
          );
          total++;
        }
      }
      expect(seen.length / total, greaterThan(0.999));
    });
  });

  group('QuietHours', () {
    QuietHours qh(int sh, int sm, int eh, int em) =>
        QuietHours(start: LocalTime(sh, sm), end: LocalTime(eh, em));

    test('普通区间：含起点不含终点', () {
      final q = qh(13, 0, 14, 0);
      expect(q.contains(LocalTime(12, 59)), isFalse);
      expect(q.contains(LocalTime(13, 0)), isTrue);
      expect(q.contains(LocalTime(13, 59)), isTrue);
      expect(q.contains(LocalTime(14, 0)), isFalse);
    });

    test('跨午夜区间 22:00-07:00', () {
      final q = qh(22, 0, 7, 0);
      expect(q.contains(LocalTime(23, 0)), isTrue);
      expect(q.contains(LocalTime(3, 0)), isTrue);
      expect(q.contains(LocalTime(6, 59)), isTrue);
      expect(q.contains(LocalTime(7, 0)), isFalse);
      expect(q.contains(LocalTime(12, 0)), isFalse);
      expect(q.contains(LocalTime(21, 59)), isFalse);
    });

    test('起止相同 = 关闭', () {
      final q = qh(0, 0, 0, 0);
      expect(q.isDisabled, isTrue);
      expect(q.contains(LocalTime(3, 0)), isFalse);
    });

    test('顺延到免打扰结束时刻', () {
      final q = qh(22, 0, 7, 0);
      expect(q.shiftOutOf(LocalTime(23, 30)), LocalTime(7, 0));
      expect(q.shiftOutOf(LocalTime(12, 0)), LocalTime(12, 0));
    });
  });

  group('WindowPolicy', () {
    test('每天槽位少 → 排更多天（一槽两条通知，要除以 2）', () {
      const p = WindowPolicy(maxScheduled: 56, minDays: 3, maxDays: 14);
      expect(p.daysFor(1), 14); // 56/(1×2)=28，被 maxDays 压到 14
      expect(p.daysFor(2), 14); // 56/4=14
      expect(p.daysFor(4), 7); // 56/8=7
    });

    test('每天槽位多 → 天数收缩但不低于下限', () {
      const p = WindowPolicy(maxScheduled: 56, minDays: 3, maxDays: 14);
      expect(p.daysFor(10), 3); // 56/20=2 → clamp 到 3
      expect(p.daysFor(100), 3);
    });

    test('没有项目时按最长窗口（省得反复重排）', () {
      const p = WindowPolicy(maxScheduled: 56, minDays: 3, maxDays: 14);
      expect(p.daysFor(0), 14);
    });

    test('endFor 含当天', () {
      const p = WindowPolicy(maxScheduled: 56, minDays: 3, maxDays: 14);
      // 每天 4 个槽位 → 8 条通知/天 → 7 天窗口 → 3/1 到 3/7
      expect(p.endFor(LocalDate(2025, 3, 1), 4), LocalDate(2025, 3, 7));
    });
  });

  group('ReschedulePolicy', () {
    final today = LocalDate(2025, 3, 10);
    final last = LocalDate(2025, 3, 10);

    test('数据变更必定重排', () {
      expect(
        ReschedulePolicy.shouldReschedule(
          trigger: RescheduleTrigger.dataChanged,
          today: today,
          lastScheduledFor: last,
        ),
        isTrue,
      );
    });

    test('回前台但没跨天，不重排', () {
      expect(
        ReschedulePolicy.shouldReschedule(
          trigger: RescheduleTrigger.resumed,
          today: today,
          lastScheduledFor: last,
        ),
        isFalse,
      );
    });

    test('回前台且已跨天，重排', () {
      expect(
        ReschedulePolicy.shouldReschedule(
          trigger: RescheduleTrigger.resumed,
          today: LocalDate(2025, 3, 11),
          lastScheduledFor: last,
        ),
        isTrue,
      );
    });
  });

  group('NotificationPlanner', () {
    final labels = {
      't1': (taskName: '吃降压药', memberName: '妈妈'),
      't2': (taskName: '跳绳', memberName: '小明'),
    };

    test('正常排一条提醒 + 一条催办', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(7, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
      );

      expect(planned, hasLength(2));
      expect(planned[0].kind, ReminderKind.due);
      expect(planned[0].at.time, LocalTime(8, 0));
      expect(planned[1].kind, ReminderKind.followup);
      expect(planned[1].at.time, LocalTime(8, 15));
      expect(planned[0].title, '吃降压药');
      expect(planned[0].body, '妈妈');
    });

    test('已结案的槽位一条都不排', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(7, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
        filters: PlannedFilters(
          doneKeys: {
            PlannedFilters.keyOf('t1', LocalDate(2025, 3, 1), 0),
          },
        ),
      );
      expect(planned, isEmpty);
    });

    test('已经过去的时刻不排（否则打开 App 就被轰炸）', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(9, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
      );
      // 8:00 已过；8:15 也过了 → 一条都不排
      expect(planned, isEmpty);
    });

    test('提醒刚过但催办还没到点，只排催办', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(8, 5));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
      );
      expect(planned, hasLength(1));
      expect(planned.single.kind, ReminderKind.followup);
    });

    test('全局关闭提醒时什么都不排', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(7, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
        filters: const PlannedFilters(remindersEnabled: false),
      );
      expect(planned, isEmpty);
    });

    test('labels 里没有的项目不排（提醒关闭的项目走这条路）', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(7, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t9', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
      );
      expect(planned, isEmpty);
    });

    test('免打扰顺延：22:30 的药提醒推到次日 07:00', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(20, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 22, 30)],
        labels: labels,
        now: now,
        filters: PlannedFilters(
          quietHours: QuietHours(
            start: LocalTime(22, 0),
            end: LocalTime(7, 0),
          ),
        ),
      );

      final due = planned.firstWhere((p) => p.kind == ReminderKind.due);
      expect(due.at.date, LocalDate(2025, 3, 2));
      expect(due.at.time, LocalTime(7, 0));
    });

    test('提醒在免打扰前、催办正好落进免打扰：只顺延催办', () {
      // 21:55 提醒正常发出；21:55+15=22:10 落在 22:00-07:00 里，
      // 顺延到次日 07:00 —— 比"21:55 就催"晚得多，但比丢掉好。
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(20, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 21, 55)],
        labels: labels,
        now: now,
        filters: PlannedFilters(
          quietHours: QuietHours(
            start: LocalTime(22, 0),
            end: LocalTime(7, 0),
          ),
        ),
      );

      final due = planned.firstWhere((p) => p.kind == ReminderKind.due);
      expect(due.at.time, LocalTime(21, 55));

      final fu = planned.firstWhere((p) => p.kind == ReminderKind.followup);
      expect(fu.at.date, LocalDate(2025, 3, 2));
      expect(fu.at.time, LocalTime(7, 0));
    });

    test('提醒被顺延到免打扰结束后，催办跟着排在它之后', () {
      // 22:50 的提醒推到次日 07:00，催办自然落在 07:15，两者不重合。
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(20, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 22, 50)],
        labels: labels,
        now: now,
        filters: PlannedFilters(
          quietHours: QuietHours(
            start: LocalTime(22, 0),
            end: LocalTime(7, 0),
          ),
        ),
      );

      expect(planned, hasLength(2));
      expect(planned.first.at.time, LocalTime(7, 0));
      expect(planned.last.at.time, LocalTime(7, 15));
    });

    test('催办延迟可调', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(7, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 8, 0)],
        labels: labels,
        now: now,
        filters: const PlannedFilters(followupDelayMinutes: 30),
      );
      final fu = planned.firstWhere((p) => p.kind == ReminderKind.followup);
      expect(fu.at.time, LocalTime(8, 30));
    });

    test('跨午夜的槽位，催办正确进位到次日', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(20, 0));
      final planned = NotificationPlanner.plan(
        expanded: [_slot('t1', 2025, 3, 1, 23, 55)],
        labels: labels,
        now: now,
      );
      final fu = planned.firstWhere((p) => p.kind == ReminderKind.followup);
      expect(fu.at.date, LocalDate(2025, 3, 2));
      expect(fu.at.time, LocalTime(0, 10));
    });

    test('结果按真实时刻排序，跨天也正确', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(0, 0));
      final planned = NotificationPlanner.plan(
        expanded: [
          _slot('t2', 2025, 3, 1, 23, 52), // 疗程日是 1 号，但 23:52
          _slot('t1', 2025, 3, 1, 8, 0),
          _slot('t1', 2025, 3, 2, 8, 0),
        ],
        labels: labels,
        now: now,
      );

      // 8:00(1号) → 8:15 → 8:00(2号) → 8:15 → 23:52 → 次日 00:07
      final times = planned.map((p) => '${p.at.date} ${p.at.time}').toList();
      final sortedCopy = [...times]..sort();
      expect(times, sortedCopy);
    });

    test('cap 截断保留最近的，不留尾巴', () {
      final now = LocalDateTimeRef(LocalDate(2025, 3, 1), LocalTime(0, 0));
      final slots = [
        for (var d = 0; d < 10; d++) _slot('t1', 2025, 3, 1 + d, 8, 0),
      ];
      final planned = NotificationPlanner.plan(
        expanded: slots,
        labels: labels,
        now: now,
      );
      expect(planned, hasLength(20));

      final capped = NotificationPlanner.cap(planned, 6);
      expect(capped, hasLength(6));
      expect(capped.first.at.date, LocalDate(2025, 3, 1));
      expect(capped.last.at.date, LocalDate(2025, 3, 3));
    });

    test('cap 的 maxCount 为 0 时不排', () {
      expect(NotificationPlanner.cap([], 0), isEmpty);
      expect(NotificationPlanner.cap([], 10), isEmpty);
    });
  });
}
