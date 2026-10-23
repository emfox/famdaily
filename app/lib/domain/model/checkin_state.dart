/// 打卡结果的三种态（需求 3.6.2）。
///
/// > 补卡 ≠ 把没做标成做了。
///
/// 这两个语义一旦混在同一个按钮里，整个产品的数据就不可信了——
/// 而"可信"正是这个产品的全部价值。
library;

enum CheckinState {
  /// 做了，且按时。计入完成率 + 准时率。
  done,

  /// 做了，但过了时间才记录。计入完成率，**不计入**准时率。
  makeup,

  /// 明确承认没做（已结案）。不计入完成率分子。
  skipped,
}

extension CheckinStateX on CheckinState {
  /// 是否算"做了"（完成率的分子）。
  bool get countsAsDone =>
      this == CheckinState.done || this == CheckinState.makeup;

  /// 是否算"准时"（准时率的分子）。
  bool get countsAsOnTime => this == CheckinState.done;

  String get labelZh => switch (this) {
    CheckinState.done => '准时',
    CheckinState.makeup => '补',
    CheckinState.skipped => '没做',
  };

  /// 数据库里存的值（显式写死，避免以后改枚举顺序把历史数据读错）。
  String get dbValue => switch (this) {
    CheckinState.done => 'done',
    CheckinState.makeup => 'makeup',
    CheckinState.skipped => 'skipped',
  };
}

/// 数据库值 → 枚举。未知值返回 null（**不要**猜成 done，那等于凭空造出"已完成"）。
CheckinState? checkinStateFromDb(String? raw) => switch (raw) {
  'done' => CheckinState.done,
  'makeup' => CheckinState.makeup,
  'skipped' => CheckinState.skipped,
  _ => null,
};
