/// 时刻规则：**每天在几点做**（"时刻"维度，需求 3.2.1 第 2 个正交维度）。
///
/// 四种基本型可以**相加**（多个时间段），底层数据结构只有这一套；
/// UI 上的"三层规则"只是分组展示，不影响存储。
library;

import 'local_date.dart';
import 'local_time.dart';

sealed class TimeRule {
  const TimeRule();

  /// 展开到某一天的若干时刻（已排序、已去重）。
  ///
  /// [date] 用于"跟随三餐"这类按天计算的规则（若将来引入日落等日相规则也走这里）。
  List<LocalTime> timesOn(LocalDate date);

  /// 不用日期就能展开的规则（固定时刻、间隔、组合）返回 true。
  ///
  /// UI 要拿"某天几点"做预览和编辑回填，但**不能固定取今天**——
  /// 否则日历页预览 3 号时看到的时刻会是今天的；也不能取 1970，
  /// 因为将来加入"日落"这类日相规则后会算错。所以让规则自己说清楚。
  bool get isDateIndependent;

  /// 展开成**未归一化的当天第几分钟**，允许越界（负数或 > 1439）以表达跨午夜。
  ///
  /// 排程器必须用这个方法而不是 [timesOn]：`timesOn` 会把 21:00+4h 折回 01:00，
  /// 跨天信息就丢了，"宵夜后 4 小时吃药"会被错误地排到同一天凌晨。
  /// 默认实现就是按 0..1439 展开（无跨天）。
  List<int> shiftedMinutesOn(LocalDate date) =>
      timesOn(date).map((t) => t.minuteOfDay).toList();
}

/// 一天 N 次 · 固定时刻（最常用：跳绳每晚 20:00、吃药 15:00 和 22:00）。
final class FixedTimesRule extends TimeRule {
  FixedTimesRule(List<LocalTime> times)
    : assert(times.isNotEmpty, '至少给一个时刻'),
      _times = List.unmodifiable(
        (times.toList()..sort()).toSet().toList(),
      );

  final List<LocalTime> _times;

  List<LocalTime> get times => _times;

  @override
  List<LocalTime> timesOn(LocalDate date) => _times;

  @override
  bool get isDateIndependent => true;

  @override
  bool operator ==(Object other) =>
      other is FixedTimesRule && _listEq(other._times, _times);

  @override
  int get hashCode => Object.hashAll(_times);

  @override
  String toString() => 'FixedTimesRule(${_times.join(', ')})';
}

/// 跟随三餐 ± 偏移（"饭后 30 分钟"）。
///
/// [offsetMinutes] 可以为负（饭前），也可以很大（跨午夜，如宵夜后 60 分钟）。
/// 偏移导致跨天时，排程器会把时刻落到**次日/前日**——`timesOn` 只返回当天的时刻，
/// 跨天部分由排程器在展开时处理（见 `scheduler.dart` 的说明）。
final class MealTimesRule extends TimeRule {
  MealTimesRule({
    required List<MealAnchor> anchors,
    this.offsetMinutes = 0,
    Map<MealAnchor, LocalTime>? anchorOverrides,
  }) : assert(anchors.isNotEmpty, '至少选一餐'),
       anchors = List.unmodifiable(
         anchors.toSet().toList()..sort((a, b) => a.index.compareTo(b.index)),
       ),
       anchorOverrides = Map.unmodifiable(anchorOverrides ?? const {});

  final List<MealAnchor> anchors;

  /// 正数 = 饭后 N 分钟；负数 = 饭前 N 分钟。
  final int offsetMinutes;

  /// 用户自定义的三餐时刻（不填则用 [MealAnchor.defaultTime]）。
  final Map<MealAnchor, LocalTime> anchorOverrides;

  LocalTime timeFor(MealAnchor anchor) =>
      anchorOverrides[anchor] ?? anchor.defaultTime;

  /// 每个锚点的原始时刻（未加偏移），升序。
  List<LocalTime> rawAnchors() =>
      (anchors.map(timeFor).toList()..sort());

  @override
  bool get isDateIndependent => false;

  @override
  List<LocalTime> timesOn(LocalDate date) => shiftedMinutesOn(date)
      .map((m) => LocalTime.fromMinuteOfDay((m % 1440 + 1440) % 1440))
      .toSet()
      .toList()
    ..sort();

  @override
  List<int> shiftedMinutesOn(LocalDate date) {
    final result = <int>{};
    for (final anchor in anchors) {
      result.add(timeFor(anchor).shiftedMinuteOfDay(offsetMinutes));
    }
    return result.toList()..sort();
  }

  @override
  bool operator ==(Object other) =>
      other is MealTimesRule &&
      _listEq(other.anchors, anchors) &&
      other.offsetMinutes == offsetMinutes &&
      _mapEq(other.anchorOverrides, anchorOverrides);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(anchors),
    offsetMinutes,
    Object.hashAllUnordered(
      anchorOverrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() =>
      'MealTimesRule($anchors, offset: ${offsetMinutes}min)';
}

/// 每 N 小时一次，限定起止时段（"每 2 小时喝水，9:00–21:00"）。
///
/// 语义（已定，见 tech-stack §5.2 单测清单）：
/// - **含起含止**：9:00–21:00 每 2 小时 → 9, 11, 13, 15, 17, 19, 21 共 **7 条**
/// - **不允许跨午夜**（`from` 必须早于 `to`），UI 直接禁止
final class IntervalRule extends TimeRule {
  IntervalRule({
    required this.everyMinutes,
    required this.from,
    required this.to,
  }) : assert(everyMinutes > 0, '间隔必须为正'),
       assert(
         from.minuteOfDay < to.minuteOfDay,
         '起止时刻不能跨午夜，也不能相等',
       );

  final int everyMinutes;
  final LocalTime from;
  final LocalTime to;

  /// 从 [from] 起，每 [everyMinutes] 一次，直到不超过 [to]。
  List<LocalTime> times() {
    final out = <LocalTime>[];
    var m = from.minuteOfDay;
    while (m <= to.minuteOfDay) {
      out.add(LocalTime.fromMinuteOfDay(m));
      m += everyMinutes;
    }
    return out;
  }

  /// 一天会生成多少条（用于校验"别一次排 200 条"）。
  int get count => (to.minuteOfDay - from.minuteOfDay) ~/ everyMinutes + 1;

  @override
  List<LocalTime> timesOn(LocalDate date) => times();

  @override
  bool get isDateIndependent => true;

  @override
  bool operator ==(Object other) =>
      other is IntervalRule &&
      other.everyMinutes == everyMinutes &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(everyMinutes, from, to);

  @override
  String toString() => 'IntervalRule(every ${everyMinutes}min, $from–$to)';
}

/// 组合多个时刻规则（"上午 9/11 点，下午 15/17 点"= 两个 FixedTimesRule 相加）。
final class CombinedTimeRule extends TimeRule {
  CombinedTimeRule(List<TimeRule> rules)
    : assert(rules.isNotEmpty, '至少给一个子规则'),
      rules = List.unmodifiable(rules);

  final List<TimeRule> rules;

  @override
  List<LocalTime> timesOn(LocalDate date) {
    final set = <LocalTime>{};
    for (final r in rules) {
      set.addAll(r.timesOn(date));
    }
    return set.toList()..sort();
  }

  /// 所有子规则都与日期无关才算无关。
  @override
  bool get isDateIndependent => rules.every((r) => r.isDateIndependent);

  @override
  bool operator ==(Object other) =>
      other is CombinedTimeRule && _listEq(other.rules, rules);

  @override
  int get hashCode => Object.hashAll(rules);

  @override
  String toString() => 'CombinedTimeRule(${rules.join(' + ')})';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _mapEq<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final e in a.entries) {
    if (b[e.key] != e.value) {
      return false;
    }
  }
  return true;
}
