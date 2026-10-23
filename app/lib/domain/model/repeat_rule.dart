/// 重复规则：**在哪几天做**（对应"哪天"维度，需求 3.2.1 第 1 个正交维度）。
///
/// 三个条件同时给出时取**交集**，全部为空表示"每天"。
/// 例：`weekdays: {1,3,5}` + `parity: oddWeeks` → 单周的周一/三/五。
library;

import 'local_date.dart';

/// 连续 `everyNDays` 天的相位（从哪一天起算"第 1 天"）。
///
/// 必须显式存，否则"每 3 天一次"在改规则后会漂移到别的日子。
/// 约定：`anchor` 当天算"第 1 天"，即 `(date - anchor) % n == 0` 时命中。
final class RepeatRule {
  const RepeatRule({
    this.weekdays,
    this.everyNDays,
    this.anchor,
    this.parity,
    this.monthDays,
  }) : assert(
         everyNDays == null || everyNDays > 0,
         'everyNDays 必须为正',
       );

  /// 每天都做。
  static const daily = RepeatRule();

  /// 仅周几（1 = 周一 … 7 = 周日）。空集合等同于 null（不限）。
  final Set<int>? weekdays;

  /// 每 N 天一次。null = 不限。
  final int? everyNDays;

  /// 每 N 天的相位起点。仅当 [everyNDays] 非空时有意义。
  ///
  /// 若为 null，排程器会退回"以 [RepeatRule] 构造时传入的 epochDay 0"，
  /// 这是不推荐的用法——UI 层必须传入用户选定的起始日。
  final LocalDate? anchor;

  /// 单双周 / 工作日 / 周末 这类快捷筛选。
  final ParityFilter? parity;

  /// 每月几号（1..31）。null = 不限。
  ///
  /// 注意：31 号在 2 月不存在，排程器会**跳过当月**（不折回月末），
  /// 这是"每月 31 号"最符合直觉的解释。
  final List<int>? monthDays;

  /// 是否一项限制都没有（= 每天）。
  bool get isEveryDay =>
      (weekdays?.isEmpty ?? true) &&
      everyNDays == null &&
      parity == null &&
      (monthDays?.isEmpty ?? true);

  /// 判断某一天是否命中本规则。
  bool matches(LocalDate date) {
    if (isEveryDay) {
      return true;
    }

    // 维度 1：周几
    final wd = weekdays;
    if (wd != null && wd.isNotEmpty && !wd.contains(date.weekday)) {
      return false;
    }

    // 维度 2：每隔 N 天
    final n = everyNDays;
    if (n != null) {
      final from = anchor ?? localEpoch;
      // 用取模保证负数也正确（date 早于 anchor 时）
      final diff = date.epochDay - from.epochDay;
      final rem = diff % n;
      if (rem != 0) {
        return false;
      }
    }

    // 维度 3：单双周 / 工作日 / 周末
    final p = parity;
    if (p != null && !p.matches(date)) {
      return false;
    }

    // 维度 4：每月几号
    final md = monthDays;
    if (md != null && md.isNotEmpty && !md.contains(date.day)) {
      return false;
    }

    return true;
  }

  /// 本规则是否"永远不会触发"（用户配了矛盾条件）。
  ///
  /// 例：`weekdays: {}` 不会（视为不限）；但 `weekdays: {6,7}` + `parity: workdays`
  /// 就是矛盾——UI 应该在保存前拦下，而不是让用户建一个永远不提醒的项目。
  bool get isSatisfiable {
    if (isEveryDay) {
      return true;
    }
    // 周几 ∩ 工作日/周末：有交集才可能触发
    if (parity != null && weekdays != null && weekdays!.isNotEmpty) {
      final allowedWeekdays = parity!.allowedWeekdays;
      if (!weekdays!.any(allowedWeekdays.contains)) {
        return false;
      }
    }
    return true;
  }

  RepeatRule copyWith({
    Set<int>? weekdays,
    int? everyNDays,
    LocalDate? anchor,
    ParityFilter? parity,
    List<int>? monthDays,
    bool clearWeekdays = false,
    bool clearEveryNDays = false,
    bool clearParity = false,
    bool clearMonthDays = false,
  }) {
    return RepeatRule(
      weekdays: clearWeekdays ? null : (weekdays ?? this.weekdays),
      everyNDays: clearEveryNDays ? null : (everyNDays ?? this.everyNDays),
      anchor: clearEveryNDays ? null : (anchor ?? this.anchor),
      parity: clearParity ? null : (parity ?? this.parity),
      monthDays: clearMonthDays ? null : (monthDays ?? this.monthDays),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! RepeatRule) {
      return false;
    }
    return _setEq(other.weekdays, weekdays) &&
        other.everyNDays == everyNDays &&
        other.anchor == anchor &&
        other.parity == parity &&
        _listEq(other.monthDays, monthDays);
  }

  @override
  int get hashCode => Object.hash(
    weekdays == null ? null : Object.hashAllUnordered(weekdays!),
    everyNDays,
    anchor,
    parity,
    monthDays == null ? null : Object.hashAll(monthDays!),
  );

  @override
  String toString() =>
      'RepeatRule(weekdays: $weekdays, everyNDays: $everyNDays, '
      'anchor: $anchor, parity: $parity, monthDays: $monthDays)';

  static bool _setEq(Set<int>? a, Set<int>? b) {
    if (a == null || b == null) {
      return a == null && b == null;
    }
    return a.length == b.length && a.every(b.contains);
  }

  static bool _listEq(List<int>? a, List<int>? b) {
    if (a == null || b == null) {
      return a == null && b == null;
    }
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
}

/// 单双周 / 工作日 / 周末。
enum ParityFilter {
  /// 单周（以 [isEvenWeek] 的基准日判定）。
  oddWeeks,

  /// 双周。
  evenWeeks,

  /// 周一至周五。
  workdays,

  /// 周六、周日。
  weekends;

  /// 该筛选允许的周几集合（1 = 周一）。
  Set<int> get allowedWeekdays => switch (this) {
    ParityFilter.oddWeeks || ParityFilter.evenWeeks => {1, 2, 3, 4, 5, 6, 7},
    ParityFilter.workdays => {1, 2, 3, 4, 5},
    ParityFilter.weekends => {6, 7},
  };

  bool matches(LocalDate date) => switch (this) {
    ParityFilter.oddWeeks => !_isEvenWeek(date),
    ParityFilter.evenWeeks => _isEvenWeek(date),
    ParityFilter.workdays => !date.isWeekend,
    ParityFilter.weekends => date.isWeekend,
  };

  /// 单双周基准：以 1970-01-01（周四）所在的那一周为"第 1 周"，奇数周为单周。
  ///
  /// 这个基准是**全局固定**的，不是"从今天起算"——否则用户改规则时单双周会整体位移。
  static bool _isEvenWeek(LocalDate date) {
    // 1970-01-01 是周四，把 epochDay 折算到"周一为一周之始"
    final mondayBased = date.epochDay - (date.weekday - 1);
    final weekIndex = (mondayBased - (-3)) ~/ 7; // 1970-01-01 的周一 = epochDay -3
    return weekIndex.isEven;
  }
}
