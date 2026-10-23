import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/rule_text.dart';
import 'package:famdaily/domain/model/task.dart';
import 'package:famdaily/domain/model/task_status.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

Task _task({
  RepeatRule repeat = const RepeatRule(),
  TimeRule? time,
  Course course = Course.none,
  String name = '吃药',
}) => Task(
  id: 't1',
  memberId: 'm1',
  name: name,
  repeat: repeat,
  time: time ?? FixedTimesRule([LocalTime(8, 0)]),
  course: course,
  status: TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

void main() {
  group('重复规则说人话', () {
    test('什么都不限时说「每天」，不说「每周一至周日」', () {
      expect(RuleText.repeat(_task()), '每天');
    });

    test('周几按周一到周日排序，用顿号连', () {
      final t = _task(repeat: const RepeatRule(weekdays: {5, 1, 3}));
      expect(RuleText.repeat(t), '周一、三、五');
    });

    test('多个维度同时给时全部说出来（取交集是排程的事，不是文案的事）', () {
      final t = _task(
        repeat: const RepeatRule(
          weekdays: {1, 3, 5},
          parity: ParityFilter.oddWeeks,
        ),
      );
      expect(RuleText.repeat(t), '周一、三、五 单周');
    });

    test('每 N 天', () {
      final t = _task(
        repeat: RepeatRule(everyNDays: 3, anchor: LocalDate(2025, 3, 1)),
      );
      expect(RuleText.repeat(t), '每 3 天');
    });

    test('每月几号排序后列出', () {
      final t = _task(repeat: const RepeatRule(monthDays: [15, 1]));
      expect(RuleText.repeat(t), '每月 1、15 号');
    });

    test('工作日 / 周末 有专名，不写成「周一至周五」', () {
      expect(
        RuleText.repeat(
          _task(repeat: const RepeatRule(parity: ParityFilter.workdays)),
        ),
        '工作日',
      );
      expect(
        RuleText.repeat(
          _task(repeat: const RepeatRule(parity: ParityFilter.weekends)),
        ),
        '周末',
      );
    });
  });

  group('时刻规则', () {
    test('一次时说「每天 1 次」，钟点单独一行', () {
      final t = _task(time: FixedTimesRule([LocalTime(8, 0)]));
      expect(RuleText.cadence(t), '每天 1 次');
      expect(RuleText.timesLine(t), '8:00');
    });

    test('三次时给出次数和全部钟点', () {
      final t = _task(
        time: FixedTimesRule([
          LocalTime(7, 30),
          LocalTime(12, 30),
          LocalTime(18, 30),
        ]),
      );
      expect(RuleText.cadence(t), '每天 3 次');
      expect(RuleText.timesLine(t), '7:30 / 12:30 / 18:30');
    });

    test('跟随三餐说「一日三次 · 跟早饭、午饭、晚饭」', () {
      final t = _task(
        time: MealTimesRule(
          anchors: [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
        ),
      );
      expect(RuleText.cadence(t), '一日三次 · 跟早饭、午饭、晚饭');
    });

    test('饭后偏移写进同一句', () {
      final t = _task(
        time: MealTimesRule(anchors: [MealAnchor.lunch], offsetMinutes: 30),
      );
      expect(RuleText.cadence(t), '一日一次 · 跟午饭后 30 分钟');
    });

    test('跨午夜的槽位标出「次日」，不让人以为凌晨那次算当天早上', () {
      // 晚饭 18:30 + 8 小时 = 次日 2:30
      final t = _task(
        time: MealTimesRule(anchors: [MealAnchor.dinner], offsetMinutes: 480),
      );
      expect(RuleText.timesLine(t), '次日2:30');
    });

    test('每 2 小时 9:00–21:00 共 7 次', () {
      final t = _task(
        time: IntervalRule(
          everyMinutes: 120,
          from: LocalTime(9, 0),
          to: LocalTime(21, 0),
        ),
      );
      expect(RuleText.cadence(t), '每天 7 次');
      expect(
        RuleText.timesLine(t),
        '9:00 / 11:00 / 13:00 / 15:00 / 17:00 / 19:00 / 21:00',
      );
    });
  });

  group('疗程', () {
    test('长期就说「长期」，不硬凑日期', () {
      expect(RuleText.course(Course.none), '长期');
    });

    test('连 N 天给起止，别只给天数（用户想知道做到哪天）', () {
      final c = Course.days(LocalDate(2025, 10, 24), 7);
      expect(RuleText.course(c), '10月24日 起连着做 7 天（到 10月30日）');
    });

    test('纯区间', () {
      final c = Course.range(LocalDate(2025, 3, 1), LocalDate(2025, 5, 31));
      expect(RuleText.course(c), '3月1日 → 5月31日');
    });

    test('疗程进度：第几天 / 共几天', () {
      final c = Course.days(LocalDate(2025, 10, 24), 7);
      expect(RuleText.courseProgress(c, LocalDate(2025, 10, 26)), '第 3/7 天');
    });

    test('长期没有进度可讲，返回 null 而不是「长期 · 第 1 天」', () {
      expect(
        RuleText.courseProgress(Course.none, LocalDate(2025, 3, 1)),
        isNull,
      );
    });

    test('到期后说「疗程已到期」，不说「还剩 -3 天」', () {
      final c = Course.days(LocalDate(2025, 10, 1), 3);
      expect(RuleText.courseProgress(c, LocalDate(2025, 10, 10)), '疗程已到期');
    });

    test('还没开始时说开始日，不显示「第 0 天」', () {
      final c = Course.range(LocalDate(2025, 12, 1), LocalDate(2025, 12, 7));
      expect(RuleText.courseProgress(c, LocalDate(2025, 11, 20)), '12月1日 才开始');
    });

    test('纯区间形态说「还剩 N 天」，最后一天单独说', () {
      final c = Course.range(LocalDate(2025, 3, 1), LocalDate(2025, 3, 10));
      expect(RuleText.courseProgress(c, LocalDate(2025, 3, 5)), '还剩 5 天');
      expect(RuleText.courseProgress(c, LocalDate(2025, 3, 10)), '今天是最后一天');
    });
  });

  group('详情页头部', () {
    test('三行：频率 / 钟点 / 疗程', () {
      final t = _task(
        repeat: const RepeatRule(weekdays: {1}),
        time: FixedTimesRule([LocalTime(7, 30), LocalTime(19, 0)]),
      );
      expect(RuleText.headlineLines(t), [
        '周一 · 每天 2 次',
        '7:30 / 19:00',
        '疗程：长期',
      ]);
    });
  });
}
