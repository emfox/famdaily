/// 把"哪天 × 几点 × 到哪天"这套规则说成人话。
///
/// 放在 domain 层（零 Flutter 依赖）而不是页面里，因为它不是排版而是
/// **语义**：详情页、成员页副标题、"生成打卡链接"的只读页以后都要说同一套话。
/// 两处各写一份，迟早会出现"编辑页说周一三五、详情页说每天"。
///
/// 与 `TaskDraft.describeTime()` 的关系：那边是**编辑中**的草稿复述
/// （要能反映用户还没保存的改动），这里是**已保存**项目的只读复述。
/// 两者都从 [TimeRule] 真展开，不靠 Tab 猜。
library;

import '../model/course.dart';
import '../model/local_date.dart';
import '../model/local_time.dart';
import '../model/repeat_rule.dart';
import '../model/task.dart';
import '../model/time_rule.dart';

/// 规则的自然语言复述。
abstract final class RuleText {
  /// 「每周一、三、五 · 每天 3 次」这类一句概括（列表副标题用，尽量短）。
  static String repeat(Task task) {
    final r = task.repeat;
    final chunks = <String>[];

    final wd = r.weekdays;
    if (wd != null && wd.isNotEmpty) {
      chunks.add('周${_weekdays(wd)}');
    }
    final n = r.everyNDays;
    if (n != null) {
      chunks.add('每 $n 天');
    }
    final p = r.parity;
    if (p != null) {
      chunks.add(switch (p) {
        ParityFilter.oddWeeks => '单周',
        ParityFilter.evenWeeks => '双周',
        ParityFilter.workdays => '工作日',
        ParityFilter.weekends => '周末',
      });
    }
    final md = r.monthDays;
    if (md != null && md.isNotEmpty) {
      chunks.add('每月 ${(md.toList()..sort()).join('、')} 号');
    }
    return chunks.isEmpty ? '每天' : chunks.join(' ');
  }

  /// 时刻规则里"重复的一句"（不含具体钟点）：`每天` / `每天 3 次` / `跟随三餐`。
  ///
  /// 具体钟点另给 [timesLine]——因为一日多次时列一行太长，
  /// 详情页要能拆成两行（"一日三次" + "7:30 / 12:30 / 18:30"）。
  static String cadence(Task task, {LocalDate? on}) {
    final rule = task.time;
    final count = rule.timesOn(on ?? _anyDay).length;

    if (rule is MealTimesRule) {
      final offset = rule.offsetMinutes;
      final meals = rule.anchors.map((a) => _meal(a)).join('、');
      var text = '一日${_cn(rule.anchors.length)}次 · 跟$meals';
      if (offset > 0) {
        text = '$text后 $offset 分钟';
      } else if (offset < 0) {
        text = '$text前 ${-offset} 分钟';
      }
      return text;
    }
    if (count <= 1) {
      return '每天 1 次';
    }
    return '每天 $count 次';
  }

  /// 具体钟点：「7:30 / 12:30 / 18:30」。
  ///
  /// 跨午夜的槽位（宵夜后 4 小时）显示成 `次日1:00`——
  /// 只写 `1:00` 会让人以为那是凌晨那次也算在当天早上。
  static String timesLine(Task task, {LocalDate? on}) {
    final rule = task.time;
    final day = on ?? _anyDay;
    final minutes = rule.shiftedMinutesOn(day);
    if (minutes.isEmpty) {
      return '（还没设时间）';
    }
    return minutes.map(_hmShifted).join(' / ');
  }

  /// 疗程：「10月24日 起连着做 7 天」/「长期」。
  static String course(Course c) {
    if (c.isOpenEnded) {
      return '长期';
    }
    final start = _md(c.start!);
    final total = c.totalDays;
    if (total != null) {
      return '$start 起连着做 $total 天（到 ${_md(c.end!)}）';
    }
    return '$start → ${_md(c.end!)}';
  }

  /// 疗程进度：「第 3/7 天」/「还剩 2 天」/「已经到期」。
  ///
  /// 长期返回 null——「长期 · 第几天」这种话没有意义，说了反而让人以为快结束了。
  static String? courseProgress(Course c, LocalDate today) {
    if (c.isOpenEnded) {
      return null;
    }
    if (c.isExpired(today)) {
      return '疗程已到期';
    }
    final total = c.totalDays;
    final idx = c.dayIndex(today);
    if (idx == null) {
      // 还没开始。
      return '${_md(c.start!)} 才开始';
    }
    if (total != null) {
      return '第 $idx/$total 天';
    }
    final left = c.daysRemaining(today);
    return left == 0 ? '今天是最后一天' : '还剩 $left 天';
  }

  /// 详情页头部那几行：谁 · 什么频率 / 几点 / 疗程。
  ///
  /// 合成一个 list 而不是拼一段字符串：中间某行可能要点（将来点疗程跳改期限），
  /// 拼成字符串就没法拆回来了。
  static List<String> headlineLines(Task task, {LocalDate? on}) => [
    '${repeat(task)} · ${cadence(task, on: on)}',
    timesLine(task, on: on),
    '疗程：${course(task.course)}',
  ];

  // -------------------------------------------------------------------

  /// 1970-01-01，与 `Task.timesPerDayHint` 用的是同一个参照日。
  static final LocalDate _anyDay = LocalDate(1970, 1, 1);

  static String _weekdays(Set<int> days) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final sorted = days.where((d) => d >= 1 && d <= 7).toList()..sort();
    return sorted.map((d) => names[d - 1]).join('、');
  }

  static String _meal(MealAnchor a) => switch (a) {
    MealAnchor.breakfast => '早饭',
    MealAnchor.lunch => '午饭',
    MealAnchor.dinner => '晚饭',
  };

  static String _cn(int n) => switch (n) {
    1 => '一',
    2 => '两',
    3 => '三',
    4 => '四',
    _ => '$n',
  };

  static String _md(LocalDate d) => '${d.month}月${d.day}日';

  /// 未归一化的分钟数 → `7:30` / `次日1:00` / `前一天23:00`。
  ///
  /// 用 floor 除而不是 `~/`：Dart 的整除对负数**向零截断**，
  /// -60 ~/ 1440 == 0，会把"前一天 23:00"错算成"次日 0:00 之前"。
  static String _hmShifted(int minuteOfDay) {
    final days = (minuteOfDay / 1440).floor();
    final m = minuteOfDay - days * 1440;
    final t = LocalTime.fromMinuteOfDay(m);
    final hm = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    if (days == 0) {
      return hm;
    }
    return days > 0 ? '次日$hm' : '前一天$hm';
  }
}
