/// 本地日历日期（只有年月日，没有时刻、没有时区）。
///
/// 为什么不用 `DateTime`：打卡的"某一天"是一个日历概念，不是时间点。
/// `DateTime` 带上时间和时区后，跨夏令时、跨时区、`isSameDay` 比较都容易出错。
/// 这里只保留 `year-month-day`，比较和排序都是纯整数运算。
library;

/// 一个不受时区影响的本地日期。
///
/// 内部用"自 1970-01-01 起的天数"（[epochDay]）做唯一表示，
/// 这样 [compareTo]、差值、周几都能用整数算，不会有浮点或时区误差。
final class LocalDate implements Comparable<LocalDate> {
  const LocalDate._(this.year, this.month, this.day, this.epochDay);

  /// 用年月日构造，自动校验合法性（如 2 月 30 日会抛 [ArgumentError]）。
  factory LocalDate(int year, int month, int day) {
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', '月份必须在 1..12');
    }
    if (day < 1 || day > daysInMonth(year, month)) {
      throw ArgumentError.value(day, 'day', '$year-$month 没有第 $day 天');
    }
    return LocalDate._(year, month, day, _toEpochDay(year, month, day));
  }

  /// 从 [DateTime] 取本地日期部分。
  factory LocalDate.fromDateTime(DateTime dt) =>
      LocalDate(dt.year, dt.month, dt.day);

  /// 从"自 1970-01-01 起的天数"还原。
  factory LocalDate.fromEpochDay(int epochDay) {
    // Howard Hinnant 的 civil_from_days 算法，纯整数，无时区依赖。
    final z = epochDay + 719468;
    final era = (z >= 0 ? z : z - 146096) ~/ 146097;
    final doe = z - era * 146097;
    final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
    final y = yoe + era * 400;
    final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
    final mp = (5 * doy + 2) ~/ 153;
    final d = doy - (153 * mp + 2) ~/ 5 + 1;
    final m = mp < 10 ? mp + 3 : mp - 9;
    return LocalDate._(m <= 2 ? y + 1 : y, m, d, epochDay);
  }

  /// 今天（按给定时钟，测试里可注入固定时间）。
  factory LocalDate.today([DateTime? now]) =>
      LocalDate.fromDateTime(now ?? DateTime.now());

  final int year;
  final int month;
  final int day;

  /// 自 1970-01-01 起的天数；可正可负。
  final int epochDay;

  /// 周几，1 = 周一 … 7 = 周日（与 `DateTime.weekday` 一致）。
  int get weekday => ((epochDay + 3) % 7 + 7) % 7 + 1;

  bool get isWeekend => weekday >= 6;

  /// 是否是某一年的 2 月 29 日。
  bool get isLeapDay => month == 2 && day == 29;

  LocalDate addDays(int days) => LocalDate.fromEpochDay(epochDay + days);

  LocalDate addMonths(int months) {
    final total = year * 12 + (month - 1) + months;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    // 1 月 31 日 + 1 个月 → 2 月 28/29 日（截断，不溢出到下个月）
    final d = day > daysInMonth(y, m) ? daysInMonth(y, m) : day;
    return LocalDate(y, m, d);
  }

  /// 本月最后一天。
  LocalDate get lastDayOfMonth =>
      LocalDate(year, month, daysInMonth(year, month));

  /// 从 [from] 到本日期相差的天数（本日期更晚则为正）。
  int daysSince(LocalDate from) => epochDay - from.epochDay;

  bool isBefore(LocalDate other) => epochDay < other.epochDay;
  bool isAfter(LocalDate other) => epochDay > other.epochDay;
  bool isSameDay(LocalDate other) => epochDay == other.epochDay;

  /// 闭区间包含判断。
  bool isBetween(LocalDate from, LocalDate to) =>
      epochDay >= from.epochDay && epochDay <= to.epochDay;

  @override
  int compareTo(LocalDate other) => epochDay.compareTo(other.epochDay);

  @override
  bool operator ==(Object other) =>
      other is LocalDate && other.epochDay == epochDay;

  @override
  int get hashCode => epochDay.hashCode;

  /// `2026-10-23` 形式，便于日志与 JSON。
  @override
  String toString() =>
      '$year-${_pad(month)}-${_pad(day)}';

  /// 解析 `2026-10-23`。
  static LocalDate parse(String s) {
    final parts = s.split('-');
    if (parts.length != 3) {
      throw FormatException('不是合法日期：$s', s);
    }
    return LocalDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// 转为当天 00:00 的本地 [DateTime]（给需要 DateTime 的 API 用）。
  DateTime toDateTime() => DateTime(year, month, day);

  /// 某年某月的天数。
  static int daysInMonth(int year, int month) {
    const table = <int>[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month == 2 && _isLeapYear(year)) {
      return 29;
    }
    return table[month - 1];
  }

  /// 某年是否是闰年（格里高利历规则）。
  static bool _isLeapYear(int year) =>
      (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  static int _toEpochDay(int y, int m, int d) {
    // Howard Hinnant 的 days_from_civil。
    final yy = m <= 2 ? y - 1 : y;
    final era = (yy >= 0 ? yy : yy - 399) ~/ 400;
    final yoe = yy - era * 400;
    final doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) ~/ 5 + d - 1;
    final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
    return era * 146097 + doe - 719468;
  }

  static String _pad(int v) => v.toString().padLeft(2, '0');
}

const localEpoch = LocalDate._(1970, 1, 1, 0);
