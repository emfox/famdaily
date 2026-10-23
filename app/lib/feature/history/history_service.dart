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
