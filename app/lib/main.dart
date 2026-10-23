import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_boot.dart';
import 'app/bootstrap_page.dart';
import 'app/home_shell.dart';

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
        builder: (context, services) => HomeShell(services: services),
      ),
    );
  }
}
