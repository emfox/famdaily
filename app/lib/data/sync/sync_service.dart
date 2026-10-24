/// 同步的编排层：什么时候推、推什么、失败怎么办、失败之后还要不要试。
///
/// 这个类**不 import Flutter**，也不碰任何 Widget。原因很实际：
/// 同步的全部难度都在"何时做、做几次、什么时候放弃"这些时序判断上，
/// 而时序最怕的就是被 `mounted` 和 `setState` 搅进去。界面只读它的状态。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../db/mappers.dart';
import 'sync_api.dart';
import 'sync_config.dart';
import 'sync_merge.dart';
import 'sync_protocol.dart';

/// 界面上能看到的一次同步的结果。
enum SyncOutcome {
  /// 还没跑过。
  idle,

  /// 正在跑。
  running,

  /// 成功（可能带若干条被拒）。
  ok,

  /// 被拒了若干条，其余成功。
  partial,

  /// 没配对过，什么都没做。
  notConfigured,

  /// 失败。看 [SyncStatus.errorKind]。
  failed,
}

/// `SyncService` 的状态快照。不可变，界面读它。
final class SyncStatus {
  const SyncStatus({
    this.outcome = SyncOutcome.idle,
    this.lastSuccessAtMs,
    this.errorKind,
    this.errorMessage,
    this.rejects = const [],
    this.writtenRows = 0,
    this.sinceReset = false,
  });

  final SyncOutcome outcome;
  final int? lastSuccessAtMs;
  final SyncErrorKind? errorKind;
  final String? errorMessage;

  /// 本次被服务端拒绝的条目（只留前几条，够看清原因就行）。
  final List<SyncReject> rejects;

  /// 这次同步从远端写进来的行数。0 = 数据没变，界面不必刷。
  final int writtenRows;

  /// 服务端说我的水位太新，下次要全量拉。
  final bool sinceReset;

  bool get isRunning => outcome == SyncOutcome.running;

  /// 设置页那一行右侧的字。**空字符串 = 这一行不该出现**。
  ///
  /// `idle` 有两层含义：从没跑过（`SyncStatus` 的初始值）和跑过但状态被
  /// 重置了。分不清，所以统一**不显示**——宁可少说一句，也不要在新用户
  /// 第一次进设置时给他一个"未同步"的红字，他其实还没开启过这东西。
  /// 配对过之后第一次同步成功就会变成"刚刚同步"。
  String get shortLabel => switch (outcome) {
    SyncOutcome.notConfigured => '',
    SyncOutcome.running => '同步中…',
    SyncOutcome.ok => _ago(lastSuccessAtMs),
    SyncOutcome.partial => '部分内容没同步上',
    SyncOutcome.failed => errorKind?.label ?? '同步失败',
    SyncOutcome.idle => '',
  };

  static String _ago(int? atMs) {
    if (atMs == null) {
      return '未同步';
    }
    final diff = DateTime.now().millisecondsSinceEpoch - atMs;
    if (diff < 60 * 1000) {
      return '刚刚同步';
    }
    if (diff < 60 * 60 * 1000) {
      return '${diff ~/ (60 * 1000)} 分钟前';
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return '${diff ~/ (60 * 60 * 1000)} 小时前';
    }
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }
}

/// 退避表（协议文档 §6）：30s → 1m → 3m → 10m → 30m，**只在内存**。
///
/// 存在内存里是刻意的：重启 App 就重来一轮。否则一次长时间断网之后，
/// 退避会一路涨到 30 分钟，而用户"关掉重开"这个动作本来就该被当成
/// "我现在想试一次"。
const _backoffSteps = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 3),
  Duration(minutes: 10),
  Duration(minutes: 30),
];

/// 本地变更后的防抖。3 秒：够把"连续勾三个项目"合成一次推。
const _pushDebounce = Duration(seconds: 3);

/// 回前台时，距上次成功超过这个间隔才拉。
const _foregroundMinGap = Duration(seconds: 30);

/// 同步服务。
///
/// 生命周期挂在 `AppServices` 上，与 App 同生共死。
final class SyncService {
  SyncService({
    required AppDatabase db,
    required SyncConfigStore config,
    required SyncApi Function(Uri baseUrl, SyncTransport transport) apiFactory,
    SyncTransport Function()? transportFactory,
    int Function()? nowMs,
    String Function()? newId,
    Future<void> Function()? onDataChanged,
  }) : _db = db,
       _config = config,
       _apiFactory = apiFactory,
       _transportFactory = transportFactory ?? HttpSyncTransport.new,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newId = newId ?? (() => 'c${DateTime.now().microsecondsSinceEpoch}'),
       _onDataChanged = onDataChanged;

  final AppDatabase _db;
  final SyncConfigStore _config;
  final SyncApi Function(Uri baseUrl, SyncTransport transport) _apiFactory;
  final SyncTransport Function() _transportFactory;
  final int Function() _nowMs;
  final String Function() _newId;

  /// 远端真的有写入时调用（用来重排提醒 + 叫醒首页）。
  ///
  /// 做成回调而不是直接依赖 `ReminderScheduler`：这个类要保持可测，
  /// 而重排要碰通知插件。回调也让"同步之后谁被通知"这件事在装配处一眼可见。
  final Future<void> Function()? _onDataChanged;

  final _controller = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();

  /// 当前状态。界面订阅 [stream] 拿变化。
  SyncStatus get status => _status;

  Stream<SyncStatus> get stream => _controller.stream;

  /// 正在跑的同步。并发调用会**复用**这一个而不是再起一次：
  /// 冷启动和回前台可能几乎同时触发，两次 `/sync` 会把限流打满。
  Future<SyncStatus>? _inflight;

  Timer? _debounce;
  Timer? _backoffTimer;
  int _backoffIndex = 0;
  bool _disposed = false;

  /// 上次成功的时间（内存里也留一份，避免每次都读库）。
  int? _lastSuccessAtMs;

  // -------------------------------------------------------------------
  // 对外触发点
  // -------------------------------------------------------------------

  /// 冷启动、回前台、手动。都走这一个入口。
  ///
  /// [reason] 只用于日志与调试，不参与逻辑判断。
  Future<SyncStatus> syncNow({String reason = 'manual'}) {
    // 已经释放就别再碰数据库。定时器醒来时宿主可能已经关了库
    // （集成测试收尾、App 退出），那时再查库会抛
    // "Can't re-open a database after closing it" —— 一句和真实原因
    // 毫无关系的报错，能让人查半天。
    if (_disposed) {
      return Future.value(_status);
    }
    final running = _inflight;
    if (running != null) {
      return running;
    }
    final future = _run(reason: reason);
    _inflight = future;
    // 无论成败都要把 _inflight 清掉，否则一次失败会永久堵住后续同步。
    return future.whenComplete(() => _inflight = null);
  }

  /// 本地变更后调用：防抖 3 秒再推。
  ///
  /// 3 秒是"用户还在连续操作"和"用户已经走开"之间的折中。更短会推得频繁
  /// （点一次勾推一次），更长会让用户盯着"待同步"发呆。
  void notifyLocalChange() {
    if (_disposed) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_pushDebounce, () {
      unawaited(syncNow(reason: 'localChange'));
    });
  }

  /// 回前台。距上次成功不到 30 秒就跳过 —— 用户在 App 里切来切去
  /// 不该每次都发一个请求。
  Future<SyncStatus> onForeground() async {
    final last = _lastSuccessAtMs ?? await _config.lastSuccessAtMs();
    _lastSuccessAtMs = last;
    if (last != null && _nowMs() - last < _foregroundMinGap.inMilliseconds) {
      return _status;
    }
    return syncNow(reason: 'foreground');
  }

  /// 配对成功后立刻同步一次（把新家庭的数据拉下来）。
  Future<SyncStatus> afterPairing() {
    _backoffIndex = 0;
    _backoffTimer?.cancel();
    return syncNow(reason: 'paired');
  }

  /// 给成员发一个打卡链接。
  ///
  /// 和同步共用一个 `SyncApi`，因为**它用的是同一套设备凭据**：链接是
  /// "这台已经配对的设备"替某个成员申请的。没配对时直接抛
  /// [SyncNotPairedException]，让界面提示"先同步"而不是一个网络错误。
  ///
  /// 单独包一层（而不是让界面自己 new 一个 `SyncApi`）的三个理由：
  /// 1. 界面拿不到 `token`（它在 `settings` 表里，不该散出去）；
  /// 2. transport 的关闭时机要统一，多一处 new 就多一处泄漏；
  /// 3. 测试能注入假 transport，不用起服务。
  Future<MemberLinkResult> createMemberLink(String memberId) async {
    final cfg = await _config.load();
    if (cfg == null || !cfg.isComplete) {
      throw const SyncNotPairedException();
    }
    final transport = _transportFactory();
    final api = _apiFactory(Uri.parse(cfg.baseUrl), transport);
    try {
      return await api.memberLink(token: cfg.token, memberId: memberId);
    } finally {
      // 这里**必须** close：`HttpSyncTransport` 每次请求自己造
      // `HttpClient`，不关就是一次链接生成泄漏一个连接池。
      api.close();
    }
  }

  /// 作废成员的打卡链接（关掉那个入口）。
  ///
  /// 返回 `true` = 真的废掉了一条；`false` = 本来就没有有效链接。
  /// **不要吞掉这个 bool**：界面对这两种情况说的是两句不同的话。
  Future<bool> revokeMemberLink(String memberId) async {
    final cfg = await _config.load();
    if (cfg == null || !cfg.isComplete) {
      throw const SyncNotPairedException();
    }
    final transport = _transportFactory();
    final api = _apiFactory(Uri.parse(cfg.baseUrl), transport);
    try {
      return await api.revokeMemberLink(token: cfg.token, memberId: memberId);
    } finally {
      api.close();
    }
  }

  /// `GET /export`：把服务端那份数据取回成本地备份的字节。
  ///
  /// 返回的就是 App 的备份 JSON（字段与 `BackupData.toJson` 一致），
  /// 所以既能直接存成文件，也能喂给「选一份备份恢复」。
  ///
  /// **和本机导出并列存在，不是替代**：本机导出能带照片，这一份永远不能
  /// （照片从不上传）；但本机数据库坏了、换了手机、App 被删了重装，
  /// 只有这一份取得回来。
  Future<List<int>> exportBackupBytes() async {
    final cfg = await _config.load();
    if (cfg == null || !cfg.isComplete) {
      throw const SyncNotPairedException();
    }
    final transport = _transportFactory();
    final api = _apiFactory(Uri.parse(cfg.baseUrl), transport);
    try {
      return await api.exportBackupBytes(token: cfg.token);
    } finally {
      api.close();
    }
  }

  /// 这台设备配没配对（有没有一份完整的同步配置）。
  ///
  /// **不用 `status.outcome`**：那是"上一次同步的结果"，冷启动时还没跑过，
  /// 初始值是 `idle`，看起来和"配对过但还没同步"一模一样。想知道
  /// "该不该显示云端功能"，必须问配置本身。
  Future<bool> isPaired() async {
    final cfg = await _config.load();
    return cfg != null && cfg.isComplete;
  }

  /// 清掉"不可重试"的失败状态（用户手动点「重试」时用）。
  void resetError() {
    _backoffIndex = 0;
    _backoffTimer?.cancel();
    _emit(
      SyncStatus(outcome: SyncOutcome.idle, lastSuccessAtMs: _lastSuccessAtMs),
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _debounce?.cancel();
    _backoffTimer?.cancel();
    _debounce = null;
    _backoffTimer = null;
    unawaited(_controller.close());
  }

  // -------------------------------------------------------------------
  // 主流程
  // -------------------------------------------------------------------

  Future<SyncStatus> _run({required String reason}) async {
    final cfg = await _config.load();
    if (cfg == null) {
      _emit(const SyncStatus(outcome: SyncOutcome.notConfigured));
      return _status;
    }

    _emit(
      SyncStatus(
        outcome: SyncOutcome.running,
        lastSuccessAtMs: _lastSuccessAtMs,
      ),
    );

    final transport = _transportFactory();
    SyncApi? api;
    try {
      api = _apiFactory(Uri.parse(cfg.baseUrl), transport);
      final since = await _config.loadSince();
      final request = await _buildRequest(since);
      final response = await api.sync(token: cfg.token, request: request);

      // ---- 1. 先落库（顺序：成员 → 项目 → 打卡 → 设置）----
      final written = await _applyResponse(response);

      // ---- 2. 落库成功之后才推进水位 ----
      // 反过来（先推进再落库）会让"写库失败"变成"数据永久丢失"：
      // 服务端认为我收到过了，我也认为自己收到过了，下次不再拉。
      await _config.saveSince(response.sinceReset ? 0 : response.cursor);
      final now = _nowMs();
      await _config.markSuccess(now);
      _lastSuccessAtMs = now;

      // ---- 3. 有写入才重排 + 叫醒界面 ----
      if (written > 0) {
        await _onDataChanged?.call();
      }

      final partial = response.rejected.isNotEmpty;
      await _config.saveRejects(
        partial
            ? response.rejected.take(3).map((r) => r.toString()).join('；')
            : '',
      );

      _backoffIndex = 0;
      _backoffTimer?.cancel();
      _emit(
        SyncStatus(
          outcome: partial ? SyncOutcome.partial : SyncOutcome.ok,
          lastSuccessAtMs: now,
          rejects: response.rejected.take(3).toList(),
          writtenRows: written,
          sinceReset: response.sinceReset,
        ),
      );
      debugPrint(
        '[sync] $reason 完成：写入 $written 行，被拒 ${response.rejected.length} 条',
      );
      return _status;
    } on SyncAuthException catch (e) {
      // 不重试。token 失效只有用户重新配对能解，自动重试只会把限流打满，
      // 并且让"同步码失效"这个真实原因在日志里被埋掉。
      await _config.markError(SyncErrorKind.auth, e.message, _nowMs());
      _emit(
        SyncStatus(
          outcome: SyncOutcome.failed,
          lastSuccessAtMs: _lastSuccessAtMs,
          errorKind: SyncErrorKind.auth,
          errorMessage: e.message,
        ),
      );
      debugPrint('[sync] $reason 鉴权失败：${e.message}');
      return _status;
    } on SyncFormatException catch (e) {
      await _config.markError(SyncErrorKind.protocol, '$e', _nowMs());
      _emit(
        SyncStatus(
          outcome: SyncOutcome.failed,
          lastSuccessAtMs: _lastSuccessAtMs,
          errorKind: SyncErrorKind.protocol,
          errorMessage: '$e',
        ),
      );
      debugPrint('[sync] $reason 协议不匹配：$e');
      return _status;
    } catch (e) {
      // 传输失败 / 5xx / 429：可以重试，走退避。
      final message = e is SyncHttpException ? e.message : '$e';
      await _config.markError(SyncErrorKind.network, message, _nowMs());
      _emit(
        SyncStatus(
          outcome: SyncOutcome.failed,
          lastSuccessAtMs: _lastSuccessAtMs,
          errorKind: SyncErrorKind.network,
          errorMessage: message,
        ),
      );
      debugPrint('[sync] $reason 失败：$message');
      _scheduleRetry();
      return _status;
    } finally {
      api?.close();
    }
  }

  /// 指数退避。**只在内存**，重启就重来。
  void _scheduleRetry() {
    if (_disposed) {
      return;
    }
    _backoffTimer?.cancel();
    final step =
        _backoffSteps[_backoffIndex.clamp(0, _backoffSteps.length - 1)];
    _backoffIndex = (_backoffIndex + 1).clamp(0, _backoffSteps.length - 1);
    _backoffTimer = Timer(step, () {
      if (_disposed) {
        return;
      }
      unawaited(syncNow(reason: 'retry'));
    });
    debugPrint('[sync] ${step.inSeconds} 秒后重试');
  }

  /// 装配这次要推的全量当前状态。
  ///
  /// **每次都推全量**（协议文档 §3.1）：家庭规模下约 150KB，比维护变更集
  /// 简单一个数量级，也不会有"漏推某种操作"这种 bug。
  /// `checkins` 永远显式给（哪怕是 `[]`）—— 只有"我真的要推打卡"时，
  /// 服务端才会做墓碑判断。
  Future<SyncRequest> _buildRequest(int since) async {
    final members = await _db.listMembersIncludingDeleted();
    final taskRows = await _db.select(_db.tasks).get();
    final checkins = await _db.listAllCheckins();
    final settings = await _db.listSyncedSettings();
    // **我撤销过哪些打卡**，只能从本地变更日志里读（见
    // `AppDatabase.deletedCheckinKeys` 的注释：光看"本地没有"分不清
    // "我删了"和"我从来没有"）。
    final removed = await _db.deletedCheckinKeys();
    // 本地现在有的那些，用同一个编码（`任务id|日期|序号`）表示，
    // 才能和撤销集合对齐。`CheckinDto.key` 用的是 `\u0000` 分隔，
    // 这里直接拼同一个形状，避免两套编码对不上。
    final presentKeys = {
      for (final c in checkins) '${c.taskId}|${c.date}|${c.slotIndex}',
    };

    return SyncRequest(
      since: since,
      members: [for (final m in members) MemberDto.fromDomain(m)],
      tasks: [for (final row in taskRows) _taskDto(row)],
      checkins: [for (final c in checkins) CheckinDto.fromDomain(c)],
      // 推上去的那条如果同时也在撤销集合里，说明撤销之后又打过卡 ——
      // 以"有"为准，不能既说它有又说要删。
      removedCheckins: [
        for (final k in removed)
          if (!presentKeys.contains(k)) k,
      ],
      settings: settings.values.toList(),
    );
  }

  TaskDto _taskDto(TaskRow row) {
    final t = Mappers.taskFromRow(row);
    return TaskDto(
      id: t.id,
      memberId: t.memberId,
      name: t.name,
      note: t.note,
      iconId: t.iconId,
      // 规则原文直接搬：服务端不解释内容，解码/再编码只多一次出错的机会。
      repeatJson: row.repeatJson,
      timeJson: row.timeJson,
      courseStart: t.course.start?.toString(),
      courseEnd: t.course.end?.toString(),
      // 从行里读，不从 Course 反推（"连续 N 天"只存在这一列上）。
      courseTotalDays: row.courseTotalDays,
      status: t.status,
      reminderEnabled: t.reminderEnabled,
      sortOrder: t.sortOrder,
      rulesEffectiveFrom: row.rulesEffectiveFrom?.toString(),
      createdAtMs: t.createdAtMs,
      updatedAtMs: t.updatedAtMs,
      deletedAtMs: t.deletedAtMs,
    );
  }

  /// 把响应落进库。返回真的写了的行数。
  ///
  /// 顺序受外键约束：先成员、再项目、最后打卡。
  Future<int> _applyResponse(SyncResponse response) async {
    var written = 0;

    for (final remote in response.members) {
      final local = await _db.findMember(remote.id);
      if (await _db.applyRemoteMember(remote, mergeMember(local, remote))) {
        written++;
      }
    }

    for (final remote in response.tasks) {
      final local = await _db.findTask(remote.id);
      final row = await (_db.select(
        _db.tasks,
      )..where((t) => t.id.equals(remote.id))).getSingleOrNull();
      final winner = mergeTask(
        local,
        remote,
        localDeleted: row?.deletedAtMs != null,
      );
      if (await _db.applyRemoteTask(remote, winner)) {
        written++;
      }
    }

    for (final remote in response.checkins) {
      final date = remote.dateValue();
      // 打卡可能引用一个本地还没有的项目（对端新建的项目被这一批的
      // 位置挤出了响应）。外键是 RESTRICT，插下去会抛 —— 跳过，
      // 下一轮拉取会带着项目和这条一起下来。
      if (await _db.findTask(remote.taskId) == null) {
        continue;
      }
      if (shouldDropByTombstone(remote)) {
        if (await _db.dropCheckin(
          taskId: remote.taskId,
          date: date,
          slotIndex: remote.slotIndex,
        )) {
          written++;
        }
        continue;
      }
      final local = await _db.findCheckin(
        taskId: remote.taskId,
        date: date,
        slotIndex: remote.slotIndex,
      );
      final merged = mergeCheckin(local, remote);
      if (await _db.applyRemoteCheckin(
        remote,
        merged,
        _newId,
        nowMs: _nowMs(),
      )) {
        written++;
      }
    }

    for (final remote in response.settings) {
      if (!syncedSettingKeys.contains(remote.key)) {
        // 服务端不该发白名单之外的键，但真发了也不能写进本机：
        // 那里可能有 `sync.token` 这种"两台设备必须各是各的"的东西。
        continue;
      }
      final localAt = await _db.settingUpdatedAt(remote.key);
      if (!shouldTakeRemoteSetting(localUpdatedAtMs: localAt, remote: remote)) {
        continue;
      }
      if (await _db.applyRemoteSetting(remote)) {
        written++;
      }
    }

    return written;
  }

  void _emit(SyncStatus s) {
    _status = s;
    if (!_controller.isClosed) {
      _controller.add(s);
    }
  }
}
