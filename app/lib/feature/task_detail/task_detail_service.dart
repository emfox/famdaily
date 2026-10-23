/// 打卡项详情页的数据装配：项目本身 + 一段时间内的统计 + 最近记录。
///
/// 跟 `HistoryService` / `StatsService` 是一类东西：只回答"这一屏长什么样"，
/// 不做交互、不写库。
library;

import 'package:clock/clock.dart';

import '../../data/db/app_database.dart' hide Member, Task, Checkin, Slot;
import '../../domain/model/checkin.dart';
import '../../domain/model/checkin_state.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/member.dart';
import '../../domain/model/task.dart';
import '../../domain/stats/stats.dart';

/// 最近记录里的一条（按天分组后的一行）。
final class RecordEntry {
  const RecordEntry({
    required this.date,
    required this.dueMinuteOfDay,
    required this.record,
    this.slotIndex = 0,
  });

  final LocalDate date;

  /// 当时算出的应完成时刻（当天第几分钟，可越界跨午夜）。
  final int dueMinuteOfDay;

  /// 记录本身；null = 那天没记（还挂着）。
  final CheckinRecord? record;

  /// 当天第几次（一日多次时用来排序）。
  final int slotIndex;

  CheckinState? get state => record?.state;

  bool get hasPhoto => record?.hasPhoto ?? false;
  String? get note => record?.note;

  /// 打卡时间（`9:12`）；"没做"也记了时间，但显示上没有意义。
  String? get doneAtHm {
    final ms = record?.doneAtMs;
    if (ms == null || record!.state == CheckinState.skipped) {
      return null;
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 补卡时那行小字：「补卡（当天 9:12 记上）」。
  ///
  /// 必须区分"几点应的"和"几点记的"——补卡的全部意义就在这个差值上。
  /// 如果它们是同一天就不写日期，只写钟点。
  String? get makeupNote {
    if (record?.state != CheckinState.makeup) {
      return null;
    }
    final ms = record?.doneAtMs;
    if (ms == null) {
      return '补卡';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final sameDay =
        dt.year == date.year && dt.month == date.month && dt.day == date.day;
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    return sameDay ? '补卡（当天 $hm 记上）' : '补卡（${dt.month}月${dt.day}日 $hm 记上）';
  }
}

/// 一天的一撮记录（详情页"最近记录"按天分组）。
final class RecordDay {
  const RecordDay({required this.date, required this.entries});

  final LocalDate date;

  /// 按应完成时刻正序。
  final List<RecordEntry> entries;

  /// 「10月23日 周三」。今年的不写年份——翻最近记录时年份是噪音。
  String label(LocalDate today) {
    final prefix = date.year == today.year ? '' : '${date.year}年';
    return '$prefix${date.month}月${date.day}日 ${_weekday(date)}';
  }

  static String _weekday(LocalDate d) =>
      const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];
}

/// 详情页整屏。
final class TaskDetail {
  const TaskDetail({
    required this.task,
    required this.member,
    required this.stats,
    required this.days,
    required this.today,
  });

  final Task task;

  /// 归属成员；项目还在但成员被删了时为 null（页面显示"已删除的成员"）。
  final Member? member;

  /// 这段时间的统计（口径与统计页一致：分母是已排出的槽位）。
  final StatsSummary stats;

  /// 最近记录，新的一天在前。
  final List<RecordDay> days;

  final LocalDate today;

  bool get isEmpty => days.isEmpty;

  String get headline => stats.expected == 0
      ? '这段时间没有排过'
      : '共 ${stats.expected} 次该做，做了 ${stats.onTime + stats.makeup} 次';
}

/// 装配器。
final class TaskDetailService {
  TaskDetailService(this._db);

  final AppDatabase _db;

  /// 最近记录最多列多少天。
  ///
  /// 30 天：正好等于补卡窗口，超出的日子本来就改不动了，
  /// 列出来只会让人以为还能改。想看更早的去历史页。
  static const int recentDays = 30;

  /// 读某项的详情。项目不存在（或被硬删）时返回 null。
  Future<TaskDetail?> load(String taskId, {DateTime? at}) async {
    final moment = at ?? clock.now();
    final today = LocalDate.fromDateTime(moment);

    final task = await _db.findTask(taskId);
    if (task == null) {
      return null;
    }
    final member = await _db.findMember(task.memberId);

    final from = today.addDays(-(recentDays - 1));
    final slots = await _db.slotsBetween(from, today);
    final records = await _db.checkinsBetween(from, today);

    final mine = slots
        .where((s) => s.taskId == taskId && !s.dueDate.isAfter(today))
        .toList();
    final bySlot = <String, CheckinRecord>{
      for (final r in records)
        if (r.taskId == taskId) '${r.date.epochDay}|${r.slotIndex}': r,
    };

    // 统计分母 = 这段时间真正排出来的槽位（与统计页同口径），
    // 未来槽位不算——它们还没发生。"排过但没记"的进 unrecorded。
    final summary = Stats.summarize([
      for (final s in mine)
        StatsEntry(s.date, bySlot['${s.date.epochDay}|${s.slotIndex}']?.state),
    ]);

    // 记录里可能有"槽位已被重排掉但记录还在"的（改了时间规则）：
    // 那些人确实做过这件事，不能因为槽位没了就从最近记录里消失。
    final slotKeys = {
      for (final s in mine) '${s.date.epochDay}|${s.slotIndex}',
    };
    final orphans = records.where(
      (r) =>
          r.taskId == taskId &&
          !r.date.isBefore(from) &&
          !slotKeys.contains('${r.date.epochDay}|${r.slotIndex}'),
    );

    final entries =
        <RecordEntry>[
          for (final s in mine)
            RecordEntry(
              date: s.date,
              dueMinuteOfDay: s.dueTime.minuteOfDay,
              slotIndex: s.slotIndex,
              record: bySlot['${s.date.epochDay}|${s.slotIndex}'],
            ),
          for (final r in orphans)
            RecordEntry(
              date: r.date,
              dueMinuteOfDay: r.dueAtMinuteOfDay ?? 0,
              slotIndex: r.slotIndex,
              record: r,
            ),
        ]..sort((a, b) {
          final byDate = b.date.compareTo(a.date);
          if (byDate != 0) {
            return byDate;
          }
          return a.dueMinuteOfDay.compareTo(b.dueMinuteOfDay);
        });

    final days = <RecordDay>[];
    for (final e in entries) {
      if (days.isNotEmpty && days.last.date == e.date) {
        days.last.entries.add(e);
      } else {
        days.add(RecordDay(date: e.date, entries: [e]));
      }
    }

    return TaskDetail(
      task: task,
      // 成员被软删了也要把对象留着。曾经这里是 `isDeleted ? null : member`，
      // 结果界面上只剩一句「已删的成员」——项目是**谁做**的这条信息就没了，
      // 而它恰恰是历史记录里最该留住的东西。头像画不画由界面决定
      // （见 task_detail_page），别在数据层就把人名删掉。
      member: member,
      stats: summary,
      days: days,
      today: today,
    );
  }
}
