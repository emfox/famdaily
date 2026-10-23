/// 今日清单的数据装配：把"项目 + 当天槽位 + 打卡记录"拼成 UI 能直接画的行。
///
/// 这一层刻意不做任何交互，只回答一个问题：**此刻这一页应该长什么样**。
/// 所有排序、分组、进度都由此决定，界面只管画。
library;


import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_row.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/member.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/scheduling/scheduler.dart';
import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../data/db/app_database.dart' as rows show TaskRow;
import '../../data/db/mappers.dart' show Mappers;
import '../../app/test_clock.dart';

/// 首页的两种排法。
enum HomeLayout {
  /// 时间轴：全体成员混排，按时间走。
  timeline,

  /// 成员：按人分组，各自一张卡。
  members,
}

/// 一位成员 + 他今天的行。
final class MemberSection {
  const MemberSection({
    required this.member,
    required this.rows,
    required this.doneCount,
  });

  final Member member;
  final List<CheckinRow> rows;

  /// 已完成（准时或补卡）条数。
  final int doneCount;

  int get totalCount => rows.length;
}

/// 首页的一屏数据。
final class TodayView {
  const TodayView({
    required this.date,
    required this.now,
    required this.overdue,
    required this.done,
    required this.upcoming,
    required this.sections,
    required this.doneCount,
    required this.totalCount,
  });

  static const empty = TodayView(
    date: null,
    now: null,
    overdue: [],
    done: [],
    upcoming: [],
    sections: [],
    doneCount: 0,
    totalCount: 0,
  );

  final LocalDate? date;
  final LocalTime? now;

  /// 时间轴视图的三组。排序规则见 ui-spec §1。
  final List<CheckinRow> overdue;
  final List<CheckinRow> done;
  final List<CheckinRow> upcoming;

  /// 成员视图的分组。
  final List<MemberSection> sections;

  final int doneCount;
  final int totalCount;

  bool get isEmpty => totalCount == 0;

  /// 0..1 的完成比例。
  double get progress => totalCount == 0 ? 0 : doneCount / totalCount;
}

/// 今日清单装配器。
final class TodayService {
  TodayService(this._db);

  final AppDatabase _db;

  /// 读某一天（默认今天）的一屏数据。
  Future<TodayView> load({LocalDate? date, DateTime? at}) async {
    final moment = at ?? appNow();
    final today = date ?? LocalDate.fromDateTime(moment);
    final nowTime = LocalTime(moment.hour, moment.minute);

    final members = await _db.listMembers();
    final memberMap = {for (final m in members) m.id: m};
    final tasks = (await _db.listAllTasks())
        .where((t) => t.isLive && memberMap.containsKey(t.memberId))
        .toList();

    if (tasks.isEmpty) {
      return TodayView(
        date: today,
        now: nowTime,
        overdue: const [],
        done: const [],
        upcoming: const [],
        sections: const [],
        doneCount: 0,
        totalCount: 0,
      );
    }

    // 展平出当天的槽位。这里只展开"这一天"，不是滚动窗口——
    // 首页只需要今天，不必为它算未来两周。
    final specs = [
      for (final t in tasks)
        ScheduleSpec(
          taskId: t.id,
          repeat: t.repeat,
          time: t.time,
          course: t.course,
        ),
    ];
    final expansion = Scheduler.expand(
      specs: specs,
      from: today,
      to: today,
      maxSlots: 500,
    );

    // 槽位可能跨到次日（宵夜后 4 小时的药），那种不算"今天要做的"。
    final slots = expansion.slots
        .where((s) => s.date.isSameDay(s.dueAt.date))
        .toList();

    final records = await _db.checkinsOn(today);
    final byKey = <String, CheckinRecord>{
      for (final r in records) '${r.taskId}|${r.slotIndex}': r,
    };

    final taskMap = {for (final t in tasks) t.id: t};
    final rows = <CheckinRow>[
      for (final s in slots)
        CheckinRow(
          task: taskMap[s.taskId]!,
          date: s.date,
          slotIndex: s.index,
          dueAt: s.dueAt,
          dueMinuteOfDay: s.dueMinuteOfDay,
          record: byKey['${s.taskId}|${s.index}'],
        ),
    ];

    // ---- 时间轴分组（ui-spec §1 排序规则）----
    final overdue = <CheckinRow>[];
    final done = <CheckinRow>[];
    final upcoming = <CheckinRow>[];

    for (final r in rows) {
      switch (r.visual(today, nowTime)) {
        case CheckinVisual.overdue:
          overdue.add(r);
        case CheckinVisual.doneOnTime:
        case CheckinVisual.doneMakeup:
        case CheckinVisual.skipped:
          // 「没做」也算处理过的，归到"已完成"组的下方——
          // 不归到"今天漏了"，因为漏指的是"还没交代"。
          done.add(r);
        case CheckinVisual.pending:
          upcoming.add(r);
      }
    }

    // 超时最久的排最上面。
    overdue.sort(
      (a, b) => b.lateMinutes(nowTime).compareTo(a.lateMinutes(nowTime)),
    );
    // 已完成按时间正序（一天的时间流，别倒着读）。
    done.sort((a, b) => a.dueMinuteOfDay.compareTo(b.dueMinuteOfDay));
    upcoming.sort((a, b) => a.dueMinuteOfDay.compareTo(b.dueMinuteOfDay));

    // ---- 成员分组 ----
    final sections = <MemberSection>[];
    for (final m in members) {
      final mine = rows.where((r) => r.task.memberId == m.id).toList()
        ..sort((a, b) => a.dueMinuteOfDay.compareTo(b.dueMinuteOfDay));
      if (mine.isEmpty) {
        continue;
      }
      sections.add(
        MemberSection(
          member: m,
          rows: mine,
          doneCount: mine
              .where(
                (r) =>
                    r.visual(today, nowTime) == CheckinVisual.doneOnTime ||
                    r.visual(today, nowTime) == CheckinVisual.doneMakeup,
              )
              .length,
        ),
      );
    }

    final doneCount =
        done
            .where(
              (r) =>
                  r.visual(today, nowTime) == CheckinVisual.doneOnTime ||
                  r.visual(today, nowTime) == CheckinVisual.doneMakeup,
            )
            .length;

    return TodayView(
      date: today,
      now: nowTime,
      overdue: overdue,
      done: done,
      upcoming: upcoming,
      sections: sections,
      doneCount: doneCount,
      totalCount: rows.length,
    );
  }

  /// 打卡：写入一条记录并立刻取消该槽位的提醒。
  ///
  /// 「做了什么」由 [state] 表达，**绝不在这里替用户猜**——
  /// 超时的项该显成补卡还是没做，只能由用户在弹层里选（ui-spec §1.2）。
  Future<void> checkIn({
    required CheckinRow row,
    required CheckinRecord record,
    required AppDatabase db,
  }) async {
    final nowMs = appNow().millisecondsSinceEpoch;
    await db.upsertCheckin(record, nowMs: nowMs);
  }

  /// 撤销打卡（回到未记录）。30 天外由 DAO 拒绝。
  Future<bool> undo({
    required CheckinRow row,
    required LocalDate today,
  }) async {
    return _db.clearCheckin(
      taskId: row.task.id,
      date: row.date,
      slotIndex: row.slotIndex,
      today: today,
      nowMs: appNow().millisecondsSinceEpoch,
    );
  }
}

/// 供 UI 取成员名的快捷方法（避免每处都写空判断）。
String memberNameOf(Task task, Map<String, Member> members) =>
    members[task.memberId]?.name ?? '家人';

/// 项目当前是否算"活着的"（active 且未删）。
bool isTaskLive(Task t) => t.status.isLive && t.deletedAtMs == null;

/// 兼容导出：领域模型的打卡记录类型别名。
typedef Record = CheckinRecord;

/// 把 DAO 行转成领域模型的便捷入口（UI 层不该直接认识 Mappers）。
Future<List<Member>> loadMembers(AppDatabase db) => db.listMembers();

/// 同上，项目。
Future<List<Task>> loadTasks(AppDatabase db) => db.listAllTasks();

/// 同上，某天的记录。
Future<List<CheckinRecord>> loadRecords(AppDatabase db, LocalDate date) =>
    db.checkinsOn(date);

/// 把一个库里读出来的任务转成领域模型（给编辑页回填用）。
Task? taskFromRow(rows.TaskRow? row) =>
    row == null ? null : Mappers.taskFromRow(row);
