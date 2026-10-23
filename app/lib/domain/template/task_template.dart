/// 预置模板库（ui-spec §2.1「12 个模板定义」）。
///
/// 模板只做一件事：**给出一个合理的初值**。选中之后所有字段都能继续改，
/// 不存在"模板专属逻辑"——比如「吃药」的「跟随三餐」就是预填 3 个时刻，
/// 和用户在「自己定时刻」里手动加三个时间**完全等价**（ui-spec 明文要求）。
/// 这条约束决定了这里的 `timeRule` 只能是 `MealTimesRule` / `FixedTimesRule`
/// 这类普通规则，不许出现 `TemplateTimeRule`。
library;

import '../model/course.dart';
import '../model/local_time.dart';
import '../model/repeat_rule.dart';
import '../model/time_rule.dart';

/// 模板的分组（ui-spec 的三段标题）。
enum TemplateGroup {
  health('健康 · 给父母用得最多'),
  sports('运动'),
  study('学习 / 生活');

  const TemplateGroup(this.titleZh);

  final String titleZh;
}

/// 一个预置模板。
final class TaskTemplate {
  const TaskTemplate({
    required this.id,
    required this.name,
    required this.group,
    required this.iconId,
    required this.timeRule,
    this.note,
    this.repeat = RepeatRule.daily,
    this.course = Course.none,
  });

  final String id;

  /// 默认名字（用户可以改，如「吃药」→「降压药」）。
  final String name;

  final TemplateGroup group;

  /// 图标 id，见 `TaskIcons`。
  final String iconId;

  /// 默认时刻规则。
  final TimeRule timeRule;

  /// 事前说明；null = 不预填。
  final String? note;

  final RepeatRule repeat;
  final Course course;

  /// 非模板项（「都不是？自己起一个」）。
  static final blank = TaskTemplate(
    id: '',
    name: '',
    group: TemplateGroup.study,
    iconId: 'star',
    timeRule: _defaultSingleTime,
    repeat: RepeatRule.daily,
    course: Course.none,
  );

  /// 空白表单的默认时刻：20:00（大多数人"每天一件事"发生在晚上）。
  ///
  /// 用 `static final` 而非 const 的原因同 [TemplateLibrary.all]：
  /// `TimeRule` 是 sealed 的，子类只能写在 `time_rule.dart` 里，
  /// 这里不能为了 const 另造一个只含一个时刻的子类。
  static final TimeRule _defaultSingleTime =
      FixedTimesRule([TimeDefaults.evening]);

  bool get isBlank => id.isEmpty;
}

/// 全部模板，顺序即展示顺序（分组内保持 ui-spec 的列序）。
///
/// 用 `static final` 而不是 `const`：`FixedTimesRule` / `MealTimesRule`
/// 的构造器不是 const（它们在构造时就做去重、排序、防越界）。
/// 这不算妥协——模板是只读数据，`final` 一样安全。
abstract final class TemplateLibrary {
  static final List<TaskTemplate> all = List.unmodifiable([
    // ---- 健康 ----
    TaskTemplate(
      id: 'medicine',
      name: '吃药',
      group: TemplateGroup.health,
      iconId: 'pill',
      note: '每次几粒，饭后半小时',
      timeRule: MealTimesRule(
        anchors: const [MealAnchor.breakfast, MealAnchor.lunch, MealAnchor.dinner],
        offsetMinutes: 30,
      ),
    ),
    TaskTemplate(
      id: 'water',
      name: '喝水',
      group: TemplateGroup.health,
      iconId: 'water',
      note: '一次 300ml',
      timeRule: FixedTimesRule(_at(9, 0, 11, 0, 14, 0, 16, 0, 19, 0)),
    ),
    TaskTemplate(
      id: 'bp',
      name: '量血压',
      group: TemplateGroup.health,
      iconId: 'stethoscope',
      note: '静坐 5 分钟后测',
      timeRule: FixedTimesRule(_at(8, 0)),
    ),
    TaskTemplate(
      id: 'glucose',
      name: '测血糖',
      group: TemplateGroup.health,
      iconId: 'drop',
      note: '空腹或餐后 2 小时',
      timeRule: FixedTimesRule(_at(7, 30)),
    ),
    TaskTemplate(
      id: 'vitamin',
      name: '维生素',
      group: TemplateGroup.health,
      iconId: 'leaf',
      timeRule: FixedTimesRule(_at(8, 30)),
    ),
    TaskTemplate(
      id: 'sleep',
      name: '早睡',
      group: TemplateGroup.health,
      iconId: 'moon',
      timeRule: FixedTimesRule(_at(22, 30)),
    ),
    // ---- 运动 ----
    TaskTemplate(
      id: 'rope',
      name: '跳绳',
      group: TemplateGroup.sports,
      iconId: 'rope',
      timeRule: FixedTimesRule(_at(20, 0)),
    ),
    TaskTemplate(
      id: 'walk',
      name: '散步',
      group: TemplateGroup.sports,
      iconId: 'walk',
      timeRule: FixedTimesRule(_at(19, 0)),
    ),
    TaskTemplate(
      id: 'stretch',
      name: '拉伸',
      group: TemplateGroup.sports,
      iconId: 'stretch',
      timeRule: FixedTimesRule(_at(21, 0)),
    ),
    // ---- 学习 / 生活 ----
    TaskTemplate(
      id: 'homework',
      name: '作业',
      group: TemplateGroup.study,
      iconId: 'book',
      timeRule: FixedTimesRule(_at(19, 30)),
    ),
    TaskTemplate(
      id: 'reading',
      name: '阅读',
      group: TemplateGroup.study,
      iconId: 'reading',
      timeRule: FixedTimesRule(_at(20, 30)),
    ),
    TaskTemplate(
      id: 'wash',
      name: '洗漱',
      group: TemplateGroup.study,
      iconId: 'brush',
      timeRule: FixedTimesRule(_at(7, 0, 21, 30)),
    ),
  ]);

  static List<TaskTemplate> of(TemplateGroup group) =>
      all.where((t) => t.group == group).toList();

  static TaskTemplate? byId(String id) =>
      all.where((t) => t.id == id).firstOrNull;

  /// `_at(7, 30, 21, 0)` → `[07:30, 21:00]`，把模板表读起来还是像表格。
  static List<LocalTime> _at(int h1, int m1, [int? h2, int? m2, int? h3, int? m3,
      int? h4, int? m4, int? h5, int? m5, int? h6, int? m6]) {
    final pairs = [h1, m1, h2, m2, h3, m3, h4, m4, h5, m5, h6, m6];
    final out = <LocalTime>[];
    for (var i = 0; i + 1 < pairs.length; i += 2) {
      final h = pairs[i];
      final m = pairs[i + 1];
      if (h == null || m == null) {
        continue;
      }
      out.add(LocalTime(h, m));
    }
    return out;
  }
}
