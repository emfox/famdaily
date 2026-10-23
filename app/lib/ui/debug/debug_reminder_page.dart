import 'package:flutter/material.dart';

import '../../data/db/app_database.dart';
import '../../data/repo_impl/reminder_scheduler.dart';
import '../../domain/model/local_date.dart';
import '../../domain/notification/window_policy.dart';

/// 提醒调试页：把"到底排了哪些通知"摊开给人看。
///
/// 为什么值一个专门的页面：提醒出问题时，用户只能说"它没响"，
/// 而开发者看不到系统通知队列。这一页把每一项决策（窗口到哪天、
/// 展开多少槽位、为什么被跳过）都摆在明面上，比翻日志快得多。
///
/// 入口藏在设置里（需求里"导出备份要藏得深"是同一个思路：
/// 这些是排查工具，不是日常功能）。
class DebugReminderPage extends StatefulWidget {
  const DebugReminderPage({
    required this.db,
    required this.scheduler,
    super.key,
  });

  final AppDatabase db;
  final ReminderScheduler scheduler;

  @override
  State<DebugReminderPage> createState() => _DebugReminderPageState();
}

class _DebugReminderPageState extends State<DebugReminderPage> {
  RescheduleResult? _result;
  List<SlotRow> _slots = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final today = LocalDate.fromDateTime(DateTime.now());
      final slots = await widget.db.slotsBetween(
        today,
        today.addDays(13),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _slots = slots;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _forceReschedule() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.scheduler.reschedule(
        trigger: RescheduleTrigger.dataChanged,
      );
      if (!mounted) {
        return;
      }
      setState(() => _result = result);
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒调试'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _forceReschedule,
            icon: const Icon(Icons.bolt),
            label: const Text('强制重排一次'),
          ),
          const SizedBox(height: 16),
          if (r != null) _ResultCard(result: r),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '已落库的槽位（未来 14 天，共 ${_slots.length} 条）',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (_slots.isEmpty)
            Text(
              '还没有槽位。先去建一个打卡项目，再回来点重排。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            )
          else
            for (final s in _slots) _SlotTile(slot: s),
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final RescheduleResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('窗口覆盖到', result.windowEnd?.toString() ?? '—'),
      ('展开槽位', '${result.slots}'),
      ('规划通知', '${result.planned}'),
      ('实际排上', '${result.scheduled}'),
      ('是否被截断', result.truncated ? '是（受 56 条上限）' : '否'),
      if (result.skippedReason != null) ('跳过原因', result.skippedReason!),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('上次重排结果', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        k,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                    Expanded(child: Text(v)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot});

  final SlotRow slot;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        slot.followupId == null
            ? Icons.notifications_off_outlined
            : Icons.notifications_active_outlined,
        size: 20,
      ),
      title: Text('${slot.dueDate} ${slot.dueTime}'),
      subtitle: Text(
        '${slot.taskId.substring(0, slot.taskId.length.clamp(0, 8))} · '
        '第 ${slot.slotIndex + 1} 次 · 归属 ${slot.date}',
      ),
      trailing: Text(
        'ID ${slot.remindId ?? '—'}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
