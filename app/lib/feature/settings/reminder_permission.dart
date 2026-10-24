/// 提醒权限的引导与状态检查。
///
/// 为什么单独一个文件：这是本项目踩过最贵的一个坑——**App 从来没申请过
/// 通知权限**。`NotificationService.requestPermission()` 写了、却没有任何
/// 地方调用它。于是：
///
/// - Android 13+ 上 POST_NOTIFICATIONS 默认拒绝 → `hasPermission()` 恒 false
///   → 重排时一条通知都不往系统里塞 → 用户"从来没收到过提醒"，界面上也没有
///   任何解释；
/// - Android 14+ 上 `SCHEDULE_EXACT_ALARM` 默认不授予 → 就算有通知权限，
///   `exactAllowWhileIdle` 也全部抛错被吞成日志。
///
/// 两条叠在一起，功能等于完全没做。而这一切**在单元测试和端到端测试里都看不
/// 出来**——测试里注入的假网关永远返回"已授权"。
///
/// 所以这里做两件事：
/// 1. 在用户刚建完第一个打卡项、正看着"几点提醒"的时候，问一次权限
///    （先给价值再要权限，比冷启动就弹框的通过率高得多）；
/// 2. 把"到底缺哪一项"算出来，让设置页能直说，而不是让用户自己猜。
library;

import 'package:flutter/material.dart';

import '../../data/notifier/notification_service.dart';

/// 系统层的提醒能力状态。
enum ReminderCapability {
  /// 通知权限 + 精确闹钟都拿到了，准点响。
  ready,

  /// 有通知权限，但没有精确闹钟权限：会响，但可能晚几分钟到几十分钟。
  inexactOnly,

  /// 没有通知权限：**一条都不会响**。
  noPermission,
}

extension ReminderCapabilityText on ReminderCapability {
  String get label => switch (this) {
    ReminderCapability.ready => '正常',
    ReminderCapability.inexactOnly => '会响，但可能不准时',
    ReminderCapability.noPermission => '不会响',
  };

  /// 设置页那一行的说明。写清楚"怎么办"，而不是只报错。
  String get hint => switch (this) {
    ReminderCapability.ready => '到点会准时弹通知',
    ReminderCapability.inexactOnly =>
      '系统限制了「闹钟和提醒」权限，到点会响但可能晚一会儿。'
          '想准点，去系统设置里给 Famdaily 打开这一项。',
    ReminderCapability.noPermission =>
      '系统里没给 Famdaily 通知权限，到点不会弹任何东西。'
          '打卡数据照常在记，只是不提醒。',
  };

  bool get needsAction => this != ReminderCapability.ready;
}

/// 读一次当前状态。
Future<ReminderCapability> readCapability(NotificationGateway gateway) async {
  if (!await gateway.hasPermission()) {
    return ReminderCapability.noPermission;
  }
  if (!await gateway.canScheduleExact()) {
    return ReminderCapability.inexactOnly;
  }
  return ReminderCapability.ready;
}

/// 申请提醒相关权限，返回申请后的状态。
///
/// 顺序是刻意的：先问通知权限（这是硬门槛），拿到了再问精确闹钟。
/// 精确闹钟在 Android 上会跳出 App 到系统设置页，用户回来时如果通知权限
/// 还没给，那一次跳转就白费了。
Future<ReminderCapability> requestPermissions(
  NotificationGateway gateway,
) async {
  if (!await gateway.hasPermission()) {
    await gateway.requestPermission();
  }
  if (await gateway.hasPermission() && !await gateway.canScheduleExact()) {
    await gateway.requestExactAlarms();
  }
  return readCapability(gateway);
}

/// 建完第一个打卡项之后，问一次权限。
///
/// **只问一次**：用 `reminders.permissionAsked` 记住。反复弹框是最快让人
/// 关掉通知的做法，而且 Android 上拒绝两次之后系统就不再弹了，
/// 再问也没用——那种情况只能靠设置页里的常驻提示。
///
/// 返回 null 表示这次没问（之前问过 / 已经有权限），调用方据此决定是否提示。
Future<ReminderCapability?> askPermissionOnce({
  required NotificationGateway gateway,
  required Future<String?> Function(String key) readFlag,
  required Future<void> Function(String key) writeFlag,
}) async {
  const key = 'reminders.permissionAsked';

  final already = await readFlag(key);
  if (already == 'true') {
    return null;
  }
  // 已经全都有权限，就不用问，也不用记——哪天用户把权限撤了，还能再问一次。
  if (await readCapability(gateway) == ReminderCapability.ready) {
    return null;
  }

  await writeFlag(key);
  return requestPermissions(gateway);
}

/// 提醒状态的那一行（设置页顶部）。
///
/// 只在有问题时出现：一切正常时不该占位置，那属于"没消息就是好消息"。
class ReminderStatusBanner extends StatelessWidget {
  const ReminderStatusBanner({
    required this.capability,
    required this.onFix,
    super.key,
  });

  final ReminderCapability capability;

  /// 点「去开启」要做的事。
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    if (!capability.needsAction) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isBlocking = capability == ReminderCapability.noPermission;
    final color = isBlocking
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isBlocking
                    ? Icons.notifications_off_outlined
                    : Icons.alarm_off_outlined,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isBlocking ? '到点不会提醒你' : '提醒可能不准时',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(capability.hint, style: theme.textTheme.bodySmall),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => onFix(),
              child: const Text('去开启'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 调试用：把当前能力打成一行日志。
void debugLogCapability(ReminderCapability c) {
  debugPrint('[reminder] 系统能力：${c.name}（${c.label}）');
}
