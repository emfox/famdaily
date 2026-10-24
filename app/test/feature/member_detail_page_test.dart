import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_config.dart';
import 'package:famdaily/data/sync/sync_service.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/feature/members/member_detail_page.dart';
import 'package:famdaily/feature/members/member_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 一条预设响应。
final class _Resp {
  const _Resp(this.status, this.body);

  final int status;
  final Map<String, Object?>? body;
}

/// 只认成员链接接口的假 transport。
///
/// 故意**不**实现成一个"什么都能返回"的万能假货：那样测试会无意间依赖
/// 它没实现的行为。这里每一条断言关心的东西（路径、Bearer、有没有被关）
/// 都被单独记下来。
///
/// 默认响应（`status`/`body`）对**所有**路径生效；需要"一次测试里先 link
/// 再 unlink"时用 `byPath` 给某条路径单独指定。**不按调用次序返回**：
/// 次序依赖会让用例在加一个请求之后悄悄错位，而按路径匹配只会"没命中就用默认"。
final class _FakeLinkTransport implements SyncTransport {
  _FakeLinkTransport({
    required this.status,
    required this.body,
    Map<String, _Resp>? byPath,
    this.throwOn = const {},
  }) : byPath = byPath ?? const {};

  final int status;
  final Map<String, Object?>? body;
  final Map<String, _Resp> byPath;

  /// 命中这些路径就直接抛 [TransportException]，模拟连不上。
  final Set<String> throwOn;

  final List<String> calls = [];
  final List<String?> authHeaders = [];
  bool closed = false;

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    calls.add(url.path);
    authHeaders.add(headers['Authorization']);
    if (throwOn.contains(url.path)) {
      throw TransportException('连不上');
    }
    final hit = byPath[url.path];
    return HttpResponseData(
      statusCode: hit?.status ?? status,
      json: hit == null ? this.body : hit.body,
    );
  }

  @override
  Future<HttpResponseData> get(
    Uri url, {
    Map<String, String> headers = const {},
    bool keepRawBody = false,
  }) async {
    calls.add(url.path);
    return const HttpResponseData(statusCode: 404, json: null);
  }

  @override
  void close() => closed = true;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  late AppDatabase db;
  late MemberService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = MemberService(db: db);
    for (final (i, name) in ['我', '妈妈'].indexed) {
      await db
          .into(db.members)
          .insert(
            Mappers.memberToCompanion(
              domain.Member(
                id: 'm$i',
                name: name,
                sortOrder: i,
                createdAtMs: _ts,
                updatedAtMs: _ts,
              ),
            ),
          );
    }
  });

  tearDown(() async => db.close());

  testWidgets('画出名字、项目数与一行摘要', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('他的打卡项'), findsOneWidget);
    // 一个项目都没排时的摘要（本月无记录时走"还没安排打卡项"分支）。
    expect(find.text('还没安排打卡项'), findsWidgets);
  });

  group('生成打卡链接', () {
    /// 造一个假 transport：只认 `/members/:id/link`，记下请求，返回给定响应。
    ///
    /// 不 mock `SyncService` 本身 —— 那样测的是"我 mock 得对不对"。
    /// 这里真正跑的是 `SyncService.createMemberLink` → 读配置 → 拼 URL →
    /// 设 header → 发请求这条链，只有最底下那层网络换成假的。
    _FakeLinkTransport makeTransport({
      int status = 200,
      Map<String, Object?>? body,
      Map<String, _Resp>? byPath,
      Set<String> throwOn = const {},
    }) => _FakeLinkTransport(
      status: status,
      body: body,
      byPath: byPath,
      throwOn: throwOn,
    );

    SyncService makeSync(SyncTransport t, {bool paired = true}) => SyncService(
      db: db,
      config: SyncConfigStore(db),
      apiFactory: (baseUrl, transport) =>
          SyncApi(transport: transport, baseUrl: baseUrl),
      transportFactory: () => t,
    );

    /// 把同步配置写进库（相当于配对过）。
    Future<void> pair() async {
      for (final (k, v) in [
        (SyncKeys.baseUrl, 'http://sync.test'),
        (SyncKeys.token, 'dev-token-123'),
        (SyncKeys.deviceId, 'dev1'),
        (SyncKeys.familyId, 'fam1'),
      ]) {
        await db.setSetting(k, v, nowMs: _ts);
      }
    }

    testWidgets('没给 SyncService 时点进去说明原因，而不是什么都不发生', (tester) async {
      await tester.pumpWidget(
        _wrap(MemberDetailPage(service: service, memberId: 'm1')),
      );
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '生成打卡链接'),
      );
      // **不再置灰**：置灰的入口在老人眼里等于"坏了"，而这个功能是好的。
      // 真正的原因是"要先配对"，得说出来。
      expect(tile.enabled, isTrue);
      expect(find.textContaining('先在「设置 → 同步」里配对'), findsOneWidget);

      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();
      expect(find.text('同步还没启用，没法生成链接'), findsOneWidget);
    });

    testWidgets('配对后点开，弹窗里出现链接和「复制」「分享」', (tester) async {
      await pair();
      final t = makeTransport(
        body: {
          'ok': true,
          'url': 'https://fam.example/m/abc123',
          'issuedAtMs': _ts,
        },
      );
      await tester.pumpWidget(
        _wrap(
          MemberDetailPage(service: service, memberId: 'm1', sync: makeSync(t)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('让成员自己在手机浏览器里打'), findsOneWidget);
      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();

      expect(find.text('给妈妈发打卡链接'), findsOneWidget);
      expect(
        find.textContaining('https://fam.example/m/abc123'),
        findsOneWidget,
      );
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      // 「只显示这一次」这条提示必须在。用户以为关掉还能再看到，
      // 结果会来问"链接哪去了"，而服务端只有哈希，找不回来。
      expect(find.textContaining('只显示这一次'), findsOneWidget);

      // 请求打到正确的路径，且带上了设备 Bearer。
      expect(t.calls, ['/members/m1/link']);
      expect(t.authHeaders.single, 'Bearer dev-token-123');
      // transport 必须被关掉：每次请求自己造 HttpClient，不关就是泄漏。
      expect(t.closed, isTrue);
    });

    testWidgets('没配对：弹窗说清楚要先配对，不显示链接', (tester) async {
      final t = makeTransport(body: {});
      await tester.pumpWidget(
        _wrap(
          MemberDetailPage(service: service, memberId: 'm1', sync: makeSync(t)),
        ),
      );
      await tester.pumpAndSettle();
      // 没配对时副标题就该提示，不用点进去才知道。
      expect(find.textContaining('先在「设置 → 同步」里配对'), findsOneWidget);

      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有同步过'), findsOneWidget);
      // 一个请求都不该发出去。
      expect(t.calls, isEmpty);
    });

    testWidgets('设备凭据失效：说"重新配对"，不给「再试一次」', (tester) async {
      await pair();
      final t = makeTransport(
        status: 401,
        body: {
          'error': {'code': 'unauthorized'},
        },
      );
      await tester.pumpWidget(
        _wrap(
          MemberDetailPage(service: service, memberId: 'm1', sync: makeSync(t)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('凭据失效'), findsOneWidget);
      // 401 重试一万次也一样。给一个「再试一次」按钮只会让人一直点。
      expect(find.text('再试一次'), findsNothing);
      expect(find.text('知道了'), findsOneWidget);
    });

    testWidgets('网络失败：给「再试一次」', (tester) async {
      await pair();
      final t = makeTransport(status: 503, body: {});
      await tester.pumpWidget(
        _wrap(
          MemberDetailPage(service: service, memberId: 'm1', sync: makeSync(t)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('生成失败了'), findsOneWidget);
      expect(find.text('再试一次'), findsOneWidget);
    });

    testWidgets('「作废这个链接」只在弹窗里，详情页列表里没有', (tester) async {
      // L-13。这条唯一的用处是防止有人把入口挪回详情页列表：
      // 那样做的话，没生成过链接的成员点进去只会得到 revoked:false，白跑一趟。
      await pair();
      final t = makeTransport(
        body: {'url': 'https://fam.example/m/abc', 'issuedAtMs': _ts},
      );
      await tester.pumpWidget(
        _wrap(
          MemberDetailPage(service: service, memberId: 'm1', sync: makeSync(t)),
        ),
      );
      await tester.pumpAndSettle();

      // 打开之前，列表里没有。
      expect(find.widgetWithText(ListTile, '作废这个链接'), findsNothing);
      expect(find.text('作废这个链接'), findsNothing);

      await tester.tap(find.text('生成打卡链接'));
      await tester.pumpAndSettle();

      // 弹窗里有，且只有一个。
      expect(find.text('作废这个链接'), findsOneWidget);
    });
  });

  testWidgets('没给 onOpenTasks 时「他的打卡项」也是灰的', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '他的打卡项'),
    );
    expect(tile.enabled, isFalse);
  });

  testWidgets('删除要走二次确认；点「再想想」什么都不发生', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除这个成员'));
    await tester.pumpAndSettle();

    expect(find.text('删除 妈妈？'), findsOneWidget);
    expect(find.textContaining('打卡记录会留在日历里'), findsOneWidget);

    await tester.tap(find.text('再想想'));
    await tester.pumpAndSettle();

    expect(await service.find('m1'), isNotNull);
    expect((await service.find('m1'))!.isDeleted, isFalse);
  });

  testWidgets('确认删除后软删除并退出', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除这个成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    final m = await service.find('m1');
    expect(m, isNotNull, reason: '软删除：行还在');
    expect(m!.isDeleted, isTrue);
    // 列表里已经看不到了。
    expect((await service.list()).map((r) => r.member.id), ['m0']);
  });

  testWidgets('成员已经被删掉了，进来直接退出而不是画空壳', (tester) async {
    await service.remove('m1', nowMs: _ts);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      MemberDetailPage(service: service, memberId: 'm1'),
                ),
              ),
              child: const Text('进来'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进来'));
    await tester.pumpAndSettle();

    expect(find.text('删除这个成员'), findsNothing);
    expect(find.text('进来'), findsOneWidget, reason: '已经退回上一页');
  });
}
