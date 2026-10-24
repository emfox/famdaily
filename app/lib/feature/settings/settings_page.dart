import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_boot.dart';
import '../../app/build_info.dart';
import '../../data/backup/backup_service.dart';
import '../../data/repo_impl/reminder_scheduler.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_service.dart';
import '../../domain/notification/window_policy.dart';
import 'backup_page.dart';
import 'reminder_permission.dart';
import 'reminder_settings_page.dart';
import 'sync_page.dart';

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
    this.backup,
    super.key,
  });

  final AppServices services;

  /// 调试入口（走「关于」里的彩蛋进）。
  final VoidCallback onOpenDebug;

  /// 打开成员管理；null = 这一屏不支持（测试里可以省掉）。
  final VoidCallback? onOpenMembers;

  /// 成员数，显示在「成员」右侧。null = 不显示。
  final int? memberCount;

  /// 备份服务；null = 这一屏没有备份入口（测试里可以省掉）。
  final BackupService? backup;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _versionTaps = 0;
  bool _loading = true;
  bool _remindersOn = true;
  String? _backupHint;
  ReminderSettings? _reminderSettings;

  /// 系统层能力：有没有通知权限、能不能排精确闹钟。
  ///
  /// 单独读一次而不是并进 `_load` 的 Future.wait：这是唯一会去敲系统接口的
  /// 一项，慢一点不该拖住整页的渲染。
  ReminderCapability? _capability;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_loadCapability());
  }

  Future<void> _loadCapability() async {
    final c = await readCapability(widget.services.notifications);
    if (mounted) {
      setState(() => _capability = c);
    }
  }

  /// 「去开启」：申请一遍，回来把结果写回界面。
  ///
  /// 申请完要重排一次：没权限期间那些通知根本没进系统，光有权限没人去排。
  Future<void> _fixCapability() async {
    final c = await requestPermissions(widget.services.notifications);
    if (!mounted) {
      return;
    }
    setState(() => _capability = c);
    if (c == ReminderCapability.ready) {
      await widget.services.scheduler.reschedule(
        trigger: RescheduleTrigger.settingsChanged,
      );
      if (mounted) {
        await _load();
      }
    }
  }

  Future<void> _load() async {
    final db = widget.services.db;
    final raw = await db.getSetting(SettingsKeys.remindersEnabled);
    // 备份提示是**轻提示**：超过 30 天才出现一行小字，不弹窗、不加红点。
    final hint = await widget.backup?.reminderLine();
    final reminders = await ReminderSettingsStore(db).load();
    if (!mounted) {
      return;
    }
    setState(() {
      _remindersOn = raw != 'false';
      _backupHint = hint;
      _reminderSettings = reminders;
      _loading = false;
    });
  }

  /// 副标题：把"催不催、几点到几点别吵"压成一行，省一次点击。
  String get _reminderSummary {
    final r = _reminderSettings;
    if (r == null) {
      return '';
    }
    final fu = r.followupEnabled ? '再催 ${r.followupMinutes} 分钟' : '不催';
    return r.quietEnabled ? '$fu · 安静 ${r.quietLabel}' : fu;
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

  Future<void> _openReminders() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReminderSettingsPage(
          store: ReminderSettingsStore(widget.services.db),
          reschedule: () async {
            await widget.services.scheduler.reschedule(
              trigger: RescheduleTrigger.settingsChanged,
            );
          },
        ),
      ),
    );
    await _load();
  }

  Future<void> _openSync() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SyncPage(
          service: widget.services.sync,
          config: SyncConfigStore(widget.services.db),
          // 配对/断开之后这一行要跟着变
          onPaired: () async {
            if (mounted) {
              setState(() {});
            }
          },
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openBackup() async {
    final backup = widget.backup;
    if (backup == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BackupPage(
          service: backup,
          // 云端导出用。**配没配对交给页面自己判断**：这里判断一次、
          // 用户在同步页又配了一次，返回栈退回来时这个判断就过期了。
          // 页面每次 `initState` 重新问，不会错。
          sync: widget.services.sync,
          reschedule: () async {
            await widget.services.scheduler.reschedule(
              trigger: RescheduleTrigger.dataChanged,
            );
          },
        ),
      ),
    );
    // 回来之后提示可能该消失/该出现，重读一次。
    final hint = await backup.reminderLine();
    if (mounted) {
      setState(() => _backupHint = hint);
    }
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
                if (_capability != null)
                  ReminderStatusBanner(
                    capability: _capability!,
                    onFix: _fixCapability,
                  ),
                SwitchListTile.adaptive(
                  value: _remindersOn,
                  onChanged: (v) => _setReminders(v),
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('到点提醒'),
                  subtitle: const Text('关掉之后所有项目都不响，打卡照常'),
                ),
                ListTile(
                  leading: const Icon(Icons.alarm_on_outlined),
                  title: const Text('催一次 / 免打扰'),
                  subtitle: Text(
                    _capability == null || !_capability!.needsAction
                        ? _reminderSummary
                        : ' · ${_capability!.label}',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  enabled: _remindersOn,
                  onTap: _remindersOn
                      ? () => unawaited(_openReminders())
                      : null,
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
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  enabled: widget.onOpenMembers != null,
                  onTap: widget.onOpenMembers,
                ),
                const Divider(height: 24),

                // 同步放在「家人」下面、「数据」上面：它管的是
                // "我们一家人的东西能不能对上"，不是备份。
                const _SectionHeader('家人的手机'),
                _SyncTile(
                  service: widget.services.sync,
                  onOpen: () => unawaited(_openSync()),
                ),
                const Divider(height: 24),

                const _SectionHeader('数据'),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出备份'),
                  // 需求里这条是 P0，但明确要求"藏得好一点"——
                  // 放这里而不是首页，是因为它是救命功能，不是日常功能。
                  subtitle: Text(_backupHint ?? '存一份 JSON 到手机里，换机时能搬回来'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  enabled: widget.backup != null,
                  onTap: widget.backup == null
                      ? null
                      : () => unawaited(_openBackup()),
                ),
                const Divider(height: 24),

                const _SectionHeader('关于'),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('版本'),
                  subtitle: Text('0.1.0（开发版 · ${BuildInfo.label}）'),
                  onTap: _onVersionTap,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Famdaily 只做一件事：让家里那些「每天都要做的小事」'
                    '有人记得、有人看见。\n不排名、不加分、不催命。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.6,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 设置页里「同步」那一行。
///
/// 只显示一句状态（未开启 / 刚刚同步 / 同步码已失效），**不放同步按钮**：
/// 点进来才有细节。首页尤其不该出现任何同步状态 —— 用户是来打卡的，
/// 不是来运维的。
class _SyncTile extends StatelessWidget {
  const _SyncTile({required this.service, required this.onOpen});

  final SyncService service;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: service.stream,
      initialData: service.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? const SyncStatus();
        final label = status.shortLabel;
        final failed = status.outcome == SyncOutcome.failed;
        final theme = Theme.of(context);
        return ListTile(
          leading: Icon(failed ? Icons.sync_problem : Icons.devices_outlined),
          title: const Text('多台手机同步'),
          subtitle: const Text('家人在自己手机上打卡，这里也看得到'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label.isNotEmpty)
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          onTap: onOpen,
        );
      },
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
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
