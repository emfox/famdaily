import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/uuid.dart';
import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_row.dart';
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../home/checkin_sheets.dart';
import '../home/today_page.dart' show MemberAvatar;
import '../theme/status_style.dart';
import 'history_service.dart';

/// 某一天的明细 + 补卡（ui-spec §3.2）。
///
/// 补卡这件事只有一个入口：点那条"可补"的行 → 弹出和首页超时项**同一个**
/// 两出口弹层。复用同一个弹层不是省事，而是保证"补卡 / 没做"的语义
/// 在首页和历史页里**永远一致**——两处各写一个，迟早会有一处把
/// "没做"记成"做了"。
class DayDetailPage extends StatefulWidget {
  const DayDetailPage({
    required this.service,
    required this.date,
    this.db,
    this.scheduler,
    super.key,
  });

  final HistoryService service;
  final LocalDate date;

  /// 写入用；null 表示只读浏览（Widget 测试可以直接只测渲染）。
  final AppDatabase? db;

  /// 打卡后立刻静音该槽位，与首页行为一致。
  final ReminderCanceller? scheduler;

  @override
  State<DayDetailPage> createState() => _DayDetailPageState();
}

/// 只依赖"取消某槽位提醒"这一个动作，避免历史页拖进整个调度器。
abstract interface class ReminderCanceller {
  Future<void> cancelForCheckin({
    required String taskId,
    required LocalDate date,
    required int slotIndex,
  });
}

class _DayDetailPageState extends State<DayDetailPage> {
  DayDetail? _detail;
  List<Member> _members = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final detail = await widget.service.loadDay(widget.date);
    final db = widget.db;
    final members = db == null ? <Member>[] : await db.listMembers();
    if (!mounted) {
      return;
    }
    setState(() {
      _detail = detail;
      _members = members;
      _loading = false;
    });
  }

  Future<void> _onTapRow(CheckinRow row) async {
    final detail = _detail;
    if (detail == null || !detail.editable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              HistoryService.readOnlyHint(
                detail?.date ?? widget.date,
                LocalDate.fromDateTime(clock.now()),
              ),
            ),
          ),
        );
      return;
    }

    final visual = row.visual(detail.date, detail.now);
    switch (visual) {
      case CheckinVisual.doneOnTime:
      case CheckinVisual.doneMakeup:
      case CheckinVisual.skipped:
        // 已结案 → 撤销（与首页一致：再点一下就是回退）。
        final ok = await widget.service.undo(row: row, today: detail.date);
        if (!mounted) {
          return;
        }
        if (!ok) {
          _snack('超过 ${HistoryService.editWindowDays} 天，不能再改了');
          return;
        }
        await _load();
        return;

      case CheckinVisual.overdue:
      case CheckinVisual.pending:
        // 历史里的"还来得及"其实是过去某天没交代，语义上等同于超时：
        // 都要问一句"做了没记 / 没做"，绝不自作主张记成准时。
        final choice = await showOverdueSheet(context, row);
        if (choice == null || !mounted) {
          return;
        }
        await _write(row, choice);
        if (mounted) {
          await _load();
        }
    }
  }

  Future<void> _write(CheckinRow row, CheckinChoice choice) async {
    final db = widget.db;
    if (db == null) {
      return;
    }
    final state = switch (choice) {
      CheckinChoice.done => CheckinState.done,
      CheckinChoice.makeup => CheckinState.makeup,
      CheckinChoice.skipped => CheckinState.skipped,
    };
    final nowMs = clock.now().millisecondsSinceEpoch;
    await db.upsertCheckin(
      CheckinRecord(
        id: row.record?.id ?? newId(),
        taskId: row.task.id,
        date: row.date,
        slotIndex: row.slotIndex,
        state: state,
        doneAtMs: nowMs,
        dueAtMinuteOfDay: row.dueMinuteOfDay,
        note: row.record?.note,
        photoPath: row.record?.photoPath,
      ),
      nowMs: nowMs,
    );
    await widget.scheduler?.cancelForCheckin(
      taskId: row.task.id,
      date: row.date,
      slotIndex: row.slotIndex,
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final memberMap = {for (final m in _members) m.id: m};

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.date.month}月${widget.date.day}日',
          style: theme.textTheme.titleLarge,
        ),
      ),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _SummaryTiles(detail: detail),
                  if (!detail.editable) ...[
                    const SizedBox(height: 10),
                    _ReadOnlyNotice(
                      text: HistoryService.readOnlyHint(
                        detail.date,
                        LocalDate.fromDateTime(clock.now()),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (detail.isEmpty)
                    _EmptyDay(date: detail.date)
                  else
                    ..._buildGroups(context, detail, memberMap),
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

  List<Widget> _buildGroups(
    BuildContext context,
    DayDetail detail,
    Map<String, Member> memberMap,
  ) {
    final grouped = HistoryService.groupByMember(detail.rows);
    final widgets = <Widget>[];
    // 按成员出现顺序（service 已按成员排序过行）。
    for (final entry in grouped.entries) {
      final member = memberMap[entry.key];
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: Row(
            children: [
              if (member != null) ...[
                MemberAvatar(member: member, size: 22),
                const SizedBox(width: 8),
              ],
              Text(
                member?.name ?? '已删除的成员',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
        ),
      );
      for (final row in entry.value) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _HistoryTile(
              row: row,
              detail: detail,
              onTap: () => unawaited(_onTapRow(row)),
            ),
          ),
        );
      }
    }
    return widgets;
  }
}

/// 顶部三个数字：完成 / 补卡 / 没做（ui-spec §3.2）。
class _SummaryTiles extends StatelessWidget {
  const _SummaryTiles({required this.detail});

  final DayDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = detail.summary;
    final done = s.expected - s.skipped - s.unrecorded;

    final tiles = <(String, String, Color)>[
      ('${done.clamp(0, s.expected)}/${s.expected}', '完成', scheme.primary),
      ('${s.makeup}', '补卡', scheme.primary.withValues(alpha: 0.7)),
      ('${s.skipped}', '没做', scheme.outline),
    ];

    return Row(
      children: [
        for (final (value, label, color) in tiles)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Text(
                      value,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline,
            size: 15,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 历史里的一行：与首页同款五态，但**不带勾选圈**——这里不是打卡台，
/// 点整行才进入"改这一笔"的选择。
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.row,
    required this.detail,
    required this.onTap,
  });

  final CheckinRow row;
  final DayDetail detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visual = row.visual(detail.date, detail.now);
    final style = StatusStyle.of(visual, scheme);
    final tag = _tagOf(visual);

    return Material(
      color: style.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: detail.editable ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.task.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              decoration: visual == CheckinVisual.skipped
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: style.foreground,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (tag != null)
                          _Tag(text: tag, color: style.foreground),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _hm(row.dueMinuteOfDay),
                        if (row.record?.note?.isNotEmpty ?? false) row.record!.note!,
                        if (row.record?.photoPath != null) '📷',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _VisualMark(visual: visual, color: style.foreground),
            ],
          ),
        ),
      ),
    );
  }

  static String? _tagOf(CheckinVisual v) => switch (v) {
    CheckinVisual.doneOnTime => '准时',
    CheckinVisual.doneMakeup => '补',
    CheckinVisual.skipped => '没做',
    CheckinVisual.overdue => '可补',
    CheckinVisual.pending => '可补',
  };
}

/// 五态图形，与首页同一套：实心=准时，空心=补，叉=没做，空心圈=可补。
class _VisualMark extends StatelessWidget {
  const _VisualMark({required this.visual, required this.color});

  final CheckinVisual visual;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return switch (visual) {
      CheckinVisual.doneOnTime => Icon(
        Icons.check_circle,
        size: 22,
        color: color,
      ),
      CheckinVisual.doneMakeup => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.6),
        ),
        child: Icon(Icons.check, size: 13, color: color),
      ),
      CheckinVisual.skipped => Icon(Icons.close, size: 22, color: color),
      CheckinVisual.overdue || CheckinVisual.pending => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1.4),
        ),
      ),
    };
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, height: 1.4, color: color),
      ),
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.date});

  final LocalDate date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.event_available_outlined,
            size: 44,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '这天没有安排',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

String _hm(int minuteOfDay) =>
    '${minuteOfDay ~/ 60}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';
