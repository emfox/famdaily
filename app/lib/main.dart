import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_boot.dart';
import 'app/bootstrap_page.dart';
import 'domain/model/local_date.dart';
import 'domain/notification/window_policy.dart';
import 'ui/debug/debug_reminder_page.dart';

/// 进程级依赖都从这里走。
///
/// 没有一上来就用 ProviderScope：提醒初始化是"必须成功才能进主界面"的
/// 异步前置步骤，用一个显式的 bootstrap 阶段比藏在 Provider 的 AsyncValue
/// 里清楚。具体业务页面再用 Riverpod 管自己的状态。
void main() {
  runApp(const FamdailyApp());
}

class FamdailyApp extends StatefulWidget {
  const FamdailyApp({super.key});

  @override
  State<FamdailyApp> createState() => _FamdailyAppState();
}

class _FamdailyAppState extends State<FamdailyApp> {
  late final AppBoot _boot = AppBoot();

  @override
  void dispose() {
    _boot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Famdaily',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C8C6A)),
        useMaterial3: true,
      ),
      home: BootstrapPage(
        boot: _boot,
        builder: (context, services) => _HomeScaffold(services: services),
      ),
    );
  }
}

/// 临时的首页壳：第 5 步换成真正的三态首页。
class _HomeScaffold extends StatefulWidget {
  const _HomeScaffold({required this.services});

  final AppServices services;

  @override
  State<_HomeScaffold> createState() => _HomeScaffoldState();
}

class _HomeScaffoldState extends State<_HomeScaffold>
    with WidgetsBindingObserver {
  late LocalDate _lastKnownDay = LocalDate.fromDateTime(DateTime.now());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    // 回前台只做一件事：如果已经跨天，就重排提醒。
    // 每次切回来都重排会白白重建几十条通知，很费电（见 ReschedulePolicy）。
    final today = LocalDate.fromDateTime(DateTime.now());
    if (today == _lastKnownDay) {
      return;
    }
    _lastKnownDay = today;
    unawaited(
      widget.services.scheduler.reschedule(
        trigger: RescheduleTrigger.resumed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Famdaily')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text('替家人记着。', style: theme.textTheme.titleLarge),
              const SizedBox(height: 24),
              Text(
                '提醒已在后台排好\n下一步：首页三态',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextButton.icon(
            onPressed: () {
              final s = widget.services;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      DebugReminderPage(db: s.db, scheduler: s.scheduler),
                ),
              );
            },
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('提醒调试'),
          ),
        ),
      ),
    );
  }
}
