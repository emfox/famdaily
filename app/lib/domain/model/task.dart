/// 打卡项目：某成员的某件固定事项（吃药、跳绳……）。
library;

import 'course.dart';
import 'local_date.dart';
import 'repeat_rule.dart';
import 'task_status.dart';
import 'time_rule.dart';

/// 一个打卡项目。
///
/// 时间规则是两个**正交**维度（需求 3.2.1）：哪天做 × 几点做，再叠疗程。
/// 三者分开存，不合成"排程表达式字符串"——合成会丢掉维度信息，
/// 编辑界面的三层折叠表单就没法回显了。
final class Task {
  const Task({
    required this.id,
    required this.memberId,
    required this.name,
    required this.repeat,
    required this.time,
    required this.course,
    required this.status,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.note,
    this.iconId,
    this.reminderEnabled = true,
    this.sortOrder = 0,
    this.deletedAtMs,
  });

  final String id;
  final String memberId;
  final String name;

  /// 事前说明（"白色药片 2 粒，饭后半小时"），区别于打卡时的备注。
  final String? note;

  /// 图标 id；null = 用名字首字色块。
  final String? iconId;

  final RepeatRule repeat;
  final TimeRule time;
  final Course course;

  final TaskStatus status;

  /// 到点系统通知开关。
  final bool reminderEnabled;

  final int sortOrder;
  final int createdAtMs;
  final int updatedAtMs;
  final int? deletedAtMs;

  /// 是否参与排程（只有 active 才算）。
  bool get isLive => status.isLive && deletedAtMs == null;

  /// 某天有几次（用于列表副标题"每天 3 次"）。
  ///
  /// 用 [Course.start] 作参照日；长期项目就没有固定参照，
  /// 退化为"以 Course.none 判断"，时刻规则与日期无关的形态仍然正确。
  int get timesPerDayHint {
    final ref = course.start ?? Course.none.start;
    if (ref == null) {
      // 长期项目：时刻规则里唯一与日期相关的是"跟随三餐"，与具体日期无关，
      // 用一个固定参照日即可（1970-01-01）。
      return time.timesOn(_referenceDate).length;
    }
    return time.timesOn(ref).length;
  }

  Task copyWith({
    String? memberId,
    String? name,
    String? note,
    String? iconId,
    RepeatRule? repeat,
    TimeRule? time,
    Course? course,
    TaskStatus? status,
    bool? reminderEnabled,
    int? sortOrder,
    int? updatedAtMs,
    int? deletedAtMs,
  }) => Task(
    id: id,
    memberId: memberId ?? this.memberId,
    name: name ?? this.name,
    note: note ?? this.note,
    iconId: iconId ?? this.iconId,
    repeat: repeat ?? this.repeat,
    time: time ?? this.time,
    course: course ?? this.course,
    status: status ?? this.status,
    reminderEnabled: reminderEnabled ?? this.reminderEnabled,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    deletedAtMs: deletedAtMs ?? this.deletedAtMs,
  );

  /// 长期项目没有疗程起始日时，用一个固定参照日数次数。
  static final LocalDate _referenceDate = LocalDate(1970, 1, 1);
}
