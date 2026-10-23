import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:flutter_test/flutter_test.dart';

final someDay = LocalDate(2026, 10, 23);

List<String> fmt(List<LocalTime> ts) => ts.map((e) => e.toString()).toList();

void main() {
  group('FixedTimesRule', () {
    test('自动排序去重', () {
      final r = FixedTimesRule([
        LocalTime(20, 0),
        LocalTime(8, 0),
        LocalTime(20, 0),
        LocalTime(12, 0),
      ]);
      expect(fmt(r.timesOn(someDay)), ['08:00', '12:00', '20:00']);
    });

    test('单次', () {
      final r = FixedTimesRule([LocalTime(20, 0)]);
      expect(fmt(r.timesOn(someDay)), ['20:00']);
    });

    test('相等', () {
      final a = FixedTimesRule([LocalTime(8, 0), LocalTime(20, 0)]);
      final b = FixedTimesRule([LocalTime(20, 0), LocalTime(8, 0)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('IntervalRule（含起含止 = 7 条，已定语义）', () {
    test('每 2 小时，9:00–21:00 → 7 条', () {
      final r = IntervalRule(
        everyMinutes: 120,
        from: LocalTime(9, 0),
        to: LocalTime(21, 0),
      );
      expect(fmt(r.times()), [
        '09:00',
        '11:00',
        '13:00',
        '15:00',
        '17:00',
        '19:00',
        '21:00',
      ]);
      expect(r.count, 7);
    });

    test('不能整除时到 to 之前为止', () {
      final r = IntervalRule(
        everyMinutes: 240,
        from: LocalTime(9, 0),
        to: LocalTime(21, 0),
      );
      // 9, 13, 17, 21
      expect(fmt(r.times()), ['09:00', '13:00', '17:00', '21:00']);
    });

    test('from >= to 非法', () {
      expect(
        () => IntervalRule(
          everyMinutes: 60,
          from: LocalTime(21, 0),
          to: LocalTime(9, 0),
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => IntervalRule(
          everyMinutes: 60,
          from: LocalTime(9, 0),
          to: LocalTime(9, 0),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('间隔必须为正', () {
      expect(
        () => IntervalRule(
          everyMinutes: 0,
          from: LocalTime(9, 0),
          to: LocalTime(10, 0),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('MealTimesRule', () {
    test('三餐原样（偏移 0）', () {
      final r = MealTimesRule(
        anchors: [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
      );
      expect(fmt(r.timesOn(someDay)), ['07:30', '12:00', '18:30']);
    });

    test('饭后 30 分钟', () {
      final r = MealTimesRule(
        anchors: [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
        offsetMinutes: 30,
      );
      expect(fmt(r.timesOn(someDay)), ['08:00', '12:30', '19:00']);
    });

    test('饭前 30 分钟', () {
      final r = MealTimesRule(
        anchors: [MealAnchor.lunch],
        offsetMinutes: -30,
      );
      expect(fmt(r.timesOn(someDay)), ['11:30']);
    });

    test('自定义锚点时刻并排序', () {
      final r = MealTimesRule(
        anchors: [MealAnchor.dinner, MealAnchor.breakfast],
        anchorOverrides: {
          MealAnchor.dinner: LocalTime(19, 0),
          MealAnchor.breakfast: LocalTime(6, 0),
        },
      );
      expect(fmt(r.timesOn(someDay)), ['06:00', '19:00']);
    });

    test('偏移跨午夜时，timesOn 返回包裹后的时刻（跨天由展开器处理）', () {
      final r = MealTimesRule(
        anchors: [MealAnchor.dinner],
        offsetMinutes: 240,
        anchorOverrides: {MealAnchor.dinner: LocalTime(21, 0)},
      );
      expect(fmt(r.timesOn(someDay)), ['01:00']);
    });

    test('相等', () {
      final a = MealTimesRule(anchors: [MealAnchor.lunch, MealAnchor.dinner]);
      final b = MealTimesRule(anchors: [MealAnchor.dinner, MealAnchor.lunch]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('CombinedTimeRule（多个时间段相加）', () {
    test('上午 9/11 + 下午 15/17', () {
      final r = CombinedTimeRule([
        FixedTimesRule([LocalTime(9, 0), LocalTime(11, 0)]),
        FixedTimesRule([LocalTime(15, 0), LocalTime(17, 0)]),
      ]);
      expect(fmt(r.timesOn(someDay)), ['09:00', '11:00', '15:00', '17:00']);
    });

    test('重叠时刻去重', () {
      final r = CombinedTimeRule([
        FixedTimesRule([LocalTime(9, 0)]),
        FixedTimesRule([LocalTime(9, 0), LocalTime(18, 0)]),
      ]);
      expect(fmt(r.timesOn(someDay)), ['09:00', '18:00']);
    });

    test('固定 + 间隔混合', () {
      final r = CombinedTimeRule([
        IntervalRule(
          everyMinutes: 120,
          from: LocalTime(9, 0),
          to: LocalTime(11, 0),
        ),
        FixedTimesRule([LocalTime(21, 0)]),
      ]);
      expect(fmt(r.timesOn(someDay)), ['09:00', '11:00', '21:00']);
    });
  });
}
