/// 疗程：**做到哪天为止**（"疗程"维度，需求 3.2.1 第 3 个正交维度）。
library;

import 'local_date.dart';

/// 项目的时间边界。
///
/// 三种形态，语义互斥：
/// - [Course.none]：长期习惯（跳绳），永不自动结束
/// - [Course.range]：起止日期
/// - [Course.days]：从 [start] 起连续 N 天（N 含首日）
///
/// 🟡 已定：到期自动**归档**，停止提醒，历史完整保留（需求 3.2.1 疗程）。
final class Course {
  const Course._({
    required this.start,
    required this.end,
    required this.totalDays,
  });

  /// 长期，无期限。
  static const none = Course._(start: null, end: null, totalDays: null);

  /// 起止日期（含两端）。
  factory Course.range(LocalDate start, LocalDate end) {
    if (end.isBefore(start)) {
      throw ArgumentError('结束日期不能早于开始日期');
    }
    return Course._(start: start, end: end, totalDays: null);
  }

  /// 从 [start] 起连续 [days] 天（含首日）。
  factory Course.days(LocalDate start, int days) {
    if (days <= 0) {
      throw ArgumentError.value(days, 'days', '天数必须为正');
    }
    return Course._(
      start: start,
      end: start.addDays(days - 1),
      totalDays: days,
    );
  }

  /// 从 [from] 解析出一个疗程（导入历史数据用）。
  factory Course.fromRange(LocalDate? start, LocalDate? end) {
    if (start == null && end == null) {
      return Course.none;
    }
    if (start == null || end == null) {
      throw ArgumentError('起止日期必须同时给出或同时为空');
    }
    return Course.range(start, end);
  }

  /// 开始日期；null = 长期。
  final LocalDate? start;

  /// 结束日期（含）；null = 长期。
  final LocalDate? end;

  /// 若是"连续 N 天"形态，记下 N（用于 UI 显示"第 3/7 天"）。
  final int? totalDays;

  bool get isOpenEnded => start == null && end == null;

  /// 某天是否落在疗程内。长期疗程恒为 true。
  bool contains(LocalDate date) {
    if (isOpenEnded) {
      return true;
    }
    return date.isBetween(start!, end!);
  }

  /// 疗程进行到第几天（1-based）；不在疗程内或长期则为 null。
  int? dayIndex(LocalDate date) {
    if (!contains(date) || isOpenEnded) {
      return null;
    }
    return date.daysSince(start!) + 1;
  }

  /// 距离结束还有几天（含当天算 0）；长期为 null。
  int? daysRemaining(LocalDate date) {
    if (isOpenEnded) {
      return null;
    }
    return end!.daysSince(date);
  }

  /// 是否已到期（严格晚于结束日）。
  bool isExpired(LocalDate today) => !isOpenEnded && today.isAfter(end!);

  /// 是否快到期（🟡 需求 3.2.1"到期前轻提示"，默认提前 2 天）。
  bool isEndingSoon(LocalDate today, {int withinDays = 2}) {
    if (isOpenEnded) {
      return false;
    }
    final left = daysRemaining(today);
    return left != null && left >= 0 && left <= withinDays;
  }

  @override
  bool operator ==(Object other) =>
      other is Course &&
      other.start == start &&
      other.end == end &&
      other.totalDays == totalDays;

  @override
  int get hashCode => Object.hash(start, end, totalDays);

  @override
  String toString() =>
      isOpenEnded ? 'Course.none' : 'Course($start → $end, ${totalDays}d)';
}
