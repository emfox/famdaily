import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repo_impl/reminder_scheduler.dart';
import 'app_boot.dart';

/// 启动页：跑 [AppBoot.init]，期间给一句人话而不是一个转圈。
///
/// 不设最短展示时长——初始化本来就快（本地库 + 排几十条通知），
/// 故意拖 2 秒只会让人以为卡了。
class BootstrapPage extends StatefulWidget {
  const BootstrapPage({
    required this.boot,
    required this.builder,
    super.key,
  });

  final AppBoot boot;

  /// 初始化完成后要显示的真实界面。
  final Widget Function(BuildContext context, AppServices services) builder;

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapPageState extends State<BootstrapPage> {
  AppServices? _services;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final s = await widget.boot.init();
      if (mounted) {
        setState(() => _services = s);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _services;
    if (s != null) {
      return widget.builder(context, s);
    }

    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text('正在准备…', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '把该提醒的都排好',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text('启动失败', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SelectableText(
                      '$_error',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() => _error = null);
                        unawaited(_run());
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// [RescheduleResult] 在这里被引用，保持 import 不空转（启动页展示用）。
typedef DebugResult = RescheduleResult;
