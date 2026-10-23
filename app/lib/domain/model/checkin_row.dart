/// 一行展示单元：把"项目 + 当天第几次"和"打卡结果"合成 UI 需要的五态
/// （见 ui-spec 的五态视觉规则表）。
library;

import 'checkin.dart';
import 'checkin_state.dart';
import 'local_date.dart';
import 'local_time.dart';
import 'task.dart';
import '../scheduling/scheduler.dart' show LocalDateTimeRef;

int _floorDiv(int a, int b) => (a / b).floor();

/// 五态（ui-spec）：待做 / 已过时间未做 / 准时 / 补卡 / 没做。
///
/// 记忆口诀：**实心=准时，空心=补，叉=没做，空心待做=还来得及。**
enum CheckinVisual {
  /// 未到时间，还来得及。
  pending,

  /// 已过时间但没打卡，行淡红 + "迟 N 分钟"。
  overdue,

  /// 做了，按时。
  doneOnTime,

  /// 做了，但是补的。
  doneMakeup,

  /// 明确没做（灰、淡化，**不许标红**——标红等于惩罚用户）。
  skipped,
}

/// 今日清单/历史明细里的一行。
final class CheckinRow {
  const CheckinRow({
    required this.task,
    required this.date,
    required this.slotIndex,
    required this.dueAt,
    required this.dueMinuteOfDay,
    this.record,
    this.remindedFollowup = false,
  });

  final Task task;
  final LocalDate date;
  final int slotIndex;

  /// 应完成时刻（可能跨天，见 Slot.dueAt 的说明）。
  final LocalDateTimeRef dueAt;

  /// 未归一化的当天第几分钟（可越界）。
  final int dueMinuteOfDay;

  /// 已有记录；null = 还没打卡。
  final CheckinRecord? record;

  /// 是否已经发过二次催办（避免重复催）。
  final bool remindedFollowup;

  /// 唯一键，与排程槽位一致。
  String get key => '${task.id}|${date.epochDay}|$slotIndex';

  /// 计算五态。
  ///
  /// [today] 用于判断"今天/过去/未来"，[now] 用于判断是否已过时间。
  /// 过去的日子一律算"已过时间"（迟到的分钟数没意义，UI 不展示）。
  CheckinVisual visual(LocalDate today, LocalTime now) {
    final state = record?.state;
    if (state != null) {
      return switch (state) {
        CheckinState.done => CheckinVisual.doneOnTime,
        CheckinState.makeup => CheckinVisual.doneMakeup,
        CheckinState.skipped => CheckinVisual.skipped,
      };
    }
    if (date.isBefore(today)) {
      return CheckinVisual.overdue;
    }
    if (date.isSameDay(today) && now.isAfter(_dueTime())) {
      return CheckinVisual.overdue;
    }
    return CheckinVisual.pending;
  }

  /// 是否可以修改（决策 3：30 天内）。
  bool canEdit(LocalDate today) => EditWindow.canEdit(date, today);

  /// 应完成时刻在本日内的钟点（跨天部分已被吸收，用于展示与迟到计算）。
  ///
  /// 必须用 `_floorDiv` 而不是 `%`：Dart 的 `%` 对负数向零截断。
  LocalTime _dueTime() =>
      LocalTime.fromMinuteOfDay(dueMinuteOfDay - (_floorDiv(dueMinuteOfDay, 1440) * 1440));

  /// 已过应完成时刻多少分钟；未到时间为负。
  int lateMinutes(LocalTime now) => now.minuteOfDay - _dueTime().minuteOfDay;
}
