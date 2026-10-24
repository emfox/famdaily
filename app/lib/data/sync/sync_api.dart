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

/// 一次请求的结果：状态码 + 已解析的 JSON。
final class HttpResponseData {
  const HttpResponseData({required this.statusCode, required this.json});

  final int statusCode;

  /// body 解析成的 map；空 body 或不是对象时为 null。
  final Map<String, Object?>? json;

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

  Future<HttpResponseData> get(Uri url, {Map<String, String> headers});

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
  }) : _client = client ?? HttpClient();

  final Duration connectTimeout;
  final Duration totalTimeout;
  final HttpClient _client;

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) => _send('POST', url, headers: headers, body: body);

  @override
  Future<HttpResponseData> get(Uri url, {Map<String, String> headers = const {}}) =>
      _send('GET', url, headers: headers);

  Future<HttpResponseData> _send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    Future<HttpResponseData> run() async {
      final req = await _client.openUrl(method, url);
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
      return HttpResponseData(statusCode: resp.statusCode, json: parsed);
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
      // 每次请求新建连接：同步是低频操作（几分钟一次），连接复用省不了
      // 什么，却会在沙箱休眠后留下一个僵死的 keep-alive 连接 —— 下次
      // 请求直接超时，而重试才会好。这个 bug 极难归因。
      _client.close(force: true);
    }
  }

  @override
  void close() => _client.close(force: true);
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
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
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

  /// 轮换 token（其他设备全部失效）。
  Future<PairClaimResult> rotateToken({required String token}) async {
    final resp = await _transport.post(
      _uri('/pair/rotate'),
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
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
