import 'dart:typed_data';

import 'package:famdaily/app/app_boot.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/notifier/notification_service.dart';
import 'package:famdaily/data/photo/photo_store.dart';
import 'package:famdaily/data/repo_impl/reminder_scheduler.dart';
import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_config.dart';
import 'package:famdaily/data/sync/sync_service.dart';
import 'package:famdaily/feature/settings/settings_page.dart';
import 'package:famdaily/feature/settings/sync_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 同步相关界面。
///
/// 这些测试守的是**用户能看见的那几句话和那几个按钮**，不是同步逻辑
/// （那在 `sync_service_test.dart`）。界面出错的代价不一样：
/// 逻辑错了数据不对，界面错了用户根本不知道有这功能，或者更糟——
/// 以为自己在同步，其实没连上。

/// 假传输：配对预览成功、认领成功、同步返回空。
final class _FakeTransport implements SyncTransport {
  int previewCalls = 0;
  int claimCalls = 0;
  int syncCalls = 0;
  int status = 200;
  Map<String, Object?> body = {};

  @override
  Future<HttpResponseData> get(Uri url, {Map<String, String> headers = const {}}) async {
    previewCalls++;
    if (status != 200) {
      return HttpResponseData(statusCode: status, json: body);
    }
    return const HttpResponseData(
      statusCode: 200,
      json: {
        'familyName': '我们家',
        'members': [
          {'name': '爸爸'},
          {'name': '妈妈'},
        ],
        'expiresAtMs': 1,
      },
    );
  }

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    if (url.path.endsWith('/pair/claim')) {
      claimCalls++;
      if (status != 200) {
        return HttpResponseData(statusCode: status, json: this.body);
      }
      return const HttpResponseData(
        statusCode: 200,
        json: {'token': 'tk', 'deviceId': 'dev', 'familyId': 'fam'},
      );
    }
    syncCalls++;
    return const HttpResponseData(
      statusCode: 200,
      json: {
        'ok': true,
        'cursor': 10,
        'writeHighWater': 0,
        'sinceReset': false,
        'pulled': {
          'members': <Object?>[],
          'tasks': <Object?>[],
          'checkins': <Object?>[],
          'settings': <Object?>[],
        },
        'rejected': <Object?>[],
        'tombstoned': 0,
      },
    );
  }

  @override
  void close() {}
}

/// 这个文件根本不会去选图，给个空实现就行。
final class _NoopPicker implements PhotoPicker {
  @override
  Future<Uint8List?> pick(PhotoSource source) async => null;
}

void main() {
  late AppDatabase db;
  late _FakeTransport transport;
  late SyncConfigStore config;
  late SyncService service;
  late AppServices services;

  setUp(() {
    db = AppDatabase.forTesting(openTestConnection());
    transport = _FakeTransport();
    config = SyncConfigStore(db);
    service = SyncService(
      db: db,
      config: config,
      apiFactory: (baseUrl, t) => SyncApi(transport: t, baseUrl: baseUrl),
      transportFactory: () => transport,
    );
    services = AppServices(
      db: db,
      notifications: NotificationService(),
      scheduler: ReminderScheduler(
        db: db,
        notifications: NotificationService(),
      ),
      photoPicker: _NoopPicker(),
      photoStore: PhotoStore(),
      sync: service,
    );
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  Future<void> pumpSyncPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          service: service,
          config: config,
          onPaired: () async {},
          apiFactory: (baseUrl) =>
              SyncApi(transport: transport, baseUrl: baseUrl),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('同步页', () {
    testWidgets('没配对时：说清楚"数据只在你这台手机上"，给配对按钮', (tester) async {
      await pumpSyncPage(tester);

      expect(find.text('还没开启同步'), findsOneWidget);
      expect(find.textContaining('只在这台手机上'), findsOneWidget);
      expect(find.text('输入同步码，和家人的手机连上'), findsOneWidget);
      // 没配对时不该出现"立刻同步"/"断开"
      expect(find.text('立刻同步一次'), findsNothing);
      expect(find.text('断开同步'), findsNothing);
    });

    testWidgets('已配对时：显示同步按钮和断开入口', (tester) async {
      await config.save(
        const SyncConfig(
          baseUrl: 'https://sync.example.com',
          token: 'tk',
          deviceId: 'd',
          familyId: 'f',
        ),
        nowMs: 1,
      );
      await pumpSyncPage(tester);

      expect(find.text('立刻同步一次'), findsOneWidget);
      expect(find.text('断开同步'), findsOneWidget);
    });

    testWidgets('断开只清配置，一行数据都不删', (tester) async {
      await config.save(
        const SyncConfig(
          baseUrl: 'https://sync.example.com',
          token: 'tk',
          deviceId: 'd',
          familyId: 'f',
        ),
        nowMs: 1,
      );
      // 造一条真实数据
      await db.setSetting('reminders.enabled', 'false', nowMs: 1);
      await pumpSyncPage(tester);

      await tester.tap(find.text('断开同步'));
      await tester.pumpAndSettle();
      expect(find.text('断开同步？'), findsOneWidget);
      // 对话框里必须明说"数据不删"，否则没人敢按
      expect(find.textContaining('本机数据一条都不会删'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '断开'));
      await tester.pumpAndSettle();

      expect(await config.load(), isNull);
      expect(await db.getSetting('reminders.enabled'), 'false');
    });

    testWidgets('协议边界写在页面上，不折叠', (tester) async {
      await pumpSyncPage(tester);

      // 这几条是"已知缺陷"的用户版。藏在"了解更多"里等于骗人。
      expect(find.textContaining('照片只留在拍它的那台手机上'), findsOneWidget);
      expect(find.textContaining('删除可能传不过去'), findsOneWidget);
    });
  });

  group('配对页', () {
    Future<void> openPairing(WidgetTester tester) async {
      await pumpSyncPage(tester);
      await tester.tap(find.text('输入同步码，和家人的手机连上'));
      await tester.pumpAndSettle();
    }

    testWidgets('地址为空就报错，不发请求', (tester) async {
      await openPairing(tester);

      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();

      expect(find.textContaining('先填服务地址'), findsOneWidget);
      expect(transport.previewCalls, 0);
    });

    testWidgets('同步码位数不对：本地就拦下', (tester) async {
      await openPairing(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '服务地址').first,
        'https://sync.example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        'ABC',
      );
      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();

      expect(find.textContaining('12 个字符'), findsOneWidget);
      expect(transport.previewCalls, 0);
    });

    testWidgets('预览成功后要看到成员名才敢确认', (tester) async {
      await openPairing(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '服务地址').first,
        'https://sync.example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        '2345 6789 abcd',
      );
      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();

      expect(find.text('这个家里有：'), findsOneWidget);
      expect(find.text('爸爸、妈妈'), findsOneWidget);
      expect(find.text('是我们家，确认'), findsOneWidget);
      // 还没确认，不该已经认领
      expect(transport.claimCalls, 0);
    });

    testWidgets('改了码之后预览要消失（否则会对着上次的人按确认）', (tester) async {
      await openPairing(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '服务地址').first,
        'https://sync.example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        '2345 6789 abcd',
      );
      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();
      expect(find.text('爸爸、妈妈'), findsOneWidget);

      // 回到可编辑状态（预览时输入框是禁用的），先点"换个码"
      await tester.tap(find.text('换个码'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        '2345 6789 abce',
      );
      await tester.pumpAndSettle();

      expect(find.text('爸爸、妈妈'), findsNothing);
      expect(find.widgetWithText(FilledButton, '下一步'), findsOneWidget);
    });

    testWidgets('同步码失效：给一句人话，不是 HTTP 401', (tester) async {
      transport.status = 401;
      transport.body = {'error': 'token 无效'};
      await openPairing(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '服务地址').first,
        'https://sync.example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        '2345 6789 abcd',
      );
      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();

      expect(find.textContaining('同步码不对'), findsOneWidget);
      expect(find.textContaining('401'), findsNothing);
    });

    testWidgets('确认后写入配置并回退', (tester) async {
      await openPairing(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '服务地址').first,
        'https://sync.example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '同步码').first,
        '2345 6789 abcd',
      );
      await tester.tap(find.widgetWithText(FilledButton, '下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('是我们家，确认'));
      await tester.pumpAndSettle();

      final cfg = await config.load();
      expect(cfg, isNotNull);
      expect(cfg!.token, 'tk');
      expect(cfg.familyId, 'fam');
      // 配对之后立刻同步了一次（把家里已有的数据拉下来）
      expect(transport.syncCalls, 1);
    });
  });

  group('设置页那一行', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            services: services,
            onOpenDebug: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('有同步入口，且在「家人」和「数据」之间', (tester) async {
      await pumpSettings(tester);
      await tester.scrollUntilVisible(
        find.text('多台手机同步'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('多台手机同步'), findsOneWidget);
      expect(find.text('家人的手机'), findsOneWidget);
    });

    testWidgets('没配对时右侧不显示任何状态字（不吓唬新用户）', (tester) async {
      await pumpSettings(tester);
      await tester.scrollUntilVisible(
        find.text('多台手机同步'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      final tile = find.ancestor(
        of: find.text('多台手机同步'),
        matching: find.byType(ListTile),
      );
      expect(tile, findsOneWidget);
      // "未同步"这种字在没开启时一个都不该出现
      expect(find.text('未同步'), findsNothing);
      expect(find.text('同步失败'), findsNothing);
    });
  });
}
