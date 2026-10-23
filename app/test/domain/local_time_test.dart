import 'package:famdaily/domain/model/local_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalTime 构造', () {
    test('合法', () {
      final t = LocalTime(8, 5);
      expect(t.hour, 8);
      expect(t.minute, 5);
      expect(t.minuteOfDay, 485);
      expect(t.toString(), '08:05');
    });

    test('边界 00:00 与 23:59', () {
      expect(LocalTime(0, 0).minuteOfDay, 0);
      expect(LocalTime(23, 59).minuteOfDay, 1439);
    });

    test('非法抛 ArgumentError', () {
      expect(() => LocalTime(24, 0), throwsArgumentError);
      expect(() => LocalTime(-1, 0), throwsArgumentError);
      expect(() => LocalTime(0, 60), throwsArgumentError);
    });

    test('fromMinuteOfDay 往返', () {
      for (final m in [0, 1, 59, 60, 480, 1439]) {
        expect(LocalTime.fromMinuteOfDay(m).minuteOfDay, m);
      }
      expect(() => LocalTime.fromMinuteOfDay(1440), throwsArgumentError);
      expect(() => LocalTime.fromMinuteOfDay(-1), throwsArgumentError);
    });
  });

  group('addMinutes（关键：跨天必须看得见）', () {
    test('不跨天', () {
      final (days, t) = LocalTime(12, 0).addMinutes(30);
      expect(days, 0);
      expect(t, LocalTime(12, 30));
    });

    test('跨到次日凌晨', () {
      final (days, t) = LocalTime(23, 30).addMinutes(60);
      expect(days, 1);
      expect(t, LocalTime(0, 30));
    });

    test('正好跨 24 小时', () {
      final (days, t) = LocalTime(18, 30).addMinutes(1440);
      expect(days, 1);
      expect(t, LocalTime(18, 30));
    });

    test('负数（饭前）跨到前一日', () {
      final (days, t) = LocalTime(0, 30).addMinutes(-60);
      expect(days, -1);
      expect(t, LocalTime(23, 30));
    });

    test('回归：宵夜 21:00 饭后 240 分钟 = 次日 01:00', () {
      final (days, t) = LocalTime(21, 0).addMinutes(240);
      expect(days, 1);
      expect(t, LocalTime(1, 0));
    });
  });

  group('比较', () {
    test('isBetween 含端点', () {
      final from = LocalTime(9, 0);
      final to = LocalTime(21, 0);
      expect(LocalTime(9, 0).isBetween(from, to), isTrue);
      expect(LocalTime(21, 0).isBetween(from, to), isTrue);
      expect(LocalTime(8, 59).isBetween(from, to), isFalse);
      expect(LocalTime(21, 1).isBetween(from, to), isFalse);
    });

    test('from > to 视为空区间', () {
      expect(
        LocalTime(12, 0).isBetween(LocalTime(21, 0), LocalTime(9, 0)),
        isFalse,
      );
    });

    test('排序', () {
      final list = [LocalTime(20, 0), LocalTime(8, 0), LocalTime(12, 30)]
        ..sort();
      expect(list.map((e) => e.toString()), ['08:00', '12:30', '20:00']);
    });

    test('相等', () {
      expect(LocalTime(8, 0), LocalTime(8, 0));
      expect(LocalTime(8, 0).hashCode, LocalTime(8, 0).hashCode);
      expect(LocalTime(8, 0) == LocalTime(8, 1), isFalse);
    });
  });

  group('parse', () {
    test('往返', () {
      for (final s in ['00:00', '08:05', '23:59']) {
        expect(LocalTime.parse(s).toString(), s);
      }
    });

    test('非法格式', () {
      expect(() => LocalTime.parse('8'), throwsFormatException);
      expect(() => LocalTime.parse('08:05:00'), throwsFormatException);
    });
  });

  group('三餐锚点', () {
    test('默认时刻有序', () {
      expect(
        MealAnchor.breakfast.defaultTime.isBefore(MealAnchor.lunch.defaultTime),
        isTrue,
      );
      expect(
        MealAnchor.lunch.defaultTime.isBefore(MealAnchor.dinner.defaultTime),
        isTrue,
      );
    });
  });
}
