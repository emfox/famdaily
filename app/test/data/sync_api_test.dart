import 'dart:convert';
import 'dart:io';

import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SyncApi` 对着一个**真的** `HttpServer` 打。
///
/// 用真 server 而不是 mock：这一层存在的全部意义就是"HTTP 拼对了没有"，
/// mock 掉 HTTP 就等于把这层测成了它自己。钉住的几件具体的事：
/// header 里的 `Bearer`、把 401 和 500 分到不同的异常、超时、
/// 基址带子路径时 URL 拼得对不对。

/// 一个可编程的假服务端。
final class _Server {
  _Server._(this._server);

  static Future<_Server> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = _Server._(s);
    s.listen(self._handle);
    return self;
  }

  final HttpServer _server;

  /// 下一次请求的响应。默认返回 ok。
  int status = 200;
  Map<String, Object?> body = {'ok': true};
  Duration delay = Duration.zero;

  /// 收到的最后一次请求，用来断言 URL / header / body。
  String? lastPath;
  String? lastMethod;
  String? lastAuth;
  Map<String, Object?>? lastJson;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest req) async {
    lastPath = req.uri.path;
    lastMethod = req.method;
    lastAuth = req.headers.value('authorization');
    final raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      lastJson = decoded is Map ? decoded.cast<String, Object?>() : null;
    } else {
      lastJson = null;
    }
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late _Server server;
  late SyncTransport transport;
  late SyncApi api;

  setUp(() async {
    server = await _Server.start();
    transport = HttpSyncTransport(
      connectTimeout: const Duration(seconds: 2),
      totalTimeout: const Duration(seconds: 3),
    );
    api = SyncApi(transport: transport, baseUrl: Uri.parse(server.baseUrl));
  });

  tearDown(() async {
    api.close();
    await server.stop();
  });

  group('/sync 请求', () {
    test('路径、方法、Bearer、body 都对', () async {
      server.body = {
        'ok': true,
        'cursor': 42,
        'writeHighWater': 0,
        'sinceReset': false,
        'pulled': <String, Object?>{
          'members': <Object?>[],
          'tasks': <Object?>[],
          'checkins': <Object?>[],
          'settings': <Object?>[],
        },
        'rejected': <Object?>[],
        'tombstoned': 0,
      };

      final resp = await api.sync(
        token: 'abc123',
        request: const SyncRequest(since: 7, checkins: []),
      );

      expect(server.lastMethod, 'POST');
      expect(server.lastPath, '/sync');
      expect(server.lastAuth, 'Bearer abc123');
      expect(server.lastJson!['since'], 7);
      expect(resp.cursor, 42);
    });

    test('基址带子路径时不会把路径吃掉', () async {
      // 发布到 https://host/famdaily/ 这种子路径下时，拼错就会 404。
      final sub = SyncApi(
        transport: transport,
        baseUrl: Uri.parse('${server.baseUrl}/famdaily/'),
      );
      server.body = {
        'ok': true,
        'cursor': 0,
        'pulled': <String, Object?>{
          'members': <Object?>[],
          'tasks': <Object?>[],
          'checkins': <Object?>[],
          'settings': <Object?>[],
        },
      };
      await sub.sync(
        token: 't',
        request: const SyncRequest(since: 0, checkins: []),
      );
      expect(server.lastPath, '/famdaily/sync');
      sub.close();
    });
  });

  group('同一个 transport 连发两次', () {
    // 这条是从真机上逮回来的：早先每发一次请求就在 finally 里
    // `_client.close(force: true)`，于是**第二次请求必然抛
    // "Client is closed"**。测试里每例都新建 transport，把这个洞盖住了。
    // 现在的规则：自建的客户端每次请求换一个；外部注入的不关（不是我们的）。
    test('连发三次都通（自建客户端）', () async {
      server.body = {
        'ok': true,
        'cursor': 1,
        'writeHighWater': 0,
        'sinceReset': false,
        'pulled': <String, Object?>{
          'members': <Object?>[],
          'tasks': <Object?>[],
          'checkins': <Object?>[],
          'settings': <Object?>[],
        },
        'rejected': <Object?>[],
      };
      for (var i = 0; i < 3; i++) {
        final r = await api.sync(
          token: 't',
          request: const SyncRequest(since: 0, checkins: []),
        );
        expect(r.cursor, 1);
      }
    });

    test('注入的 HttpClient 不会被 close 掉', () async {
      final injected = HttpClient();
      addTearDown(() => injected.close(force: true));
      final t = HttpSyncTransport(client: injected);
      final a = SyncApi(transport: t, baseUrl: Uri.parse(server.baseUrl));
      server.body = {
        'ok': true,
        'cursor': 1,
        'pulled': <String, Object?>{
          'members': <Object?>[],
          'tasks': <Object?>[],
          'checkins': <Object?>[],
          'settings': <Object?>[],
        },
      };
      await a.sync(
        token: 't',
        request: const SyncRequest(since: 0, checkins: []),
      );
      a.close();
      // close 之后这个注入的客户端仍然可用（调用方可能还要用）
      final req = await injected.getUrl(Uri.parse(server.baseUrl));
      final resp = await req.close();
      expect(resp.statusCode, 200);
      t.close();
    });
  });

  group('错误分类', () {
    test('401 → SyncAuthException（不重试）', () async {
      server.status = 401;
      server.body = {'error': 'token 无效'};
      await expectLater(
        api.sync(
          token: 'bad',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(
          isA<SyncAuthException>().having(
            (e) => e.message,
            'message',
            contains('token'),
          ),
        ),
      );
    });

    test('403 也算鉴权失败', () async {
      server.status = 403;
      server.body = {'error': 'forbidden'};
      await expectLater(
        api.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('500 → SyncHttpException（可重试）', () async {
      server.status = 500;
      server.body = {'error': 'boom'};
      await expectLater(
        api.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(
          isA<SyncHttpException>().having((e) => e.statusCode, 'code', 500),
        ),
      );
    });

    test('400 → SyncFormatException（版本不匹配，不重试）', () async {
      server.status = 400;
      server.body = {'error': '协议版本不支持'};
      await expectLater(
        api.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test('200 但 ok 不为 true → 抛错，不当成空响应', () async {
      server.status = 200;
      server.body = {'ok': false, 'error': '内部错误'};
      await expectLater(
        api.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test('超时 → TransportException', () async {
      server.delay = const Duration(seconds: 2);
      final slow = SyncApi(
        transport: HttpSyncTransport(
          totalTimeout: const Duration(milliseconds: 200),
        ),
        baseUrl: Uri.parse(server.baseUrl),
      );
      await expectLater(
        slow.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(isA<TransportException>()),
      );
      slow.close();
    });

    test('端口没人监听 → TransportException', () async {
      final dead = SyncApi(
        transport: HttpSyncTransport(
          totalTimeout: const Duration(seconds: 1),
        ),
        // 一个几乎不可能有人监听的端口
        baseUrl: Uri.parse('http://127.0.0.1:1'),
      );
      await expectLater(
        dead.sync(
          token: 'x',
          request: const SyncRequest(since: 0, checkins: []),
        ),
        throwsA(isA<TransportException>()),
      );
      dead.close();
    });
  });

  group('配对', () {
    test('预览：同步码先规范化再拼进 URL', () async {
      server.body = {
        'familyName': '我们家',
        'members': [
          {'name': '爸爸'},
        ],
        'expiresAtMs': 1,
      };
      // 用户手输的是小写、带空格、没前缀。同步码是 12 个字符
      // （FAM 前缀只是装饰），字母表里**没有** 0 1 I L O ——
      // 那几个字符手写会被认错。
      final preview = await api.preview('2345 6789 abcd');
      expect(server.lastMethod, 'GET');
      // `%2D` 是连字符被编码后的样子，服务端解码后仍是 FAM-2345-...
      expect(
        Uri.decodeComponent(server.lastPath!),
        '/pair/FAM-2345-6789-ABCD',
      );
      expect(preview.familyName, '我们家');
      expect(preview.memberNames, ['爸爸']);
    });

    test('同步码格式不对：本地就拦下，不发请求', () async {
      await expectLater(
        api.preview('123'),
        throwsA(isA<SyncFormatException>()),
      );
      expect(server.lastPath, isNull);
    });

    test('claim：带设备名、不带 token', () async {
      server.body = {
        'token': 'tk',
        'deviceId': 'd1',
        'familyId': 'f1',
      };
      final r = await api.claim(code: 'FAM-2345-6789-ABCD', deviceName: '妈妈的手机');
      expect(server.lastPath, '/pair/claim');
      expect(server.lastAuth, isNull);
      expect(server.lastJson!['code'], 'FAM-2345-6789-ABCD');
      expect(server.lastJson!['deviceName'], '妈妈的手机');
      expect(r.token, 'tk');
    });

    test('rotate：带旧 token', () async {
      server.body = {'token': 'new', 'deviceId': 'd1', 'familyId': 'f1'};
      await api.rotateToken(token: 'old');
      expect(server.lastPath, '/pair/rotate');
      expect(server.lastAuth, 'Bearer old');
      // 空 body 也真的发出去了：`{}` 能解析成一个空 map。
      // 发空字符串的话服务端会读 body 读不到 length 而挂住（踩过）。
      expect(server.lastJson, isEmpty);
    });
  });
}
