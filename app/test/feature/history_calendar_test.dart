import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/stats/stats.dart';
import 'package:famdaily/feature/history/history_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个汇总：全部准时。
StatsSummary full(int n) =>
    StatsSummary(expected: n, onTime: n, makeup: 0, skipped: 0, unrecorded: 0);

/// 造一个汇总：完成率由 [done] / [total] 决定，可选有没有"没做"。
StatsSummary mix({
  required int total,
  required int done,
  int skipped = 0,
  int unrecorded = 0,
}) => StatsSummary(
  expected: total,
  onTime: done,
  makeup: 0,
  skipped: skipped,
  unrecorded: unrecorded,
);

void main() {
  final today = LocalDate(2026, 3, 15);

  group('底色分档（ui-spec §3.1）', () {
    test('100% = 深绿', () {
      expect(HistoryCalendar.toneOf(full(3), isFuture: false), DayTone.full);
    });

    test('60–99% = 中绿', () {
      expect(
        HistoryCalendar.toneOf(mix(total: 10, done: 6), isFuture: false),
        DayTone.medium,
      );
      expect(
        HistoryCalendar.toneOf(mix(total: 10, done: 9), isFuture: false),
        DayTone.medium,
      );
    });

    test('1–59% = 浅绿', () {
      expect(
        HistoryCalendar.toneOf(mix(total: 10, done: 1), isFuture: false),
        DayTone.light,
      );
      expect(
        HistoryCalendar.toneOf(mix(total: 10, done: 5), isFuture: false),
        DayTone.light,
      );
    });

    test('有「没做」优先变暖红，哪怕完成率 100%', () {
      // 这条是设计稿写死的优先级：粉饰成全绿等于骗人。
      expect(
        HistoryCalendar.toneOf(
          mix(total: 2, done: 2, skipped: 1),
          isFuture: false,
        ),
        DayTone.warm,
      );
    });

    test('未来一律不涂色', () {
      expect(
        HistoryCalendar.toneOf(full(3), isFuture: true),
        DayTone.none,
      );
    });

    test('排了但一条没处理 = 不涂色（不算浅绿）', () {
      expect(
        HistoryCalendar.toneOf(mix(total: 3, done: 0), isFuture: false),
        DayTone.none,
      );
    });

    test('没有槽位 = 不涂色', () {
      expect(
        HistoryCalendar.toneOf(StatsSummary.empty, isFuture: false),
        DayTone.none,
      );
    });
  });

  group('月历排布', () {
    test('2026 年 3 月从周日开始：前面补 6 个空格', () {
      // 2026-03-01 是周日 → 周一起始要补 6 格
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 3,
        byDay: const {},
        today: today,
      );
      expect(grid.first.weekday, 7);
      expect(grid.cells.first.date, LocalDate(2026, 2, 23));
      expect(grid.cells.first.inMonth, isFalse);
      expect(grid.cells[6].date, LocalDate(2026, 3, 1));
      expect(grid.cells[6].inMonth, isTrue);
    });

    test('格子数总是 7 的整数倍', () {
      for (var m = 1; m <= 12; m++) {
        final grid = HistoryCalendar.buildMonth(
          year: 2026,
          month: m,
          byDay: const {},
          today: today,
        );
        expect(grid.cells.length % 7, 0, reason: '月份 $m');
        expect(
          grid.cells.where((c) => c.inMonth).length,
          LocalDate.daysInMonth(2026, m),
          reason: '月份 $m',
        );
      }
    });

    test('闰年 2 月 29 天也算对', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2028,
        month: 2,
        byDay: const {},
        today: today,
      );
      expect(grid.cells.where((c) => c.inMonth).length, 29);
    });

    test('今天被标出来，且在当月', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 3,
        byDay: const {},
        today: today,
      );
      final marked = grid.cells.where((c) => c.isToday).toList();
      expect(marked, hasLength(1));
      expect(marked.single.date, today);
      expect(marked.single.inMonth, isTrue);
    });

    test('别的月份不标今天', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 4,
        byDay: const {},
        today: today,
      );
      expect(grid.cells.any((c) => c.isToday), isFalse);
    });

    test('未来日子 isFuture = true，且不参与月度汇总', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 3,
        byDay: {
          LocalDate(2026, 3, 10): full(2),
          LocalDate(2026, 3, 15): full(3), // 今天
          LocalDate(2026, 3, 20): full(4), // 未来
        },
        today: today,
      );
      final d20 = grid.cells.firstWhere(
        (c) => c.date == LocalDate(2026, 3, 20),
      );
      expect(d20.isFuture, isTrue);
      // 10 号 2 条 + 15 号 3 条 = 5，20 号不算
      expect(grid.summary.expected, 5);
      expect(grid.summary.onTime, 5);
    });

    test('补白格子不带数据（避免把上个月的数据涂到本月格子里）', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 3,
        byDay: {
          // 2 月 23 日恰好是 3 月历的补白格
          LocalDate(2026, 2, 23): full(9),
        },
        today: today,
      );
      final pad = grid.cells.first;
      expect(pad.inMonth, isFalse);
      expect(pad.summary.expected, 0);
      expect(pad.tone, DayTone.none);
    });

    test('标题是「2026 年 3 月」', () {
      final grid = HistoryCalendar.buildMonth(
        year: 2026,
        month: 3,
        byDay: const {},
        today: today,
      );
      expect(grid.titleZh, '2026 年 3 月');
    });
  });
}
