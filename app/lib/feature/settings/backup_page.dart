import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/backup/backup_data.dart';
import '../../data/backup/backup_service.dart';
import '../../data/db/app_database.dart' show BackupCounts;

/// 导出备份（ui-spec §6.2）。
///
/// **这是保险，不是日常功能**。所以这一页刻意做得平淡：没有插图、没有
/// 引导、没有"立即备份"的催促按钮，只有三个事实——备份里有什么、
/// 存到哪、能恢复成什么样。
class BackupPage extends StatefulWidget {
  const BackupPage({required this.service, this.reschedule, super.key});

  final BackupService service;

  /// 恢复之后要立刻重排提醒（新旧数据的时间规则不一样）。
  final Future<void> Function()? reschedule;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  BackupCounts? _counts;
  bool _includePhotos = false;
  bool _busy = false;
  String? _lastResult;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCounts());
  }

  Future<void> _loadCounts() async {
    final counts = await widget.service.db.counts();
    if (mounted) {
      setState(() => _counts = counts);
    }
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
      _lastResult = null;
    });
    try {
      final result = await widget.service.exportAndShare(
        includePhotos: _includePhotos,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _lastResult =
            '${result.fileName}（${result.sizeLabel}）\n'
            '${result.data.summary}';
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '导出没成功：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 恢复：选文件 → 预览 → 二次确认 → 执行。
  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
      _lastResult = null;
    });
    try {
      final bytes = await widget.service.gateway.pickBackupFile();
      if (bytes == null) {
        return;
      }
      final preview = await widget.service.preview(bytes);
      if (!mounted) {
        return;
      }

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('用这份备份替换现在所有数据？'),
          content: Text(
            preview.warning +
                (preview.isStale() ? '\n\n⚠ 这份备份已经放了很久，确认不是旧文件。' : ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('再想想'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (!(ok ?? false)) {
        return;
      }

      await widget.service.restore(preview.incoming);
      await widget.reschedule?.call();
      await _loadCounts();
      if (mounted) {
        setState(() => _lastResult = '已恢复：${preview.incoming.summary}');
      }
    } on BackupFormatException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '恢复没成功，原来的数据没动：$e');
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
    final counts = _counts;

    return Scaffold(
      appBar: AppBar(title: Text('导出备份', style: theme.textTheme.headlineSmall)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              '备份是保险，不是日常。存到你自己的地方（网盘、邮箱、电脑），'
              '换手机或者重装的时候能原样搬回来。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ),

          const _SectionHeader('备份内容'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('只备份记录'),
                  icon: Icon(Icons.description_outlined, size: 18),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('连照片一起'),
                  icon: Icon(Icons.photo_library_outlined, size: 18),
                ),
              ],
              selected: {_includePhotos},
              onSelectionChanged: _busy
                  ? null
                  : (v) => setState(() => _includePhotos = v.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              _includePhotos
                  ? '打卡时拍的照片会一起打进去，文件会大很多。'
                  : '成员、项目、时间规则、全部打卡记录、设置。照片不含。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),

          if (counts != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                '备份内容：${counts.label}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              '格式是能直接打开看的 JSON，不是加密黑盒。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            // 不放转圈动画：打包本身是几十毫秒的事，转圈只会让界面显得更慢，
            // 而且无限动画会让 Widget 测试的 pumpAndSettle 永远等不到静止。
            child: FilledButton.icon(
              onPressed: _busy ? null : () => unawaited(_export()),
              icon: const Icon(Icons.ios_share, size: 18),
              label: Text(_busy ? '正在打包…' : '导出到文件'),
            ),
          ),

          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _Notice(
                icon: Icons.check_circle_outline,
                color: theme.colorScheme.primary,
                text: '已导出 $_lastResult',
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _Notice(
                icon: Icons.error_outline,
                color: theme.colorScheme.error,
                text: _error!,
              ),
            ),

          const SizedBox(height: 28),
          const Divider(height: 1),
          const _SectionHeader('从备份恢复'),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('选一份备份恢复'),
            subtitle: const Text('会先给你看"拿什么换什么"，确认之后才动'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            enabled: !_busy,
            onTap: () => unawaited(_restore()),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
