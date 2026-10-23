/// 历史页的数据装配：某个月的日历底色 + 某一天的明细。
///
/// 跟首页的 `TodayService` 是同一类东西：只回答"这一屏该长什么样"，不做交互。
library;

import 'package:clock/clock.dart';

import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_state.dart';
import '../../domain/model/checkin_row.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/scheduling/scheduler.dart';
import '../../domain/stats/stats.dart';
import '../history/history_calendar.dart';

/// 月历数据集：格子 + 汇总。
final class MonthView {
  const MonthView({required this.grid, required this.now});

  final MonthGrid grid;
  final LocalTime now;

  int get year => grid.year;
  int get month => grid.month;
}

/// 某一天的明细。
final class DayDetail {
  const DayDetail({
    required this.date,
    required this.rows,
    required this.summary,
    required this.editable,
    required this.now,
  });

  final LocalDate date;

  /// 当天全部行（按成员排序、组内按时间正序）。
  final List<CheckinRow> rows;

  final StatsSummary summary;

  /// 是否还能改（30 天内，且不是未来）。
  ///
  /// 超过 30 天只读（需求：补卡窗口 30 天），未来日期也不给"补"——
  /// 未来的事还没发生，谈不上补。
  final bool editable;

  final LocalTime now;

  bool get isEmpty => rows.isEmpty;
}

/// 历史页装配器。
final class HistoryService {
  HistoryService(this._db);

  final AppDatabase _db;

  /// 装配器用的库。历史页要把它递给明细页：明细页得能读到**含已删除**
  /// 的成员表，才画得出"那天是谁做的"。曾经明细页的 `db` 是可空的，
  /// 历史页没传，结果所有分组标题都退化成「不认识的成员」——
  /// 页面不报错，只是名字全没了，测试也全绿（组件测试自己把 db 传了）。
  AppDatabase get db => _db;

  /// 补卡窗口（天）。**从领域层取**，不在这里另写一个 30——
  /// 之前这里独立定义了 30，`loadDay` 却拿它跟 `date.isAfter(today)` 拼，
  /// 结果所有过去的日子都被判成只读。窗口口径只有 `EditWindow` 一处。
  static const int editWindowDays = EditWindow.editableDays;

  /// 读某个月的日历。
  Future<MonthView> loadMonth({
    required int year,
    required int month,
    DateTime? at,
  }) async {
    final moment = at ?? clock.now();
    final today = LocalDate.fromDateTime(moment);
    final first = LocalDate(year, month, 1);
    final last = first.lastDayOfMonth;

    // 只查"这个月"的槽位与记录。补白那几天（上月末尾/下月初）不查——
    // 它们只画淡数字，涂色会让人误以为那是本月的数据。
    final slots = await _db.slotsBetween(first, last);
    final records = await _db.checkinsBetween(first, last);

    final bySlot = <String, CheckinState>{
      for (final r in records) '${r.taskId}|${r.date}|${r.slotIndex}': r.state,
    };

    final entries = <StatsEntry>[
      for (final s in slots)
        StatsEntry(
          s.date,
          bySlot['${s.taskId}|${s.date}|${s.slotIndex}'],
        ),
    ];

    final byDay = Stats.byDay(entries, from: first, to: last);

    return MonthView(
      grid: HistoryCalendar.buildMonth(
        year: year,
        month: month,
        byDay: byDay,
        today: today,
      ),
      now: LocalTime(moment.hour, moment.minute),
    );
  }

  /// 读某一天的明细。
  Future<DayDetail> loadDay(LocalDate date, {DateTime? at}) async {
    final moment = at ?? clock.now();
    final today = LocalDate.fromDateTime(moment);
    final nowTime = LocalTime(moment.hour, moment.minute);

    final members = await _db.listMembers();
    final memberOrder = {for (var i = 0; i < members.length; i++) members[i].id: i};
    final taskMap = {for (final t in await _db.listAllTasks()) t.id: t};

    // 只要当天的槽位。跨午夜到次日的那些（宵夜后 4 小时的药）
    // 在首页已经按 dueAt.date 剔除，这里保持同样的口径：
    // 历史是"那天该做什么"，与"提醒落在哪天"无关。
    final slots = (await _db.slotsBetween(date, date))
        .where((s) => s.dueDate.isSameDay(date))
        .toList();
    final records = await _db.checkinsBetween(date, date);
    final bySlot = <String, CheckinRecord>{
      for (final r in records) '${r.taskId}|${r.slotIndex}': r,
    };

    final rows = <CheckinRow>[];
    for (final s in slots) {
      final task = taskMap[s.taskId];
      if (task == null) {
        // 项目被硬删除后残留的槽位不该画出来（软删除的项目还留着，能看到）。
        continue;
      }
      final due = LocalDateTimeRef(s.dueDate, s.dueTime);
      rows.add(
        CheckinRow(
          task: task,
          date: s.date,
          slotIndex: s.slotIndex,
          dueAt: due,
          dueMinuteOfDay: s.dueTime.minuteOfDay,
          record: bySlot['${s.taskId}|${s.slotIndex}'],
        ),
      );
    }

    // 有记录但没槽位的"孤儿"也必须列出来。
    //
    // 槽位是调度器算出来的产物，会重排、会清理；而记录是用户真做过的事。
    // 两者对不上的情况真实存在：新建完项目立刻打卡、但重排还没跑完，
    // 那天就没有对应槽位——旧代码只遍历槽位，于是这条打卡**凭空消失**，
    // 用户看到的就是"历史里查不到我刚打的卡"。
    //
    // 项目被硬删除时连记录一起没了（外键级联），所以这里能查到的 task
    // 一定还在，画出来都是该给人看的。
    final filled = {for (final r in rows) '${r.task.id}|${r.slotIndex}'};
    for (final record in records) {
      final key = '${record.taskId}|${record.slotIndex}';
      if (filled.contains(key)) {
        continue;
      }
      final task = taskMap[record.taskId];
      if (task == null) {
        continue;
      }
      // 应做时刻优先取记录里存的那份（打卡当时的真实规则），
      // 没有就退回 0 点——排序会把它排在最前，总比丢掉强。
      final minute = record.dueAtMinuteOfDay ?? 0;
      rows.add(
        CheckinRow(
          task: task,
          date: date,
          slotIndex: record.slotIndex,
          dueAt: LocalDateTimeRef(date, LocalTime.fromMinuteOfDay(minute)),
          dueMinuteOfDay: minute,
          record: record,
        ),
      );
    }

    // 先按成员顺序，再按时间——照着"谁、几点"读下来最顺。
    rows.sort((a, b) {
      final ma = memberOrder[a.task.memberId] ?? 1 << 20;
      final mb = memberOrder[b.task.memberId] ?? 1 << 20;
      if (ma != mb) {
        return ma.compareTo(mb);
      }
      return a.dueMinuteOfDay.compareTo(b.dueMinuteOfDay);
    });

    final summary = Stats.summarize([
      for (final r in rows) StatsEntry(r.date, r.record?.state),
    ]);

    final editable = EditWindow.canEdit(date, today);

    return DayDetail(
      date: date,
      rows: rows,
      summary: summary,
      editable: editable,
      now: nowTime,
    );
  }

  /// 撤销某一笔（回到未记录）。
  ///
  /// 30 天窗口由 `AppDatabase.clearCheckin` 判定，这里只把 bool 结果
  /// 往上抛给页面——窗口口径只有一处定义，不在 UI 里再算一遍。
  Future<bool> undo({required CheckinRow row, required LocalDate today}) {
    return _db.clearCheckin(
      taskId: row.task.id,
      date: row.date,
      slotIndex: row.slotIndex,
      today: today,
      nowMs: clock.now().millisecondsSinceEpoch,
    );
  }

  /// 某天各成员的完成情况（明细页顶部的分组用）。
  static Map<String, List<CheckinRow>> groupByMember(List<CheckinRow> rows) {
    final out = <String, List<CheckinRow>>{};
    for (final r in rows) {
      out.putIfAbsent(r.task.memberId, () => []).add(r);
    }
    return out;
  }

  /// 补卡窗口外只读时给一句人话。
  static String readOnlyHint(LocalDate date, LocalDate today) {
    if (date.isAfter(today)) {
      return '还没到的日子';
    }
    return '超过 $editWindowDays 天，只能看不能改';
  }
}
