/// 打卡记录与"能不能改"的时间窗口规则（决策 3：回看不限 / 补卡与"没做" 30 天）。
library;

import 'checkin_state.dart';
import 'local_date.dart';

/// 一条打卡记录（对应某项目某天的第 n 次）。
///
/// [dueAtMinuteOfDay] 是**冗余**存下来的当日应完成分钟数——需求 3.2.1
/// "改规则不影响历史"要求它不能靠 join 当前规则重算，否则改一次时间规则，
/// 三个月前的记录会突然集体变成"迟到"。
final class CheckinRecord {
  const CheckinRecord({
    required this.id,
    required this.taskId,
    required this.date,
    required this.slotIndex,
    required this.state,
    this.doneAtMs,
    this.dueAtMinuteOfDay,
    this.note,
    this.photoPath,
  });

  final String id;
  final String taskId;

  /// 归属的**疗程日**（不是提醒实际落在哪一天）。
  final LocalDate date;

  /// 当天第几次（0 起）。
  final int slotIndex;

  final CheckinState state;

  /// 提交时刻（毫秒时间戳）；"没做"也可能有时间（何时点的）。
  final int? doneAtMs;

  /// 当时算出的应完成时刻（当天第几分钟，可越界表示跨午夜）。
  final int? dueAtMinuteOfDay;

  /// 文字备注（可选）。
  final String? note;

  /// 照片相对路径（可选）。只存本地，不同步网页（架构文档 §4）。
  final String? photoPath;

  bool get hasPhoto => photoPath != null && photoPath!.isNotEmpty;
}

/// 时间窗口规则。
///
/// 三个数字来自决策 3：
/// - 日历**回看不限**（不是窗口，是"永远能看"）
/// - 补卡 / "没做" **30 天内**可改
/// - 超过期限：只展示，不可改
abstract final class EditWindow {
  /// 补卡与"没做"可回溯的天数。
  static const int editableDays = 30;

  /// [date] 这一天在 [today] 看来是否还能修改。
  static bool canEdit(LocalDate date, LocalDate today) {
    // 未来日期不能预先打卡（不算补卡，也不允许提前勾）
    if (date.isAfter(today)) {
      return false;
    }
    return today.daysSince(date) <= editableDays;
  }

  /// 是否已经超过可修改期限（用于 UI 置灰 + "超出可修改期限"小字）。
  static bool isExpired(LocalDate date, LocalDate today) =>
      today.daysSince(date) > editableDays;

  /// 距离失去修改权还有几天（0 = 今天是最后一天）。
  static int? daysLeft(LocalDate date, LocalDate today) {
    if (!canEdit(date, today)) {
      return null;
    }
    return editableDays - today.daysSince(date);
  }
}
