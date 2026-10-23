import 'package:flutter/material.dart';

import '../../app/app_boot.dart';
import '../../data/repo_impl/reminder_scheduler.dart';
import '../../domain/notification/window_policy.dart';

/// 设置页。
///
/// 原则：**P0 的救命功能藏深，日常开关放浅**。
/// 导出备份、提醒调试这些"一辈子用两次但关键"的东西放最下面；
/// 免打扰、提醒时间这些影响每天体验的放上面。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.services,
    required this.onOpenDebug,
    this.onOpenMembers,
    this.memberCount,
    super.key,
  });

  final AppServices services;

  /// 调试入口（走「关于」里的彩蛋进）。
  final VoidCallback onOpenDebug;

  /// 打开成员管理；null = 这一屏不支持（测试里可以省掉）。
  final VoidCallback? onOpenMembers;

  /// 成员数，显示在「成员」右侧。null = 不显示。
  final int? memberCount;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _versionTaps = 0;
  bool _loading = true;
  bool _remindersOn = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.services.db;
    final raw = await db.getSetting(SettingsKeys.remindersEnabled);
    if (!mounted) {
      return;
    }
    setState(() {
      _remindersOn = raw != 'false';
      _loading = false;
    });
  }

  Future<void> _setReminders(bool on) async {
    setState(() => _remindersOn = on);
    await widget.services.db.setSetting(
      SettingsKeys.remindersEnabled,
      on ? 'true' : 'false',
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    // 全局关提醒也要重排：否则系统队列里那几十条还会照常响。
    await widget.services.scheduler.reschedule(
      trigger: RescheduleTrigger.settingsChanged,
    );
  }

  /// 连点版本号 5 次露出调试入口（测试也要点 5 次，别改成隐藏手势）。
  void _onVersionTap() {
    _versionTaps++;
    if (_versionTaps == 4) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('再点一次…')));
    }
    if (_versionTaps >= 5) {
      _versionTaps = 0;
      widget.onOpenDebug();
    }
  }

  void _notReady(String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what：下一步做')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('设置', style: theme.textTheme.headlineSmall)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const _SectionHeader('提醒'),
                SwitchListTile.adaptive(
                  value: _remindersOn,
                  onChanged: (v) => _setReminders(v),
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('到点提醒'),
                  subtitle: const Text('关掉之后所有项目都不响，打卡照常'),
                ),
                ListTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: const Text('免打扰'),
                  subtitle: const Text('这段时间里的提醒会顺延到结束之后'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _notReady('免打扰时段'),
                ),
                const Divider(height: 24),

                const _SectionHeader('家人'),
                ListTile(
                  leading: const Icon(Icons.group_outlined),
                  title: const Text('成员'),
                  subtitle: const Text('加人、改名字、换头像'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.memberCount != null)
                        Text(
                          '${widget.memberCount} 位',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  enabled: widget.onOpenMembers != null,
                  onTap: widget.onOpenMembers,
                ),
                const Divider(height: 24),

                const _SectionHeader('数据'),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出备份'),
                  // 需求里这条是 P0，但明确要求"藏得好一点"——
                  // 放这里而不是首页，是因为它是救命功能，不是日常功能。
                  subtitle: const Text('存一份 JSON 到手机里，换机时能搬回来'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _notReady('导出备份'),
                ),
                const Divider(height: 24),

                const _SectionHeader('关于'),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('版本'),
                  subtitle: const Text('0.1.0（开发中）'),
                  onTap: _onVersionTap,
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Famdaily 只做一件事：让家里那些「每天都要做的小事」'
                    '有人记得、有人看见。\n不排名、不加分、不催命。',
                    style: TextStyle(fontSize: 12, height: 1.6),
                  ),
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}
