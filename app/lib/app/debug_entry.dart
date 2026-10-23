import 'package:flutter/material.dart';

import '../app/app_boot.dart';
import '../ui/debug/debug_reminder_page.dart';

/// 调试入口的落地页：目前只有提醒调试，做成一个列表方便以后再挂。
///
/// 单独一层的理由是**藏得深**：设置 → 关于 → 连点版本号 → 调试，
/// 这些是排查工具，不该出现在日常路径上（与"导出备份藏在设置里"同一思路）。
class DebugEntryPage extends StatelessWidget {
  const DebugEntryPage({
    required this.services,
    super.key,
  });

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('调试')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('提醒调试'),
            subtitle: const Text('看看排了哪些通知、为什么没排'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => DebugReminderPage(
                  db: services.db,
                  scheduler: services.scheduler,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
