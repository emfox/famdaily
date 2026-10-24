/// 同步的本地配置与服务端地址。
library;

import '../db/app_database.dart';
import 'sync_protocol.dart';

/// 同步相关的设置键。
///
/// 全部塞在 `settings` 表里，**不升 schemaVersion**：这些是"这台设备
/// 和那个家庭绑没绑"的运行时状态，不是业务数据。
abstract final class SyncKeys {
  static const deviceId = 'sync.deviceId';
  static const token = 'sync.token';
  static const familyId = 'sync.familyId';
  static const baseUrl = 'sync.baseUrl';
  static const since = 'sync.since';
  static const lastSuccessAtMs = 'sync.lastSuccessAtMs';
  static const lastError = 'sync.lastError';
  static const lastErrorAtMs = 'sync.lastErrorAtMs';
  static const lastRejects = 'sync.lastRejects';

  /// 以上全部**不参与同步**（见 `syncedSettingKeys` 白名单）。
  static const all = {
    deviceId,
    token,
    familyId,
    baseUrl,
    since,
    lastSuccessAtMs,
    lastError,
    lastErrorAtMs,
    lastRejects,
  };
}

/// 配对后落到本机的那份凭据。
final class SyncConfig {
  const SyncConfig({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    required this.familyId,
  });

  final String baseUrl;
  final String token;
  final String deviceId;
  final String familyId;

  bool get isComplete =>
      baseUrl.isNotEmpty &&
      token.isNotEmpty &&
      deviceId.isNotEmpty &&
      familyId.isNotEmpty;
}

/// 读 / 写同步配置。
final class SyncConfigStore {
  SyncConfigStore(this.db);

  final AppDatabase db;

  Future<SyncConfig?> load() async {
    final base = await db.getSetting(SyncKeys.baseUrl);
    final token = await db.getSetting(SyncKeys.token);
    final device = await db.getSetting(SyncKeys.deviceId);
    final family = await db.getSetting(SyncKeys.familyId);
    if (base == null || token == null || device == null || family == null) {
      return null;
    }
    final cfg = SyncConfig(
      baseUrl: base,
      token: token,
      deviceId: device,
      familyId: family,
    );
    return cfg.isComplete ? cfg : null;
  }

  Future<void> save(SyncConfig cfg, {required int nowMs}) async {
    await db.setSetting(SyncKeys.baseUrl, cfg.baseUrl, nowMs: nowMs);
    await db.setSetting(SyncKeys.token, cfg.token, nowMs: nowMs);
    await db.setSetting(SyncKeys.deviceId, cfg.deviceId, nowMs: nowMs);
    await db.setSetting(SyncKeys.familyId, cfg.familyId, nowMs: nowMs);
  }

  /// 断开同步：删配置，但**不删数据**。
  ///
  /// 水位的处理是关键：`sync.since` 一定要一起清掉。留着的话下次重新配对
  /// 会用旧家庭的 `cursor` 去问新家庭，服务端要么回 `sinceReset`、
  /// 要么直接把"水位之后的行"全发过来 —— 两种都不是用户想要的。
  Future<void> clear({required int nowMs}) async {
    for (final key in SyncKeys.all) {
      await db.clearSetting(key, nowMs: nowMs);
    }
  }

  Future<int> loadSince() async {
    final raw = await db.getSetting(SyncKeys.since);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> saveSince(int cursor) async {
    // 推进水位不走 setSetting 的 nowMs 语义：这不是一次用户操作，
    // 不需要在 change_log 里留痕（留了反而会让 pendingSyncCount 虚高）。
    await db.applyRemoteSetting(_rawSetting(SyncKeys.since, '$cursor'));
  }

  Future<int?> lastSuccessAtMs() async {
    final raw = await db.getSetting(SyncKeys.lastSuccessAtMs);
    return int.tryParse(raw ?? '');
  }

  Future<void> markSuccess(int nowMs) async {
    await db.applyRemoteSetting(
      _rawSetting(SyncKeys.lastSuccessAtMs, '$nowMs'),
    );
    await db.clearSetting(SyncKeys.lastError, nowMs: nowMs);
    await db.clearSetting(SyncKeys.lastErrorAtMs, nowMs: nowMs);
  }

  Future<String?> lastError() => db.getSetting(SyncKeys.lastError);

  Future<void> markError(SyncErrorKind kind, String message, int nowMs) async {
    await db.applyRemoteSetting(
      _rawSetting(SyncKeys.lastError, '${kind.name}:$message'),
    );
    await db.applyRemoteSetting(_rawSetting(SyncKeys.lastErrorAtMs, '$nowMs'));
  }

  Future<String?> lastRejects() => db.getSetting(SyncKeys.lastRejects);

  Future<void> saveRejects(String summary) async {
    await db.applyRemoteSetting(_rawSetting(SyncKeys.lastRejects, summary));
  }
}

/// 失败分类。决定"要不要自动重试"，是这套东西唯一有分支的地方。
enum SyncErrorKind {
  /// 连不上 / 超时 / 5xx。沙箱休眠是常态，这类**必须**自动重试。
  network,

  /// 401 / 403。token 失效，重试一万次也不会好，还会把服务端限流打满。
  auth,

  /// 400 / 协议解析失败。版本不匹配，同上。
  protocol,

  /// 服务端明确拒绝的条目，但请求本身成功了。
  partial;

  String get label => switch (this) {
    network => '网络不通',
    auth => '同步码已失效',
    protocol => '版本不匹配',
    partial => '部分内容被拒绝',
  };

  bool get shouldRetry => this == network;
}

/// 内部用：造一条"只带 key/value 的设置 DTO"，时间戳取 0。
///
/// 时间戳给 0 是刻意的：这些键**不参与同步**，`updated_at_ms` 只在本机
/// 被读，没有任何比较逻辑会用到它。
SettingDto _rawSetting(String key, String value) =>
    SettingDto(key: key, value: value, updatedAtMs: 0);
