import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../data/repo_impl/reminder_scheduler.dart' show SettingsKeys;
import '../../domain/model/local_time.dart';

/// 一个提醒相关的设置项集合。
///
/// 单独抽成不可变值对象：读一次库、改一个字段、整份写回去，
/// 避免"三个 Switch 各自 setState 各自落库"那种竞态。
final class ReminderSettings {
  const ReminderSettings({
    required this.enabled,
    required this.followupEnabled,
    required this.followupMinutes,
    required this.quietStart,
    required this.quietEnd,
  });

  /// 默认值：全开、15 分钟催办、免打扰关。
  ///
  /// 免打扰默认**关**而不是 22:30–7:00：默认给人静音一整晚，
  /// 早上的药可能就不响了。宁可先吵，让用户自己决定。
  static const defaults = ReminderSettings(
    enabled: true,
    followupEnabled: true,
    followupMinutes: 15,
    quietStart: null,
    quietEnd: null,
  );

  final bool enabled;
  final bool followupEnabled;

  /// 二次催办延迟。需求定 15 分钟，这里允许 5 / 15 / 30 三档。
  final int followupMinutes;

  /// 免打扰起止；两者都为 null = 不启用。
  final LocalTime? quietStart;
  final LocalTime? quietEnd;

  bool get quietEnabled => quietStart != null && quietEnd != null;

  /// 催办可选延迟。
  static const List<int> followupChoices = [5, 15, 30];

  ReminderSettings copyWith({
    bool? enabled,
    bool? followupEnabled,
    int? followupMinutes,
    LocalTime? quietStart,
    LocalTime? quietEnd,
    bool clearQuiet = false,
  }) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    followupEnabled: followupEnabled ?? this.followupEnabled,
    followupMinutes: followupMinutes ?? this.followupMinutes,
    quietStart: clearQuiet ? null : (quietStart ?? this.quietStart),
    quietEnd: clearQuiet ? null : (quietEnd ?? this.quietEnd),
  );

  /// `22:30 – 7:00`；没启用返回 `关`。
  String get quietLabel {
    if (!quietEnabled) {
      return '关';
    }
    String fmt(LocalTime t) =>
        '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    return '${fmt(quietStart!)} – ${fmt(quietEnd!)}';
  }

  /// 设置页那一行副标题。
  String get summary => quietEnabled ? quietLabel : '这段时间里的提醒会顺延到结束之后';

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.followupEnabled == followupEnabled &&
      other.followupMinutes == followupMinutes &&
      other.quietStart == quietStart &&
      other.quietEnd == quietEnd;

  @override
  int get hashCode =>
      Object.hash(enabled, followupEnabled, followupMinutes, quietStart, quietEnd);
}

/// 读写这套设置。抽出来是因为设置页和排程器都要用同一套默认值。
final class ReminderSettingsStore {
  const ReminderSettingsStore(this._db);

  final AppDatabase _db;

  Future<ReminderSettings> load() async {
    final enabled = await _db.getSetting(SettingsKeys.remindersEnabled);
    final fuOn = await _db.getSetting(SettingsKeys.followupEnabled);
    final fuMin = await _db.getSetting(SettingsKeys.followupMinutes);
    final qs = await _db.getSetting(SettingsKeys.quietStart);
    final qe = await _db.getSetting(SettingsKeys.quietEnd);

    final start = _tryParse(qs);
    final end = _tryParse(qe);

    return ReminderSettings(
      enabled: enabled != 'false',
      followupEnabled: fuOn != 'false',
      followupMinutes:
          int.tryParse(fuMin ?? '') ?? ReminderSettings.defaults.followupMinutes,
      // 起止只有一个能解析时当成没启用：半条区间是坏数据，不是设置。
      quietStart: start != null && end != null ? start : null,
      quietEnd: start != null && end != null ? end : null,
    );
  }

  Future<void> save(ReminderSettings s, {required DateTime at}) async {
    final nowMs = at.millisecondsSinceEpoch;
    await _db.setSetting(SettingsKeys.remindersEnabled, '${s.enabled}', nowMs: nowMs);
    await _db.setSetting(
      SettingsKeys.followupEnabled,
      '${s.followupEnabled}',
      nowMs: nowMs,
    );
    await _db.setSetting(
      SettingsKeys.followupMinutes,
      '${s.followupMinutes}',
      nowMs: nowMs,
    );
    // 关掉免打扰时删掉两个键，而不是写 '00:00'——排程器把"起止相同"
    // 当作空区间，但库里留两个假值以后排查时容易看错。
    if (s.quietEnabled) {
      await _db.setSetting(
        SettingsKeys.quietStart,
        s.quietStart.toString(),
        nowMs: nowMs,
      );
      await _db.setSetting(SettingsKeys.quietEnd, s.quietEnd.toString(), nowMs: nowMs);
    } else {
      await _db.clearSetting(SettingsKeys.quietStart, nowMs: nowMs);
      await _db.clearSetting(SettingsKeys.quietEnd, nowMs: nowMs);
    }
  }

  static LocalTime? _tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      return LocalTime.parse(raw);
    } on Object {
      return null;
    }
  }
}

/// 提醒设置页：到点提醒 / 二次催办 / 免打扰时段（ui-spec §6）。
class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({
    required this.store,
    required this.reschedule,
    super.key,
  });

  final ReminderSettingsStore store;

  /// 任何改动都要重排：系统队列里已经有几十条按旧设置排好的通知，
  /// 不重排的话"关掉免打扰"今天不会生效，明天才生效。
  final Future<void> Function() reschedule;

  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage> {
  ReminderSettings? _value;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final v = await widget.store.load();
    if (mounted) {
      setState(() => _value = v);
    }
  }

  Future<void> _apply(ReminderSettings next) async {
    setState(() {
      _value = next;
      _saving = true;
    });
    await widget.store.save(next, at: DateTime.now());
    await widget.reschedule();
    if (mounted) {
      setState(() => _saving = false);
    }
  }

  Future<void> _pickQuietTime({required bool isStart}) async {
    final current = _value;
    if (current == null) {
      return;
    }
    // 24 小时制：晚上 10 点写成 22:00 比 10:00 PM 更省一次翻译。
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (isStart ? current.quietStart : current.quietEnd)?.hour ?? (isStart ? 22 : 7),
        minute: (isStart ? current.quietStart : current.quietEnd)?.minute ?? 0,
      ),
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) {
      return;
    }
    final t = LocalTime(picked.hour, picked.minute);
    await _apply(
      isStart
          ? current.copyWith(quietStart: t)
          : current.copyWith(quietEnd: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _value;

    return Scaffold(
      appBar: AppBar(title: Text('提醒', style: theme.textTheme.headlineSmall)),
      body: v == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                SwitchListTile.adaptive(
                  value: v.enabled,
                  onChanged: _saving
                      ? null
                      : (on) => unawaited(_apply(v.copyWith(enabled: on))),
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('到点提醒'),
                  subtitle: const Text('关掉之后所有项目都不响，打卡照常'),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: v.followupEnabled,
                  onChanged: v.enabled && !_saving
                      ? (on) =>
                            unawaited(_apply(v.copyWith(followupEnabled: on)))
                      : null,
                  secondary: const Icon(Icons.alarm_on_outlined),
                  title: const Text('没打卡再催一次'),
                  subtitle: Text(
                    v.followupEnabled
                        ? '到点还没打，${v.followupMinutes} 分钟后再提醒一次'
                        : '只提醒一次，不催',
                  ),
                ),
                if (v.enabled && v.followupEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final m in ReminderSettings.followupChoices)
                          ChoiceChip(
                            label: Text('$m 分钟'),
                            selected: v.followupMinutes == m,
                            onSelected: _saving
                                ? null
                                : (_) => unawaited(
                                    _apply(v.copyWith(followupMinutes: m)),
                                  ),
                          ),
                      ],
                    ),
                  ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: v.quietEnabled,
                  onChanged: v.enabled && !_saving
                      ? (on) => unawaited(
                          _apply(
                            on
                                // 打开时给一对合理默认值：22:30 – 7:00。
                                ? v.copyWith(
                                    quietStart: LocalTime(22, 30),
                                    quietEnd: LocalTime(7, 0),
                                  )
                                : v.copyWith(clearQuiet: true),
                          ),
                        )
                      : null,
                  secondary: const Icon(Icons.bedtime_outlined),
                  title: const Text('免打扰时段'),
                  subtitle: const Text('这段时间里的提醒会顺延到结束之后'),
                ),
                if (v.enabled && v.quietEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => unawaited(_pickQuietTime(isStart: true)),
                            child: Text('从 ${_hm(v.quietStart)}'),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('到'),
                        ),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => unawaited(_pickQuietTime(isStart: false)),
                            child: Text('到 ${_hm(v.quietEnd)}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!v.enabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      '提醒总开关关着，下面这些先不起作用。',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
              ],
            ),
    );
  }

  static String _hm(LocalTime? t) {
    if (t == null) {
      return '--:--';
    }
    return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
}
