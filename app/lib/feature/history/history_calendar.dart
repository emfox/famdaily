/// 历史月历的纯计算：格子排布、底色分档、本月汇总口径。
///
/// 为什么不放在 Widget 里：这套规则有三个容易错的地方——周一起始的
/// 前置空格数、"有没做"优先于完成率、未来日期不算进分母。
/// 它们都是**产品语义**（ui-spec §3.1 的底色映射表），值得单测。
library;

import '../../domain/model/local_date.dart';
import '../../domain/stats/stats.dart';

/// 一天的底色档位（ui-spec §3.1「底色映射」）。
enum DayTone {
  /// 未来 / 没数据：不涂色，字灰。
  none,

  /// 1–59%。
  light,

  /// 60–99%。
  medium,

  /// 100%。
  full,

  /// 有「没做」记录——**优先级高于完成率**。
  ///
  /// 100% 完成率但有一条"没做"的日子仍然要做暖红：那天确实有件事黄了，
  /// 涂成全绿等于粉饰。这个优先级是设计稿明确写死的。
  warm,
}

/// 一个日历格子。
final class DayCell {
  const DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isFuture,
    required this.summary,
    required this.tone,
  });

  final LocalDate date;

  /// 是否属于当前月（前后补白的日子为 false，只画淡数字）。
  final bool inMonth;

  final bool isToday;
  final bool isFuture;

  /// 当天的汇总；没数据时是 [StatsSummary.empty]。
  final StatsSummary summary;

  final DayTone tone;

  /// 有没有任何记录（用来决定要不要画小圆点）。
  bool get hasData => summary.expected > 0;

  /// 完成率文本，如 `86%`（不带小数，日历格子太窄）。
  String get percentText => summary.expected == 0
      ? ''
      : '${(summary.completionRate * 100).round()}%';
}

/// 一个月的格子与汇总。
final class MonthGrid {
  const MonthGrid({
    required this.year,
    required this.month,
    required this.cells,
    required this.summary,
  });

  final int year;
  final int month;

  /// 按周排好的格子，长度是 7 的倍数。
  final List<DayCell> cells;

  /// 本月已完成的日子汇总之和（只算当月、不算未来）。
  final StatsSummary summary;

  String get titleZh => '$year 年 $month 月';

  LocalDate get first => LocalDate(year, month, 1);

  LocalDate get last => first.lastDayOfMonth;
}

/// 历史页的日历装配。
abstract final class HistoryCalendar {
  /// 做一个月历。
  ///
  /// [byDay] 是"某天 → 当天汇总"，通常由 `Stats.byDay` 产出；
  /// [today] 用来标记"今天"以及把未来日子排除在汇总之外。
  static MonthGrid buildMonth({
    required int year,
    required int month,
    required Map<LocalDate, StatsSummary> byDay,
    required LocalDate today,
  }) {
    final first = LocalDate(year, month, 1);
    final last = first.lastDayOfMonth;

    // 周一起始：前置补白 = weekday - 1 天。
    final leading = first.weekday - 1;
    // 尾部补到整周。
    final trailing = (7 - (leading + last.day) % 7) % 7;

    final cells = <DayCell>[];
    var cursor = first.addDays(-leading);
    final total = leading + last.day + trailing;
    for (var i = 0; i < total; i++) {
      final inMonth = !cursor.isBefore(first) && !cursor.isAfter(last);
      final summary = inMonth
          ? (byDay[cursor] ?? StatsSummary.empty)
          : StatsSummary.empty;
      final isFuture = cursor.isAfter(today);
      cells.add(
        DayCell(
          date: cursor,
          inMonth: inMonth,
          isToday: cursor.isSameDay(today),
          isFuture: isFuture,
          summary: summary,
          tone: toneOf(summary, isFuture: isFuture),
        ),
      );
      cursor = cursor.addDays(1);
    }

    // 月度汇总：只算当月、且不超过今天。未来的日子还没发生，
    // 算进分母会让"本月完成率"永远低一截，谁看谁泄气。
    var monthSummary = StatsSummary.empty;
    for (final c in cells) {
      if (!c.inMonth || c.isFuture) {
        continue;
      }
      monthSummary = monthSummary + c.summary;
    }

    return MonthGrid(
      year: year,
      month: month,
      cells: cells,
      summary: monthSummary,
    );
  }

  /// 底色分档（ui-spec §3.1 的映射表，顺序即优先级）。
  static DayTone toneOf(StatsSummary s, {required bool isFuture}) {
    if (isFuture || s.expected == 0) {
      return DayTone.none;
    }
    if (s.skipped > 0) {
      return DayTone.warm;
    }
    final rate = s.completionRate;
    if (rate >= 1) {
      return DayTone.full;
    }
    if (rate >= 0.6) {
      return DayTone.medium;
    }
    if (rate > 0) {
      return DayTone.light;
    }
    // 排了但一条都没处理（分母 > 0、全悬空）：这不算"浅绿"，是没数据。
    return DayTone.none;
  }
}
