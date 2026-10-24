import 'package:famdaily/data/notifier/notification_service.dart';
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/feature/settings/reminder_permission.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记住"问过没有"的内存版开关。
final class _Flags {
  final Map<String, String> _v = {};

  Future<String?> read(String key) async => _v[key];
  Future<void> write(String key) async => _v[key] = 'true';

  bool get asked => _v['reminders.permissionAsked'] == 'true';
}

/// 可控的通知网关，带"用户会不会同意"。
final class _Gateway implements NotificationGateway {
  _Gateway({
    this.permission = false,
    this.exact = false,
    this.willGrantNotification = true,
    this.willGrantExact = true,
  });

  bool permission;
  bool exact;
  final bool willGrantNotification;
  final bool willGrantExact;

  int notificationAsks = 0;
  int exactAsks = 0;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> requestPermission() async {
    notificationAsks++;
    if (willGrantNotification) {
      permission = true;
    }
    return permission;
  }

  @override
  Future<bool> canScheduleExact() async => exact;

  @override
  Future<bool> requestExactAlarms() async {
    exactAsks++;
    if (willGrantExact) {
      exact = true;
    }
    return exact;
  }

  @override
  Future<List<int>> pendingIds() async => const [];

  @override
  Future<int> applyPlan(
    List<PlannedNotification> plan, {
    bool allowInexact = false,
  }) async => plan.length;

  @override
  Future<void> cancelSlot({
    required String taskId,
    required domain.LocalDate date,
    required int slotIndex,
  }) async {}

  @override
  Future<void> cancelAll() async {}
}

void main() {
  group('读能力：三种状态分得清', () {
    test('有通知权限、有精确闹钟 → ready', () async {
      final g = _Gateway(permission: true, exact: true);
      expect(await readCapability(g), ReminderCapability.ready);
    });

    test('有通知权限、没精确闹钟 → inexactOnly（会响，但可能晚）', () async {
      final g = _Gateway(permission: true, exact: false);
      expect(await readCapability(g), ReminderCapability.inexactOnly);
    });

    test('没通知权限 → noPermission（一条都不会响）', () async {
      final g = _Gateway(permission: false, exact: false);
      expect(await readCapability(g), ReminderCapability.noPermission);
    });

    test('没通知权限时不去纠结精确闹钟', () async {
      // 通知权限是硬门槛：连门都进不去，谈精度没意义。
      final g = _Gateway(permission: false, exact: true);
      expect(await readCapability(g), ReminderCapability.noPermission);
    });
  });

  group('申请权限：先问通知，再问精确闹钟', () {
    test('两个都缺：先问通知，拿到了再问精确', () async {
      final g = _Gateway(permission: false, exact: false);

      final c = await requestPermissions(g);

      expect(c, ReminderCapability.ready);
      expect(g.notificationAsks, 1);
      expect(g.exactAsks, 1);
    });

    test('通知权限被拒：不去问精确闹钟，直接返回不会响', () async {
      // 精确闹钟在 Android 上会把人跳转到系统设置页。
      // 通知权限都没给，跳那一下纯属打扰。
      final g = _Gateway(permission: false, willGrantNotification: false);

      final c = await requestPermissions(g);

      expect(c, ReminderCapability.noPermission);
      expect(g.notificationAsks, 1);
      expect(g.exactAsks, 0);
    });

    test('通知权限被拒后，精确闹钟 granted 也不该被当成 ready', () async {
      final g = _Gateway(
        permission: false,
        exact: true,
        willGrantNotification: false,
      );
      expect(await requestPermissions(g), ReminderCapability.noPermission);
    });

    test('通知权限有、精确闹钟拒了 → inexactOnly', () async {
      final g = _Gateway(
        permission: true,
        exact: false,
        willGrantExact: false,
      );

      final c = await requestPermissions(g);

      expect(c, ReminderCapability.inexactOnly);
      expect(g.notificationAsks, 0, reason: '已经有通知权限，不该再弹一次');
      expect(g.exactAsks, 1);
    });
  });

  group('只问一次', () {
    test('第一次缺权限：问，并记下问过了', () async {
      final flags = _Flags();
      final g = _Gateway(permission: false);

      final c = await askPermissionOnce(
        gateway: g,
        readFlag: flags.read,
        writeFlag: flags.write,
      );

      expect(c, ReminderCapability.ready);
      expect(g.notificationAsks, 1);
      expect(flags.asked, isTrue);
    });

    test('问过之后不再问第二次', () async {
      final flags = _Flags();
      final g = _Gateway(permission: false);

      await askPermissionOnce(
        gateway: g,
        readFlag: flags.read,
        writeFlag: flags.write,
      );
      // 用户后来在系统里撤了权限
      g.permission = false;
      final second = await askPermissionOnce(
        gateway: g,
        readFlag: flags.read,
        writeFlag: flags.write,
      );

      expect(second, isNull, reason: '反复弹框是最快让人关掉通知的做法');
      expect(g.notificationAsks, 1);
    });

    test('已经有全部权限：不问，也不标记（哪天撤了还能再问）', () async {
      final flags = _Flags();
      final g = _Gateway(permission: true, exact: true);

      final c = await askPermissionOnce(
        gateway: g,
        readFlag: flags.read,
        writeFlag: flags.write,
      );

      expect(c, isNull);
      expect(g.notificationAsks, 0);
      expect(flags.asked, isFalse);
    });
  });

  group('文案', () {
    test('三种状态各有各的说法，且不空', () {
      for (final c in ReminderCapability.values) {
        expect(c.label, isNotEmpty);
        expect(c.hint, isNotEmpty);
      }
    });

    test('「不会响」这一条必须说清楚数据还在记', () {
      // 用户看到"不会响"最直接的反应是"那这 App 还有啥用"。
      expect(ReminderCapability.noPermission.hint, contains('打卡数据'));
    });

    test('只有 ready 不需要用户动作', () {
      expect(ReminderCapability.ready.needsAction, isFalse);
      expect(ReminderCapability.inexactOnly.needsAction, isTrue);
      expect(ReminderCapability.noPermission.needsAction, isTrue);
    });
  });
}
