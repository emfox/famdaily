/// 统计页的数据装配（ui-spec §3.3）。
///
/// 口径全部来自 `domain/stats`，这里不重新定义任何一个率——
/// 分母永远是"已排出的槽位"，**不做连续打卡天数**（需求 3.7：
/// 连续天数会激励人为保数字而补卡，数据就脏了）。
library;


import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/stats/stats.dart';
import '../../app/test_clock.dart';

/// 统计区间。
enum StatsPeriod {
  thisMonth('本月'),
  lastMonth('上月'),
  last90Days('近 90 天'),
  thisYear('今年');

  const StatsPeriod(this.label);

  final String label;
}

/// 一个区间的起止（含两端）。
final class DateRange {
  const DateRange(this.from, this.to);

  final LocalDate from;
  final LocalDate to;

  /// 按区间与"今天"算出真实起止。
  ///
  /// 所有区间都**截到今天**：未来的槽位还没发生，算进分母会让完成率
  /// 永远上不去——这是最容易让人误以为"我做得很差"的一种口径错误。
  static DateRange of(StatsPeriod period, LocalDate today) {
    final first = LocalDate(today.year, today.month, 1);
    final lastMonthEnd = first.addDays(-1);
    return switch (period) {
      StatsPeriod.thisMonth => DateRange(first, today),
      // 上月最后一天回推：跨年时（1 月看 12 月）也正确。
      StatsPeriod.lastMonth => DateRange(
        LocalDate(lastMonthEnd.year, lastMonthEnd.month, 1),
        lastMonthEnd,
      ),
      StatsPeriod.last90Days => DateRange(today.addDays(-89), today),
      StatsPeriod.thisYear => DateRange(LocalDate(today.year, 1, 1), today),
    };
  }

  int get days => to.daysSince(from) + 1;

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => '$from ~ $to';
}

/// 一个成员的一行。
final class MemberStatsRow {
  const MemberStatsRow({required this.member, required this.summary});

  final Member member;
  final StatsSummary summary;
}

/// 统计页的整屏数据。
final class StatsView {
  const StatsView({
    required this.period,
    required this.range,
    required this.overall,
    required this.rows,
    required this.memberFilter,
  });

  final StatsPeriod period;
  final DateRange range;

  /// 全部成员合计（已按 [memberFilter] 过滤）。
  final StatsSummary overall;

  /// 按成员分行，顺序与成员排序一致。
  final List<MemberStatsRow> rows;

  /// 当前筛了谁；null = 全部成员。
  final String? memberFilter;

  /// 一句话总结，避免用户自己算。
  String get headline {
    if (overall.expected == 0) {
      return '这段时间没有排过打卡项';
    }
    return '共 ${overall.expected} 次该做，做了 ${overall.onTime + overall.makeup} 次';
  }
}

/// 统计页装配器。
final class StatsService {
  StatsService(this._db);

  final AppDatabase _db;

  Future<StatsView> load({
    StatsPeriod period = StatsPeriod.thisMonth,
    String? memberFilter,
    DateTime? at,
  }) async {
    final today = LocalDate.fromDateTime(at ?? appNow());
    final range = DateRange.of(period, today);

    final members = await _db.listMembers();
    final memberOrder = {
      for (var i = 0; i < members.length; i++) members[i].id: i,
    };
    final taskMember = {
      for (final t in await _db.listAllTasks()) t.id: t.memberId,
    };

    final slots = await _db.slotsBetween(range.from, range.to);
    final records = await _db.checkinsBetween(range.from, range.to);
    final bySlot = <String, CheckinState>{
      for (final r in records) '${r.taskId}|${r.date}|${r.slotIndex}': r.state,
    };

    // 按成员分桶。删掉的成员（软删除）仍可能出现——它们的记录还挂在
    // member_id 上，但不该在统计里占一行，直接跳过。
    final buckets = <String, List<StatsEntry>>{};
    for (final s in slots) {
      if (s.dueDate.isAfter(today)) {
        continue; // 跨午夜落到明天的槽位不算今天的
      }
      final memberId = taskMember[s.taskId];
      if (memberId == null || !memberOrder.containsKey(memberId)) {
        continue;
      }
      if (memberFilter != null && memberId != memberFilter) {
        continue;
      }
      buckets.putIfAbsent(memberId, () => []).add(
        StatsEntry(s.date, bySlot['${s.taskId}|${s.date}|${s.slotIndex}']),
      );
    }

    final rows = <MemberStatsRow>[
      for (final m in members)
        if (buckets.containsKey(m.id))
          MemberStatsRow(
            member: m,
            summary: Stats.summarize(buckets[m.id]!),
          ),
    ];

    final all = rows.fold(
      StatsSummary.empty,
      (acc, r) => acc + r.summary,
    );

    return StatsView(
      period: period,
      range: range,
      overall: all,
      rows: rows,
      memberFilter: memberFilter,
    );
  }
}
