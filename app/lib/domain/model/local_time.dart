/// 本地时刻（只有时分，没有日期、没有时区）。
///
/// 用"当天第几分钟"（`minuteOfDay`）作为唯一表示，比较、排序、加偏移都是整数运算。
/// 分钟精度：提醒里"饭后 30 分钟"这种偏移就是分钟级，秒没有意义。
library;

final class LocalTime implements Comparable<LocalTime> {
  const LocalTime._(this.hour, this.minute);

  /// 构造一个合法时刻（0 ≤ hour < 24，0 ≤ minute < 60）。
  factory LocalTime(int hour, int minute) {
    if (hour < 0 || hour > 23) {
      throw ArgumentError.value(hour, 'hour', '小时必须在 0..23');
    }
    if (minute < 0 || minute > 59) {
      throw ArgumentError.value(minute, 'minute', '分钟必须在 0..59');
    }
    return LocalTime._(hour, minute);
  }

  /// 从"当天第几分钟"还原（0..1439）。
  factory LocalTime.fromMinuteOfDay(int minuteOfDay) {
    if (minuteOfDay < 0 || minuteOfDay > 1439) {
      throw ArgumentError.value(minuteOfDay, 'minuteOfDay', '必须在 0..1439');
    }
    return LocalTime._(minuteOfDay ~/ 60, minuteOfDay % 60);
  }

  factory LocalTime.parse(String s) {
    final parts = s.split(':');
    if (parts.length != 2) {
      throw FormatException('不是合法时刻：$s', s);
    }
    return LocalTime(int.parse(parts[0]), int.parse(parts[1]));
  }

  final int hour;
  final int minute;

  int get minuteOfDay => hour * 60 + minute;

  /// 加分钟偏移。**会跨天**：返回 (跨过的天数, 结果时刻)。
  ///
  /// 例：23:30 + 60 分钟 → (+1, 00:30)；00:30 − 60 分钟 → (−1, 23:30)。
  /// 调用方必须处理这个 `days`，否则"饭后 30 分钟"在跨午夜时会静默算错。
  ///
  /// ⚠️ Dart 的 `~/` 与 `%` 都是**向零截断**，对负数不做 floor mod
  /// （实测 `-30 ~/ 1440 == 0`、`-30 % 1440 == -30`）。
  /// 所以这里必须用 floor 除法，否则"饭前 60 分钟"会被算成同一天。
  (int days, LocalTime time) addMinutes(int minutes) {
    final total = minuteOfDay + minutes;
    final days = (total / 1440).floor();
    final rem = total - days * 1440;
    return (days, LocalTime.fromMinuteOfDay(rem));
  }

  /// 是否在 [from, to] 闭区间内。**不处理跨午夜**（from > to 视为空区间）。
  bool isBetween(LocalTime from, LocalTime to) =>
      minuteOfDay >= from.minuteOfDay && minuteOfDay <= to.minuteOfDay;

  /// 加分钟偏移，返回**未归一到 0..1439** 的"当天第几分钟"。
  ///
  /// 跨天的偏移需要保留这个越界值（如 +240 分钟 → 1540），
  /// 交给排程器按 floor 除法折算成"第几天 + 几点"。若先归一化，跨天信息就丢了。
  int shiftedMinuteOfDay(int minutes) => minuteOfDay + minutes;

  bool isBefore(LocalTime other) => minuteOfDay < other.minuteOfDay;
  bool isAfter(LocalTime other) => minuteOfDay > other.minuteOfDay;

  @override
  int compareTo(LocalTime other) => minuteOfDay.compareTo(other.minuteOfDay);

  @override
  bool operator ==(Object other) =>
      other is LocalTime && other.minuteOfDay == minuteOfDay;

  @override
  int get hashCode => minuteOfDay.hashCode;

  /// `08:05` 形式。
  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// 三餐锚点。需求 3.2.1 第一层"一日 N 次 · 跟随三餐"。
enum MealAnchor {
  breakfast(TimeDefaults.breakfast),
  lunch(TimeDefaults.lunch),
  dinner(TimeDefaults.dinner);

  const MealAnchor(this.defaultTime);

  /// 默认锚点时刻，用户可改。
  final LocalTime defaultTime;
}

/// 出厂默认时刻（设置里可改，这里只是初始值）。
///
/// ⚠️ 用私有常量构造器写，不能写 `static const x = LocalTime(7, 30)`——
/// Dart 不允许在 const 上下文调用非 const factory。
abstract final class TimeDefaults {
  static const breakfast = LocalTime._(7, 30);
  static const lunch = LocalTime._(12, 0);
  static const dinner = LocalTime._(18, 30);

  /// 新建项目时的默认时刻（晚上八点，一天里最可能"想起来做点事"的时段）。
  static const evening = LocalTime._(20, 0);
}
