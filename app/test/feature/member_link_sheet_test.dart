import 'dart:async';

import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_config.dart';
import 'package:famdaily/data/sync/sync_service.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/feature/members/member_link_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 假链接**和**断言用的是同一个常量。
///
/// ⚠️ 两处各写一遍的话，"作废后 URL 消失"这条永远绿 —— 因为它本来就没出现过。
const _url = 'https://fam.example/m/abc123';
const _linkPath = '/members/m1/link';
const _unlinkPath = '/members/m1/unlink';

final class _Member {
  static const mom = domain.Member(
    id: 'm1',
    name: '妈妈',
    sortOrder: 0,
    createdAtMs: _ts,
    updatedAtMs: _ts,
  );
}

/// 按路径回答的假 transport。
///
/// 一次测试里要"先 link 再 unlink"，还要"第一次失败、重试成功"，
/// 所以除了固定的 [byPath] 之外还有一个可变的 [next]：每次请求先问它，
/// 返回 null 才落回 [byPath]。
final class _FakeTransport implements SyncTransport {
  /// 每次请求现算响应；返回 null 就落回 [defaults]。
  FutureOr<HttpResponseData?> Function(String path)? next;

  final Map<String, HttpResponseData> defaults = {
    _linkPath: const HttpResponseData(
      statusCode: 200,
      json: {'ok': true, 'url': _url, 'issuedAtMs': _ts, 'memberId': 'm1'},
    ),
  };

  final List<String> calls = [];
  final List<String?> authHeaders = [];

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    calls.add(url.path);
    authHeaders.add(headers['Authorization']);
    final n = next;
    if (n != null) {
      final r = await n(url.path);
      if (r != null) {
        return r;
      }
    }
    final fixed = defaults[url.path];
    if (fixed != null) {
      return fixed;
    }
    // 没预设的路径**响亮地失败**：静默返回 200 {} 会让"请求没发出去"
    // 和"发出去了"看起来一样。
    throw StateError('测试没给 ${url.path} 预设响应');
  }

  @override
  Future<HttpResponseData> get(
    Uri url, {
    Map<String, String> headers = const {},
    bool keepRawBody = false,
  }) async => const HttpResponseData(statusCode: 404, json: null);

  @override
  void close() {}
}

/// 把弹窗挂在一条真正能 pop 的 route 上。
///
/// 不能 `home: MemberLinkSheet(...)`：`AlertDialog` 要求有 `Navigator`
/// 才能 pop，而 `initState` 里就发请求，必须和线上一样用 route 打开。
Widget _host(SyncService sync) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => showDialog<void>(
            context: ctx,
            builder: (_) => MemberLinkSheet(sync: sync, member: _Member.mom),
          ),
          child: const Text('打开弹窗'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开弹窗'));
  await tester.pumpAndSettle();
}

Future<void> _tapRevokeEntry(WidgetTester tester) async {
  await tester.tap(find.text('作废这个链接'));
  await tester.pumpAndSettle();
}

Future<void> _confirmRevoke(WidgetTester tester) async {
  await tester.tap(find.text('作废'));
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    for (final (k, v) in [
      (SyncKeys.baseUrl, 'http://sync.test'),
      (SyncKeys.token, 'dev-token-123'),
      (SyncKeys.deviceId, 'dev1'),
      (SyncKeys.familyId, 'fam1'),
    ]) {
      await db.setSetting(k, v, nowMs: _ts);
    }
  });

  tearDown(() async => db.close());

  SyncService makeSync(SyncTransport t) => SyncService(
    db: db,
    config: SyncConfigStore(db),
    apiFactory: (baseUrl, transport) =>
        SyncApi(transport: transport, baseUrl: baseUrl),
    transportFactory: () => t,
  );

  /// unlink 回这个响应。
  void revokeAs(_FakeTransport t, HttpResponseData resp) {
    t.next = (path) => path == _unlinkPath ? resp : null;
  }

  group('作废链接：入口与二次确认', () {
    testWidgets('ready 态有「作废这个链接」，点了只弹确认框、不发请求', (tester) async {
      final t = _FakeTransport();
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);

      expect(find.text('作废这个链接'), findsOneWidget);
      expect(find.textContaining(_url), findsOneWidget);

      await _tapRevokeEntry(tester);

      expect(find.text('作废妈妈的打卡链接？'), findsOneWidget);
      expect(find.text('再想想'), findsOneWidget);
      // 三条正文各自的理由见 docs/member-link-management §4.2。
      expect(find.textContaining('永远打不开了'), findsOneWidget);
      expect(find.textContaining('会马上退出登录'), findsOneWidget);
      expect(find.textContaining('已经打过的卡都在'), findsOneWidget);

      // L-01：确认之前一个 unlink 请求都不该发。
      expect(t.calls, [_linkPath]);
    });

    testWidgets('点「再想想」什么都不发生，链接还在', (tester) async {
      final t = _FakeTransport();
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);

      await tester.tap(find.text('再想想'));
      await tester.pumpAndSettle();

      // L-02。探测值是**调用列表本身**，不是 UI 文案 ——
      // 只断言"弹窗还在"的话，请求发了又失败，弹窗也在，抓不住。
      expect(t.calls, [_linkPath], reason: '点「再想想」不该发任何 unlink');
      expect(find.textContaining(_url), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
    });
  });

  group('作废链接：两个终态必须分开', () {
    testWidgets('真的废掉了 → 终态，URL 消失，只剩「知道了」', (tester) async {
      final t = _FakeTransport();
      revokeAs(
        t,
        const HttpResponseData(
          statusCode: 200,
          json: {'ok': true, 'memberId': 'm1', 'revoked': true},
        ),
      );
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-03/L-04
      expect(t.calls, [_linkPath, _unlinkPath]);
      expect(t.authHeaders.last, 'Bearer dev-token-123');
      expect(find.textContaining('已经作废'), findsOneWidget);
      expect(find.textContaining('找你要一个新链接'), findsOneWidget);
      expect(
        find.textContaining(_url),
        findsNothing,
        reason: '哈希已清，留着会让人以为还能用',
      );
      expect(find.text('分享'), findsNothing);
      expect(find.text('再试一次'), findsNothing);
      expect(find.text('知道了'), findsOneWidget);
    });

    testWidgets('服务端说没有链接可废 → 说"本来就没有"，不说"已经作废"', (tester) async {
      final t = _FakeTransport();
      revokeAs(
        t,
        const HttpResponseData(
          statusCode: 200,
          json: {'ok': true, 'memberId': 'm1', 'revoked': false},
        ),
      );
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-05。这两条是本功能最关键的断言：探测值必须是 revoked:false，
      // 用 revoked:true 的用例测不出"透传"（恒返回 true 也照样绿）。
      expect(find.textContaining('没有有效的打卡链接'), findsOneWidget);
      expect(find.textContaining('已经作废'), findsNothing);
      expect(find.text('再试一次'), findsNothing);
    });

    testWidgets('响应缺 revoked → 同"本来就没有"，不报失败', (tester) async {
      final t = _FakeTransport();
      // 探测值是**缺字段**，不是 false —— 缺字段才是 `as bool` 会崩的情况。
      revokeAs(t, const HttpResponseData(statusCode: 200, json: {'ok': true}));
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-06
      expect(find.textContaining('没有有效的打卡链接'), findsOneWidget);
      expect(find.text('再试一次'), findsNothing, reason: '副作用已经发生，不能说"失败"');
    });

    testWidgets('终态按返回只关弹窗，不连带关掉下面的页面', (tester) async {
      final t = _FakeTransport();
      revokeAs(
        t,
        const HttpResponseData(statusCode: 200, json: {'revoked': true}),
      );
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // 不 pageBack：宿主页没有 AppBar，没有返回按钮可点。
      // 「系统返回键」在这一层等价于 pop 最上面的 route。
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      // L-12：宿主页的按钮还在，说明只 pop 了弹窗那一层。
      expect(find.text('打开弹窗'), findsOneWidget);
    });
  });

  group('作废链接：失败分支', () {
    testWidgets('401 → 说重新配对，不给「再试一次」，不说已作废', (tester) async {
      final t = _FakeTransport();
      revokeAs(
        t,
        const HttpResponseData(
          statusCode: 401,
          json: {
            'error': {'code': 'unauthorized', 'message': '配对已失效，请重新配对'},
          },
        ),
      );
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-07
      expect(find.textContaining('凭据失效'), findsOneWidget);
      expect(find.textContaining('没做成'), findsOneWidget);
      expect(find.text('再试一次'), findsNothing, reason: '重试同一个失效凭据不会有别的结果');
      expect(find.textContaining('已经作废'), findsNothing);
      expect(find.textContaining(_url), findsOneWidget, reason: '没废成，链接还要能发');
    });

    testWidgets('连不上 → 说"可能还没作废"，给「再试一次」，URL 仍可复制', (tester) async {
      final t = _FakeTransport();
      t.next = (path) {
        if (path == _unlinkPath) {
          throw TransportException('连不上');
        }
        return null;
      };
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-08
      expect(find.textContaining('连不上服务'), findsOneWidget);
      expect(find.textContaining('可能还没作废'), findsOneWidget);
      expect(find.text('再试一次'), findsOneWidget);
      expect(find.textContaining('已经作废'), findsNothing);
      // L-08 补充：失败后 URL 必须还在 —— 请求可能根本没出去。
      expect(find.textContaining(_url), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets('404（成员在服务端不存在）→ 当作"不用作废"，不说失败', (tester) async {
      final t = _FakeTransport();
      revokeAs(
        t,
        const HttpResponseData(
          statusCode: 404,
          json: {
            'error': {'code': 'member_not_found', 'message': '没有这个成员'},
          },
        ),
      );
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      // L-09：成员都没了，链接自然不可能再用 —— 目的已达成。
      expect(find.textContaining('没有有效的打卡链接'), findsOneWidget);
      expect(find.text('再试一次'), findsNothing);
      expect(find.textContaining('已经作废'), findsNothing);
    });

    testWidgets('失败后点「再试一次」成功 → 进终态', (tester) async {
      final t = _FakeTransport();
      var first = true;
      t.next = (path) {
        if (path != _unlinkPath) {
          return null;
        }
        if (first) {
          first = false;
          return const HttpResponseData(statusCode: 503, json: {'error': '忙'});
        }
        return const HttpResponseData(statusCode: 200, json: {'revoked': true});
      };
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await _confirmRevoke(tester);

      expect(find.text('再试一次'), findsOneWidget);

      await tester.tap(find.text('再试一次'));
      await tester.pumpAndSettle();

      // L-10
      expect(t.calls.where((p) => p == _unlinkPath), hasLength(2));
      expect(find.textContaining('已经作废'), findsOneWidget);
      expect(find.textContaining('找你要一个新链接'), findsOneWidget);
    });
  });

  group('作废链接：不越界', () {
    testWidgets('三个终态都不提供「重新生成一个」', (tester) async {
      for (final resp in [
        const HttpResponseData(statusCode: 200, json: {'revoked': true}),
        const HttpResponseData(statusCode: 200, json: {'revoked': false}),
        const HttpResponseData(statusCode: 404, json: null),
      ]) {
        final t = _FakeTransport();
        revokeAs(t, resp);
        await tester.pumpWidget(_host(makeSync(t)));
        await _open(tester);
        await _tapRevokeEntry(tester);
        await _confirmRevoke(tester);

        // L-11。用精确匹配而不是 textContaining('重新生成')：
        // ready 态的说明文字里本来就有"重新生成会让旧的失效"。
        expect(find.text('重新生成一个'), findsNothing);
        expect(find.textContaining('再生成'), findsNothing);

        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('revoking 态一个按钮都没有（请求已发出，不能取消）', (tester) async {
      final t = _FakeTransport();
      // 永远不返回的 unlink：把界面卡在 revoking 态。
      t.next = (path) {
        if (path == _unlinkPath) {
          return Completer<HttpResponseData>().future;
        }
        return null;
      };
      await tester.pumpWidget(_host(makeSync(t)));
      await _open(tester);
      await _tapRevokeEntry(tester);
      await tester.tap(find.text('作废'));
      // 只 pump 一帧：请求永远不会回来，settle 会超时。
      // 这一帧里确认框还在淡出（pop 动画），所以**只能看链接弹窗自己**——
      // 直接 find.byType(TextButton) 会把确认框那两个也算进来。
      await tester.pump();

      expect(find.text('正在作废…'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.text('知道了'), findsNothing);
      expect(find.text('作废这个链接'), findsNothing);
      expect(find.text('分享'), findsNothing);
      expect(find.text('复制'), findsNothing);
    });
  });
}
