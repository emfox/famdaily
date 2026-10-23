import 'dart:async';

import 'package:flutter/material.dart';

import '../members/member_avatar.dart';
import 'stats_service.dart';

/// 统计页（ui-spec §3.3）。
///
/// **不显示"连续打卡天数"**。需求 3.7 写得很清楚：连续天数会激励人
/// 为了保数字而补卡，数据就脏了。这一页只回答"该做的做了多少次"。
class StatsPage extends StatefulWidget {
  const StatsPage({required this.service, super.key});

  final StatsService service;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsPeriod _period = StatsPeriod.thisMonth;
  String? _memberFilter;
  StatsView? _view;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final view = await widget.service.load(
      period: _period,
      memberFilter: _memberFilter,
    );
    if (mounted) {
      setState(() => _view = view);
    }
  }

  void _setPeriod(StatsPeriod p) {
    setState(() => _period = p);
    unawaited(_load());
  }

  void _setMember(String? id) {
    setState(() => _memberFilter = id);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view;

    return Scaffold(
      appBar: AppBar(
        title: Text('统计', style: theme.textTheme.headlineSmall),
      ),
      body: view == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final p in StatsPeriod.values)
                        ChoiceChip(
                          label: Text(p.label),
                          selected: _period == p,
                          onSelected: (_) => _setPeriod(p),
                        ),
                      const SizedBox(width: 4),
                      // 成员筛选用下拉而不是一排 Chip：家里四五个人，
                      // 一排 Chip 会换行换得很难看。
                      _MemberDropdown(
                        rows: view.rows,
                        selected: _memberFilter,
                        onChanged: _setMember,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _OverallCard(view: view),
                ),
                const SizedBox(height: 24),
                if (view.rows.length > 1) ...[
                  const _SectionHeader('按成员'),
                  for (final row in view.rows)
                    _MemberRowTile(row: row, onTap: () => _setMember(row.member.id)),
                ],
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    '完成率 =（准时 + 补卡）/ 该做；准时率 = 准时 / 该做。\n'
                    '没做的会计入分母，但不会把你的数字"抹掉"。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.view});

  final StatsView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = view.overall;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _BigRate(
                  label: '完成率',
                  value: s.percent(s.completionRate),
                  ratio: s.completionRate,
                  emphasized: true,
                ),
              ),
              Expanded(
                child: _BigRate(
                  label: '准时率',
                  value: s.percent(s.onTimeRate),
                  ratio: s.onTimeRate,
                  emphasized: false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            view.headline,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _BigRate extends StatelessWidget {
  const _BigRate({
    required this.label,
    required this.value,
    required this.ratio,
    required this.emphasized,
  });

  final String label;
  final String value;
  final double ratio;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = emphasized
        ? theme.colorScheme.primary
        : theme.colorScheme.primary.withValues(alpha: 0.45);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}

class _MemberRowTile extends StatelessWidget {
  const _MemberRowTile({required this.row, required this.onTap});

  final MemberStatsRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = row.summary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          children: [
            MemberAvatar(member: row.member, size: 32),
            const SizedBox(width: 12),
            SizedBox(
              width: 64,
              child: Text(
                row.member.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: s.completionRate.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.primary.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${s.percent(s.completionRate)} / ${s.percent(s.onTimeRate)}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberDropdown extends StatelessWidget {
  const _MemberDropdown({
    required this.rows,
    required this.selected,
    required this.onChanged,
  });

  final List<MemberStatsRow> rows;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ids = {for (final r in rows) r.member.id};
    // 选中的成员在这段时间没有数据时也要能在下拉里找到，
    // 否则筛完会"看起来像筛丢了"。
    final showSelected = selected != null && !ids.contains(selected);

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: selected,
        borderRadius: BorderRadius.circular(12),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('全部成员'),
          ),
          for (final r in rows)
            DropdownMenuItem<String?>(
              value: r.member.id,
              child: Text(r.member.name),
            ),
          if (showSelected)
            DropdownMenuItem<String?>(
              value: selected,
              child: const Text('（这段时间没有记录）'),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
