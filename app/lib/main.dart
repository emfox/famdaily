import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_boot.dart';
import 'app/bootstrap_page.dart';
import 'app/home_shell.dart';

/// 品牌种子色。整个 App 的所有颜色都从它派生（M3 动态配色的静态替代），
/// 所以这里是全工程唯一允许出现颜色字面量的地方。
const seedGreen = Color(0xFF4C8C6A);

/// 亮色主题。
///
/// 单独抽成函数是为了测试能拿到**同一个** ThemeData 做对比度断言——
/// 测试里另写一份 seed 就等于没测到真正跑在手机上的那套颜色。
ThemeData famdailyTheme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: seedGreen, brightness: brightness),
  useMaterial3: true,
);

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
      theme: famdailyTheme(Brightness.light),
      // 系统深色时必须跟着变。之前只有 theme 没有 darkTheme，
      // 夜里打开还是一整屏亮白，是这批问题里最刺眼的一个。
      // 跟随系统而不是自己做开关：系统那个开关用户已经会用了。
      darkTheme: famdailyTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: BootstrapPage(
        boot: _boot,
        builder: (context, services) => HomeShell(services: services),
      ),
    );
  }
}
