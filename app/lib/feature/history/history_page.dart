import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../domain/model/local_date.dart';
import '../../domain/stats/stats.dart';
import 'day_detail_page.dart';
import 'history_calendar.dart';
import 'history_service.dart';

/// 历史页：月历 + 本月完成率（ui-spec §3.1）。
///
/// 日历格子的底色是"那天过得怎么样"的一眼总结。这里刻意**不做连续天数**、
/// 不做排行榜——需求 3.7 明确说过，数字只能用来回看，不能用来施压。
class HistoryPage extends StatefulWidget {
  const HistoryPage({
    required this.service,
    required this.onOpenStats,
    super.key,
  });

  final HistoryService service;

  /// 右上角「统计」入口（P2 接统计页，现在先留位）。
  final VoidCallback? onOpenStats;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late LocalDate _cursor = LocalDate.fromDateTime(clock.now());
  MonthView? _view;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final view = await widget.service.loadMonth(
      year: _cursor.year,
      month: _cursor.month,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _view = view;
      _loading = false;
    });
  }

  void _shiftMonth(int delta) {
    setState(() => _cursor = _cursor.addMonths(delta));
    _load();
  }

  void _goToday() {
    setState(() => _cursor = LocalDate.fromDateTime(clock.now()));
    _load();
  }

  Future<void> _openDay(LocalDate date) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DayDetailPage(
          service: widget.service,
          date: date,
        ),
      ),
    );
    // 从明细页回来可能有补卡动作，刷新一下底色。
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view;

    return Scaffold(
      appBar: AppBar(
        title: Text('历史', style: theme.textTheme.headlineSmall),
        actions: [
          if (widget.onOpenStats != null)
            TextButton(
              onPressed: widget.onOpenStats,
              child: const Text('统计'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: view == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  _MonthHeader(
                    title: view.grid.titleZh,
                    onPrev: () => _shiftMonth(-1),
                    onNext: () => _shiftMonth(1),
                    onToday: _goToday,
                    isCurrentMonth: _isCurrentMonth(view),
                  ),
                  _WeekdayHeader(),
                  _MonthBody(
                    grid: view.grid,
                    onTapDay: _openDay,
                  ),
                  const SizedBox(height: 14),
                  _MonthSummaryBar(summary: view.grid.summary),
                  const SizedBox(height: 12),
                  const _Legend(),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  bool _isCurrentMonth(MonthView v) {
    final today = LocalDate.fromDateTime(clock.now());
    return v.year == today.year && v.month == today.month;
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.title,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.isCurrentMonth,
  });

  final String title;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final bool isCurrentMonth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const Spacer(),
        if (!isCurrentMonth)
          TextButton(onPressed: onToday, child: const Text('今天')),
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
          tooltip: '上个月',
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: '下个月',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MonthBody extends StatelessWidget {
  const _MonthBody({required this.grid, required this.onTapDay});

  final MonthGrid grid;
  final ValueChanged<LocalDate> onTapDay;

  @override
  Widget build(BuildContext context) {
    // 7 列固定，行数按格子数算。用 Column + Row 而不是 GridView：
    // 高度可以自然包裹，外面已经是 ListView，嵌套滚动会抢手势。
    final rows = <Widget>[];
    for (var i = 0; i < grid.cells.length; i += 7) {
      rows.add(
        Row(
          children: [
            for (var j = 0; j < 7; j++)
              Expanded(
                child: _DaySquare(
                  cell: grid.cells[i + j],
                  onTap: grid.cells[i + j].inMonth
                      ? () => onTapDay(grid.cells[i + j].date)
                      : null,
                ),
              ),
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

/// 一个日期格。有数据时涂底色，空格子只画淡数字。
class _DaySquare extends StatelessWidget {
  const _DaySquare({required this.cell, required this.onTap});

  final DayCell cell;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (bg, fg) = _colorsFor(cell.tone, scheme);
    final baseColor = cell.inMonth ? fg ?? scheme.onSurface : scheme.outlineVariant;

    return AspectRatio(
      aspectRatio: 1,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              color: cell.inMonth ? bg : null,
              borderRadius: BorderRadius.circular(10),
              border: cell.isToday
                  ? Border.all(color: scheme.primary, width: 1.6)
                  : null,
            ),
            child: Center(
              child: Text(
                '${cell.date.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: baseColor,
                  fontWeight: cell.isToday ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 表格里的颜色是**产品语义**，所以在代码里写死而不是跟着主题走——
  /// 主题换了也得保证"深绿 = 全做完、暖红 = 有没做"这件事不变。
  static (Color?, Color?) _colorsFor(DayTone tone, ColorScheme scheme) {
    return switch (tone) {
      DayTone.none => (null, scheme.onSurface),
      DayTone.light => (const Color(0xFFE8F1EB), const Color(0xFF2F4A3B)),
      DayTone.medium => (const Color(0xFFA8CBB5), const Color(0xFF1F3A2B)),
      DayTone.full => (const Color(0xFF7FB094), Colors.white),
      DayTone.warm => (const Color(0xFFFDEEE9), const Color(0xFF7A3B2E)),
    };
  }
}

/// 本月完成率 / 准时率（一根细条 + 数字，不用大圆环）。
class _MonthSummaryBar extends StatelessWidget {
  const _MonthSummaryBar({required this.summary});

  final StatsSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('本月', style: theme.textTheme.labelLarge),
              const Spacer(),
              if (summary.expected == 0)
                Text(
                  '还没有记录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                Text(
                  '共 ${summary.expected} 次',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (summary.expected > 0) ...[
            const SizedBox(height: 14),
            _RateRow(
              label: '完成率',
              rate: summary.completionRate,
              text: summary.percent(summary.completionRate),
              color: scheme.primary,
            ),
            const SizedBox(height: 10),
            _RateRow(
              label: '准时率',
              rate: summary.onTimeRate,
              text: summary.percent(summary.onTimeRate),
              color: scheme.primary.withValues(alpha: 0.55),
            ),
          ],
        ],
      ),
    );
  }
}

class _RateRow extends StatelessWidget {
  const _RateRow({
    required this.label,
    required this.rate,
    required this.text,
    required this.color,
  });

  final String label;
  final double rate;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: rate.clamp(0, 1),
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 54,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const items = <(String, Color)>[
      ('全做完', Color(0xFF7FB094)),
      ('一般', Color(0xFFA8CBB5)),
      ('松', Color(0xFFE8F1EB)),
      ('有没做', Color(0xFFFDEEE9)),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final (label, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  border: color == const Color(0xFFE8F1EB)
                      ? Border.all(color: theme.colorScheme.outlineVariant)
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
