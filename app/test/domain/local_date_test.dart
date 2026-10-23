import 'package:famdaily/domain/model/local_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalDate 基本构造', () {
    test('合法日期', () {
      final d = LocalDate(2026, 10, 23);
      expect(d.year, 2026);
      expect(d.month, 10);
      expect(d.day, 23);
      expect(d.toString(), '2026-10-23');
    });

    test('非法日期抛 ArgumentError', () {
      expect(() => LocalDate(2026, 13, 1), throwsArgumentError);
      expect(() => LocalDate(2026, 2, 30), throwsArgumentError);
      expect(() => LocalDate(2026, 0, 1), throwsArgumentError);
      expect(() => LocalDate(2026, 1, 0), throwsArgumentError);
    });

    test('闰年 2 月 29 日合法、平年不合法', () {
      expect(LocalDate(2024, 2, 29).day, 29);
      expect(() => LocalDate(2026, 2, 29), throwsArgumentError);
      expect(LocalDate(2000, 2, 29).day, 29); // 400 整除，是闰年
      expect(() => LocalDate(1900, 2, 29), throwsArgumentError); // 整百非 400
    });

    test('daysInMonth', () {
      expect(LocalDate.daysInMonth(2026, 1), 31);
      expect(LocalDate.daysInMonth(2026, 2), 28);
      expect(LocalDate.daysInMonth(2024, 2), 29);
      expect(LocalDate.daysInMonth(2026, 4), 30);
      expect(LocalDate.daysInMonth(2026, 12), 31);
    });
  });

  group('epochDay 往返', () {
    test('1970-01-01 是第 0 天', () {
      expect(LocalDate(1970, 1, 1).epochDay, 0);
      expect(LocalDate.fromEpochDay(0), LocalDate(1970, 1, 1));
    });

    test('任意日期 fromEpochDay 往返一致', () {
      for (final y in [1969, 1970, 1999, 2000, 2024, 2026, 2100]) {
        for (final m in [1, 2, 3, 6, 12]) {
          final d = LocalDate(y, m, LocalDate.daysInMonth(y, m));
          expect(LocalDate.fromEpochDay(d.epochDay), d, reason: '$d');
        }
      }
    });

    test('负数 epochDay（1970 年之前）', () {
      final d = LocalDate(1969, 12, 31);
      expect(d.epochDay, -1);
      expect(LocalDate.fromEpochDay(-1), d);
    });

    test('与 DateTime 的 epochDay 对齐（UTC 参照）', () {
      final d = LocalDate(2026, 10, 23);
      final expectDays =
          DateTime.utc(2026, 10, 23).millisecondsSinceEpoch ~/ 86400000;
      expect(d.epochDay, expectDays);
    });
  });

  group('weekday', () {
    test('已知日期', () {
      expect(LocalDate(1970, 1, 1).weekday, 4); // 周四
      expect(LocalDate(2026, 10, 23).weekday, 5); // 周五
      expect(LocalDate(2026, 10, 26).weekday, 1); // 周一
      expect(LocalDate(2026, 10, 25).weekday, 7); // 周日
    });

    test('与 DateTime.weekday 一致（连续 400 天）', () {
      var d = LocalDate(2025, 1, 1);
      for (var i = 0; i < 400; i++) {
        expect(d.weekday, d.toDateTime().weekday, reason: '$d');
        d = d.addDays(1);
      }
    });

    test('isWeekend', () {
      expect(LocalDate(2026, 10, 24).isWeekend, isTrue); // 周六
      expect(LocalDate(2026, 10, 25).isWeekend, isTrue); // 周日
      expect(LocalDate(2026, 10, 26).isWeekend, isFalse);
    });
  });

  group('加减', () {
    test('addDays 跨月跨年', () {
      expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
      expect(LocalDate(2026, 1, 1).addDays(-1), LocalDate(2025, 12, 31));
      expect(LocalDate(2024, 2, 28).addDays(1), LocalDate(2024, 2, 29));
    });

    test('addMonths 月末截断', () {
      expect(LocalDate(2026, 1, 31).addMonths(1), LocalDate(2026, 2, 28));
      expect(LocalDate(2024, 1, 31).addMonths(1), LocalDate(2024, 2, 29));
      expect(LocalDate(2026, 3, 31).addMonths(-1), LocalDate(2026, 2, 28));
      expect(LocalDate(2026, 12, 15).addMonths(1), LocalDate(2027, 1, 15));
    });

    test('daysSince', () {
      expect(LocalDate(2026, 10, 25).daysSince(LocalDate(2026, 10, 23)), 2);
      expect(LocalDate(2026, 10, 23).daysSince(LocalDate(2026, 10, 25)), -2);
    });

    test('lastDayOfMonth', () {
      expect(LocalDate(2024, 2, 10).lastDayOfMonth, LocalDate(2024, 2, 29));
      expect(LocalDate(2026, 2, 10).lastDayOfMonth, LocalDate(2026, 2, 28));
    });
  });

  group('比较与解析', () {
    test('比较', () {
      final a = LocalDate(2026, 10, 23);
      final b = LocalDate(2026, 10, 24);
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect(a.isSameDay(LocalDate(2026, 10, 23)), isTrue);
      expect(a.isBetween(a, b), isTrue);
      expect(b.isBetween(a, b), isTrue);
    });

    test('相等与 hashCode', () {
      expect(LocalDate(2026, 10, 23), LocalDate(2026, 10, 23));
      expect(
        LocalDate(2026, 10, 23).hashCode,
        LocalDate(2026, 10, 23).hashCode,
      );
      expect(LocalDate(2026, 10, 23) == LocalDate(2026, 10, 24), isFalse);
    });

    test('parse / toString 往返', () {
      for (final s in ['2026-01-01', '2024-02-29', '1999-12-31']) {
        expect(LocalDate.parse(s).toString(), s);
      }
      expect(() => LocalDate.parse('2026/10/23'), throwsFormatException);
      expect(() => LocalDate.parse('2026-10'), throwsFormatException);
    });

    test('fromDateTime 取本地日期', () {
      expect(
        LocalDate.fromDateTime(DateTime(2026, 10, 23, 23, 59, 59)),
        LocalDate(2026, 10, 23),
      );
    });
  });
}
