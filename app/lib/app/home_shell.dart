import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_boot.dart';
import '../feature/history/history_page.dart';
import '../feature/history/history_service.dart';
import '../feature/home/home_screen.dart';
import '../feature/settings/settings_page.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(services: widget.services),
          HistoryPage(
            service: _history,
            onOpenStats: null, // 统计页 P2 接
          ),
          SettingsPage(
            services: widget.services,
            onOpenDebug: () => unawaited(_openDebug()),
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

  Future<void> _openDebug() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DebugEntryPage(services: widget.services),
      ),
    );
  }
}
