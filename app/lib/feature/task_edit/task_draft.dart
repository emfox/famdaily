/// 新建打卡项表单的**纯状态**（无 Flutter 依赖，可单测）。
///
/// 三步式表单（ui-spec §2）里的所有判断——能不能保存、预览文案是什么、
/// 展开后一天几次——都收在这里。页面只负责把控件的变化写进来、把
/// [buildPreview] 画出来。这样"表单能不能存"这种规则可以脱离模拟器测。
library;

import '../../domain/model/course.dart';
import '../../domain/model/local_date.dart';
import '../../domain/model/local_time.dart';
import '../../domain/model/repeat_rule.dart';
import '../../domain/model/task.dart';
import '../../domain/model/task_status.dart';
import '../../domain/model/time_rule.dart';
import '../../domain/template/task_template.dart';

/// 步骤 3 的三个 Tab（ui-spec §2.3）。
///
/// 三者**共用同一份底层状态**（`timePoints` + `repeat` + `course`），
/// 切换 Tab 只是换一种编辑方式，不换数据结构：
/// - [once]：1 个时刻
/// - [several]：N 个时刻（N ∈ 1..6），或"跟三餐走"
/// - [custom]：任意时刻列表
enum TimeTab {
  once('每天一次'),
  several('一天几次'),
  custom('自己定时刻');

  const TimeTab(this.labelZh);

  final String labelZh;
}

/// 一天最多几个时刻（「一天几次」的 N 上限，ui-spec §2.3）。
const int maxPointsPerDay = 6;

/// 表单的可变状态。
///
/// 刻意做成**可变对象**而不是 `copyWith` 的不可变值：三步表单里每一步都在
/// 就地改十来个字段，不可变会让页面代码变成一长串 `_state = _state.copyWith(...)`。
final class TaskDraft {
  TaskDraft({
    this.templateId = '',
    String name = '',
    String note = '',
    String? iconId,
    this.memberId,
    List<LocalTime>? timePoints,
    RepeatRule? repeat,
    Course? course,
    this.reminderEnabled = true,
    TimeTab timeTab = TimeTab.once,
    this.followMeals = false,
    this.followMealOffsetMinutes = 30,
    Map<MealAnchor, LocalTime>? mealAnchors,
    bool repeatExpanded = false,
    bool advancedExpanded = false,
    int intervalEveryMinutes = 0,
    LocalTime? intervalFrom,
    LocalTime? intervalTo,
  }) : name = name,
       note = note,
       _iconId = iconId,
       _timePoints = [...(timePoints ?? const [TimeDefaults.evening])],
       repeat = repeat ?? RepeatRule.daily,
       course = course ?? Course.none,
       _mealAnchors = {...?mealAnchors},
       timeTab = timeTab,
       repeatExpanded = repeatExpanded,
       advancedExpanded = advancedExpanded,
       intervalEveryMinutes = intervalEveryMinutes,
       intervalFrom = intervalFrom,
       intervalTo = intervalTo;

  /// 从模板新建（选中模板 → 带出全部默认值）。
  factory TaskDraft.fromTemplate(TaskTemplate t) {
    final draft = TaskDraft(
      templateId: t.id,
      name: t.name,
      note: t.note ?? '',
      iconId: t.iconId,
      repeat: t.repeat,
      course: t.course,
    );
    // 把模板的时刻规则**展开成具体时刻**，而不是留一个特殊规则对象。
    // 这条是 ui-spec 的硬要求：「跟三餐走」= 预填 3 个时刻的快捷方式。
    //
    // 显式声明成 TimeRule 再 switch：直接 switch `t.timeRule` 时，
    // 分支体会读到 `t.timeRule`（属性访问不走类型提升），拿不到子类成员。
    final TimeRule rule = t.timeRule;
    switch (rule) {
      case MealTimesRule():
        draft
          ..followMeals = true
          ..followMealOffsetMinutes = rule.offsetMinutes
          // 与 MealTimesRule.timesOn 一致：锚点 + 偏移。少了这一步，
          // 「饭后 30 分」的药会变成饭点整吃。
          .._timePoints = [
            for (final a in rule.anchors)
              rule.timeFor(a).addMinutes(rule.offsetMinutes).$2,
          ]
          .._mealAnchors = {...rule.anchorOverrides}
          ..timeTab = TimeTab.several;
      case FixedTimesRule():
        draft._timePoints = [...rule.times];
        draft.timeTab = rule.times.length == 1
            ? TimeTab.once
            : TimeTab.custom;
      default:
        draft._timePoints = rule.timesOn(_anyDay);
    }
    return draft;
  }

  String templateId;

  String name;
  String note;

  String? _iconId;

  /// 图标 id；null = 用模板的、再不行用 star。
  String? get iconId => _iconId ?? (templateId.isEmpty ? 'star' : _tplIcon);
  set iconId(String? v) => _iconId = v;

  String? _tplIcon;

  /// 谁做（成员 id）。第一步不选，第二步必须选。
  String? memberId;

  List<LocalTime> _timePoints;

  /// 当天的时刻列表（升序、去重由 setter 保证）。
  List<LocalTime> get timePoints => List.unmodifiable(_timePoints);

  RepeatRule repeat;
  Course course;

  bool reminderEnabled;

  /// 当前停在哪个 Tab（纯 UI 态，不参与保存）。
  TimeTab timeTab;

  /// 「跟三餐走」开关。打开时 [timePoints] 由三餐 + 偏移推导。
  bool followMeals;

  /// 跟随三餐的偏移（正 = 饭后，负 = 饭前）。只对三餐时刻生效。
  ///
  /// ui-spec §2.1 的「吃药」是"跟随三餐，饭后 30 分"，即三餐时刻各 +30。
  int followMealOffsetMinutes;

  Map<MealAnchor, LocalTime> _mealAnchors;

  /// 用户自定的三餐时刻（不填 = 用 [MealAnchor.defaultTime]）。
  Map<MealAnchor, LocalTime> get mealAnchors => Map.unmodifiable(_mealAnchors);

  /// 更多规则面板是否展开（纯 UI 态）。
  bool repeatExpanded;

  /// 高级面板是否展开（纯 UI 态）。
  bool advancedExpanded;

  /// 按间隔：每 N 分钟一次；0 = 不用这个规则。
  int intervalEveryMinutes;
  LocalTime? intervalFrom;
  LocalTime? intervalTo;

  /// 已选的三餐锚点（跟随时有效）。默认三餐全选。
  Set<MealAnchor> mealSelection = {...MealAnchor.values};

  // ---------------------------------------------------------------------
  // 时刻编辑
  // ---------------------------------------------------------------------

  /// 换一组时刻（会排序去重）。三餐跟随模式下手改会**自动关掉跟随**，
  /// 因为"跟三餐"和"手填"是两套来源，同时存在用户会看不懂。
  void setTimePoints(List<LocalTime> times) {
    _timePoints = _dedup(times);
    if (followMeals) {
      followMeals = false;
    }
    if (_timePoints.length == 1) {
      timeTab = TimeTab.once;
    }
  }

  /// 改第 [i] 个时刻。
  void setPointAt(int i, LocalTime t) {
    final next = [..._timePoints];
    if (i < 0 || i >= next.length) {
      return;
    }
    next[i] = t;
    setTimePoints(next);
  }

  /// 追加一个时刻（默认接在最后一个之后一小时，避免和已有重复）。
  void addPoint({LocalTime? at}) {
    if (_timePoints.length >= maxPointsPerDay) {
      return;
    }
    final base = at ?? _suggestNextTime();
    setTimePoints([..._timePoints, base]);
  }

  bool get canAddPoint => _timePoints.length < maxPointsPerDay;
  bool get canRemovePoint => _timePoints.length > 1;

  /// 删第 [i] 个（至少留一个）。
  void removePointAt(int i) {
    if (!canRemovePoint || i < 0 || i >= _timePoints.length) {
      return;
    }
    final next = [..._timePoints]..removeAt(i);
    setTimePoints(next);
  }

  /// 打开/关闭「跟三餐走」。
  ///
  /// 打开时立刻把三餐时刻（+偏移）写进 [timePoints]——从这一刻起数据就
  /// 只有一种形态，后面的预览、保存全都读 [timePoints]。
  void setFollowMeals(bool on) {
    followMeals = on;
    if (on) {
      _syncMealTimes();
    }
  }

  /// 改三餐偏移（正 = 饭后，负 = 饭前），立刻重算时刻。
  void setFollowMealOffset(int minutes) {
    followMealOffsetMinutes = minutes;
    if (followMeals) {
      _syncMealTimes();
    }
  }

  /// 勾掉某一餐。
  void toggleMeal(MealAnchor anchor, bool on) {
    final next = {...mealSelection};
    if (on) {
      next.add(anchor);
    } else {
      next.remove(anchor);
    }
    if (next.isEmpty) {
      // 一餐都不选等于这个项目没时刻，不允许。
      return;
    }
    mealSelection = next;
    if (followMeals) {
      _syncMealTimes();
    }
  }

  /// 改某餐的钟点。
  void setMealTime(MealAnchor anchor, LocalTime t) {
    _mealAnchors = {..._mealAnchors, anchor: t};
    if (followMeals) {
      _syncMealTimes();
    }
  }

  LocalTime mealTimeOf(MealAnchor anchor) =>
      _mealAnchors[anchor] ?? anchor.defaultTime;

  void _syncMealTimes() {
    final ordered = MealAnchor.values.where(mealSelection.contains).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    _timePoints = _dedup([
      for (final a in ordered) mealTimeOf(a).addMinutes(followMealOffsetMinutes).$2,
    ]);
    timeTab = TimeTab.several;
  }

  /// 选完模板后回填图标（模板切换时用）。
  void applyTemplate(TaskTemplate t) {
    templateId = t.id;
    if (name.isEmpty || name == _previousTemplateName) {
      name = t.name;
    }
    if (note.isEmpty || note == _previousTemplateNote) {
      note = t.note ?? '';
    }
    _iconId = null;
    _tplIcon = t.iconId;
    repeat = t.repeat;
    course = t.course;
    followMeals = false;
    mealSelection = {...MealAnchor.values};
    _mealAnchors = {};
    _timePoints = [...t.timeRule.timesOn(_anyDay)];
    timeTab = _timePoints.length == 1 ? TimeTab.once : TimeTab.custom;
    _previousTemplateName = t.name;
    _previousTemplateNote = t.note ?? '';
  }

  String _previousTemplateName = '';
  String _previousTemplateNote = '';

  // ---------------------------------------------------------------------
  // 校验与产出
  // ---------------------------------------------------------------------

  /// 名字是否算填了（去空白后非空）。
  bool get hasName => name.trim().isNotEmpty;

  /// 能不能保存：名字 + 谁做 + 至少一个时刻。
  bool get canSave =>
      hasName &&
      memberId != null &&
      _timePoints.isNotEmpty &&
      effectiveRepeat.isSatisfiable;

  /// 不能保存时的第一个原因（用来给顶栏一个说明，而不是让"保存"莫名灰着）。
  String? get blockReason {
    if (!hasName) {
      return '给它起个名字';
    }
    if (memberId == null) {
      return '选一下谁做';
    }
    if (_timePoints.isEmpty) {
      return '至少要有一个时间';
    }
    if (!effectiveRepeat.isSatisfiable) {
      return '选的日期永远不会发生';
    }
    return null;
  }

  /// 真正生效的重复规则：默认取 [repeat]，但若填了间隔规则就叠加。
  RepeatRule get effectiveRepeat => repeat;

  /// 真正生效的时刻规则。
  ///
  /// 注意**顺序**：间隔规则是"额外的时段"，与外层时刻取**并集**
  /// （CombinedTimeRule）。因为用户的心智是"下午再加一句每 2 小时"，
  /// 不是"把原来的时刻全部替换掉"。
  TimeRule buildTimeRule() {
    final base = FixedTimesRule(_timePoints);
    if (!hasIntervalRule) {
      return base;
    }
    final extra = IntervalRule(
      everyMinutes: intervalEveryMinutes,
      from: intervalFrom!,
      to: intervalTo!,
    );
    return CombinedTimeRule([base, extra]);
  }

  /// 间隔规则的输入是否完整且不自相矛盾。
  bool get hasIntervalRule =>
      intervalEveryMinutes > 0 &&
      intervalFrom != null &&
      intervalTo != null &&
      intervalFrom!.isBefore(intervalTo!);

  /// 展开成最终 [Task]。
  ///
  /// [id] 与 [nowMs] 由调用方给（页面用 `newId()` / `clock.now()`，测试用固定值）。
  Task toTask({
    required String id,
    required String memberId,
    required int nowMs,
    int sortOrder = 0,
  }) {
    return Task(
      id: id,
      memberId: memberId,
      name: name.trim(),
      note: note.trim().isEmpty ? null : note.trim(),
      iconId: iconId,
      repeat: effectiveRepeat,
      time: buildTimeRule(),
      course: course,
      status: TaskStatus.active,
      reminderEnabled: reminderEnabled,
      sortOrder: sortOrder,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    );
  }

  /// 从已有项目回填（编辑复用同一套表单）。
  static TaskDraft fromTask(Task t) {
    final draft = TaskDraft(
      name: t.name,
      note: t.note ?? '',
      iconId: t.iconId,
      memberId: t.memberId,
      repeat: t.repeat,
      course: t.course,
      reminderEnabled: t.reminderEnabled,
    );
    draft._timePoints = [...t.time.timesOn(_anyDay)];
    draft.timeTab = draft._timePoints.length == 1
        ? TimeTab.once
        : TimeTab.custom;
    return draft;
  }

  // ---------------------------------------------------------------------
  // 预览
  // ---------------------------------------------------------------------

  /// 置底的自然语言复述（ui-spec §2.3「预览」）。
  ///
  /// 分三段说清楚三件不同的事：**谁做什么** / **什么时候** / **做多久**。
  /// 时间部分必须真的从 [buildTimeRule] 展开，不能凭 Tab 猜——
  /// 否则用户打开间隔规则后预览还是老样子，就成了骗人的。
  String buildPreview({String? memberName}) {
    final who = memberName ?? '这件事';
    final title = hasName ? '$who · ${name.trim()}' : who;
    final parts = <String>[title, describeTime()];
    final courseText = describeCourse();
    if (courseText != null) {
      parts.add(courseText);
    }
    return parts.join('\n');
  }

  /// 「每天 7:30 / 12:30 / 18:30」这一句。
  String describeTime() {
    final rule = buildTimeRule();
    final times = rule.timesOn(LocalDate.today());
    final timePart = times.isEmpty
        ? '（还没有时间）'
        : times.length == 1
        ? times.first.toString()
        : times.map((t) => _hm(t)).join(' / ');

    final countPart = followMeals
        ? '跟随三餐'
        : times.length == 1
        ? '每天'
        : '每天 ${times.length} 次';

    final dayPart = describeRepeat();
    final base = '$countPart $dayPart $timePart';
    if (!hasIntervalRule) {
      return base;
    }
    final extra = IntervalRule(
      everyMinutes: intervalEveryMinutes,
      from: intervalFrom!,
      to: intervalTo!,
    );
    final spanHours = intervalEveryMinutes % 60 == 0
        ? '${intervalEveryMinutes ~/ 60} 小时'
        : '$intervalEveryMinutes 分钟';
    return '$base\n另加每 $spanHours一次'
        '（${extra.from}–${extra.to}，共 ${extra.count} 次）';
  }

  /// 「每天 / 每周一三五 / 隔周 / 每月 1 号」。
  String describeRepeat() {
    final r = repeat;
    if (r.isEveryDay) {
      return '每天';
    }
    final chunks = <String>[];
    final wd = r.weekdays;
    if (wd != null && wd.isNotEmpty) {
      chunks.add('周${_weekdayText(wd)}');
    }
    final n = r.everyNDays;
    if (n != null) {
      chunks.add('每 $n 天');
    }
    final parity = r.parity;
    if (parity != null) {
      chunks.add(
        switch (parity) {
          ParityFilter.oddWeeks => '单周',
          ParityFilter.evenWeeks => '双周',
          ParityFilter.workdays => '工作日',
          ParityFilter.weekends => '周末',
        },
      );
    }
    final md = r.monthDays;
    if (md != null && md.isNotEmpty) {
      chunks.add('每月 ${md.join('、')} 号');
    }
    return chunks.isEmpty ? '每天' : chunks.join(' ');
  }

  /// 「连着做 7 天，到 10/30 结束」；长期返回 null（不必说）。
  String? describeCourse() {
    if (course.isOpenEnded) {
      return null;
    }
    final total = course.totalDays;
    final end = course.end!;
    if (total != null) {
      return '连着做 $total 天，到 ${end.month}/${end.day} 结束';
    }
    return '${course.start!.month}/${course.start!.day}'
        ' → ${end.month}/${end.day}';
  }

  // ---------------------------------------------------------------------

  LocalTime _suggestNextTime() {
    final last = _timePoints.isEmpty ? null : _timePoints.last;
    if (last == null) {
      return TimeDefaults.evening;
    }
    return last.addMinutes(60).$2;
  }

  List<LocalTime> _dedup(List<LocalTime> times) =>
      (times.toList()..sort()).toSet().toList();

  static final LocalDate _anyDay = LocalDate(1970, 1, 1);
}

String _hm(LocalTime t) =>
    '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

String _weekdayText(Set<int> days) {
  const names = ['一', '二', '三', '四', '五', '六', '日'];
  final sorted = days.where((d) => d >= 1 && d <= 7).toList()..sort();
  return sorted.map((d) => names[d - 1]).join();
}
