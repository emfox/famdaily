/// 时间窗口规则：哪些通知该排、排到哪天、什么时候不打扰。
///
/// 这一层**刻意不碰 Flutter**，只做纯计算，这样滚动窗口、免打扰判定、
/// 催办取消这些最容易出错的逻辑可以脱离模拟器单测。
library;

import '../model/local_date.dart';
import '../model/local_time.dart';

/// 一段"几点到几点别吵我"。
///
/// 必须支持跨午夜（22:00 → 07:00），而且判定要按"墙钟区间"而不是
/// "分钟数比大小"——后者对跨午夜区间会得出完全相反的结论。
final class QuietHours {
  const QuietHours({required this.start, required this.end});

  final LocalTime start;
  final LocalTime end;

  /// 一段都不静音（起止分钟相同 = 空区间）。
  ///
  /// 不用 `static const`：`LocalTime` 的公开构造器是 factory，不算常量表达式。
  /// 它是不可变对象，`static final` 一样安全。
  static final QuietHours none = QuietHours(
    start: LocalTime(0, 0),
    end: LocalTime(0, 0),
  );

  /// 是否一段都不静音。
  bool get isDisabled => _isSameMinute;

  bool get _isSameMinute => start.minuteOfDay == end.minuteOfDay;

  /// [time] 是否落在免打扰时段内（含起点，不含终点，与"9:00-21:00 每 2 小时"一致）。
  bool contains(LocalTime time) {
    if (isDisabled) {
      return false;
    }
    final s = start.minuteOfDay;
    final e = end.minuteOfDay;
    final t = time.minuteOfDay;
    if (s < e) {
      return t >= s && t < e;
    }
    // 跨午夜：22:00-07:00 = [22:00, 24:00) ∪ [00:00, 07:00)
    return t >= s || t < e;
  }

  /// 提醒时间落在免打扰里时，顺延到免打扰结束的那一刻。
  ///
  /// 不选择"直接丢掉"：吃药这种事儿丢一次就断疗程了，
  /// 顺延到早上虽然晚，但比静默丢弃好。
  LocalTime shiftOutOf(LocalTime time) {
    if (!contains(time)) {
      return time;
    }
    return end;
  }

  @override
  bool operator ==(Object other) =>
      other is QuietHours && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => isDisabled ? 'QuietHours(off)' : 'QuietHours($start-$end)';
}

/// 滚动窗口的参数。
///
/// iOS 只保留最近 64 条待处理通知（tech-stack §4.1），所以窗口是
/// "宁可多排几天但绝不越过上限"的折中：按每天条数自适应天数。
final class WindowPolicy {
  const WindowPolicy({
    this.maxScheduled = 56,
    this.minDays = 3,
    this.maxDays = 14,
  });

  /// 一次最多排多少条。留 8 条余量给系统的其他通知与缓冲。
  ///
  /// 不做成 64（满额）的原因：iOS 在"写入第 65 条"时会把最老的一条挤掉，
  /// 而挤掉的往往是**今天最早**那条——正好是最要紧的一条。
  final int maxScheduled;

  final int minDays;
  final int maxDays;

  /// 按平均每天**槽位数**决定窗口覆盖几天。
  ///
  /// 注意入参是槽位数而不是通知数：一个槽位会产生「提醒 + 催办」两条通知，
  /// 所以内部要乘 2 再算天数，否则实际条数会翻倍越过上限。
  int daysFor(int dailySlots) {
    final perDay = _effectiveDaily(dailySlots);
    if (perDay <= 0) {
      return maxDays;
    }
    return (maxScheduled / perDay).floor().clamp(minDays, maxDays);
  }

  /// 每个槽位实际产生的通知条数（提醒 + 催办）。
  static const int notificationsPerSlot = 2;

  /// 按槽位数算天数时用的等效"每天通知数"。
  int _effectiveDaily(int dailySlots) => dailySlots * notificationsPerSlot;

  /// 窗口覆盖的最后一天。
  LocalDate endFor(LocalDate today, int dailySlots) =>
      today.addDays(daysFor(dailySlots) - 1);
}

/// 窗口重排的触发时机。
///
/// 明确列出而不是"想排就排"：iOS 上频繁大批量重排会拖慢冷启动，
/// 而且每次重排都要重建几十条通知，很费电。
enum RescheduleTrigger {
  /// 冷启动。
  appLaunch,

  /// 从后台回到前台（可能已经跨天了）。
  resumed,

  /// 数据变更（新建/编辑/删除项目，打卡，撤销）。
  dataChanged,

  /// 跨天（前台停留跨过零点）。
  dayChanged,

  /// 用户手动在设置里改了提醒相关开关。
  settingsChanged,
}

/// 判定"这次事件需不需要真的重排"。
///
/// 数据变更与设置变更是必排的；前台恢复只有在**隔了一天**时才排，
/// 否则每次切回来都白跑一遍。
abstract final class ReschedulePolicy {
  static bool shouldReschedule({
    required RescheduleTrigger trigger,
    required LocalDate today,
    required LocalDate lastScheduledFor,
  }) {
    return switch (trigger) {
      RescheduleTrigger.dataChanged || RescheduleTrigger.settingsChanged =>
        true,
      RescheduleTrigger.appLaunch => true,
      RescheduleTrigger.resumed || RescheduleTrigger.dayChanged =>
        today.isAfter(lastScheduledFor),
    };
  }
}
