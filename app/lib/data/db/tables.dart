import 'package:drift/drift.dart';

import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/repeat_rule.dart';
import '../../domain/model/task_status.dart';
import '../../domain/model/time_rule.dart';

/// SQLite 里存日期的类型转换器：存 `YYYY-MM-DD` 文本。
///
/// 用文本而不是 epochDay 整数，是为了让数据库文件**人可读**——
/// 用户导出备份、或者将来手工排查时能看懂。排序仍正确（ISO 日期字典序 = 时间序）。
class LocalDateConverter extends TypeConverter<LocalDate, String> {
  const LocalDateConverter();

  @override
  LocalDate fromSql(String fromDb) => LocalDate.parse(fromDb);

  @override
  String toSql(LocalDate value) => value.toString();
}

/// 存 `HH:mm` 文本。
class LocalTimeConverter extends TypeConverter<LocalTime, String> {
  const LocalTimeConverter();

  @override
  LocalTime fromSql(String fromDb) => LocalTime.parse(fromDb);

  @override
  String toSql(LocalTime value) => value.toString();
}

/// 成员表。
///
/// 成员是**纯标签**——不是账号、没有密码、不能登录（需求 2）。
class Members extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// 预置头像 id；null = 用名字首字 + 色块兜底。
  TextColumn get avatarId => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  /// 软删除：历史记录要留在日历里，所以不物理删行。
  IntColumn get deletedAtMs => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 打卡项目表。
class Tasks extends Table {
  TextColumn get id => text()();

  TextColumn get memberId =>
      text().references(Members, #id, onDelete: KeyAction.restrict)();

  TextColumn get name => text()();

  /// 事前说明（"白色药片 2 粒"），与打卡时的备注区分开。
  TextColumn get note => text().nullable()();

  /// 图标 id；null = 名字首字色块。
  TextColumn get iconId => text().nullable()();

  // ---- 三层规则中的两个正交维度，各存一段 JSON ----
  //
  // 不把它们摊成列（weekdays、everyNDays、fromTime、toTime……）的原因：
  // 规则种类还会长，摊成列后每加一种规则都要写一次迁移；而 JSON 只需升 schemaVersion。
  TextColumn get repeatJson => text()();
  TextColumn get timeJson => text()();

  // ---- 疗程 ----
  TextColumn get courseStart => text().nullable().map(const LocalDateConverter())();
  TextColumn get courseEnd => text().nullable().map(const LocalDateConverter())();
  IntColumn get courseTotalDays => integer().nullable()();

  /// 规则生效日（含）。null = 从创建起一直有效。
  ///
  /// 改规则时不覆盖旧值，而是"封存旧规则 + 从今天起生效新规则"，
  /// 历史当天仍按旧规则计算（需求 3.2.1「改规则不影响历史」）。
  TextColumn get rulesEffectiveFrom =>
      text().nullable().map(const LocalDateConverter())();

  /// active / paused / archived / deleted 的字符串值。
  TextColumn get status => text().withDefault(const Constant('active'))();

  BoolColumn get reminderEnabled =>
      boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  IntColumn get deletedAtMs => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 打卡记录表。
///
/// 唯一索引 `(taskId, date, slotIndex)` 是幂等的保证：同一次打卡重复写入不会变成两条。
class Checkins extends Table {
  TextColumn get id => text()();

  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.restrict)();

  /// 归属的**疗程日**，不是提醒实际落在哪一天。
  TextColumn get date => text().map(const LocalDateConverter())();

  /// 当天第几次（0 起）。
  IntColumn get slotIndex => integer().withDefault(const Constant(0))();

  /// done / makeup / skipped。
  TextColumn get state => text()();

  /// 提交时刻（毫秒时间戳）。
  IntColumn get doneAtMs => integer().nullable()();

  /// 当时算出的应完成时刻（当天第几分钟，可越界）。
  ///
  /// **冗余存下来**：改规则后不能靠 join 当前规则重算，否则三个月前的记录
  /// 会集体变成"迟到"。这是"改规则不影响历史"的第二个落点。
  IntColumn get dueAtMinuteOfDay => integer().nullable()();

  TextColumn get note => text().nullable()();

  /// 照片相对路径。只存本地，不同步网页（架构文档 §4）。
  TextColumn get photoPath => text().nullable()();

  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 排程槽位表：展开器的落地结果，也是提醒 ID 的反查表。
class Slots extends Table {
  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.restrict)();

  TextColumn get date => text().map(const LocalDateConverter())();

  IntColumn get slotIndex => integer()();

  /// 真实触发时刻（已含跨天偏移）。
  TextColumn get dueDate => text().map(const LocalDateConverter())();
  TextColumn get dueTime => text().map(const LocalTimeConverter())();

  /// 到点提醒的通知 ID；null = 提醒开关关着或还没排。
  IntColumn get remindId => integer().nullable()();

  /// 15 分钟催办的通知 ID；null = 没排（关掉了，或落在免打扰时段）。
  IntColumn get followupId => integer().nullable()();

  /// 是否已发出催办（避免重复催）。
  BoolColumn get followupSent =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {taskId, date, slotIndex};
}

/// 键值设置表。
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// 变更日志：P1 只写不读，P3 同步时才知道"哪些要推上去"。
///
/// 现在就记的理由：几乎零成本，但省掉 P3 时"历史数据怎么补同步"的灾难。
class ChangeLogs extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// member / task / checkin / setting
  TextColumn get entity => text()();

  /// 对应实体主键；slots 这类派生数据不记。
  TextColumn get entityId => text()();

  /// upsert / delete
  TextColumn get op => text()();

  IntColumn get changedAtMs => integer()();

  BoolColumn get synced => boolean().withDefault(const Constant(false))();
}

/// JSON 编解码：规则对象 ⇄ 数据库文本。
///
/// 手写而不是用 freezed + json_serializable，因为 `TimeRule` 是 sealed class 族，
/// 手写 switch 反而更短、更不容易漏分支（漏了编译期就报错）。
abstract final class RuleCodec {
  /// 规则 JSON 的结构版本。将来改结构时靠它做兼容读取。
  static const int version = 1;

  static Map<String, dynamic> encodeRepeat(RepeatRule r) => {
    'v': version,
    'weekdays': r.weekdays?.toList()?..sort(),
    'everyNDays': r.everyNDays,
    'anchor': r.anchor?.toString(),
    'parity': r.parity?.name,
    'monthDays': r.monthDays,
  };

  static RepeatRule decodeRepeat(Map<String, dynamic> m) {
    final weekdays = (m['weekdays'] as List?)?.cast<int>().toSet();
    final parityName = m['parity'] as String?;
    return RepeatRule(
      weekdays: weekdays,
      everyNDays: m['everyNDays'] as int?,
      anchor: m['anchor'] == null
          ? null
          : LocalDate.parse(m['anchor'] as String),
      parity: parityName == null
          ? null
          : ParityFilter.values.firstWhere(
              (p) => p.name == parityName,
              orElse: () => ParityFilter.workdays,
            ),
      monthDays: (m['monthDays'] as List?)?.cast<int>(),
    );
  }

  static Map<String, dynamic> encodeTime(TimeRule t) => switch (t) {
    FixedTimesRule() => {
      'v': version,
      'type': 'fixed',
      'times': t.times.map((e) => e.toString()).toList(),
    },
    MealTimesRule() => {
      'v': version,
      'type': 'meal',
      'anchors': t.anchors.map((e) => e.name).toList(),
      'offset': t.offsetMinutes,
      'overrides': {
        for (final e in t.anchorOverrides.entries)
          e.key.name: e.value.toString(),
      },
    },
    IntervalRule() => {
      'v': version,
      'type': 'interval',
      'every': t.everyMinutes,
      'from': t.from.toString(),
      'to': t.to.toString(),
    },
    CombinedTimeRule() => {
      'v': version,
      'type': 'combined',
      'rules': t.rules.map(encodeTime).toList(),
    },
  };

  static TimeRule decodeTime(Map<String, dynamic> m) {
    return switch (m['type'] as String) {
      'fixed' => FixedTimesRule(
        (m['times'] as List).cast<String>().map(LocalTime.parse).toList(),
      ),
      'meal' => MealTimesRule(
        anchors: (m['anchors'] as List)
            .cast<String>()
            .map(
              (n) => MealAnchor.values.firstWhere(
                (a) => a.name == n,
                orElse: () => MealAnchor.lunch,
              ),
            )
            .toList(),
        offsetMinutes: m['offset'] as int? ?? 0,
        anchorOverrides: (m['overrides'] as Map?)?.map(
          (k, v) => MapEntry(
            MealAnchor.values.firstWhere(
              (a) => a.name == k,
              orElse: () => MealAnchor.lunch,
            ),
            LocalTime.parse(v as String),
          ),
        ),
      ),
      'interval' => IntervalRule(
        everyMinutes: m['every'] as int,
        from: LocalTime.parse(m['from'] as String),
        to: LocalTime.parse(m['to'] as String),
      ),
      'combined' => CombinedTimeRule(
        (m['rules'] as List)
            .cast<Map<String, dynamic>>()
            .map(decodeTime)
            .toList(),
      ),
      final other => throw FormatException('未知的时刻规则类型：$other'),
    };
  }

  /// 数据库里的状态字符串 ⇄ 枚举。
  static TaskStatus statusFromDb(String raw) =>
      TaskStatus.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => TaskStatus.active,
      );

  static String statusToDb(TaskStatus s) => s.name;

  /// 打卡状态必须严格解析：未知值不能被当成"已完成"。
  static CheckinState? checkinStateFromDb(String? raw) => switch (raw) {
    'done' => CheckinState.done,
    'makeup' => CheckinState.makeup,
    'skipped' => CheckinState.skipped,
    _ => null,
  };

  static String checkinStateToDb(CheckinState s) => s.dbValue;
}
