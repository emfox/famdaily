import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = LocalDate(2026, 10, 1);

  group('Course.none（长期）', () {
    test('恒包含、永不到期', () {
      expect(Course.none.isOpenEnded, isTrue);
      expect(Course.none.contains(start), isTrue);
      expect(Course.none.contains(start.addDays(9999)), isTrue);
      expect(Course.none.isExpired(start.addDays(9999)), isFalse);
      expect(Course.none.isEndingSoon(start), isFalse);
      expect(Course.none.dayIndex(start), isNull);
      expect(Course.none.daysRemaining(start), isNull);
    });
  });

  group('Course.days（连续 N 天，含首日）', () {
    test('7 天疗程的边界', () {
      final c = Course.days(start, 7);
      expect(c.end, LocalDate(2026, 10, 7));
      expect(c.totalDays, 7);
      expect(c.contains(start), isTrue);
      expect(c.contains(start.addDays(6)), isTrue);
      expect(c.contains(start.addDays(7)), isFalse);
      expect(c.contains(start.addDays(-1)), isFalse);
    });

    test('dayIndex 从 1 开始', () {
      final c = Course.days(start, 7);
      expect(c.dayIndex(start), 1);
      expect(c.dayIndex(start.addDays(3)), 4);
      expect(c.dayIndex(start.addDays(7)), isNull);
    });

    test('1 天疗程', () {
      final c = Course.days(start, 1);
      expect(c.end, start);
      expect(c.contains(start), isTrue);
      expect(c.contains(start.addDays(1)), isFalse);
    });

    test('非法天数', () {
      expect(() => Course.days(start, 0), throwsArgumentError);
      expect(() => Course.days(start, -1), throwsArgumentError);
    });
  });

  group('Course.range', () {
    test('含两端', () {
      final c = Course.range(
        LocalDate(2026, 10, 1),
        LocalDate(2026, 10, 31),
      );
      expect(c.contains(LocalDate(2026, 10, 1)), isTrue);
      expect(c.contains(LocalDate(2026, 10, 31)), isTrue);
      expect(c.contains(LocalDate(2026, 11, 1)), isFalse);
    });

    test('结束早于开始抛错', () {
      expect(
        () => Course.range(
          LocalDate(2026, 10, 31),
          LocalDate(2026, 10, 1),
        ),
        throwsArgumentError,
      );
    });

    test('同一天合法', () {
      final c = Course.range(start, start);
      expect(c.contains(start), isTrue);
    });
  });

  group('到期判断', () {
    test('isExpired 严格晚于结束日', () {
      final c = Course.days(start, 7);
      expect(c.isExpired(LocalDate(2026, 10, 7)), isFalse);
      expect(c.isExpired(LocalDate(2026, 10, 8)), isTrue);
    });

    test('isEndingSoon 默认提前 2 天，含到期当天', () {
      final c = Course.days(start, 7);
      expect(c.isEndingSoon(LocalDate(2026, 10, 4)), isFalse);
      expect(c.isEndingSoon(LocalDate(2026, 10, 5)), isTrue);
      expect(c.isEndingSoon(LocalDate(2026, 10, 7)), isTrue);
      expect(c.isEndingSoon(LocalDate(2026, 10, 8)), isFalse); // 已过期
    });

    test('daysRemaining', () {
      final c = Course.days(start, 7);
      expect(c.daysRemaining(LocalDate(2026, 10, 1)), 6);
      expect(c.daysRemaining(LocalDate(2026, 10, 7)), 0);
      expect(c.daysRemaining(LocalDate(2026, 10, 8)), -1);
    });
  });

  group('Course.fromRange', () {
    test('同时为空 → none', () {
      expect(Course.fromRange(null, null), Course.none);
    });

    test('只有一个 → 抛错', () {
      expect(() => Course.fromRange(start, null), throwsArgumentError);
      expect(() => Course.fromRange(null, start), throwsArgumentError);
    });
  });

  group('相等性', () {
    test('同起止相等', () {
      expect(
        Course.range(start, LocalDate(2026, 10, 7)),
        Course.range(start, LocalDate(2026, 10, 7)),
      );
    });

    test('连续 7 天与区间 10/1–10/7 内容相同但 totalDays 不同', () {
      final a = Course.days(start, 7);
      final b = Course.range(start, LocalDate(2026, 10, 7));
      expect(a.contains(start.addDays(6)), b.contains(start.addDays(6)));
      expect(a.totalDays, 7);
      expect(b.totalDays, isNull);
      expect(a == b, isFalse);
    });
  });
}
