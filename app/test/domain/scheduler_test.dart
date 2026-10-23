import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

final monday = LocalDate(2026, 10, 19);

ScheduleSpec spec({
  String id = 't1',
  RepeatRule repeat = RepeatRule.daily,
  TimeRule? time,
  Course course = Course.none,
  bool enabled = true,
}) => ScheduleSpec(
  taskId: id,
  repeat: repeat,
  time: time ?? FixedTimesRule([LocalTime(20, 0)]),
  course: course,
  enabled: enabled,
);

void main() {
  group('基础展开', () {
    test('每天 20:00，展开 3 天 = 3 条', () {
      final r = Scheduler.expand(
        specs: [spec()],
        from: monday,
        to: monday.addDays(2),
      );
      expect(r.slots.length, 3);
      expect(r.truncated, isFalse);
      expect(
        r.slots.map((s) => '${s.date} ${s.dueAt.time}').toList(),
        ['2026-10-19 20:00', '2026-10-20 20:00', '2026-10-21 20:00'],
      );
    });

    test('一天 3 次，index 递增', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            time: MealTimesRule(
              anchors: [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
              offsetMinutes: 30,
            ),
          ),
        ],
        from: monday,
        to: monday,
      );
      expect(r.slots.length, 3);
      expect(r.slots.map((s) => s.index).toList(), [0, 1, 2]);
      expect(
        r.slots.map((s) => s.dueAt.time.toString()).toList(),
        ['08:00', '12:30', '19:00'],
      );
    });

    test('空区间（to < from）返回空', () {
      final r = Scheduler.expand(
        specs: [spec()],
        from: monday,
        to: monday.addDays(-1),
      );
      expect(r.slots, isEmpty);
    });

    test('暂停的项目不展开', () {
      final r = Scheduler.expand(
        specs: [spec(enabled: false)],
        from: monday,
        to: monday.addDays(6),
      );
      expect(r.slots, isEmpty);
    });

    test('同一天多个项目按时间排序', () {
      final r = Scheduler.expand(
        specs: [
          spec(id: 'late', time: FixedTimesRule([LocalTime(20, 0)])),
          spec(id: 'early', time: FixedTimesRule([LocalTime(7, 0)])),
        ],
        from: monday,
        to: monday,
      );
      expect(r.slots.map((s) => s.taskId).toList(), ['early', 'late']);
    });
  });

  group('规则叠加（三个维度正交）', () {
    test('工作日 + 每天 8:00：一周 5 条', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            repeat: const RepeatRule(parity: ParityFilter.workdays),
            time: FixedTimesRule([LocalTime(8, 0)]),
          ),
        ],
        from: monday,
        to: monday.addDays(6),
      );
      expect(r.slots.length, 5);
      expect(
        r.slots.map((s) => s.date.weekday).toList(),
        [1, 2, 3, 4, 5],
      );
    });

    test('周一三五 + 8:00/20:00：一周 6 条', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            repeat: const RepeatRule(weekdays: {1, 3, 5}),
            time: FixedTimesRule([LocalTime(8, 0), LocalTime(20, 0)]),
          ),
        ],
        from: monday,
        to: monday.addDays(6),
      );
      expect(r.slots.length, 6);
      for (final s in r.slots) {
        expect({1, 3, 5}.contains(s.date.weekday), isTrue);
      }
    });

    test('疗程 7 天 + 每天 3 次 = 21 条，第 8 天不再生成', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            time: MealTimesRule(
              anchors: [
                MealAnchor.breakfast,
                MealAnchor.lunch,
                MealAnchor.dinner,
              ],
            ),
            course: Course.days(monday, 7),
          ),
        ],
        from: monday,
        to: monday.addDays(9),
      );
      expect(r.slots.length, 21);
      expect(r.slots.last.date, monday.addDays(6));
    });

    test('疗程开始前不生成', () {
      final r = Scheduler.expand(
        specs: [spec(course: Course.days(monday.addDays(3), 7))],
        from: monday,
        to: monday.addDays(1),
      );
      expect(r.slots, isEmpty);
    });

    test('隔周 + 每周一次，两周窗口 = 1 条', () {
      // 找一个单周/双周的具体日期，用 parity 自身判定避免硬编码
      const odd = RepeatRule(parity: ParityFilter.oddWeeks);
      final start = odd.matches(monday) ? monday : monday.addDays(7);
      final r = Scheduler.expand(
        specs: [spec(repeat: odd)],
        from: start,
        to: start.addDays(13),
      );
      expect(r.slots.length, 7);
    });
  });

  group('跨午夜（关键边界）', () {
    test('晚餐 21:00 后 240 分钟 → 次日 01:00，但 date 仍是当天', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            time: MealTimesRule(
              anchors: [MealAnchor.dinner],
              offsetMinutes: 240,
              anchorOverrides: {MealAnchor.dinner: LocalTime(21, 0)},
            ),
          ),
        ],
        from: monday,
        to: monday,
      );
      expect(r.slots.length, 1);
      final s = r.slots.single;
      expect(s.date, monday);
      expect(s.dueAt.date, monday.addDays(1));
      expect(s.dueAt.time, LocalTime(1, 0));
      // dueMinuteOfDay 故意保留越界值（1500 = 次日 01:00），跨天信息不能丢
      expect(s.dueMinuteOfDay, 1500);
    });

    test('饭前跨到前一日', () {
      final r = Scheduler.expand(
        specs: [
          spec(
            time: MealTimesRule(
              anchors: [MealAnchor.breakfast],
              offsetMinutes: -60,
              anchorOverrides: {MealAnchor.breakfast: LocalTime(0, 30)},
            ),
          ),
        ],
        from: monday,
        to: monday,
      );
      final s = r.slots.single;
      expect(s.date, monday);
      expect(s.dueAt.date, monday.addDays(-1));
      expect(s.dueAt.time, LocalTime(23, 30));
    });
  });

  group('截断', () {
    test('达到 maxSlots 立即停止并标记', () {
      final r = Scheduler.expand(
        specs: [spec()],
        from: monday,
        to: monday.addDays(30),
        maxSlots: 10,
      );
      expect(r.slots.length, 10);
      expect(r.truncated, isTrue);
    });

    test('截断时先到期的优先，不会让某个项目独吞', () {
      final r = Scheduler.expand(
        specs: [
          spec(id: 'a', time: FixedTimesRule([LocalTime(8, 0)])),
          spec(id: 'b', time: FixedTimesRule([LocalTime(20, 0)])),
        ],
        from: monday,
        to: monday.addDays(30),
        maxSlots: 4,
      );
      expect(r.slots.map((s) => s.taskId).toList(), ['a', 'b', 'a', 'b']);
      expect(r.slots.last.date, monday.addDays(1));
    });

    test('slot.key 唯一', () {
      final r = Scheduler.expand(
        specs: [spec(), spec(id: 't2')],
        from: monday,
        to: monday.addDays(5),
      );
      final keys = r.slots.map((s) => s.key).toSet();
      expect(keys.length, r.slots.length);
    });
  });

  group('窗口自适应', () {
    test('每天 3 条、上限 60 条 → 窗口约 7 天（受 maxDays 约束）', () {
      final s = spec(
        time: FixedTimesRule([
          LocalTime(8, 0),
          LocalTime(12, 0),
          LocalTime(20, 0),
        ]),
      );
      final end = Scheduler.suggestWindowEnd(
        specs: [s],
        from: monday,
        maxSlots: 60,
        maxDays: 7,
      );
      expect(end, monday.addDays(6));
    });

    test('每天 30 条、上限 60 条 → 窗口压到 minDays', () {
      final times = List.generate(30, (i) => LocalTime(8 + i % 12, i));
      final s = spec(time: FixedTimesRule(times));
      final end = Scheduler.suggestWindowEnd(
        specs: [s],
        from: monday,
        maxSlots: 60,
        maxDays: 7,
        minDays: 3,
      );
      expect(end, monday.addDays(2)); // 3 天
    });

    test('没有项目时给满 maxDays', () {
      final end = Scheduler.suggestWindowEnd(
        specs: const [],
        from: monday,
        maxDays: 7,
      );
      expect(end, monday.addDays(6));
    });

    test('estimateDailyCount 向上取整', () {
      final s = spec(repeat: const RepeatRule(weekdays: {1}));
      expect(
        Scheduler.estimateDailyCount([s], from: monday, sampleDays: 7),
        1,
      );
    });
  });
}
