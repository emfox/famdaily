import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-19 是周一，用它做一周的锚点。
final monday = LocalDate(2026, 10, 19);

LocalDate dow(int weekday) => monday.addDays(weekday - 1);

void main() {
  group('默认 = 每天', () {
    test('isEveryDay 与 matches', () {
      expect(RepeatRule.daily.isEveryDay, isTrue);
      for (var i = 0; i < 40; i++) {
        expect(RepeatRule.daily.matches(monday.addDays(i)), isTrue);
      }
    });

    test('空集合视同不限', () {
      const r = RepeatRule(weekdays: {}, monthDays: []);
      expect(r.isEveryDay, isTrue);
      expect(r.matches(monday), isTrue);
    });
  });

  group('weekdays', () {
    test('周一/三/五', () {
      const r = RepeatRule(weekdays: {1, 3, 5});
      expect(r.matches(dow(1)), isTrue);
      expect(r.matches(dow(2)), isFalse);
      expect(r.matches(dow(3)), isTrue);
      expect(r.matches(dow(5)), isTrue);
      expect(r.matches(dow(6)), isFalse);
      expect(r.matches(dow(7)), isFalse);
    });

    test('一周正好命中 3 天', () {
      const r = RepeatRule(weekdays: {1, 3, 5});
      var count = 0;
      for (var i = 0; i < 7; i++) {
        if (r.matches(monday.addDays(i))) {
          count++;
        }
      }
      expect(count, 3);
    });
  });

  group('everyNDays', () {
    test('每 3 天，从 anchor 起算', () {
      final r = RepeatRule(everyNDays: 3, anchor: monday);
      expect(r.matches(monday), isTrue);
      expect(r.matches(monday.addDays(1)), isFalse);
      expect(r.matches(monday.addDays(2)), isFalse);
      expect(r.matches(monday.addDays(3)), isTrue);
      expect(r.matches(monday.addDays(6)), isTrue);
    });

    test('日期早于 anchor 时取模仍正确', () {
      final r = RepeatRule(everyNDays: 3, anchor: monday);
      expect(r.matches(monday.addDays(-3)), isTrue);
      expect(r.matches(monday.addDays(-1)), isFalse);
    });

    test('anchor 为 null 时退回 epoch', () {
      const r = RepeatRule(everyNDays: 2);
      expect(r.matches(LocalDate(1970, 1, 1)), isTrue);
      expect(r.matches(LocalDate(1970, 1, 2)), isFalse);
      expect(r.matches(LocalDate(1970, 1, 3)), isTrue);
    });
  });

  group('parity：工作日 / 周末', () {
    test('workdays', () {
      const r = RepeatRule(parity: ParityFilter.workdays);
      expect(r.matches(dow(1)), isTrue);
      expect(r.matches(dow(5)), isTrue);
      expect(r.matches(dow(6)), isFalse);
      expect(r.matches(dow(7)), isFalse);
    });

    test('weekends', () {
      const r = RepeatRule(parity: ParityFilter.weekends);
      expect(r.matches(dow(6)), isTrue);
      expect(r.matches(dow(7)), isTrue);
      expect(r.matches(dow(1)), isFalse);
    });
  });

  group('parity：单双周（全局固定基准，改规则不位移）', () {
    test('单周 + 双周互补，且每 7 天翻转一次', () {
      const odd = RepeatRule(parity: ParityFilter.oddWeeks);
      const even = RepeatRule(parity: ParityFilter.evenWeeks);
      final base = LocalDate(2026, 10, 19);
      for (var i = 0; i < 28; i++) {
        final d = base.addDays(i);
        // 同一天恰好命中一个
        expect(odd.matches(d) ^ even.matches(d), isTrue, reason: '$d');
      }
      // 同一周内 7 天结果一致
      for (var i = 0; i < 7; i++) {
        expect(odd.matches(base.addDays(i)), odd.matches(base), reason: '$i');
      }
    });

    test('单双周 + 周一三五 = 交集', () {
      const r = RepeatRule(weekdays: {1, 3, 5}, parity: ParityFilter.oddWeeks);
      // 扫两周，命中数应是"一周的 3 天"（正好落在单周或双周的那一周）
      var hits = 0;
      for (var i = 0; i < 14; i++) {
        final d = monday.addDays(i);
        if (r.matches(d)) {
          hits++;
          expect({1, 3, 5}.contains(d.weekday), isTrue, reason: '$d');
        }
      }
      expect(hits, 3);
      // 再扫 28 天，应恰好是两周的量（单周那一周各 3 天 → 6 天）
      var hits28 = 0;
      for (var i = 0; i < 28; i++) {
        if (r.matches(monday.addDays(i))) {
          hits28++;
        }
      }
      expect(hits28, 6);
    });
  });

  group('monthDays', () {
    test('每月 1 号和 15 号', () {
      const r = RepeatRule(monthDays: [1, 15]);
      expect(r.matches(LocalDate(2026, 10, 1)), isTrue);
      expect(r.matches(LocalDate(2026, 10, 15)), isTrue);
      expect(r.matches(LocalDate(2026, 10, 14)), isFalse);
      expect(r.matches(LocalDate(2026, 11, 1)), isTrue);
    });

    test('31 号在 2 月整月跳过（不折回月末）', () {
      const r = RepeatRule(monthDays: [31]);
      expect(r.matches(LocalDate(2026, 1, 31)), isTrue);
      for (var d = 1; d <= 28; d++) {
        expect(r.matches(LocalDate(2026, 2, d)), isFalse);
      }
      expect(r.matches(LocalDate(2026, 3, 31)), isTrue);
    });
  });

  group('isSatisfiable：矛盾组合应被 UI 拦下', () {
    test('周末 + 工作日 = 永不触发', () {
      const r = RepeatRule(weekdays: {6, 7}, parity: ParityFilter.workdays);
      expect(r.isSatisfiable, isFalse);
      // 真的从不命中
      for (var i = 0; i < 30; i++) {
        expect(r.matches(monday.addDays(i)), isFalse);
      }
    });

    test('周一三五 + 工作日 = 可满足', () {
      const r = RepeatRule(weekdays: {1, 3, 5}, parity: ParityFilter.workdays);
      expect(r.isSatisfiable, isTrue);
    });

    test('每天 = 可满足', () {
      expect(RepeatRule.daily.isSatisfiable, isTrue);
    });
  });

  group('相等性与 copyWith', () {
    test('集合/列表顺序不影响相等', () {
      const a = RepeatRule(weekdays: {1, 3}, monthDays: [1, 15]);
      const b = RepeatRule(weekdays: {3, 1}, monthDays: [1, 15]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith 清空字段', () {
      final a = RepeatRule(weekdays: {1}, everyNDays: 2, anchor: monday);
      expect(a.copyWith(clearWeekdays: true).weekdays, isNull);
      final b = a.copyWith(clearEveryNDays: true);
      expect(b.everyNDays, isNull);
      expect(b.anchor, isNull);
      expect(b.weekdays, {1});
    });

    test('不同 anchor 不相等（防止相位漂移被忽略）', () {
      final a = RepeatRule(everyNDays: 3, anchor: monday);
      final b = RepeatRule(everyNDays: 3, anchor: monday.addDays(1));
      // 两者只差 anchor，必须不相等
      expect(a == b, isFalse);
    });
  });
}
