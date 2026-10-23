/// 统计口径（需求 3.7）。
///
/// 三个率的分母都是"应完成"（= 已排出的槽位，不论做没做）。
/// **不做连续打卡天数**——连续天数会逼人为了保数字而补卡，数据就脏了。
library;

import '../model/checkin_state.dart';
import '../model/local_date.dart';

/// 一段时间内的统计结果。
final class StatsSummary {
  const StatsSummary({
    required this.expected,
    required this.onTime,
    required this.makeup,
    required this.skipped,
    required this.unrecorded,
  });

  /// 应完成 = 已排出的槽位总数。
  final int expected;

  /// 准时完成。
  final int onTime;

  /// 补卡。
  final int makeup;

  /// 明确"没做"。
  final int skipped;

  /// 悬空未记（既没做标记，也没打卡）——通常只出现在今天及近几天。
  final int unrecorded;

  static const empty = StatsSummary(
    expected: 0,
    onTime: 0,
    makeup: 0,
    skipped: 0,
    unrecorded: 0,
  );

  /// 完成率 = (准时完成 + 补卡) / 应完成。
  double get completionRate => expected == 0 ? 0 : (onTime + makeup) / expected;

  /// 准时率 = 准时完成 / 应完成。
  double get onTimeRate => expected == 0 ? 0 : onTime / expected;

  /// 放弃率 = 明确"没做" / 应完成。
  double get giveUpRate => expected == 0 ? 0 : skipped / expected;

  StatsSummary operator +(StatsSummary other) => StatsSummary(
    expected: expected + other.expected,
    onTime: onTime + other.onTime,
    makeup: makeup + other.makeup,
    skipped: skipped + other.skipped,
    unrecorded: unrecorded + other.unrecorded,
  );

  /// 百分比文本，一位小数；分母为 0 时给 `—`（不显示 0%，那会让人误解为"全没做"）。
  String percent(double v) =>
      expected == 0 ? '—' : '${(v * 100).toStringAsFixed(1)}%';

  @override
  String toString() =>
      'Stats(expected: $expected, onTime: $onTime, makeup: $makeup, '
      'skipped: $skipped, unrecorded: $unrecorded)';
}

/// 一条最简统计输入：某天某槽位的状态（null = 未记）。
final class StatsEntry {
  const StatsEntry(this.date, this.state);

  final LocalDate date;
  final CheckinState? state;
}

/// 统计计算。
abstract final class Stats {
  /// 从扁平条目汇总。
  static StatsSummary summarize(Iterable<StatsEntry> entries) {
    var onTime = 0;
    var makeup = 0;
    var skipped = 0;
    var unrecorded = 0;
    var expected = 0;
    for (final e in entries) {
      expected++;
      switch (e.state) {
        case CheckinState.done:
          onTime++;
        case CheckinState.makeup:
          makeup++;
        case CheckinState.skipped:
          skipped++;
        case null:
          unrecorded++;
      }
    }
    return StatsSummary(
      expected: expected,
      onTime: onTime,
      makeup: makeup,
      skipped: skipped,
      unrecorded: unrecorded,
    );
  }

  /// 最近 N 天（含今天，按疗程日归集）。
  static StatsSummary lastNDays(
    Iterable<StatsEntry> entries, {
    required LocalDate today,
    required int days,
  }) {
    final from = today.addDays(-(days - 1));
    return summarize(
      entries.where((e) => !e.date.isBefore(from) && !e.date.isAfter(today)),
    );
  }

  /// 按天分组，返回"从 [from] 到 [to]"每天一个格子（没有记录的天给 0 分母）。
  ///
  /// 用于历史日历的每日小圆点。
  static Map<LocalDate, StatsSummary> byDay(
    Iterable<StatsEntry> entries, {
    required LocalDate from,
    required LocalDate to,
  }) {
    final buckets = <LocalDate, List<StatsEntry>>{};
    for (final e in entries) {
      if (e.date.isBefore(from) || e.date.isAfter(to)) {
        continue;
      }
      buckets.putIfAbsent(e.date, () => []).add(e);
    }
    final out = <LocalDate, StatsSummary>{};
    var d = from;
    while (!d.isAfter(to)) {
      out[d] = buckets.containsKey(d)
          ? summarize(buckets[d]!)
          : StatsSummary.empty;
      d = d.addDays(1);
    }
    return out;
  }
}
