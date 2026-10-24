import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/backup/backup_data.dart';
import '../../data/backup/backup_service.dart';
import '../../data/db/app_database.dart' show BackupCounts;
import '../../data/sync/sync_api.dart';
import '../../data/sync/sync_service.dart';

/// 导出备份（ui-spec §6.2）。
///
/// **这是保险，不是日常功能**。所以这一页刻意做得平淡：没有插图、没有
/// 引导、没有"立即备份"的催促按钮，只有三个事实——备份里有什么、
/// 存到哪、能恢复成什么样。
class BackupPage extends StatefulWidget {
  const BackupPage({
    required this.service,
    this.reschedule,
    this.sync,
    super.key,
  });

  final BackupService service;

  /// 同步服务。为 null 时不显示「从服务端导出」那一块 ——
  /// 没配对过的人点了只会得到一个错误。
  final SyncService? sync;

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

  /// 「从服务端导出」单独一套忙碌/错误状态。
  ///
  /// 不复用 `_busy` / `_error`：这两个错法完全不同（一个是打包本地库，
  /// 一个是走网络），混在一起会让"本地导出失败"的提示出现在云端那一行下面。
  bool _remoteBusy = false;
  String? _remoteError;

  /// 配没配对。**异步问出来的**（读 settings 表），所以有"还没问完"这一态。
  bool? _paired;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCounts());
    unawaited(_loadPaired());
  }

  Future<void> _loadPaired() async {
    final sync = widget.sync;
    if (sync == null) {
      // 没给 SyncService（只可能出现在测试里）：当成没配对，不显示那一块。
      if (mounted) setState(() => _paired = false);
      return;
    }
    final paired = await sync.isPaired();
    if (mounted) setState(() => _paired = paired);
  }

  /// 从服务端取一份备份并弹分享。
  ///
  /// 拿到的字节**原样**写文件，不解析再序列化 —— 它本身就是 App 的备份格式，
  /// 重新编码会改键顺序，用户对比两份文件时会以为不是同一个东西。
  Future<void> _exportFromServer() async {
    final sync = widget.sync;
    if (sync == null) return;
    setState(() {
      _remoteBusy = true;
      _remoteError = null;
    });
    try {
      final bytes = await sync.exportBackupBytes();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      // 和 `BackupData.suggestedFileName` 同样的命名，只是后缀是 .json。
      // **不用 .zip**：这份没有照片，是个纯 JSON 文件，改名会让用户以为
      // "解压出来应该有照片"。
      final name =
          'famdaily-backup-${now.year}-${two(now.month)}-${two(now.day)}.json';
      // 复用备份页已有的文件网关：它已经处理了"每次导出建独立子目录"，
      // 那个细节很重要（同名文件被覆盖过一次，分享出去的可能是旧内容）。
      final path = await widget.service.gateway.writeTempFile(
        name,
        Uint8List.fromList(bytes),
      );
      await widget.service.gateway.share(path, subject: 'Famdaily 云端备份');
    } on SyncNotPairedException {
      if (mounted) setState(() => _remoteError = '还没配对过，取不到云端数据。');
    } on SyncAuthException catch (e) {
      if (mounted) {
        setState(() => _remoteError = '同步凭据失效了（${e.statusCode}），要重新配对。');
      }
    } on TransportException catch (e) {
      if (mounted) setState(() => _remoteError = '连不上服务：${e.message}');
    } catch (e) {
      if (mounted) setState(() => _remoteError = '取回来失败了：$e');
    } finally {
      if (mounted) setState(() => _remoteBusy = false);
    }
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
          // `_paired == true` 才显示。没配对的人看到一行"从云端取一份"，
          // 点进去只会得到"还没配对" —— 不如不显示，让他在同步页去配。
          // `null`（还没问完）也不显示：先出现再消失比晚出现更烦。
          if (_paired == true) ...[
            const SizedBox(height: 20),
            const Divider(height: 1),
            const _SectionHeader('从云端取一份'),
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('从服务端导出'),
              subtitle: const Text('本机数据坏了也能取回，格式和上面那份一样'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              enabled: !_busy && !_remoteBusy,
              onTap: () => unawaited(_exportFromServer()),
            ),
            if (_remoteError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _Notice(
                  icon: Icons.error_outline,
                  color: theme.colorScheme.error,
                  text: _remoteError!,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                // 说清楚它**多出来**的价值，否则用户会问"和上面那个有什么区别"。
                // 一句话：本机没了也能取回来，因为数据本来就在服务端有一份。
                '这一份是从服务端取的，本机的数据库坏了或者换了手机也能用。'
                '照片不在服务端，所以这一份永远不含照片。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
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
  const _Notice({required this.icon, required this.color, required this.text});

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
