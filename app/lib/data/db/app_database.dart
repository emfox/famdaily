import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

// 转换器列（courseStart / date / dueTime…）在生成的 .g.dart（part）里
// 直接引用 LocalDate / LocalTime 类型名，所以这两个**不能**加前缀，
// 否则 part 文件里 'LocalDate' isn't a type。
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
// 其余领域类型与生成的行类撞名，用前缀区分开。
import '../../domain/model/checkin.dart' as domain;
import '../../domain/model/checkin_state.dart' as domain;
import '../../domain/model/member.dart' as domain;
import '../../domain/model/task.dart' as domain;
import '../../domain/model/task_status.dart' as domain;
import 'mappers.dart';
import 'tables.dart';

part 'app_database.g.dart';

// 生成的行类名与领域模型撞名（Member / Task / Checkin / Slot），
// 数据库层对外的接口一律用领域模型，所以把行类前缀掉。
typedef MemberRow = Member;
typedef TaskRow = Task;
typedef CheckinRecordRow = Checkin;
typedef SlotRow = Slot;

/// Famdaily 的本地数据库。
///
/// 设计要点（tech-stack §6）：
/// - 主键一律 UUID 字符串，不用自增 int（P3 多端同步时自增会撞）
/// - 打记录 `(taskId, date, slotIndex)` 唯一，保证幂等
/// - `change_log` 从第一天就写，P3 才不用补历史
@DriftDatabase(
  tables: [Members, Tasks, Checkins, Slots, Settings, ChangeLogs],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// 测试用：内存库。
  AppDatabase.forTesting(super.executor);

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    ...super.allSchemaEntities,
    ..._indexes,
  ];

  /// 索引声明成漂移的 schema 实体，而不是裸 `customStatement`。
  ///
  /// 裸 SQL 在运行时一样能建，但**导出的 schema 快照里没有它**——
  /// 迁移工具就会以为"这一版没有索引"，跨版本迁移测试等于白测。
  static final _indexes = <Index>[
    // 打卡幂等：同一次打卡重复写入不会变成两条
    Index(
      'idx_checkins_slot',
      'CREATE UNIQUE INDEX idx_checkins_slot '
      'ON checkins (task_id, date, slot_index)',
    ),
    // 日历按日查
    Index('idx_checkins_date', 'CREATE INDEX idx_checkins_date ON checkins (date)'),
    // 今日清单按项目查
    Index('idx_checkins_task', 'CREATE INDEX idx_checkins_task ON checkins (task_id)'),
    // 排程窗口按触发日查
    Index('idx_slots_due', 'CREATE INDEX idx_slots_due ON slots (due_date, due_time)'),
    // 软删除过滤
    Index('idx_tasks_member', 'CREATE INDEX idx_tasks_member ON tasks (member_id)'),
  ];

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      // 索引已经声明在 _indexes 里，createAll 会一并建出来。
      await m.createAll();
    },
    beforeOpen: (details) async {
      // 外键约束必须显式打开，SQLite 默认是关的——关着的话
      // "删成员时还有项目引用"这种错误会静默通过。
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );



  // ---------------------------------------------------------------------
  // 成员
  // ---------------------------------------------------------------------

  /// 未删除的成员，按排序。
  Future<List<domain.Member>> listMembers() async {
    final rows = await (select(members)
          ..where((t) => t.deletedAtMs.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
    return rows.map<domain.Member>(Mappers.memberFromRow).toList();
  }

  Future<domain.Member?> findMember(String id) async {
    final row = await (select(members)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : Mappers.memberFromRow(row);
  }

  /// 新增成员，排序自动追加到末尾。
  Future<void> insertMember(domain.Member m, {required int nowMs}) async {
    await transaction(() async {
      // 用 ORDER BY ... LIMIT 1 取当前最大值：`max()` 是聚合表达式，
      // 单独 getSingleOrNull 拿不到值（会退化成全表聚合的一行）。
      final last = await (select(members)
            ..orderBy([(t) => OrderingTerm(expression: t.sortOrder, mode: OrderingMode.desc)])
            ..limit(1))
          .getSingleOrNull();
      final nextSort = (last?.sortOrder ?? -1) + 1;
      await into(members).insert(
        Mappers.memberToCompanion(m).copyWith(sortOrder: Value(nextSort)),
      );
      await _log('member', m.id, 'upsert', nowMs);
    });
  }

  Future<void> updateMember(domain.Member m, {required int nowMs}) async {
    await transaction(() async {
      await (update(members)..where((t) => t.id.equals(m.id)))
          .write(Mappers.memberToCompanion(m).copyWith(
            updatedAtMs: Value(nowMs),
          ));
      await _log('member', m.id, 'upsert', nowMs);
    });
  }

  /// 软删除：历史打卡记录仍然挂在 member_id 上，日历翻得回去。
  Future<void> deleteMember(String id, {required int nowMs}) async {
    await transaction(() async {
      await (update(members)..where((t) => t.id.equals(id)))
          .write(Mappers.softDeleteMember(id, nowMs));
      await _log('member', id, 'delete', nowMs);
    });
  }

  /// 拖拽排序：按传入的 id 顺序重写 sortOrder。
  Future<void> reorderMembers(List<String> orderedIds, {required int nowMs}) async {
    await transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (update(members)..where((t) => t.id.equals(orderedIds[i])))
            .write(MembersCompanion(sortOrder: Value(i), updatedAtMs: Value(nowMs)));
      }
      await _log('member', 'reorder', 'upsert', nowMs);
    });
  }

  // ---------------------------------------------------------------------
  // 项目
  // ---------------------------------------------------------------------

  /// 某成员下未删除的项目。
  Future<List<domain.Task>> listTasksOfMember(String memberId) async {
    final rows = await (select(tasks)
          ..where((t) => t.memberId.equals(memberId) & t.deletedAtMs.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAtMs),
          ]))
        .get();
    return rows.map<domain.Task>(Mappers.taskFromRow).toList();
  }

  /// 所有未删除的项目（今日清单要跨成员取）。
  Future<List<domain.Task>> listAllTasks() async {
    final rows = await (select(tasks)
          ..where((t) => t.deletedAtMs.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAtMs),
          ]))
        .get();
    return rows.map<domain.Task>(Mappers.taskFromRow).toList();
  }

  Stream<List<domain.Task>> watchAllTasks() {
    return (select(tasks)
          ..where((t) => t.deletedAtMs.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .watch()
        .map((rows) => rows.map<domain.Task>(Mappers.taskFromRow).toList());
  }

  Future<domain.Task?> findTask(String id) async {
    final row =
        await (select(tasks)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : Mappers.taskFromRow(row);
  }

  Future<void> insertTask(domain.Task t, {required int nowMs}) async {
    await transaction(() async {
      await into(tasks).insert(Mappers.taskToCompanion(t));
      await _log('task', t.id, 'upsert', nowMs);
    });
  }

  /// 编辑项目。
  ///
  /// 若时间规则变了，**不覆盖历史**（需求 3.2.1「改规则不影响历史」）：
  /// 旧行保留原规则并标记到 `archiveRulesBefore` 为止，
  /// 新规则从 `effectiveFrom` 起生效。P1 先只更新当前行并把生效日设为今天，
  /// 真正的封存逻辑与"规则历史表"在 P2 做——这一版把生效日字段留出来。
  Future<void> updateTask(
    domain.Task t, {
    required int nowMs,
    LocalDate? rulesEffectiveFrom,
  }) async {
    await transaction(() async {
      await (update(tasks)..where((x) => x.id.equals(t.id))).write(
        Mappers.taskToCompanion(t).copyWith(
          updatedAtMs: Value(nowMs),
          rulesEffectiveFrom: Value(rulesEffectiveFrom),
        ),
      );
      await _log('task', t.id, 'upsert', nowMs);
    });
  }

  Future<void> setTaskStatus(
    String id,
    domain.TaskStatus status, {
    required int nowMs,
  }) async {
    await transaction(() async {
      await (update(tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          status: Value(RuleCodec.statusToDb(status)),
          updatedAtMs: Value(nowMs),
        ),
      );
      await _log('task', id, 'upsert', nowMs);
    });
  }

  Future<void> deleteTask(String id, {required int nowMs}) async {
    await transaction(() async {
      await (update(tasks)..where((t) => t.id.equals(id)))
          .write(Mappers.softDeleteTask(id, nowMs));
      // 待办槽位是派生数据，删项目时直接清掉（打卡记录保留）
      await (delete(slots)..where((s) => s.taskId.equals(id))).go();
      await _log('task', id, 'delete', nowMs);
    });
  }

  // ---------------------------------------------------------------------
  // 打卡记录
  // ---------------------------------------------------------------------

  Future<List<domain.CheckinRecord>> checkinsOn(LocalDate date) async {
    final rows = await (select(checkins)
          ..where((t) => t.date.equals(date.toString())))
        .get();
    return rows.map<domain.CheckinRecord>(Mappers.checkinFromRow).toList();
  }

  Future<List<domain.CheckinRecord>> checkinsBetween(
    LocalDate from,
    LocalDate to,
  ) async {
    final rows = await (select(checkins)
          ..where(
            (t) => t.date.isBiggerOrEqualValue(from.toString()) &
                t.date.isSmallerOrEqualValue(to.toString()),
          ))
        .get();
    return rows.map<domain.CheckinRecord>(Mappers.checkinFromRow).toList();
  }

  Stream<List<domain.CheckinRecord>> watchCheckinsOn(LocalDate date) {
    return (select(checkins)..where((t) => t.date.equals(date.toString())))
        .watch()
        .map((rows) => rows.map<domain.CheckinRecord>(Mappers.checkinFromRow).toList());
  }

  /// 写入打卡（幂等）。
  ///
  /// 冲突策略（架构文档 §3）：**已完成优先**。
  /// 即：已有 done/makeup 时，后来的 skipped 不能把"做过"抹成"没做"；
  /// 反过来 done 可以覆盖 skipped（用户改主意了）。
  Future<void> upsertCheckin(domain.CheckinRecord c, {required int nowMs}) async {
    await transaction(() async {
      final existing = await (select(checkins)
            ..where(
              (t) => t.taskId.equals(c.taskId) &
                  t.date.equals(c.date.toString()) &
                  t.slotIndex.equals(c.slotIndex),
            ))
          .getSingleOrNull();

      if (existing != null) {
        final existingState = RuleCodec.checkinStateFromDb(existing.state);
        final wouldDowngrade =
            existingState != null &&
            existingState.countsAsDone &&
            !c.state.countsAsDone;
        if (wouldDowngrade) {
          // 拒绝把"做过"降级成"没做"，静默忽略并返回。
          return;
        }
        await (update(checkins)..where((t) => t.id.equals(existing.id))).write(
          Mappers.checkinToCompanion(c, nowMs).copyWith(id: Value(existing.id)),
        );
      } else {
        await into(checkins).insert(Mappers.checkinToCompanion(c, nowMs));
      }
      await _log('checkin', c.id, 'upsert', nowMs);
    });
  }

  /// 撤销打卡（回到"未记录"）。只在可编辑窗口内允许。
  Future<bool> clearCheckin({
    required String taskId,
    required LocalDate date,
    required int slotIndex,
    required LocalDate today,
    required int nowMs,
  }) async {
    if (!domain.EditWindow.canEdit(date, today)) {
      return false;
    }
    await transaction(() async {
      final row = await (select(checkins)
            ..where(
              (t) => t.taskId.equals(taskId) &
                  t.date.equals(date.toString()) &
                  t.slotIndex.equals(slotIndex),
            ))
          .getSingleOrNull();
      if (row == null) {
        return;
      }
      await (delete(checkins)..where((t) => t.id.equals(row.id))).go();
      await _log('checkin', row.id, 'delete', nowMs);
    });
    return true;
  }

  // ---------------------------------------------------------------------
  // 排程槽位
  // ---------------------------------------------------------------------

  /// 用新窗口的槽位整体替换旧窗口（幂等重排）。
  Future<void> replaceSlots(
    List<SlotsCompanion> newSlots, {
    required LocalDate from,
    required LocalDate to,
    required int nowMs,
  }) async {
    await transaction(() async {
      await (delete(slots)..where(
            (s) => s.dueDate.isBiggerOrEqualValue(from.toString()) &
                s.dueDate.isSmallerOrEqualValue(to.toString()),
          ))
          .go();
      // 槽位是**派生数据**，不进 change_log——同步时由各端按规则自己重算，
      // 传上去只会制造冲突。
      await batch(
        (b) => b.insertAll(slots, newSlots, mode: InsertMode.insertOrReplace),
      );
    });
  }

  Future<List<SlotRow>> slotsBetween(LocalDate from, LocalDate to) {
    return (select(slots)
          ..where(
            (s) => s.dueDate.isBiggerOrEqualValue(from.toString()) &
                s.dueDate.isSmallerOrEqualValue(to.toString()),
          )
          ..orderBy([
            (s) => OrderingTerm(expression: s.dueDate),
            (s) => OrderingTerm(expression: s.dueTime),
          ]))
        .get();
  }

  /// 靠通知 ID 反查"这条提醒是哪个项目的哪一次"。
  Future<SlotRow?> slotByNotificationId(int notificationId) async {
    return (select(slots)
          ..where(
            (s) =>
                s.remindId.equals(notificationId) |
                s.followupId.equals(notificationId),
          ))
        .getSingleOrNull();
  }

  Future<void> markFollowupSent(
    String taskId,
    LocalDate date,
    int slotIndex,
  ) async {
    await (update(slots)..where(
          (s) => s.taskId.equals(taskId) &
              s.date.equals(date.toString()) &
              s.slotIndex.equals(slotIndex),
        ))
        .write(const SlotsCompanion(followupSent: Value(true)));
  }

  // ---------------------------------------------------------------------
  // 设置
  // ---------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row =
        await (select(settings)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 删掉一个设置键。用于"关掉免打扰"这类要真正删掉而不是写个假值的场合。
  Future<void> clearSetting(String key, {required int nowMs}) async {
    await (delete(settings)..where((t) => t.key.equals(key))).go();
    await _log('setting', key, 'delete', nowMs);
  }

  Future<void> setSetting(String key, String value, {required int nowMs}) async {
    await into(settings).insertOnConflictUpdate(
      SettingsCompanion.insert(
        key: key,
        value: value,
        updatedAtMs: nowMs,
      ),
    );
    await _log('setting', key, 'upsert', nowMs);
  }

  // ---------------------------------------------------------------------
  // 变更日志
  // ---------------------------------------------------------------------

  Future<void> _log(String entity, String entityId, String op, int nowMs) async {
    await into(changeLogs).insert(
      ChangeLogsCompanion.insert(
        entity: entity,
        entityId: entityId,
        op: op,
        changedAtMs: nowMs,
      ),
    );
  }

  Future<int> pendingSyncCount() async {
    final count = changeLogs.id.count();
    final row = await (selectOnly(changeLogs)..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  // ---------------------------------------------------------------------
  // 备份（导出 / 恢复）
  // ---------------------------------------------------------------------

  /// 全量读：成员、项目、记录、设置。
  ///
  /// **包含软删除的行**：备份是"搬家"，不是"清理"。删掉的成员也要带上，
  /// 否则恢复后历史记录会指向一个不存在的 member_id，日历上那些日子就白了。
  Future<BackupSnapshot> readAllForBackup() async {
    final memberRows = await select(members).get();
    final taskRows = await select(tasks).get();
    final checkinRows = await select(checkins).get();
    final settingRows = await select(settings).get();

    return BackupSnapshot(
      members: memberRows.map<domain.Member>(Mappers.memberFromRow).toList(),
      tasks: taskRows.map<domain.Task>(Mappers.taskFromRow).toList(),
      checkins: checkinRows
          .map<domain.CheckinRecord>(Mappers.checkinFromRow)
          .toList(),
      settings: {
        // lastScheduledFor 是本机的排程进度，跟着备份走会让新机"以为今天
        // 已经排过了"从而不排通知。这条不该搬。
        for (final r in settingRows)
          if (r.key != 'reminders.lastScheduledFor') r.key: r.value,
      },
    );
  }

  /// 覆盖式恢复：先清空，再整体写入。
  ///
  /// 全过程在一个事务里：导入到一半失败（比如文件里有个 project 指向
  /// 不存在的 member）会整体回滚，用户的老数据还在。**这是这个功能
  /// 唯一不能出错的地方**——备份恢复失败还把原数据清了，等于双重灾难。
  Future<void> restoreAll(BackupSnapshot data, {required int nowMs}) async {
    await transaction(() async {
      // 顺序受外键约束：先删子表。
      await delete(checkins).go();
      await delete(slots).go();
      await delete(tasks).go();
      await delete(members).go();
      await delete(settings).go();
      await delete(changeLogs).go();

      await batch((b) {
        b.insertAll(
          members,
          [for (final m in data.members) Mappers.memberToCompanion(m)],
          mode: InsertMode.insertOrReplace,
        );
        b.insertAll(
          tasks,
          [for (final t in data.tasks) Mappers.taskToCompanion(t)],
          mode: InsertMode.insertOrReplace,
        );
        b.insertAll(
          checkins,
          [
            for (final c in data.checkins)
              Mappers.checkinToCompanion(c, nowMs),
          ],
          mode: InsertMode.insertOrReplace,
        );
        b.insertAll(
          settings,
          [
            for (final e in data.settings.entries)
              SettingsCompanion.insert(
                key: e.key,
                value: e.value,
                updatedAtMs: nowMs,
              ),
          ],
          mode: InsertMode.insertOrReplace,
        );
      });

      // 恢复之后变更日志是空的——老数据对"同步"来说是全新的，
      // 下次重排会把当前窗口重新算出来（槽位是派生数据，不用恢复）。
      await _log('backup', 'restore', 'upsert', nowMs);
    });
  }

  /// 一键清空（设置页底部的红字入口）。
  ///
  /// 跟恢复的区别：恢复会写回数据，清空之后是真的空。
  Future<void> wipeAll({required int nowMs}) async {
    await restoreAll(
      const BackupSnapshot(members: [], tasks: [], checkins: [], settings: {}),
      nowMs: nowMs,
    );
  }

  /// 库文件里有多少行，用来在导出页显示"备份内容"。
  Future<BackupCounts> counts() async {
    // 三次 count 而不是一条 union：三张表结构不同，硬拼一条 SQL 省不了
    // 多少时间（都是毫秒级），可读性却掉一大截。
    final cols = [members.id.count(), tasks.id.count(), checkins.id.count()];
    final m = await (selectOnly(members)..addColumns([cols[0]])).getSingle();
    final t = await (selectOnly(tasks)..addColumns([cols[1]])).getSingle();
    final c = await (selectOnly(checkins)..addColumns([cols[2]])).getSingle();
    return BackupCounts(
      members: m.read(cols[0]) ?? 0,
      tasks: t.read(cols[1]) ?? 0,
      checkins: c.read(cols[2]) ?? 0,
    );
  }
}

/// 备份的一份快照（与 `BackupData` 的区别：这份是纯数据库视角，
/// 不带格式版本号与时间戳，由上层组装成 `BackupData`）。
final class BackupSnapshot {
  const BackupSnapshot({
    required this.members,
    required this.tasks,
    required this.checkins,
    required this.settings,
  });

  final List<domain.Member> members;
  final List<domain.Task> tasks;
  final List<domain.CheckinRecord> checkins;
  final Map<String, String> settings;

  bool get isEmpty => members.isEmpty && tasks.isEmpty && checkins.isEmpty;
}

/// 导出页要显示的计数。
final class BackupCounts {
  const BackupCounts({
    required this.members,
    required this.tasks,
    required this.checkins,
  });

  final int members;
  final int tasks;
  final int checkins;

  String get label => '$members 位成员 · $tasks 个项目 · $checkins 条记录';
}

/// 真机/模拟器上的数据库连接。
QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'famdaily',
    native: const DriftNativeOptions(shareAcrossIsolates: true),
  );
}

/// 纯 Dart 测试用的内存库（`flutter test` 里不需要模拟器）。
QueryExecutor openTestConnection() {
  return NativeDatabase.memory();
}

/// 桌面调试时指向真实文件的连接（给将来 PC 端 / 调试工具用）。
QueryExecutor openFileConnection(String path) {
  return NativeDatabase(File(path));
}
