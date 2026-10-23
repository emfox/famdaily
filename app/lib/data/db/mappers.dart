import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/model/checkin.dart' as domain;
import '../../domain/model/course.dart' as domain;
import '../../domain/model/member.dart' as domain;
import '../../domain/model/task.dart' as domain;
import '../../domain/model/task_status.dart' as domain;
import 'app_database.dart';
import 'tables.dart';

/// 数据库行 ⇄ 领域模型 的映射。
///
/// 单独一层的好处：领域模型里没有一个 `db` 字段，domain 层可以完全不认识 Drift。
abstract final class Mappers {
  // ---- 读取 ----

  static domain.Member memberFromRow(MemberRow row) => domain.Member(
    id: row.id,
    name: row.name,
    avatarId: row.avatarId,
    sortOrder: row.sortOrder,
    createdAtMs: row.createdAtMs,
    updatedAtMs: row.updatedAtMs,
    deletedAtMs: row.deletedAtMs,
  );

  static domain.Task taskFromRow(TaskRow row) {
    final start = row.courseStart;
    final end = row.courseEnd;
    return domain.Task(
      id: row.id,
      memberId: row.memberId,
      name: row.name,
      note: row.note,
      iconId: row.iconId,
      repeat: RuleCodec.decodeRepeat(_decodeMap(row.repeatJson)),
      time: RuleCodec.decodeTime(_decodeMap(row.timeJson)),
      // courseTotalDays 不进领域模型：Course 已能由起止日推出天数，
      // 它只用于 UI 显示"第 3/7 天"。
      course: start == null && end == null
          ? domain.Course.none
          : domain.Course.fromRange(start, end),
      status: RuleCodec.statusFromDb(row.status),
      reminderEnabled: row.reminderEnabled,
      sortOrder: row.sortOrder,
      createdAtMs: row.createdAtMs,
      updatedAtMs: row.updatedAtMs,
      deletedAtMs: row.deletedAtMs,
    );
  }

  static domain.CheckinRecord checkinFromRow(CheckinRecordRow row) {
    final state = RuleCodec.checkinStateFromDb(row.state);
    if (state == null) {
      // 读不懂就抛出，绝不静默当成 done。
      throw FormatException('打卡记录 ${row.id} 的状态非法：${row.state}');
    }
    return domain.CheckinRecord(
      id: row.id,
      taskId: row.taskId,
      date: row.date,
      slotIndex: row.slotIndex,
      state: state,
      doneAtMs: row.doneAtMs,
      dueAtMinuteOfDay: row.dueAtMinuteOfDay,
      note: row.note,
      photoPath: row.photoPath,
    );
  }

  // ---- 写入 ----

  static MembersCompanion memberToCompanion(domain.Member m) => MembersCompanion(
    id: Value(m.id),
    name: Value(m.name),
    avatarId: Value(m.avatarId),
    sortOrder: Value(m.sortOrder),
    createdAtMs: Value(m.createdAtMs),
    updatedAtMs: Value(m.updatedAtMs),
    deletedAtMs: Value(m.deletedAtMs),
  );

  static TasksCompanion taskToCompanion(domain.Task t) => TasksCompanion(
    id: Value(t.id),
    memberId: Value(t.memberId),
    name: Value(t.name),
    note: Value(t.note),
    iconId: Value(t.iconId),
    repeatJson: Value(jsonEncode(RuleCodec.encodeRepeat(t.repeat))),
    timeJson: Value(jsonEncode(RuleCodec.encodeTime(t.time))),
    courseStart: Value(t.course.start),
    courseEnd: Value(t.course.end),
    courseTotalDays: Value(t.course.totalDays),
    status: Value(RuleCodec.statusToDb(t.status)),
    reminderEnabled: Value(t.reminderEnabled),
    sortOrder: Value(t.sortOrder),
    createdAtMs: Value(t.createdAtMs),
    updatedAtMs: Value(t.updatedAtMs),
    deletedAtMs: Value(t.deletedAtMs),
  );

  static CheckinsCompanion checkinToCompanion(domain.CheckinRecord c, int nowMs) =>
      CheckinsCompanion(
        id: Value(c.id),
        taskId: Value(c.taskId),
        date: Value(c.date),
        slotIndex: Value(c.slotIndex),
        state: Value(RuleCodec.checkinStateToDb(c.state)),
        doneAtMs: Value(c.doneAtMs),
        dueAtMinuteOfDay: Value(c.dueAtMinuteOfDay),
        note: Value(c.note),
        photoPath: Value(c.photoPath),
        createdAtMs: Value(nowMs),
        updatedAtMs: Value(nowMs),
      );

  /// 成员软删除（历史记录保留）。
  static MembersCompanion softDeleteMember(String id, int nowMs) =>
      MembersCompanion(
        deletedAtMs: Value(nowMs),
        updatedAtMs: Value(nowMs),
      );

  /// 项目软删除（日历里仍要看到"那天做过这件事"）。
  static TasksCompanion softDeleteTask(String id, int nowMs) => TasksCompanion(
    status: Value(RuleCodec.statusToDb(domain.TaskStatus.deleted)),
    deletedAtMs: Value(nowMs),
    updatedAtMs: Value(nowMs),
  );

  static Map<String, dynamic> _decodeMap(String raw) =>
      (jsonDecode(raw) as Map).cast<String, dynamic>();
}
