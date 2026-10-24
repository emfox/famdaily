import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/data/db/tables.dart';
import 'package:famdaily/data/sync/sync_merge.dart';
import 'package:famdaily/data/sync/sync_protocol.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;

/// 把 A 库的一切装成一次 `/sync` 请求，喂给 B 库。
///
/// 这是**测试用的假服务端**：它不做服务端那些判断（内容没变就不写、
/// 水位、墓碑），只负责把一端的行原样递给另一端。所以它测的是
/// 「客户端的合并 + 落库对不对」，不是「服务端对不对」——
/// 后者归 `server/test/sync.test.mjs`。
///
/// 故意写成纯函数而不是类：两个库互推时调用两次，中间不存状态，
/// 也就不会有一个"上次推了什么"的缓存悄悄把结果修正掉。

/// 一端的全部数据。
final class SyncBundle {
  const SyncBundle({
    required this.members,
    required this.tasks,
    required this.checkins,
    required this.settings,
  });

  final List<MemberDto> members;
  final List<TaskDto> tasks;
  final List<CheckinDto> checkins;
  final List<SettingDto> settings;

  bool get isEmpty =>
      members.isEmpty && tasks.isEmpty && checkins.isEmpty && settings.isEmpty;
}

/// 读一个库，装成"要推出去的样子"。
///
/// **包含软删除的行**：删掉的成员/项目必须推出去，否则另一端会一直
/// 拿它当"还活着"，历史记录也指向一个对面不存在的 id。
Future<SyncBundle> bundleOf(AppDatabase db) async {
  final memberRows = await db.select(db.members).get();
  final taskRows = await db.select(db.tasks).get();
  final checkins = await db.listAllCheckins();
  final settings = await db.listSyncedSettings();
  return SyncBundle(
    members: [
      for (final row in memberRows) MemberDto.fromDomain(Mappers.memberFromRow(row)),
    ],
    tasks: [for (final row in taskRows) _taskDto(db, row)],
    checkins: [for (final c in checkins) CheckinDto.fromDomain(c)],
    settings: settings.values.toList(),
  );
}

/// 行 → DTO。
///
/// `repeat_json` / `time_json` 直接搬库里的原文，不走 `RuleCodec` 再编码一遍：
/// 生产路径上推的就是这句原文（`Mappers.taskFromRow` 也只是 `jsonDecode` 它），
/// 在这里多绕一道只会让测试和现实不一致。
///
/// `course_total_days` 同理**从行里读**，不从 `Course` 反推：`Course` 只存
/// 起止日期，"连续 N 天"这个形态（"第 3/7 天"要用）只在这列上。
/// 从 `Course` 反推会得到 null，然后再落库就把天数丢了。
TaskDto _taskDto(AppDatabase db, TaskRow row) {
  final t = Mappers.taskFromRow(row);
  return TaskDto(
    id: t.id,
    memberId: t.memberId,
    name: t.name,
    note: t.note,
    iconId: t.iconId,
    repeatJson: row.repeatJson,
    timeJson: row.timeJson,
    courseStart: t.course.start?.toString(),
    courseEnd: t.course.end?.toString(),
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

/// 把 [bundle] 里每一行合并 / 落库进 [db]。返回"真的写了"的行数。
///
/// 顺序受外键约束：先成员、再项目、最后打卡（打卡引用项目）。
Future<int> applyBundle(
  AppDatabase db,
  SyncBundle bundle, {
  required int nowMs,
  required String Function() newId,
}) async {
  var writes = 0;

  for (final remote in bundle.members) {
    final local = await db.findMember(remote.id);
    if (await db.applyRemoteMember(remote, mergeMember(local, remote))) {
      writes++;
    }
  }

  for (final remote in bundle.tasks) {
    final local = await db.findTask(remote.id);
    final row = await (db.select(db.tasks)
          ..where((t) => t.id.equals(remote.id)))
        .getSingleOrNull();
    final winner = mergeTask(
      local,
      remote,
      localDeleted: row?.deletedAtMs != null,
    );
    if (await db.applyRemoteTask(remote, winner)) {
      writes++;
    }
  }

  // 打卡可能引用一个还没落库的项目（对端删了项目、打卡留着）。外键是
  // `ON DELETE RESTRICT` 而不是 CASCADE，插一条孤儿打卡会直接抛 —— 跳过，
  // 并在返回值里体现"没写"。
  for (final remote in bundle.checkins) {
    final date = remote.dateValue();
    if (await db.findTask(remote.taskId) == null) {
      continue;
    }
    if (shouldDropByTombstone(remote)) {
      if (await db.dropCheckin(
        taskId: remote.taskId,
        date: date,
        slotIndex: remote.slotIndex,
      )) {
        writes++;
      }
      continue;
    }
    final local = await db.findCheckin(
      taskId: remote.taskId,
      date: date,
      slotIndex: remote.slotIndex,
    );
    final merged = mergeCheckin(local, remote);
    if (await db.applyRemoteCheckin(remote, merged, newId, nowMs: nowMs)) {
      writes++;
    }
  }

  for (final remote in bundle.settings) {
    final localAt = await db.settingUpdatedAt(remote.key);
    if (!shouldTakeRemoteSetting(localUpdatedAtMs: localAt, remote: remote)) {
      continue;
    }
    if (await db.applyRemoteSetting(remote)) {
      writes++;
    }
  }

  return writes;
}

/// 把一个库里的四类数据拍平成可以逐行比对的字符串列表。
///
/// 用**字符串**而不是直接比对象：对象要比 `==`，而领域模型没有实现它，
/// 永远判不等；逐字段手写断言又会在加字段时漏掉——加字段的人不一定会
/// 回来改这段。拍平成"库里的真实样子"（含 id、含排序）最不容易骗人。
Future<List<String>> snapshotOf(AppDatabase db) async {
  final members = await db.select(db.members).get()
    ..sort((a, b) => a.id.compareTo(b.id));
  final tasks = await db.select(db.tasks).get()
    ..sort((a, b) => a.id.compareTo(b.id));
  final checkins = await db.select(db.checkins).get()
    ..sort((a, b) => a.taskId.compareTo(b.taskId) != 0
        ? a.taskId.compareTo(b.taskId)
        : (a.date != b.date
              ? a.date.compareTo(b.date)
              : a.slotIndex.compareTo(b.slotIndex)));
  final settings = await db.select(db.settings).get()
    ..sort((a, b) => a.key.compareTo(b.key));

  return [
    for (final r in members)
      'member ${r.id} ${r.name} a=${r.avatarId} s=${r.sortOrder} '
          'c=${r.createdAtMs} u=${r.updatedAtMs} d=${r.deletedAtMs}',
    for (final r in tasks) _taskLine(r),
    for (final r in checkins)
      'checkin ${r.taskId} ${r.date} #${r.slotIndex} ${r.state} '
          'done=${r.doneAtMs} due=${r.dueAtMinuteOfDay} note=${r.note} '
          'photo=${r.photoPath}',
    for (final r in settings) 'setting ${r.key}=${r.value} u=${r.updatedAtMs}',
  ];
}

/// 项目的比较行。
///
/// `repeat_json` / `time_json` **不比原文**，比解码后的规则对象：
/// `{"v":1,"weekdays":[1,2]}` 和 `{"weekdays":[1,2],"v":1}` 语义一样、
/// 字节不同，比原文会让"其实同步对了"被报成两边不一致。
String _taskLine(TaskRow r) {
  final t = Mappers.taskFromRow(r);
  String d(LocalDate? x) => x == null ? '-' : x.toString();
  return 'task ${r.id} m=${t.memberId} ${t.name} note=${t.note} '
      'icon=${t.iconId} repeat=${_rules(t.repeat)} '
      'time=${_timeRules(t.time)} '
      'course=${d(t.course.start)}..${d(t.course.end)} '
      'eff=${r.rulesEffectiveFrom} status=${t.status.name} '
      'rem=${t.reminderEnabled} s=${t.sortOrder} '
      'c=${t.createdAtMs} u=${t.updatedAtMs} d=${t.deletedAtMs}';
}

/// 规则对象的稳定指纹：编码成 map，按 key 排序拼成字符串。
///
/// 用 `RuleCodec` 的两个编码器（与写库路径同一套），所以"能写进库的规则"
/// 一定能被它表达。
String _rules(domain.RepeatRule rule) => _stable(RuleCodec.encodeRepeat(rule));

String _timeRules(domain.TimeRule rule) => _stable(RuleCodec.encodeTime(rule));

String _stable(Map<String, dynamic> json) {
  final keys = json.keys.toList()..sort();
  return '{${keys.map((k) => '$k:${json[k]}').join(',')}}';
}
