import 'package:famdaily/domain/model/checkin.dart';
import 'package:famdaily/domain/model/checkin_row.dart';
import 'package:famdaily/domain/model/checkin_state.dart';
import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/task.dart';
import 'package:famdaily/domain/model/task_status.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

final today = LocalDate(2026, 10, 23);

Task task({
  String id = 't1',
  TaskStatus status = TaskStatus.active,
  bool reminder = true,
}) => Task(
  id: id,
  memberId: 'm1',
  name: '降压药',
  repeat: RepeatRule.daily,
  time: FixedTimesRule([LocalTime(8, 0)]),
  course: Course.none,
  status: status,
  reminderEnabled: reminder,
  createdAtMs: 0,
  updatedAtMs: 0,
);

CheckinRow row({
  CheckinState? state,
  LocalDate? date,
  int dueMinute = 480,
  Task? t,
}) => CheckinRow(
  task: t ?? task(),
  date: date ?? today,
  slotIndex: 0,
  dueAt: LocalDateTimeRef.fromDayAndMinute(date ?? today, dueMinute),
  dueMinuteOfDay: dueMinute,
  record: state == null
      ? null
      : CheckinRecord(
          id: 'c1',
          taskId: t?.id ?? 't1',
          date: date ?? today,
          slotIndex: 0,
          state: state,
        ),
);

void main() {
  group('EditWindow（决策 3：30 天）', () {
    test('今天、过去 30 天可改', () {
      expect(EditWindow.canEdit(today, today), isTrue);
      expect(EditWindow.canEdit(today.addDays(-30), today), isTrue);
    });

    test('第 31 天开始不可改', () {
      expect(EditWindow.canEdit(today.addDays(-31), today), isFalse);
      expect(EditWindow.isExpired(today.addDays(-31), today), isTrue);
    });

    test('未来日期不能打卡', () {
      expect(EditWindow.canEdit(today.addDays(1), today), isFalse);
    });

    test('daysLeft 边界', () {
      expect(EditWindow.daysLeft(today, today), 30);
      expect(EditWindow.daysLeft(today.addDays(-30), today), 0);
      expect(EditWindow.daysLeft(today.addDays(-31), today), isNull);
    });
  });

  group('五态判定（ui-spec 的记忆口诀）', () {
    test('未到时间 = 空心待做', () {
      expect(
        row(dueMinute: 20 * 60).visual(today, LocalTime(9, 0)),
        CheckinVisual.pending,
      );
    });

    test('今天已过时间 = 淡红 + 迟到', () {
      final r = row(dueMinute: 8 * 60);
      expect(r.visual(today, LocalTime(9, 15)), CheckinVisual.overdue);
      expect(r.lateMinutes(LocalTime(9, 15)), 75);
    });

    test('过去的日子没记录 = 已过时间', () {
      expect(
        row(date: today.addDays(-1)).visual(today, LocalTime(9, 0)),
        CheckinVisual.overdue,
      );
    });

    test('完成 = 准时（哪怕现在还没到点）', () {
      expect(
        row(state: CheckinState.done, dueMinute: 20 * 60)
            .visual(today, LocalTime(9, 0)),
        CheckinVisual.doneOnTime,
      );
    });

    test('补卡 = 空心绿勾', () {
      expect(
        row(state: CheckinState.makeup).visual(today, LocalTime(9, 0)),
        CheckinVisual.doneMakeup,
      );
    });

    test('没做 = 灰叉，不是红', () {
      expect(
        row(state: CheckinState.skipped).visual(today, LocalTime(9, 0)),
        CheckinVisual.skipped,
      );
    });
  });

  group('跨午夜的展示时刻归一', () {
    test('次日 01:00（1500 分钟）显示为 01:00', () {
      final r = row(dueMinute: 1500);
      expect(r.lateMinutes(LocalTime(1, 30)), 30);
    });

    test('前日 23:30（-30 分钟）显示为 23:30，不能被 % 截断成负数', () {
      final r = row(dueMinute: -30);
      // -30 分钟 → 前一日 23:30，归一后 1410
      expect(r.lateMinutes(LocalTime(23, 45)), 15);
    });
  });

  group('Task 状态语义', () {
    test('只有 active 参与排程', () {
      expect(task().isLive, isTrue);
      expect(task(status: TaskStatus.paused).isLive, isFalse);
      expect(task(status: TaskStatus.archived).isLive, isFalse);
      expect(task(status: TaskStatus.deleted).isLive, isFalse);
    });

    test('提醒开关不影响是否生成待办', () {
      expect(task(reminder: false).isLive, isTrue);
    });

    test('timesPerDayHint', () {
      expect(task().timesPerDayHint, 1);
      final three = Task(
        id: 't2',
        memberId: 'm1',
        name: '三餐药',
        repeat: RepeatRule.daily,
        time: MealTimesRule(
          anchors: [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
        ),
        course: Course.none,
        status: TaskStatus.active,
        createdAtMs: 0,
        updatedAtMs: 0,
      );
      expect(three.timesPerDayHint, 3);
    });
  });

  group('CheckinState 的数据库值', () {
    test('显式字符串，不依赖枚举顺序', () {
      expect(CheckinState.done.dbValue, 'done');
      expect(CheckinState.makeup.dbValue, 'makeup');
      expect(CheckinState.skipped.dbValue, 'skipped');
      expect(checkinStateFromDb('done'), CheckinState.done);
      expect(checkinStateFromDb('unknown'), isNull);
      expect(checkinStateFromDb(null), isNull);
    });

    test('统计口径', () {
      expect(CheckinState.done.countsAsDone, isTrue);
      expect(CheckinState.done.countsAsOnTime, isTrue);
      expect(CheckinState.makeup.countsAsDone, isTrue);
      expect(CheckinState.makeup.countsAsOnTime, isFalse);
      expect(CheckinState.skipped.countsAsDone, isFalse);
    });
  });
}
