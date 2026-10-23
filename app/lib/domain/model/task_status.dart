/// 打卡项目的生命周期状态。
///
/// 三者的语义区别是产品红线（需求 3.2.1「暂停/归档/删除的语义区别」），
/// **都不抹历史**，只是"以后还会不会生成待办"不同。
library;

enum TaskStatus {
  /// 生效中：正常生成槽位、正常提醒。
  active,

  /// 暂停：不提醒、不出现在今日；记录保留；随时恢复。
  paused,

  /// 归档：疗程结束或主动收起；不提醒；需要"再来一轮"才重新开始。
  archived,

  /// 删除：项目从列表消失；记录保留但不再挂在该项目下。
  ///
  /// 注意：这是"软删除标记"，不是物理删行——日历里仍要看到"那天做过这件事"。
  deleted,
}

extension TaskStatusX on TaskStatus {
  /// 是否应该在今日清单/排程里出现。
  bool get isLive => this == TaskStatus.active;

  /// 是否已结束（归档或删除）。
  bool get isFinished =>
      this == TaskStatus.archived || this == TaskStatus.deleted;

  String get labelZh => switch (this) {
    TaskStatus.active => '进行中',
    TaskStatus.paused => '已暂停',
    TaskStatus.archived => '已归档',
    TaskStatus.deleted => '已删除',
  };
}
