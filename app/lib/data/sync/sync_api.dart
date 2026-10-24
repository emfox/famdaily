/// 同步的网络传输。**唯一碰 HTTP 的地方。**
///
/// 抽成接口不是为了将来换库，是为了测试：`SyncService` 的测试可以塞一个
/// 会超时、会 401、会返回坏 JSON 的假传输，不用起服务也不用等 15 秒。
/// 而 `SyncApi` 自己由 `sync_api_test.dart` 对着一个**真的** `HttpServer`
/// 打 —— 假的 HTTP 测不出 header 拼错、超时没设这类问题。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_protocol.dart';

/// 一次请求的结果：状态码 + 已解析的 JSON（可选原始字节）。
final class HttpResponseData {
  const HttpResponseData({
    required this.statusCode,
    required this.json,
    this.rawBody,
  });

  final int statusCode;

  /// body 解析成的 map；空 body 或不是对象时为 null。
  final Map<String, Object?>? json;

  /// 原始 body 字节；调用方没要求时是 null。
  ///
  /// 只给 `/export` 用：那一份要原样落地成文件，重新 `jsonEncode` 一遍
  /// 会改键顺序和数字格式。加上这个字段而不是给 transport 开一个新方法，
  /// 是因为"要不要留原文"本来就是**调用方**的决定。
  final List<int>? rawBody;

  @override
  String toString() => 'HttpResponseData($statusCode)';
}

/// 传输失败（连不上、超时、DNS）。
///
/// **不是**"HTTP 500"，那是 [HttpResponseData] 的一部分。区分这两件事是因为
/// 处理方式完全不同：连不上要退避重试，500 是服务端自己的问题也要重试，
/// 但 401 重试就是纯粹的浪费。
final class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => 'TransportException: $message';
}

abstract interface class SyncTransport {
  /// 发一个 POST。**不抛 [TransportException] 以外的异常**。
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  });

  /// `keepRawBody`：把 body 原样留在 `rawBody` 里（`/export` 要落地成文件）。
  /// 默认不留 —— 同步的响应都是几十 KB 的 JSON，留一份整串没意义。
  Future<HttpResponseData> get(
    Uri url, {
    Map<String, String> headers,
    bool keepRawBody,
  });

  void close();
}

/// 真的走网络。
///
/// 两个超时都是硬要求（协议文档 §6）：沙箱会休眠，连一个睡着的服务不设
/// 超时就是永远转圈，用户看到的是"卡住了"而不是"没同步上"。
/// 连接 5 秒（DNS+握手的容忍上限）、整体 15 秒（冷启动要几秒）。
final class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({
    this.connectTimeout = const Duration(seconds: 5),
    this.totalTimeout = const Duration(seconds: 15),
    HttpClient? client,
  }) : _injected = client;

  final Duration connectTimeout;
  final Duration totalTimeout;

  /// 外部注入的客户端。**注入的不会被 `close()` 关掉**——调用方可能还有
  /// 别的地方在用它。
  final HttpClient? _injected;

  /// 自己造的那个。**每次请求换一个新的**，用完立刻关（原因见 `_send`）。
  /// 存成字段只是为了 `close()` 能兜底关掉最后一个。
  HttpClient? _own;

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) => _send('POST', url, headers: headers, body: body, keepRawBody: false);

  @override
  Future<HttpResponseData> get(
    Uri url, {
    Map<String, String> headers = const {},
    bool keepRawBody = false,
  }) => _send('GET', url, headers: headers, keepRawBody: keepRawBody);

  Future<HttpResponseData> _send(
    String method,
    Uri url, {
    bool keepRawBody = false,
    required Map<String, String> headers,
    String? body,
  }) async {
    // 每次请求一个**新的**连接池：同步是低频操作（几分钟一次），复用省不了
    // 什么，却会在沙箱休眠后留下一个僵死的 keep-alive 连接 —— 下次请求
    // 直接超时，而重试才会好。这个 bug 极难归因。
    //
    // 同理**不能在这里 close 注入进来的那个**：调用方可能还在用它做别的
    // 事，关掉之后下一次 `openUrl` 会抛 "Client is closed"，而报错位置
    // 离真正的原因隔着好几层。踩过。
    final client = _injected ?? HttpClient();
    _own = _injected == null ? client : _own;

    Future<HttpResponseData> run() async {
      final req = await client.openUrl(method, url);
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      Map<String, Object?>? parsed;
      if (text.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            parsed = decoded.cast<String, Object?>();
          }
        } on FormatException {
          // 不在这里抛：状态码可能是 502（网关返回一段 HTML），
          // 调用方按状态码分类比按"解析失败"分类更有意义。
          parsed = null;
        }
      }
      return HttpResponseData(
        statusCode: resp.statusCode,
        json: parsed,
        // 只有 `/export` 要：那一份要原样落地成文件。
        rawBody: keepRawBody ? utf8.encode(text) : null,
      );
    }

    try {
      return await run().timeout(totalTimeout);
    } on TimeoutException {
      throw TransportException('超过 ${totalTimeout.inSeconds} 秒没有响应');
    } on SocketException catch (e) {
      throw TransportException('连不上：${e.message}');
    } on HttpException catch (e) {
      throw TransportException('HTTP 出错：${e.message}');
    } finally {
      if (_injected == null) {
        client.close(force: true);
      }
    }
  }

  @override
  void close() {
    // 注入的那个不归我们关。
    if (_injected == null) {
      _own?.close(force: true);
      _own = null;
    }
  }
}

/// 打服务端的门面：拼 URL、带 token、把 HTTP 错误码翻译成失败分类。
final class SyncApi {
  SyncApi({required SyncTransport transport, required Uri baseUrl})
    : _transport = transport,
      _baseUrl = baseUrl;

  final SyncTransport _transport;
  final Uri _baseUrl;

  Uri _uri(String path) {
    // 基址可能带子路径（发布到 /famdaily/ 下），拼的时候保留。
    final base = _baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// `POST /sync`。**返回值可能是被拒绝的批次** —— 那也算成功。
  Future<SyncResponse> sync({
    required String token,
    required SyncRequest request,
  }) async {
    final resp = await _transport.post(
      _uri('/sync'),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      body: request.encode(),
    );
    _throwOnError(resp, '/sync');
    final json = resp.json;
    if (json == null) {
      throw SyncFormatException('response', '服务端返回了空 body');
    }
    return SyncResponse.fromJson(json);
  }

  /// 配对前预览：只要成员名。
  Future<PairPreview> preview(String code) async {
    final normalized = normalizePairCode(code);
    if (normalized == null) {
      throw SyncFormatException('pair.code', '同步码格式不对');
    }
    // 预览接口吃的是**带前缀**的展示形式，服务端自己剥前缀。
    final resp = await _transport.get(
      _uri('/pair/${Uri.encodeComponent(normalized)}'),
      headers: const {'Accept': 'application/json'},
    );
    _throwOnError(resp, '/pair');
    final json = resp.json;
    if (json == null) {
      throw SyncFormatException('response', '服务端返回了空 body');
    }
    return PairPreview.fromJson(json);
  }

  /// 同步码换 token。
  Future<PairClaimResult> claim({
    required String code,
    required String deviceName,
  }) async {
    final normalized = normalizePairCode(code);
    if (normalized == null) {
      throw SyncFormatException('pair.code', '同步码格式不对');
    }
    final resp = await _transport.post(
      _uri('/pair/claim'),
      headers: const {'Accept': 'application/json'},
      body: jsonEncode({'code': normalized, 'deviceName': deviceName}),
    );
    _throwOnError(resp, '/pair/claim');
    final json = resp.json;
    if (json == null) {
      throw SyncFormatException('response', '服务端返回了空 body');
    }
    return PairClaimResult.fromJson(json);
  }

  /// 给成员发一个打卡链接，返回完整 URL。
  ///
  /// **URL 里的 token 只在这里出现一次**：服务端存的是哈希，返回之后再想
  /// 要同一个链接只能重新生成（会顶掉旧的）。所以调用方必须当场把它交给
  /// 用户（复制/分享），**不能只存起来等下次显示** —— 存下来的那份和
  /// 服务端的哈希对不上时没有任何办法验证，只会表现为"链接打不开"。
  Future<MemberLinkResult> memberLink({
    required String token,
    required String memberId,
  }) async {
    final resp = await _transport.post(
      _uri('/members/${Uri.encodeComponent(memberId)}/link'),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      body: '{}',
    );
    _throwOnError(resp, '/members/link');
    final json = resp.json;
    if (json == null || json['url'] is! String) {
      throw SyncFormatException('response', '服务端没返回链接');
    }
    return MemberLinkResult(
      url: json['url']! as String,
      issuedAtMs: (json['issuedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 作废成员的打卡链接。
  Future<void> revokeMemberLink({
    required String token,
    required String memberId,
  }) async {
    final resp = await _transport.post(
      _uri('/members/${Uri.encodeComponent(memberId)}/unlink'),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      body: '{}',
    );
    _throwOnError(resp, '/members/unlink');
  }

  /// `GET /export`：把服务端那份数据取回成本地备份文件的字节。
  ///
  /// 返回的字节**就是** App 的备份 JSON（格式与 `BackupData.toJson` 一致），
  /// 所以它可以直接走「选一份备份恢复」，也可以当普通备份存着。
  ///
  /// 这里拿的是**原始 body**，不走 `_transport.get` 那套 JSON 解析：
  /// 1. 解析再 `jsonEncode` 会丢掉键的顺序、也可能改数字格式，
  ///    "导出的文件和备份文件长得不一样"会让用户以为是两份不同的东西；
  /// 2. 备份可能很大（几年记录），多一次 parse/stringify 是白花的。
  Future<List<int>> exportBackupBytes({required String token}) async {
    final resp = await _transport.get(
      _uri('/export'),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      // 不传这个，`rawBody` 恒为 null，下面直接抛"服务端返回了空备份"。
      keepRawBody: true,
    );
    _throwOnError(resp, '/export');
    final raw = resp.rawBody;
    if (raw == null || raw.isEmpty) {
      throw SyncFormatException('response', '服务端返回了空备份');
    }
    return raw;
  }

  /// 轮换 token（其他设备全部失效）。
  Future<PairClaimResult> rotateToken({required String token}) async {
    final resp = await _transport.post(
      _uri('/pair/rotate'),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      body: '{}',
    );
    _throwOnError(resp, '/pair/rotate');
    final json = resp.json;
    if (json == null) {
      throw SyncFormatException('response', '服务端返回了空 body');
    }
    return PairClaimResult.fromJson(json);
  }

  void close() => _transport.close();

  /// 把非 2xx 翻译成带分类的异常。
  ///
  /// 401/403 → [SyncAuthException]（不重试）
  /// 其它    → [SyncHttpException]（按网络问题处理，重试）
  /// 400     → [SyncFormatException]（不重试，版本不匹配）
  void _throwOnError(HttpResponseData resp, String where) {
    final code = resp.statusCode;
    if (code >= 200 && code < 300) {
      return;
    }
    final detail = resp.json?['error'] ?? resp.json?['message'];
    final text = detail is String ? detail : 'HTTP $code';
    if (code == 401 || code == 403) {
      throw SyncAuthException(code, text);
    }
    if (code == 400 || code == 422) {
      throw SyncFormatException(where, text);
    }
    throw SyncHttpException(code, text);
  }
}

/// 这台设备还没配对。
///
/// **不继承 `SyncTransport` 的失败语义**：这不是"网络不通"，重试一百次
/// 也不会变。界面的正确反应是引导去设置里配对，而不是显示一个"重试"按钮。
final class SyncNotPairedException implements Exception {
  const SyncNotPairedException();

  @override
  String toString() => 'SyncNotPairedException: 还没同步过，先配对';
}

/// 凭据失效。**不要重试**：重试只会把限流打满，用户还是得重新配对。
final class SyncAuthException implements Exception {
  SyncAuthException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SyncAuthException($statusCode): $message';
}

/// 服务端错误（5xx / 网关 / 限流 429）。可以重试。
final class SyncHttpException implements Exception {
  SyncHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SyncHttpException($statusCode): $message';
}
