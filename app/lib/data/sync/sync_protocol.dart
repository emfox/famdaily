/// 同步协议的数据模型与编解码。
///
/// **这个文件不 import Flutter，也不 import 数据库**。它只认识 domain 模型和
/// 裸 map，这样协议层的测试不需要 widget 环境，将来网页端也能照抄一份 TS。
///
/// 默认姿态是**严格拒绝**：不认识的枚举值抛错，绝不猜成某个"看起来合理"的值。
/// 宽容解析会把"对端版本比我新"伪装成"数据就是这样"，等到用户发现
/// "我明明补了卡"时才无从查起。
library;

import 'dart:convert';

import '../../domain/model/checkin.dart' as domain;
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart' as domain;
import '../../domain/model/task_status.dart';

/// 协议版本。不匹配时停止同步并提示升级，而不是硬解析。
const int syncProtocolVersion = 1;

/// 编解码失败的统一异常。
///
/// 带 [where] 是为了让"哪一行坏了"在日志里看得见 —— 只说"解析失败"，
/// 排查时等于什么也没说。
final class SyncFormatException implements Exception {
  SyncFormatException(this.where, this.message);

  final String where;
  final String message;

  @override
  String toString() => 'SyncFormatException($where): $message';
}

Never _fail(String where, String message) =>
    throw SyncFormatException(where, message);

int _int(Object? v, String where, {int? fallback}) {
  if (v == null) {
    if (fallback != null) {
      return fallback;
    }
    _fail(where, '缺必填整数字段');
  }
  if (v is int) {
    return v;
  }
  if (v is num && v == v.truncate()) {
    return v.toInt();
  }
  _fail(where, '不是整数：$v');
}

int? _intOrNull(Object? v, String where) {
  if (v == null) {
    return null;
  }
  return _int(v, where);
}

String _string(Object? v, String where, {int max = 500}) {
  if (v is! String || v.isEmpty) {
    _fail(where, '缺必填字符串');
  }
  if (v.length > max) {
    _fail(where, '字符串太长（${v.length} > $max）');
  }
  return v;
}

String? _stringOrNull(Object? v, String where, {int max = 500}) {
  if (v == null) {
    return null;
  }
  if (v is! String) {
    _fail(where, '不是字符串：$v');
  }
  if (v.length > max) {
    _fail(where, '字符串太长（${v.length} > $max）');
  }
  return v.isEmpty ? null : v;
}

bool _bool(Object v, String where) {
  if (v is bool) {
    return v;
  }
  _fail(where, '不是布尔：$v');
}

/// 一行成员在协议里的样子。
///
/// 字段名用 SNAKE_CASE，与数据库列名一致。这样做不是为了省心，是为了让
/// "服务端表结构"和"协议字段"一一对应，将来加字段时不会漏掉某一层。
final class MemberDto {
  const MemberDto({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.avatarId,
    this.deletedAtMs,
  });

  factory MemberDto.fromDomain(domain.Member m) => MemberDto(
    id: m.id,
    name: m.name,
    avatarId: m.avatarId,
    sortOrder: m.sortOrder,
    createdAtMs: m.createdAtMs,
    updatedAtMs: m.updatedAtMs,
    deletedAtMs: m.deletedAtMs,
  );

  /// 从**服务端返回的行**解析。列名是数据库列名（有 `family_id` 等多余列，
  /// 忽略即可）。
  factory MemberDto.fromWire(Map<String, Object?> j) => MemberDto(
    id: _string(j['id'], 'member.id', max: 64),
    name: _string(j['name'], 'member.name', max: 40),
    avatarId: _stringOrNull(j['avatar_id'], 'member.avatar_id', max: 40),
    sortOrder: _int(j['sort_order'], 'member.sort_order', fallback: 0),
    createdAtMs: _int(j['created_at_ms'], 'member.created_at_ms'),
    updatedAtMs: _int(j['updated_at_ms'], 'member.updated_at_ms'),
    deletedAtMs: _intOrNull(j['deleted_at_ms'], 'member.deleted_at_ms'),
  );

  final String id;
  final String name;
  final String? avatarId;
  final int sortOrder;
  final int createdAtMs;
  final int updatedAtMs;
  final int? deletedAtMs;

  /// 转成 domain 模型。
  domain.Member toDomain() => domain.Member(
    id: id,
    name: name,
    avatarId: avatarId,
    sortOrder: sortOrder,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    deletedAtMs: deletedAtMs,
  );

  /// 推给服务端的样子（不带 `family_id`/`server_at_ms` 这类服务端自有列）。
  Map<String, Object?> toWire() => {
    'id': id,
    'name': name,
    'avatarId': avatarId,
    'sortOrder': sortOrder,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'deletedAtMs': deletedAtMs,
  };
}

/// 各端共用的 JSON 编解码由 `Mappers` 负责，这里只搬运。
/// 见 [TaskDto.fromWire] 的注释：规则 JSON 服务端**不解释内容**，
/// 只确认它是 JSON 对象；解释它意味着服务端要和客户端的规则版本同步演进。
final class TaskDto {
  const TaskDto({
    required this.id,
    required this.memberId,
    required this.name,
    required this.repeatJson,
    required this.timeJson,
    required this.status,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.note,
    this.iconId,
    this.courseStart,
    this.courseEnd,
    this.courseTotalDays,
    this.rulesEffectiveFrom,
    this.reminderEnabled = true,
    this.sortOrder = 0,
    this.deletedAtMs,
  });

  factory TaskDto.fromWire(Map<String, Object?> j) {
    final statusRaw = _string(j['status'], 'task.status', max: 20);
    final status = TaskStatus.values
        .where((s) => s.name == statusRaw)
        .firstOrNull;
    if (status == null) {
      // 不认识的 status 必须拒。猜成 active 会让一个已归档的项目
      // 在另一台手机上继续提醒，猜成 deleted 会让项目凭空消失。
      _fail('task.status', '不认识的 status：$statusRaw');
    }
    return TaskDto(
      id: _string(j['id'], 'task.id', max: 64),
      memberId: _string(j['member_id'], 'task.member_id', max: 64),
      name: _string(j['name'], 'task.name', max: 60),
      note: _stringOrNull(j['note'], 'task.note'),
      iconId: _stringOrNull(j['icon_id'], 'task.icon_id', max: 40),
      repeatJson: _string(j['repeat_json'], 'task.repeat_json', max: 4000),
      timeJson: _string(j['time_json'], 'task.time_json', max: 4000),
      courseStart: _stringOrNull(
        j['course_start'],
        'task.course_start',
        max: 10,
      ),
      courseEnd: _stringOrNull(j['course_end'], 'task.course_end', max: 10),
      courseTotalDays: _intOrNull(
        j['course_total_days'],
        'task.course_total_days',
      ),
      status: status,
      reminderEnabled: j['reminder_enabled'] == null
          ? true
          : _bool(
              j['reminder_enabled'] is int
                  ? j['reminder_enabled'] == 1
                  : j['reminder_enabled']!,
              'task.reminder_enabled',
            ),
      sortOrder: _int(j['sort_order'], 'task.sort_order', fallback: 0),
      rulesEffectiveFrom: _stringOrNull(
        j['rules_effective_from'],
        'task.rules_effective_from',
        max: 10,
      ),
      createdAtMs: _int(j['created_at_ms'], 'task.created_at_ms'),
      updatedAtMs: _int(j['updated_at_ms'], 'task.updated_at_ms'),
      deletedAtMs: _intOrNull(j['deleted_at_ms'], 'task.deleted_at_ms'),
    );
  }

  final String id;
  final String memberId;
  final String name;
  final String? note;
  final String? iconId;
  final String repeatJson;
  final String timeJson;
  final String? courseStart;
  final String? courseEnd;
  final int? courseTotalDays;
  final TaskStatus status;
  final bool reminderEnabled;
  final int sortOrder;
  final String? rulesEffectiveFrom;
  final int createdAtMs;
  final int updatedAtMs;
  final int? deletedAtMs;

  Map<String, Object?> toWire() => {
    'id': id,
    'memberId': memberId,
    'name': name,
    'note': note,
    'iconId': iconId,
    'repeatJson': repeatJson,
    'timeJson': timeJson,
    'courseStart': courseStart,
    'courseEnd': courseEnd,
    'courseTotalDays': courseTotalDays,
    'status': status.name,
    'reminderEnabled': reminderEnabled,
    'sortOrder': sortOrder,
    'rulesEffectiveFrom': rulesEffectiveFrom,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'deletedAtMs': deletedAtMs,
  };
}

/// 一条打卡在协议里的样子。
///
/// **`id` 不在协议里**。打卡的身份是 `(taskId, date, slotIndex)`，
/// 各端自己生成的 UUID 只是本地主键。把这个 id 传出去，服务端就会
/// 按 id 而不是按三元组合并 —— 两个人各点一次就变成两条记录，
/// 日历和统计都算两遍。
final class CheckinDto {
  const CheckinDto({
    required this.taskId,
    required this.date,
    required this.slotIndex,
    required this.state,
    required this.updatedAtMs,
    this.doneAtMs,
    this.dueAtMinuteOfDay,
    this.note,
    this.deleted = false,
  });

  factory CheckinDto.fromWire(Map<String, Object?> j) {
    final stateRaw = _string(j['state'], 'checkin.state', max: 20);
    final state = checkinStateFromDb(stateRaw);
    if (state == null) {
      // **绝不猜成 done**。猜错等于凭空造出"已完成"，统计数字从此不可信，
      // 而"可信"是这个产品的全部价值。
      _fail('checkin.state', '不认识的打卡状态：$stateRaw');
    }
    return CheckinDto(
      taskId: _string(j['task_id'], 'checkin.task_id', max: 64),
      date: _string(j['date'], 'checkin.date', max: 10),
      slotIndex: _int(j['slot_index'], 'checkin.slot_index'),
      state: state,
      doneAtMs: _intOrNull(j['done_at_ms'], 'checkin.done_at_ms'),
      dueAtMinuteOfDay: _intOrNull(
        j['due_at_minute_of_day'],
        'checkin.due_at_minute_of_day',
      ),
      note: _stringOrNull(j['note'], 'checkin.note'),
      updatedAtMs: _int(j['updated_at_ms'], 'checkin.updated_at_ms'),
      deleted: (j['deleted'] is int ? j['deleted'] == 1 : j['deleted'] == true),
    );
  }

  final String taskId;
  final String date;
  final int slotIndex;
  final CheckinState state;
  final int? doneAtMs;
  final int? dueAtMinuteOfDay;
  final String? note;
  final int updatedAtMs;

  /// 服务端墓碑。**永不推给服务端**（推的是全量当前状态，本地没有就是删了）。
  final bool deleted;

  /// 三元组键，用于本机比对"这条我有吗"。
  String get key => '$taskId\u0000$date\u0000$slotIndex';

  Map<String, Object?> toWire() => {
    'taskId': taskId,
    'date': date,
    'slotIndex': slotIndex,
    'state': state.dbValue,
    'doneAtMs': doneAtMs,
    'dueAtMinuteOfDay': dueAtMinuteOfDay,
    'note': note,
    'updatedAtMs': updatedAtMs,
  };

  /// 从本地 domain 记录造 DTO。
  ///
  /// `photoPath` **不搬**：照片只存本机（架构文档 §4）。
  factory CheckinDto.fromDomain(domain.CheckinRecord c, {int? updatedAtMs}) =>
      CheckinDto(
        taskId: c.taskId,
        date: c.date.toString(),
        slotIndex: c.slotIndex,
        state: c.state,
        doneAtMs: c.doneAtMs,
        dueAtMinuteOfDay: c.dueAtMinuteOfDay,
        note: c.note,
        // 打卡表没有 updated_at_ms 列（created_at_ms 每次写入都被覆盖）。
        // 用 doneAtMs 兜底；空的话用 0，服务端会按"更旧"处理。
        updatedAtMs: updatedAtMs ?? c.doneAtMs ?? 0,
      );

  /// 日期字面量 → LocalDate。格式不对直接抛（**不用 tryParse 静默跳过**）。
  LocalDate dateValue() {
    final parts = date.split('-');
    if (parts.length != 3) {
      _fail('checkin.date', '日期格式不对：$date');
    }
    return LocalDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}

/// 一条设置。
final class SettingDto {
  const SettingDto({
    required this.key,
    required this.value,
    required this.updatedAtMs,
  });

  factory SettingDto.fromWire(Map<String, Object?> j) => SettingDto(
    key: _string(j['key'], 'setting.key', max: 60),
    value: _string(j['value'], 'setting.value', max: 200),
    updatedAtMs: _int(j['updated_at_ms'], 'setting.updated_at_ms'),
  );

  final String key;
  final String value;
  final int updatedAtMs;

  Map<String, Object?> toWire() => {
    'key': key,
    'value': value,
    'updatedAtMs': updatedAtMs,
  };
}

/// 参与同步的设置键白名单。
///
/// 只放"两台设备应当一致"的东西。设备本地的东西（比如 `sync.*` 自己、
/// 上次重排时刻）绝不能进这个表 —— 那会让两台手机互相覆盖对方的状态。
const Set<String> syncedSettingKeys = {
  'reminders.enabled',
  'reminders.quietStart',
  'reminders.quietEnd',
  'reminders.followupMinutes',
  'reminders.followupEnabled',
  'ui.layout',
};

/// 一次同步请求的内容。
final class SyncRequest {
  const SyncRequest({
    required this.since,
    this.members = const [],
    this.tasks = const [],
    this.checkins,
    this.removedCheckins = const [],
    this.settings = const [],
  });

  final int since;
  final List<MemberDto> members;
  final List<TaskDto> tasks;

  /// 本地**现在有**的打卡。
  ///
  /// `null` = "这次只来拉数据，别动服务端的打卡"（冷启动、回前台那一次）。
  /// 非 null = "这就是我这边全部的打卡"；服务端据此做墓碑判断。
  final List<CheckinDto>? checkins;

  /// 本地**明确撤销过**的打卡，`任务id|日期|序号`。
  ///
  /// 为什么不能只靠"我推的全量里没有它"：那会把"从来没有"也当成"撤销"。
  /// 第二台手机刚配对进来时本地是空库，只推 `checkins: []`，服务端会把
  /// 全家人的打卡全判成撤销 —— 端到端接真服务时抓到的就是这个。
  ///
  /// 服务端只对**这里列出的**打卡做墓碑判断（协议 §4.3）。空数组表示
  /// "我这次没有要撤销的"，不是"我要撤销全部"。
  final List<String> removedCheckins;

  final List<SettingDto> settings;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{'since': since};
    // 只推"我确实有话说"的类别：空数组也推，表示"我这一类真的没有"。
    // 但 checkins 为 null 时**整个字段都不写**。
    map['members'] = [for (final m in members) m.toWire()];
    map['tasks'] = [for (final t in tasks) t.toWire()];
    final c = checkins;
    if (c != null) {
      map['checkins'] = [for (final x in c) x.toWire()];
      // 撤销声明和 checkins **同时出现**：服务端只有在能对比"你推了什么"
      // 和"你声明删了什么"时才知道该保留哪条。只发撤销不发全量，
      // 服务端没法判断对端是不是已经改了这条。
      map['removedCheckins'] = removedCheckins;
    }
    map['settings'] = [for (final s in settings) s.toWire()];
    return map;
  }

  String encode() => jsonEncode(toJson());
}

/// 一条被服务端拒绝的推送。
final class SyncReject {
  const SyncReject({
    required this.kind,
    required this.id,
    required this.reason,
  });

  factory SyncReject.fromWire(Map<String, Object?> j) => SyncReject(
    kind: _string(j['kind'], 'reject.kind', max: 20),
    id: j['id'] == null ? null : '${j['id']}',
    reason: _string(j['reason'], 'reject.reason', max: 300),
  );

  final String kind;
  final String? id;
  final String reason;

  @override
  String toString() => '$kind/${id ?? '?'}: $reason';
}

/// 一次同步的响应。
final class SyncResponse {
  const SyncResponse({
    required this.cursor,
    required this.writeHighWater,
    required this.sinceReset,
    required this.members,
    required this.tasks,
    required this.checkins,
    required this.settings,
    required this.rejected,
    required this.tombstoned,
  });

  factory SyncResponse.fromJson(Map<String, Object?> j) {
    if (j['ok'] != true) {
      _fail('response', 'ok 不为 true：${j['error']}');
    }
    final pulled = j['pulled'];
    if (pulled is! Map) {
      _fail('response.pulled', '缺 pulled');
    }
    List<T> parseList<T>(
      String key,
      T Function(Map<String, Object?> row) parse,
    ) {
      final raw = pulled[key];
      if (raw is! List) {
        _fail('response.pulled.$key', '不是数组');
      }
      return [
        for (final (i, row) in raw.indexed)
          if (row is Map)
            parse(row.cast<String, Object?>())
          else
            _fail('response.pulled.$key[$i]', '不是对象'),
      ];
    }

    final rejects = j['rejected'];
    return SyncResponse(
      cursor: _int(j['cursor'], 'response.cursor', fallback: 0),
      writeHighWater: _int(
        j['writeHighWater'],
        'response.writeHighWater',
        fallback: 0,
      ),
      sinceReset: j['sinceReset'] == true,
      members: parseList('members', MemberDto.fromWire),
      tasks: parseList('tasks', TaskDto.fromWire),
      checkins: parseList('checkins', CheckinDto.fromWire),
      settings: parseList('settings', SettingDto.fromWire),
      rejected: rejects is List
          ? [
              for (final r in rejects)
                if (r is Map) SyncReject.fromWire(r.cast<String, Object?>()),
            ]
          : const [],
      tombstoned: _int(j['tombstoned'], 'response.tombstoned', fallback: 0),
    );
  }

  /// 拉取水位：客户端下次的 `since`。
  final int cursor;

  /// 本批写入的最高 `server_at_ms`；没写任何东西时 0。
  /// 只用于判断"我这条到底写进去没有"。
  final int writeHighWater;

  /// `true` = 客户端的 `since` 比服务端还新（换机/时钟回拨），下次从 0 全量拉。
  final bool sinceReset;

  final List<MemberDto> members;
  final List<TaskDto> tasks;
  final List<CheckinDto> checkins;
  final List<SettingDto> settings;
  final List<SyncReject> rejected;
  final int tombstoned;

  /// 有内容需要落库吗？（用来决定"要不要重排 + 叫醒界面"）
  bool get hasWrites =>
      members.isNotEmpty ||
      tasks.isNotEmpty ||
      checkins.isNotEmpty ||
      settings.isNotEmpty;
}

/// 配对结果。
final class PairClaimResult {
  const PairClaimResult({
    required this.token,
    required this.deviceId,
    required this.familyId,
  });

  factory PairClaimResult.fromJson(Map<String, Object?> j) => PairClaimResult(
    token: _string(j['token'], 'pair.token', max: 200),
    deviceId: _string(j['deviceId'], 'pair.deviceId', max: 64),
    familyId: _string(j['familyId'], 'pair.familyId', max: 64),
  );

  final String token;
  final String deviceId;
  final String familyId;
}

/// 配对前预览：**只有成员名**。
final class PairPreview {
  const PairPreview({
    required this.familyName,
    required this.memberNames,
    required this.expiresAtMs,
  });

  factory PairPreview.fromJson(Map<String, Object?> j) {
    final raw = j['members'];
    return PairPreview(
      familyName: _string(j['familyName'], 'preview.familyName', max: 60),
      memberNames: raw is List
          ? [
              for (final m in raw)
                if (m is Map && m['name'] is String) m['name']! as String,
            ]
          : const [],
      expiresAtMs: _int(j['expiresAtMs'], 'preview.expiresAtMs', fallback: 0),
    );
  }

  final String familyName;
  final List<String> memberNames;
  final int expiresAtMs;
}

/// 一次"发打卡链接"的结果。
///
/// [url] 里的 token **只在这一刻存在**（服务端存的是哈希），所以这个对象
/// 的生命周期就是"弹窗打开 → 用户复制/分享 → 关掉"，**不要落库**。
final class MemberLinkResult {
  const MemberLinkResult({required this.url, required this.issuedAtMs});

  /// 完整链接，形如 `https://host/m/<token>`。
  final String url;

  /// 服务端签发时间。用来显示"刚刚生成"，也用来判断这个链接是不是旧的。
  final int issuedAtMs;

  /// 给用户看的短形式：域名 + 省略号。
  ///
  /// 弹窗里直接把整个 URL 摆出来会让老人以为要自己敲一遍；
  /// 真正要用的是"复制"和"分享"两个按钮。
  String get displayHost {
    final parsed = Uri.tryParse(url);
    return parsed?.host ?? url;
  }
}

/// 同步码规范化。
///
/// **`FAM` 前缀只是展示用的装饰，不参与校验。** 真实长度是 12 个字符，
/// 字母表 31 个（去掉会认错的 `0 O 1 I L`）。
///
/// 宽容的是格式：大小写、空格、连字符、换行都接受。
/// 严格的是判定：不做"把 0 当 O"这种智能纠错 —— 那会把两个不同的码
/// 纠成同一个，等于把可猜空间缩小一个数量级。
String? normalizePairCode(String? raw) {
  if (raw == null) {
    return null;
  }
  var body = raw.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
  if (body.startsWith('FAM')) {
    body = body.substring(3);
  }
  if (body.length != 12) {
    return null;
  }
  const alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  for (final ch in body.split('')) {
    if (!alphabet.contains(ch)) {
      return null;
    }
  }
  return 'FAM-${body.substring(0, 4)}-${body.substring(4, 8)}-'
      '${body.substring(8, 12)}';
}
