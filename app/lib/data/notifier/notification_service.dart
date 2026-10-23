/// 通知的平台侧实现。
///
/// 只做"照着清单干活"：建通道、申请权限、逐条 `zonedSchedule`、按 ID 取消。
/// **所有判断逻辑都在 `domain/notification/` 里**（纯 Dart，可单测），
/// 这一层保持薄，出错面才小——平台 API 是最难在 CI 里测的那部分。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/notification/notification_ids.dart';
import '../../domain/notification/notification_planner.dart';
import '../../domain/scheduling/scheduler.dart';

/// 通知通道（Android 8+ 必须有）。
abstract final class NotificationChannels {
  /// 打卡提醒。用"高"重要性：吃药这种事儿漏一次就断疗程。
  static const String reminders = 'famdaily_reminders';

  static const AndroidNotificationChannel remindersChannel =
      AndroidNotificationChannel(
        reminders,
        '打卡提醒',
        description: '到点提醒该打卡了',
        importance: Importance.high,
      );
}

/// 通知服务的接口。
///
/// 抽出接口的唯一目的是**测试**：真机上没法在单测里排系统通知，
/// 而"重排逻辑是否正确"是业务风险最高的地方，必须能测。
abstract interface class NotificationGateway {
  /// 当前是否已授权。
  Future<bool> hasPermission();

  /// 系统里还没发的通知 ID。
  Future<List<int>> pendingIds();

  /// 按清单重排，返回实际排上的条数。
  Future<int> applyPlan(List<PlannedNotification> plan);

  /// 取消某个槽位的提醒与催办。
  Future<void> cancelSlot({
    required String taskId,
    required LocalDate date,
    required int slotIndex,
  });

  /// 取消全部。
  Future<void> cancelAll();
}

/// 平台通知的封装。
///
/// 所有方法都吞掉平台异常（除了初始化）：一条通知排失败不该让整个 App 崩，
/// 用户宁可少一条提醒，也不想看到闪退。
final class NotificationService implements NotificationGateway {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  bool _ready = false;

  /// 当前时区（`Asia/Shanghai` 之类）。未初始化时为 null。
  String? timezoneName;

  /// 初始化：时区库 + 插件 + 通道。
  ///
  /// [onTap] 收到点击回调，payload 是 `taskId|epochDay|slotIndex`，
  /// 供路由跳到对应的打卡详情。
  Future<void> init({void Function(String payload)? onTap}) async {
    if (_ready) {
      return;
    }

    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      timezoneName = info.identifier;
      tz.setLocalLocation(tz.getLocation(timezoneName!));
    } catch (e) {
      // 拿不到时区就退回 UTC：提醒时间会偏，但总比不提醒强，
      // 而且这种情况只会出现在极少数魔改 ROM 上。
      debugPrint('[notify] 取时区失败，退回 UTC：$e');
      timezoneName = 'UTC';
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // 用 false：不在前台自动弹，避免用户正在 App 里操作时被横幅打断。
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null && payload.isNotEmpty) {
          onTap?.call(payload);
        }
      },
    );

    if (!kIsWeb && Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(NotificationChannels.remindersChannel);
    }

    _ready = true;
  }

  /// 申请权限。返回是否拿到。
  ///
  /// iOS 与 Android 13+ 都要显式问；Android 12 及以下直接返回 true。
  Future<bool> requestPermission() async {
    if (!_ready) {
      return false;
    }
    if (kIsWeb) {
      return false;
    }

    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final granted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    }

    return true;
  }

  /// 当前是否已授权（不做弹窗）。
  @override
  Future<bool> hasPermission() async {
    if (!_ready || kIsWeb) {
      return false;
    }
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final opts = await ios?.checkPermissions();
      return opts?.isEnabled ?? false;
    }
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      return await android?.areNotificationsEnabled() ?? false;
    }
    return true;
  }

  /// 取系统当前还没发的通知 ID 列表。
  ///
  /// iOS 有 64 条上限，这里拿到的数量就是"还剩多少额度"的依据。
  @override
  Future<List<int>> pendingIds() async {
    if (!_ready) {
      return const [];
    }
    final list = await _plugin.pendingNotificationRequests();
    return list.map((e) => e.id).toList();
  }

  /// 按清单重排：先清掉清单外的旧通知，再逐条安排。
  ///
  /// **只取消"不在新清单里"的那些**，不清空全部。原因：清空再重建之间
  /// 有个空窗期，如果这时进程被杀（用户切走 App），提醒就全丢了。
  @override
  Future<int> applyPlan(List<PlannedNotification> plan) async {
    if (!_ready) {
      return 0;
    }

    final keep = plan.map((p) => p.id).toSet();
    for (final id in await pendingIds()) {
      if (!keep.contains(id)) {
        await _safeCancel(id);
      }
    }

    var scheduled = 0;
    for (final p in plan) {
      try {
        await _plugin.zonedSchedule(
          id: p.id,
          title: p.title,
          body: p.body,
          // 一次性排定，不用 periodicallyShow：后者算不准跨天与免打扰。
          scheduledDate: _toTz(p.at),
          notificationDetails: _details(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: _payload(p),
        );
        scheduled++;
      } catch (e) {
        debugPrint('[notify] 排 ${p.id} 失败：$e');
      }
    }
    return scheduled;
  }

  /// 取消某个槽位的提醒与催办（打卡后立刻调用）。
  @override
  Future<void> cancelSlot({
    required String taskId,
    required LocalDate date,
    required int slotIndex,
  }) async {
    if (!_ready) {
      return;
    }
    await _safeCancel(NotificationIds.due(taskId, date, slotIndex));
    await _safeCancel(NotificationIds.followup(taskId, date, slotIndex));
  }

  @override
  Future<void> cancelAll() async {
    if (!_ready) {
      return;
    }
    await _plugin.cancelAll();
  }

  Future<void> _safeCancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('[notify] 取消 $id 失败：$e');
    }
  }

  NotificationDetails _details() => const NotificationDetails(
    android: AndroidNotificationDetails(
      NotificationChannels.reminders,
      '打卡提醒',
      channelDescription: '到点提醒该打卡了',
      importance: Importance.high,
      priority: Priority.high,
      // 催办是"同一条事儿"，不该在通知栏堆成一摞。
      groupKey: 'famdaily',
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      // 到点与催办属于同一组，iOS 上会归并显示。
      threadIdentifier: 'famdaily',
    ),
  );

  /// 本地墙钟 → 时区时刻。
  tz.TZDateTime _toTz(LocalDateTimeRef ref) => tz.TZDateTime(
    tz.local,
    ref.date.year,
    ref.date.month,
    ref.date.day,
    ref.time.hour,
    ref.time.minute,
  );

  String _payload(PlannedNotification p) =>
      '${p.taskId}|${p.date.epochDay}|${p.slotIndex}';
}

/// 把 payload 解析回槽位标识。
({String taskId, LocalDate date, int slotIndex})? parsePayload(String? raw) {
  if (raw == null) {
    return null;
  }
  final parts = raw.split('|');
  if (parts.length != 3) {
    return null;
  }
  final epoch = int.tryParse(parts[1]);
  final idx = int.tryParse(parts[2]);
  if (epoch == null || idx == null) {
    return null;
  }
  return (
    taskId: parts[0],
    date: LocalDate.fromEpochDay(epoch),
    slotIndex: idx,
  );
}

/// 调试用：把 [LocalTime] 格式化成 `HH:mm`（UI 调试页展示）。
String formatLocalTime(LocalTime t) => t.toString();
