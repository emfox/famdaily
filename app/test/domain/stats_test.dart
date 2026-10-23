import 'package:famdaily/domain/model/checkin_state.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/stats/stats.dart';
import 'package:flutter_test/flutter_test.dart';

final today = LocalDate(2026, 10, 23);

StatsEntry e(LocalDate d, CheckinState? s) => StatsEntry(d, s);

void main() {
  group('三个率的口径（需求 3.7）', () {
    test('完成率 = (准时 + 补卡) / 应完成', () {
      final s = Stats.summarize([
        e(today, CheckinState.done),
        e(today, CheckinState.makeup),
        e(today, null),
        e(today, CheckinState.skipped),
      ]);
      expect(s.expected, 4);
      expect(s.completionRate, 0.5);
    });

    test('准时率只算 done，补卡不算', () {
      final s = Stats.summarize([
        e(today, CheckinState.done),
        e(today, CheckinState.makeup),
      ]);
      expect(s.onTimeRate, 0.5);
      expect(s.completionRate, 1.0);
    });

    test('放弃率 = 明确没做 / 应完成', () {
      final s = Stats.summarize([
        e(today, CheckinState.skipped),
        e(today, CheckinState.done),
        e(today, CheckinState.done),
        e(today, CheckinState.done),
      ]);
      expect(s.giveUpRate, 0.25);
    });

    test('分母为 0 时显示 —— 而不是 0%', () {
      const s = StatsSummary.empty;
      expect(s.percent(s.completionRate), '—');
      expect(
        StatsSummary.empty.percent(StatsSummary.empty.onTimeRate),
        '—',
      );
    });

    test('百分比保留一位小数', () {
      final s = Stats.summarize([
        e(today, CheckinState.done),
        e(today, null),
        e(today, null),
      ]);
      expect(s.percent(s.completionRate), '33.3%');
    });
  });

  group('lastNDays', () {
    test('含今天，往前 N-1 天', () {
      final entries = [
        e(today, CheckinState.done),
        e(today.addDays(-6), CheckinState.done),
        e(today.addDays(-7), CheckinState.done), // 超界
        e(today.addDays(1), CheckinState.done), // 未来，排除
      ];
      final s = Stats.lastNDays(entries, today: today, days: 7);
      expect(s.expected, 2);
      expect(s.onTime, 2);
    });
  });

  group('byDay', () {
    test('区间内每天都有格子，缺记录的天给空统计', () {
      final map = Stats.byDay(
        [
          e(today, CheckinState.done),
          e(today.addDays(-2), CheckinState.skipped),
        ],
        from: today.addDays(-2),
        to: today,
      );
      expect(map.length, 3);
      expect(map[today]!.onTime, 1);
      expect(map[today.addDays(-2)]!.skipped, 1);
      expect(map[today.addDays(-1)]!.expected, 0);
    });

    test('区间外的记录被忽略', () {
      final map = Stats.byDay(
        [e(today.addDays(-10), CheckinState.done)],
        from: today,
        to: today,
      );
      expect(map[today]!.expected, 0);
    });
  });

  group('累加', () {
    test('两个统计相加', () {
      final a = Stats.summarize([e(today, CheckinState.done)]);
      final b = Stats.summarize([e(today, CheckinState.skipped)]);
      final sum = a + b;
      expect(sum.expected, 2);
      expect(sum.onTime, 1);
      expect(sum.skipped, 1);
    });
  });
}
