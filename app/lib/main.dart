import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Famdaily 的 App 壳。
///
/// 现阶段只跑通了 domain 层（排程展开器），界面按 tech-stack §9 的顺序
/// 从首页三态开始做。这里先给出主题、本地化与骨架，保证工程可编译可运行。
void main() {
  runApp(const FamdailyApp());
}

class FamdailyApp extends StatelessWidget {
  const FamdailyApp({super.key});

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
      supportedLocales: const [
        Locale('zh', 'CN'),
      ],
      locale: const Locale('zh', 'CN'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4C8C6A),
        ),
        useMaterial3: true,
      ),
      home: const _ScaffoldHome(),
    );
  }
}

class _ScaffoldHome extends StatelessWidget {
  const _ScaffoldHome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
              Text('Famdaily', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                '替家人记着。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '工程骨架已就绪\n下一步：首页三态',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
