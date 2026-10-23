import 'dart:async';

import 'package:flutter/material.dart';

import 'app_boot.dart';
import '../data/backup/backup_io.dart';
import '../data/backup/backup_service.dart';
import '../domain/notification/window_policy.dart' show RescheduleTrigger;
import '../feature/history/history_page.dart';
import '../feature/history/history_service.dart';
import '../feature/home/home_screen.dart';
import '../feature/members/member_list_page.dart';
import '../feature/members/member_service.dart';
import '../feature/settings/settings_page.dart';
import '../feature/stats/stats_page.dart';
import '../feature/stats/stats_service.dart';
import 'debug_entry.dart';

/// 主框架：底部三个 Tab（今日 / 历史 / 设置）。
///
/// 用 `IndexedStack` 而不是每次重建页面：切回「今日」时不该重新加载、
/// 更不该丢掉滚动位置。三个页面各自管自己的状态，Shell 只负责切换。
///
/// 调试页入口按构建模式收口：Profile 才露出来（见 [DebugEntryTile]）。
class HomeShell extends StatefulWidget {
  const HomeShell({required this.services, this.initialIndex = 0, super.key});

  final AppServices services;
  final int initialIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex;
  late final HistoryService _history = HistoryService(widget.services.db);
  late final MemberService _members = MemberService(
    db: widget.services.db,
    // 成员名会进通知文案（"爷爷的降压药"）：改了名字必须重排，
    // 否则明天响的还是旧名字。
    onDataChanged: () => widget.services.scheduler.reschedule(
      trigger: RescheduleTrigger.dataChanged,
    ),
  );

  late final StatsService _stats = StatsService(widget.services.db);

  late final BackupService _backup = BackupService(
    db: widget.services.db,
    gateway: const PlatformBackupGateway(),
  );

  int? _memberCount;

  /// 成员表改动的代数。递增即通知首页刷新。
  int _memberRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshMemberCount());
  }

  Future<void> _refreshMemberCount() async {
    final n = (await widget.services.db.listMembers()).length;
    if (mounted) {
      setState(() => _memberCount = n);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          // memberRevision：首页在 IndexedStack 里常驻，切回来不重建。
          // 成员增删后靠这个计数把它叫醒，否则「谁做」的名单一直是旧的。
          HomeScreen(
            services: widget.services,
            memberRevision: _memberRevision,
          ),
          HistoryPage(
            service: _history,
            onOpenStats: () => unawaited(_openStats()),
          ),
          SettingsPage(
            services: widget.services,
            onOpenDebug: () => unawaited(_openDebug()),
            memberCount: _memberCount,
            onOpenMembers: () => unawaited(_openMembers()),
            backup: _backup,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.check_circle_outline),
            selectedIcon: Icon(Icons.check_circle),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  Future<void> _openStats() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => StatsPage(service: _stats)),
    );
  }

  Future<void> _openMembers() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MemberListPage(service: _members)),
    );
    // 成员可能被增删改名，回来无条件刷一次：这个数字不刷就是错的。
    await _refreshMemberCount();
    if (mounted) {
      setState(() => _memberRevision++);
    }
  }

  Future<void> _openDebug() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DebugEntryPage(services: widget.services),
      ),
    );
  }
}
