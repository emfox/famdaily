/// 备份文件的格式定义与序列化。
///
/// 这一层**刻意零依赖**（不碰 Flutter、不碰文件系统、不碰数据库）：
/// 备份是"一旦坏了就全没了"的东西，必须能脱离模拟器、脱离真实设备跑穷举测试。
/// 读写文件、打包 zip、调系统分享都在 `backup_io.dart` 里。
///
/// 格式设计的三条硬要求：
/// 1. **人能读**：需求写明"不是加密黑盒"，出问题时用户能自己打开看。
/// 2. **能验**：带 format 版本号与 schema 版本号，导入时先验再动数据。
/// 3. **能部分救**：成员/项目/记录分开存，某一条坏了不至于整包拒收。
library;

import 'dart:convert';

import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_state.dart';
import '../../domain/model/course.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/member.dart';
import '../../domain/model/repeat_rule.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/model/time_rule.dart';

/// 备份文件的顶层结构（`backup.json`）。
///
/// 字段名用 snake_case 并且**不缩写**：这份文件是给人看的。
final class BackupData {
  const BackupData({
    required this.createdAtMs,
    required this.appVersion,
    required this.schemaVersion,
    required this.members,
    required this.tasks,
    required this.checkins,
    required this.settings,
    this.includesPhotos = false,
  });

  /// 当前备份格式版本。加字段不用升（读的时候缺字段就是默认值），
  /// 只有语义变了才升，升了就得在 [fromJson] 里写兼容分支。
  static const int formatVersion = 1;

  /// 文件名前缀，`famdaily-backup-2026-10-23.zip`。
  static const String filePrefix = 'famdaily-backup';

  final int createdAtMs;
  final String appVersion;

  /// 生成备份时的数据库 schemaVersion，用来判断要不要提示"版本较新"。
  final int schemaVersion;

  final List<Member> members;
  final List<Task> tasks;
  final List<CheckinRecord> checkins;
  final Map<String, String> settings;

  /// 是否包含照片目录（含照片时 zip 里多一个 `photos/`）。
  final bool includesPhotos;

  /// 人类可读的一句话摘要，导入预览直接用它。
  String get summary =>
      '${members.length} 位成员 · ${tasks.length} 个项目 · '
      '${checkins.length} 条记录';

  /// 备份时间 `2026-10-23`。
  String get dateLabel {
    final d = LocalDate.fromDateTime(
      DateTime.fromMillisecondsSinceEpoch(createdAtMs),
    );
    return d.toString();
  }

  /// 默认文件名（不带目录）。
  String get suggestedFileName => '$filePrefix-$dateLabel.zip';

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'created_at_ms': createdAtMs,
    'app_version': appVersion,
    'schema_version': schemaVersion,
    'includes_photos': includesPhotos,
    'members': [for (final m in members) BackupCodec.memberToJson(m)],
    'tasks': [for (final t in tasks) BackupCodec.taskToJson(t)],
    'checkins': [for (final c in checkins) BackupCodec.checkinToJson(c)],
    'settings': settings,
  };

  String encode({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  /// 解析。**校验从严**：格式不对直接抛 [BackupFormatException]，
  /// 让调用方在动数据库之前就失败。
  static BackupData fromJson(Map<String, dynamic> json) {
    final version = json['format_version'];
    if (version is! int) {
      throw const BackupFormatException('这不是 Famdaily 的备份文件（缺 format_version）');
    }
    if (version > formatVersion) {
      throw BackupFormatException(
        '这个备份来自更新的版本（格式 $version），当前只认到 $formatVersion。'
        '请先升级 App。',
      );
    }

    return BackupData(
      createdAtMs: _int(json['created_at_ms'], 'created_at_ms'),
      appVersion: json['app_version'] as String? ?? '未知',
      schemaVersion: json['schema_version'] as int? ?? 1,
      includesPhotos: json['includes_photos'] as bool? ?? false,
      members: _list(json['members']).map(BackupCodec.memberFromJson).toList(),
      tasks: _list(json['tasks']).map(BackupCodec.taskFromJson).toList(),
      checkins: _list(
        json['checkins'],
      ).map(BackupCodec.checkinFromJson).toList(),
      settings: switch (json['settings']) {
        final Map<String, dynamic> m => {
          for (final e in m.entries) e.key: '${e.value}',
        },
        _ => {},
      },
    );
  }

  static String encodeText(String raw) => raw;

  static int _int(Object? v, String field) {
    if (v is int) {
      return v;
    }
    throw BackupFormatException('字段 $field 应该是整数，实际是 $v');
  }

  static List<Map<String, dynamic>> _list(Object? v) {
    if (v == null) {
      return const [];
    }
    if (v is! List) {
      throw const BackupFormatException('备份里的列表字段格式不对');
    }
    return [
      for (final e in v)
        if (e is Map<String, dynamic>)
          e
        else
          throw const BackupFormatException('备份里的条目格式不对'),
    ];
  }
}

/// 备份格式不对时抛这个。消息是给人看的，会直接显示在错误提示里。
final class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 各实体的 JSON 编解码。
///
/// 跟 [RuleCodec]（数据库层的规则编解码）**故意分开**：那份是内部存法，
/// 改了不用管旧文件；这份是**对外契约**，一旦有人存过备份就不能随便改字段名。
abstract final class BackupCodec {
  // ---- 成员 ----
  static Map<String, dynamic> memberToJson(Member m) => {
    'id': m.id,
    'name': m.name,
    'avatar_id': m.avatarId,
    'sort_order': m.sortOrder,
    'created_at_ms': m.createdAtMs,
    'updated_at_ms': m.updatedAtMs,
    'deleted_at_ms': m.deletedAtMs,
  };

  static Member memberFromJson(Map<String, dynamic> j) => Member(
    id: _str(j, 'id'),
    name: _str(j, 'name'),
    avatarId: j['avatar_id'] as String?,
    sortOrder: j['sort_order'] as int? ?? 0,
    createdAtMs: j['created_at_ms'] as int? ?? 0,
    updatedAtMs: j['updated_at_ms'] as int? ?? 0,
    deletedAtMs: j['deleted_at_ms'] as int?,
  );

  // ---- 项目 ----
  static Map<String, dynamic> taskToJson(Task t) => {
    'id': t.id,
    'member_id': t.memberId,
    'name': t.name,
    'note': t.note,
    'icon_id': t.iconId,
    'repeat': RuleJson.repeatToJson(t.repeat),
    'time': RuleJson.timeToJson(t.time),
    'course_start': t.course.start?.toString(),
    'course_end': t.course.end?.toString(),
    'course_total_days': t.course.totalDays,
    'status': t.status.name,
    'reminder_enabled': t.reminderEnabled,
    'sort_order': t.sortOrder,
    'created_at_ms': t.createdAtMs,
    'updated_at_ms': t.updatedAtMs,
    'deleted_at_ms': t.deletedAtMs,
  };

  static Task taskFromJson(Map<String, dynamic> j) => Task(
    id: _str(j, 'id'),
    memberId: _str(j, 'member_id'),
    name: _str(j, 'name'),
    note: j['note'] as String?,
    iconId: j['icon_id'] as String?,
    repeat: RuleJson.repeatFromJson(_map(j['repeat'])),
    time: RuleJson.timeFromJson(_map(j['time'])),
    // 用 fromRange 而不是裸构造：它会把"只给了开始没给结束"这种坏数据
    // 挡在门外，而不是造出一个 contains() 会崩的疗程。
    course: Course.fromRange(
      _date(j['course_start']),
      _date(j['course_end']),
    ),
    status: TaskStatus.values.firstWhere(
      (TaskStatus s) => s.name == j['status'],
      orElse: () => TaskStatus.active,
    ),
    reminderEnabled: j['reminder_enabled'] as bool? ?? true,
    sortOrder: j['sort_order'] as int? ?? 0,
    createdAtMs: j['created_at_ms'] as int? ?? 0,
    updatedAtMs: j['updated_at_ms'] as int? ?? 0,
    deletedAtMs: j['deleted_at_ms'] as int?,
  );

  // ---- 打卡记录 ----
  static Map<String, dynamic> checkinToJson(CheckinRecord c) => {
    'id': c.id,
    'task_id': c.taskId,
    'date': c.date.toString(),
    'slot_index': c.slotIndex,
    'state': c.state.dbValue,
    'done_at_ms': c.doneAtMs,
    'due_at_minute_of_day': c.dueAtMinuteOfDay,
    'note': c.note,
    'photo_path': c.photoPath,
  };

  static CheckinRecord checkinFromJson(Map<String, dynamic> j) {
    final state = CheckinState.values.firstWhere(
      (CheckinState s) => s.dbValue == j['state'],
      // 不认识的打卡状态不能瞎猜成 done：那会让"没做"变成"做了"。
      orElse: () => throw BackupFormatException(
        '记录 ${j['id']} 的打卡状态无法识别：${j['state']}',
      ),
    );
    return CheckinRecord(
      id: _str(j, 'id'),
      taskId: _str(j, 'task_id'),
      date: LocalDate.parse(_str(j, 'date')),
      slotIndex: j['slot_index'] as int? ?? 0,
      state: state,
      doneAtMs: j['done_at_ms'] as int?,
      dueAtMinuteOfDay: j['due_at_minute_of_day'] as int?,
      note: j['note'] as String?,
      photoPath: j['photo_path'] as String?,
    );
  }

  // ---- 小工具 ----
  static String _str(Map<String, dynamic> j, String field) {
    final v = j[field];
    if (v is String && v.isNotEmpty) {
      return v;
    }
    throw BackupFormatException('缺字段 $field，或它不是非空字符串');
  }

  static Map<String, dynamic> _map(Object? v) {
    if (v is Map<String, dynamic>) {
      return v;
    }
    throw const BackupFormatException('规则字段格式不对');
  }

  static LocalDate? _date(Object? v) =>
      v is String && v.isNotEmpty ? LocalDate.parse(v) : null;
}

/// 规则对象的 JSON 形状。
///
/// 与数据库里的 `RuleCodec` 保持**同样的键名**，但独立实现一份：
/// 备份文件是长期契约，数据库内部格式随时可能变，两者混用迟早出事。
abstract final class RuleJson {
  static Map<String, dynamic> repeatToJson(RepeatRule r) => {
    'weekdays': r.weekdays?.toList()?..sort(),
    'every_n_days': r.everyNDays,
    'anchor': r.anchor?.toString(),
    'parity': r.parity?.name,
    'month_days': r.monthDays,
  };

  static RepeatRule repeatFromJson(Map<String, dynamic> j) => RepeatRule(
    weekdays: (j['weekdays'] as List?)?.cast<int>().toSet(),
    everyNDays: j['every_n_days'] as int?,
    anchor: j['anchor'] is String ? LocalDate.parse(j['anchor'] as String) : null,
    parity: switch (j['parity']) {
      final String raw => ParityFilter.values.firstWhere(
        (ParityFilter p) => p.name == raw,
        orElse: () => ParityFilter.workdays,
      ),
      _ => null,
    },
    monthDays: (j['month_days'] as List?)?.cast<int>(),
  );

  static Map<String, dynamic> timeToJson(TimeRule t) => switch (t) {
    FixedTimesRule() => {
      'type': 'fixed',
      'times': [for (final e in t.times) e.toString()],
    },
    MealTimesRule() => {
      'type': 'meal',
      'anchors': [for (final e in t.anchors) e.name],
      'offset_minutes': t.offsetMinutes,
      'overrides': {
        for (final e in t.anchorOverrides.entries) e.key.name: e.value.toString(),
      },
    },
    IntervalRule() => {
      'type': 'interval',
      'every_minutes': t.everyMinutes,
      'from': t.from.toString(),
      'to': t.to.toString(),
    },
    CombinedTimeRule() => {
      'type': 'combined',
      'rules': [for (final r in t.rules) timeToJson(r)],
    },
  };

  static TimeRule timeFromJson(Map<String, dynamic> j) {
    return switch (j['type']) {
      'fixed' => FixedTimesRule([
        for (final s in (j['times'] as List? ?? const []).cast<String>())
          LocalTime.parse(s),
      ]),
      'meal' => MealTimesRule(
        anchors: [
          for (final s in (j['anchors'] as List? ?? const []).cast<String>())
            MealAnchor.values.firstWhere(
              (a) => a.name == s,
              orElse: () => MealAnchor.lunch,
            ),
        ],
        offsetMinutes: j['offset_minutes'] as int? ?? 0,
        anchorOverrides: switch (j['overrides']) {
          final Map<String, dynamic> m => {
            for (final e in m.entries)
              MealAnchor.values.firstWhere(
                (a) => a.name == e.key,
                orElse: () => MealAnchor.lunch,
              ): LocalTime.parse('${e.value}'),
          },
          _ => null,
        },
      ),
      'interval' => IntervalRule(
        everyMinutes: j['every_minutes'] as int? ?? 60,
        from: LocalTime.parse(j['from'] as String? ?? '09:00'),
        to: LocalTime.parse(j['to'] as String? ?? '21:00'),
      ),
      'combined' => CombinedTimeRule([
        for (final r in (j['rules'] as List? ?? const []))
          if (r is Map<String, dynamic>) timeFromJson(r),
      ]),
      final other => throw BackupFormatException('无法识别的时刻规则：$other'),
    };
  }
}
