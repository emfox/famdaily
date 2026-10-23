import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/rule_text.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/stats/stats.dart';
import '../../data/photo/photo_store.dart';
import '../../ui/icon/task_icons.dart';
import '../members/member_avatar.dart';
import 'task_detail_service.dart';

/// 打卡项详情（ui-spec §4）。
///
/// 这一页只回答三个问题：**这是什么**（头部）、**做得怎么样**（三个数字）、
/// **最近是怎么做的**（时间线）。不做打卡操作——打卡在首页和历史页，
/// 这里再放一个勾选圈，就会出现"到底哪个才算数"的困惑。
class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({
    required this.service,
    required this.taskId,
    this.onEdit,
    this.onOpenPhoto,
    this.store,
    this.onStatusChange,
    this.onDelete,
    super.key,
  });

  final TaskDetailService service;
  final String taskId;

  /// 点「编辑」；null 时按钮不显示（只读场景）。
  final void Function(Task task)? onEdit;

  /// 点照片缩略图看大图；null 时用内置的全屏预览。
  ///
  /// 传进来的是**解析好的绝对路径**——页面内部已经做过
  /// `PhotoStore.resolve`，调用方不需要再拼目录。
  final void Function(String path)? onOpenPhoto;

  /// 照片仓库（把相对路径换成可读路径）。null 时缩略图只显示占位。
  final PhotoStore? store;

  /// 暂停/恢复/归档（ui-spec §4.1）。null 时底部不出现这几项。
  final Future<void> Function(Task task, TaskStatus status)? onStatusChange;

  /// 删除。null 时底部不出现「删除」。
  final Future<void> Function(Task task)? onDelete;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  TaskDetail? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final detail = await widget.service.load(widget.taskId);
    if (!mounted) {
      return;
    }
    setState(() {
      _detail = detail;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;

    if (detail == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('打卡项')),
        body: Center(
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  '这个打卡项已经不在了',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(detail.task.name, style: theme.textTheme.titleLarge),
        actions: [
          if (widget.onEdit != null)
            TextButton(
              onPressed: () async {
                widget.onEdit!(detail.task);
                await _load();
              },
              child: const Text('编辑'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _Header(detail: detail),
            const SizedBox(height: 18),
            _RateTiles(stats: detail.stats),
            // 一句人话解释那三个数字。光有百分比没有"共 N 次该做"，
            // 分母是 1 还是 30 看起来一模一样，但这两种情况的含义天差地别。
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                detail.headline,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Text('最近记录', style: theme.textTheme.titleSmall),
            ),
            if (detail.isEmpty)
              _EmptyRecords()
            else
              for (final day in detail.days)
                _DayGroup(
                  day: day,
                  today: detail.today,
                  store: widget.store,
                  onOpenPhoto: (path) => _openPhoto(detail, path),
                ),
            const SizedBox(height: 8),
            Text(
              '只列最近 ${TaskDetailService.recentDays} 天；更早的翻历史。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            if (widget.onStatusChange != null || widget.onDelete != null) ...[
              const SizedBox(height: 24),
              const Divider(),
              _Actions(
                task: detail.task,
                onStatusChange: widget.onStatusChange,
                onDelete: widget.onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openPhoto(TaskDetail detail, String path) {
    final custom = widget.onOpenPhoto;
    if (custom != null) {
      custom(path);
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _PhotoViewer(path: path, title: detail.task.name),
        ),
      ),
    );
  }
}

/// 底部三个动作：暂停/恢复、归档、删除（ui-spec §4.1）。
///
/// **这三条语义必须严格区分，实现时不要合并**：
///
/// | 操作 | 提醒 | 今日清单 | 记录 | 可恢复 |
/// |---|---|---|---|---|
/// | 暂停 | 停 | 不出现 | 保留 | 随时恢复 |
/// | 归档 | 停 | 不出现 | 保留 | 需「再来一轮」 |
/// | 删除 | 停 | 不出现 | **保留** | 不可 |
///
/// 所以这里给的是三个不同的动词、三种不同的确认文案，而不是一个
/// "关掉它"的开关加一个垃圾桶。用户分不清这三者的后果是：
/// 想暂停一个疗程结果删了，30 天记录再也点不回去。
class _Actions extends StatelessWidget {
  const _Actions({
    required this.task,
    required this.onStatusChange,
    required this.onDelete,
  });

  final Task task;
  final Future<void> Function(Task task, TaskStatus status)? onStatusChange;
  final Future<void> Function(Task task)? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paused = task.status == TaskStatus.paused;
    final archived = task.status == TaskStatus.archived;

    return Column(
      children: [
        if (onStatusChange != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              paused ? Icons.play_circle_outline : Icons.pause_circle_outline,
              color: scheme.primary,
            ),
            title: Text(paused ? '恢复这项' : '暂停这项'),
            subtitle: Text(paused ? '重新出现在今日清单里' : '出门旅行时用 · 记录保留，随时恢复'),
            onTap: () => onStatusChange!(
              task,
              paused ? TaskStatus.active : TaskStatus.paused,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              archived ? Icons.unarchive_outlined : Icons.inventory_2_outlined,
              color: scheme.primary,
            ),
            title: Text(archived ? '再来一轮' : '归档'),
            subtitle: Text(archived ? '按原来的规则重新开始' : '疗程结束就收起来 · 记录保留'),
            onTap: () => onStatusChange!(
              task,
              archived ? TaskStatus.active : TaskStatus.archived,
            ),
          ),
        ],
        if (onDelete != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: scheme.error),
            title: Text('删除', style: TextStyle(color: scheme.error)),
            subtitle: const Text('从清单里去掉 · 日历里的记录还在，但不能再改'),
            onTap: () => onDelete!(task),
          ),
      ],
    );
  }
}

/// 头部：图标 + 「爷爷 · 每天 3 次 / 7:30 / 12:30 / 18:30 / 疗程」。
class _Header extends StatelessWidget {
  const _Header({required this.detail});

  final TaskDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final task = detail.task;
    final member = detail.member;
    final progress = RuleText.courseProgress(task.course, detail.today);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TaskIconBadge(iconId: task.iconId, size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (member != null) ...[
                    MemberAvatar(member: member, size: 20),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      member?.name ?? '已删除的成员',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _StatusChip(task: task),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                RuleText.cadence(task),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                RuleText.timesLine(task),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                progress == null
                    ? '疗程：${RuleText.course(task.course)}'
                    : '疗程：${RuleText.course(task.course)} · $progress',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
              if (task.note?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    task.note!.trim(),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 状态小标签：进行中不画（默认状态，画出来只是噪音）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 「进行中」是默认态，标出来只会让每一行都多一个标签。
    if (task.deletedAtMs != null) {
      return _chip(scheme, '已删除');
    }
    return switch (task.status) {
      TaskStatus.active => const SizedBox.shrink(),
      final s => _chip(scheme, s.labelZh),
    };
  }

  Widget _chip(ColorScheme scheme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, height: 1.4, color: scheme.outline),
      ),
    );
  }
}

/// 三个数字：完成率 / 准时率 / 没做次数（ui-spec §4）。
///
/// 只给"没做次数"不给"没做率"：一次没做和十次没做在这个 App 里都只是
/// 一个事实，换算成百分比反而像在打分。
class _RateTiles extends StatelessWidget {
  const _RateTiles({required this.stats});

  final StatsSummary stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tiles = <(String, String, Color)>[
      (stats.percent(stats.completionRate), '完成率', scheme.primary),
      (stats.percent(stats.onTimeRate), '准时率', scheme.primary),
      ('${stats.skipped}', '没做', scheme.outline),
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
                        fontFeatures: const [FontFeature.tabularFigures()],
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

/// 一天一组：日期分隔 + 当天各条。
class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.day,
    required this.today,
    required this.store,
    required this.onOpenPhoto,
  });

  final RecordDay day;
  final LocalDate today;
  final PhotoStore? store;
  final void Function(String path) onOpenPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
          child: Row(
            children: [
              Text(
                day.label(today),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Divider(height: 1)),
            ],
          ),
        ),
        for (final e in day.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _RecordRow(entry: e, store: store, onOpenPhoto: onOpenPhoto),
          ),
      ],
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.entry,
    required this.store,
    required this.onOpenPhoto,
  });

  final RecordEntry entry;
  final PhotoStore? store;
  final void Function(String path) onOpenPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = entry.state;
    final (color, mark, label) = switch (state) {
      CheckinState.done => (scheme.primary, Icons.check_circle, '准时完成'),
      CheckinState.makeup => (
        scheme.primary,
        Icons.check_circle_outline,
        entry.makeupNote ?? '补卡',
      ),
      CheckinState.skipped => (scheme.outline, Icons.close, '没做'),
      null => (scheme.outline, Icons.remove_circle_outline, '还没记'),
    };

    final note = entry.note;
    final subtitle = <String>[
      if (note != null && note.trim().isNotEmpty) note.trim(),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              _hm(entry.dueMinuteOfDay),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Icon(mark, size: 17, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    decoration: state == CheckinState.skipped
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (entry.hasPhoto)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _Thumb(
                relativePath: entry.record!.photoPath!,
                store: store,
                onTap: onOpenPhoto,
              ),
            ),
        ],
      ),
    );
  }
}

/// 缩略图。
///
/// 分两步是必须的：库里存的是**相对路径**（`2025/03/xxx.jpg`），
/// 绝对路径在 iOS 每次升级后都会变。所以要先 `resolve` 拿到当前的绝对路径，
/// 再画。
///
/// 解析不到就画占位而不是崩：照片可能被用户从系统相册清理掉了，
/// 也可能这份数据是从没带照片的备份恢复来的——两种情况记录本身都还有效。
class _Thumb extends StatefulWidget {
  const _Thumb({
    required this.relativePath,
    required this.store,
    required this.onTap,
  });

  final String relativePath;
  final PhotoStore? store;
  final ValueChanged<String> onTap;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  String? _abs;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final store = widget.store;
    final abs = store == null
        // 没注入 store（测试/只读场景）：把相对路径当绝对路径试试。
        ? (File(widget.relativePath).existsSync() ? widget.relativePath : null)
        : await store.resolve(widget.relativePath);
    if (mounted) {
      setState(() {
        _abs = abs;
        _resolved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final abs = _abs;

    return InkWell(
      onTap: abs == null ? null : () => widget.onTap(abs),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 44,
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: abs != null
            ? Image.file(
                File(abs),
                fit: BoxFit.cover,
                cacheWidth: 132,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  size: 18,
                  color: scheme.outline,
                ),
              )
            : Icon(
                // 解析完才知道真的没有；还没解析完时先不显示叉，避免闪一下。
                _resolved
                    ? Icons.image_not_supported_outlined
                    : Icons.image_outlined,
                size: 18,
                color: scheme.outline,
              ),
      ),
    );
  }
}

class _EmptyRecords extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(
            Icons.timeline_outlined,
            size: 40,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '最近还没排到这项',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 内置的全屏看大图（替代 `onOpenPhoto` 未注入时的兜底）。
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          child: Image.file(
            File(path),
            errorBuilder: (_, _, _) =>
                const Text('照片找不到了', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
  }
}

/// 未归一化的分钟 → `7:30` / `次日1:00`。
String _hm(int minuteOfDay) {
  final days = (minuteOfDay / 1440).floor();
  final m = minuteOfDay - days * 1440;
  final h = m ~/ 60;
  final mm = (m % 60).toString().padLeft(2, '0');
  return days > 0 ? '次日$h:$mm' : '$h:$mm';
}
