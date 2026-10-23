import 'package:flutter/material.dart';

import '../../domain/model/checkin_row.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../members/member_avatar.dart';
import '../theme/status_style.dart';
import 'today_service.dart';

/// 今日清单（ui-spec §1）。
///
/// 一个 Page 两种排法（时间轴 / 成员），分段控件切换，选择会被记住
/// （由外部传入的 [layout] + [onLayoutChanged] 负责持久化）。
class TodayPage extends StatelessWidget {
  const TodayPage({
    required this.view,
    required this.layout,
    required this.onLayoutChanged,
    required this.onTapRow,
    required this.onNewTask,
    required this.onRefresh,
    required this.loading,
    super.key,
  });

  final TodayView view;
  final HomeLayout layout;
  final ValueChanged<HomeLayout> onLayoutChanged;

  /// 点某一行（勾选或整行）时回调。
  final void Function(CheckinRow row, {required bool tappedCircle}) onTapRow;

  final VoidCallback onNewTask;
  final Future<void> Function() onRefresh;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              view.now == null
                  ? '今天'
                  : '${view.now!.hour.toString().padLeft(2, '0')}:'
                        '${view.now!.minute.toString().padLeft(2, '0')}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            Text('今天', style: theme.textTheme.headlineSmall),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) {
              if (v == 'new') {
                onNewTask();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'new', child: Text('新建打卡项')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: view.isEmpty
            ? _EmptyState(onNewTask: onNewTask)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  _LayoutSwitch(
                    layout: layout,
                    onChanged: onLayoutChanged,
                  ),
                  _ProgressHeader(view: view),
                  const SizedBox(height: 8),
                  if (layout == HomeLayout.timeline)
                    ..._timelineGroups(context)
                  else
                    ..._memberGroups(context),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
      ),
    );
  }

  List<Widget> _timelineGroups(BuildContext context) {
    return [
      if (view.overdue.isNotEmpty) ...[
        _GroupHeader(
          title: '今天漏了',
          color: Theme.of(context).colorScheme.error,
        ),
        for (final r in view.overdue)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: CheckinTile(
              row: r,
              now: view.now!,
              today: view.date!,
              onTap: (circle) => onTapRow(r, tappedCircle: circle),
            ),
          ),
      ],
      if (view.done.isNotEmpty) ...[
        const _GroupHeader(title: '已完成'),
        for (final r in view.done)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: CheckinTile(
              row: r,
              now: view.now!,
              today: view.date!,
              onTap: (circle) => onTapRow(r, tappedCircle: circle),
            ),
          ),
      ],
      if (view.upcoming.isNotEmpty) ...[
        const _GroupHeader(title: '接下来'),
        for (final r in view.upcoming)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: CheckinTile(
              row: r,
              now: view.now!,
              today: view.date!,
              onTap: (circle) => onTapRow(r, tappedCircle: circle),
            ),
          ),
      ],
    ];
  }

  List<Widget> _memberGroups(BuildContext context) {
    return [
      for (final section in view.sections)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      MemberAvatar(member: section.member, size: 28),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          section.member.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        '${section.doneCount} / ${section.totalCount}',
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                for (final r in section.rows)
                  CheckinTile(
                    row: r,
                    now: view.now!,
                    today: view.date!,
                    dense: true,
                    onTap: (circle) => onTapRow(r, tappedCircle: circle),
                  ),
              ],
            ),
          ),
        ),
    ];
  }
}

class _LayoutSwitch extends StatelessWidget {
  const _LayoutSwitch({required this.layout, required this.onChanged});

  final HomeLayout layout;
  final ValueChanged<HomeLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<HomeLayout>(
        segments: const [
          ButtonSegment(
            value: HomeLayout.timeline,
            label: Text('时间轴'),
            icon: Icon(Icons.schedule, size: 18),
          ),
          ButtonSegment(
            value: HomeLayout.members,
            label: Text('成员'),
            icon: Icon(Icons.people_outline, size: 18),
          ),
        ],
        selected: {layout},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
      ),
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.view});

  final TodayView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('今天已完成', style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              '${view.doneCount} / ${view.totalCount}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: view.progress,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, this.color});

  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: c,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: c.withValues(alpha: 0.2))),
        ],
      ),
    );
  }
}

/// 一行打卡项。
///
/// 五态视觉严格按 ui-spec：**实心=准时，空心=补，叉=没做，空心待做=还来得及**。
class CheckinTile extends StatelessWidget {
  const CheckinTile({
    required this.row,
    required this.now,
    required this.today,
    required this.onTap,
    this.dense = false,
    super.key,
  });

  final CheckinRow row;
  final LocalTime now;
  final LocalDate today;
  final void Function(bool tappedCircle) onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = row.visual(today, now);
    final style = StatusStyle.of(visual, theme.colorScheme);
    final done = visual == CheckinVisual.doneOnTime ||
        visual == CheckinVisual.doneMakeup ||
        visual == CheckinVisual.skipped;

    final subtitle = _subtitle(visual, theme);

    return Material(
      color: style.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onTap(false),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 14,
            vertical: dense ? 8 : 12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: style.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.task.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                        color: done
                            ? theme.colorScheme.outline
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: visual == CheckinVisual.overdue
                            ? theme.colorScheme.error
                            : theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusMark(
                visual: visual,
                style: style,
                onTap: () => onTap(true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(CheckinVisual visual, ThemeData theme) {
    final t = row.dueAt.time;
    final hhmm =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';

    if (visual == CheckinVisual.overdue) {
      final late = row.lateMinutes(now);
      // 过去的日子不显示"迟 N 分钟"——那个数字没意义（ui-spec）。
      if (late > 0 && row.date.isSameDay(today)) {
        return '应于 $hhmm · 迟 $late 分钟';
      }
      return '应于 $hhmm';
    }
    if (visual == CheckinVisual.doneOnTime) {
      return '$hhmm · 准时';
    }
    if (visual == CheckinVisual.doneMakeup) {
      return '$hhmm · 补卡';
    }
    if (visual == CheckinVisual.skipped) {
      return '$hhmm · 没做';
    }
    return hhmm;
  }
}

/// 右侧的状态标记。点它触发打卡/撤销。
class _StatusMark extends StatelessWidget {
  const _StatusMark({
    required this.visual,
    required this.style,
    required this.onTap,
  });

  final CheckinVisual visual;
  final StatusStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: switch (visual) {
            // 实心绿：准时
            CheckinVisual.doneOnTime => Icon(
              Icons.check_circle,
              color: style.foreground,
              size: 26,
            ),
            // 空心绿：补卡
            CheckinVisual.doneMakeup => Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: style.foreground, width: 2),
              ),
              child: Icon(Icons.check, size: 14, color: style.foreground),
            ),
            // 灰叉：没做
            CheckinVisual.skipped => Icon(
              Icons.close,
              color: style.foreground,
              size: 22,
            ),
            // 空心圆：待做 / 已过时间
            _ => Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: visual == CheckinVisual.overdue
                      ? style.foreground
                      : Theme.of(context).colorScheme.outlineVariant,
                  width: 2,
                ),
              ),
            ),
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onNewTask});

  final VoidCallback onNewTask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      // 用 ListView 而不是 Center：下拉刷新在空状态下也要能用。
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(
          Icons.checklist_rtl,
          size: 56,
          color: theme.colorScheme.outlineVariant,
        ),
        const SizedBox(height: 16),
        Text(
          '还没有打卡项',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          '给家人加一件每天要做的小事',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.tonal(
            onPressed: onNewTask,
            child: const Text('新建打卡项'),
          ),
        ),
      ],
    );
  }
}
