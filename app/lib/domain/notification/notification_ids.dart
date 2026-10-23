/// 通知 ID 的确定性推导。
///
/// 为什么不能随机：加完通知后要能"回头取消指定一条"。iOS/Android 都靠
/// 整数 ID 定位通知，随机 ID 就意味着"想起取消时已经找不到它了"，
/// 于是用户打了卡还天天被催——这是打卡类 App 最招人恨的 bug。
///
/// 所以 ID 完全由 `(项目, 日期, 当天第几次, 种类)` 推出来：
/// - 同一个槽位永远得到同一个 ID，重排多少次都不会撞车
/// - 打卡后按同样的输入算一遍，就能精确取消那一条和它的催办
///
/// ## 32 位约束
/// Android 的 `NotificationManager` 只接受 int32，而 Dart 的 int 是 64 位。
/// 这里全程按 31 位无符号整数运算（`0x7FFFFFFF`），保证两端都吃得下。
library;

import '../../domain/model/local_date.dart';

/// 通知种类。两类 ID 必须落在不同段，否则会互相覆盖。
enum ReminderKind {
  /// 到点提醒。
  due,

  /// 15 分钟后的二次催办。
  followup,
}

/// 通知 ID 计算器。
abstract final class NotificationIds {
  /// 取模基数：2^31 - 1（质数，且正好卡在 int32 上界内）。
  static const int _mod = 0x7FFFFFFF;

  /// 两类 ID 的分段步长。
  ///
  /// 不用 `kind * 2^30` 那种大跳的原因：要让"同一槽位的提醒与催办"
  /// 在数值上也拉开，便于日志里肉眼分辨是哪种通知。
  static const int _kindStride = 100000000;

  /// 算出某槽位某类通知的 ID。
  ///
  /// [index] 是"当天第几次"，[kind] 区分提醒与催办。
  static int of({
    required String taskId,
    required LocalDate date,
    required int index,
    required ReminderKind kind,
  }) {
    // FNV-1a 32 位：对短字符串分布均匀，且实现只有几行，不容易写错。
    var hash = 0x811C9DC5;
    for (final byte in taskId.codeUnits) {
      hash = (hash ^ (byte & 0xFF)) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    // 把日期与序号混进来，同一个项目的不同天/不同次不能撞。
    hash = (hash ^ (date.epochDay & 0xFFFFFFFF)) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
    hash = (hash ^ (index & 0xFF)) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;

    // 1 起：0 在部分平台上被当成"无效 ID"。
    final base = 1 + hash % (_mod - _kindStride);
    return base + (kind == ReminderKind.followup ? _kindStride : 0);
  }

  /// 提醒 ID（到点）。
  static int due(String taskId, LocalDate date, int index) =>
      of(taskId: taskId, date: date, index: index, kind: ReminderKind.due);

  /// 催办 ID（到点后 15 分钟）。
  static int followup(String taskId, LocalDate date, int index) =>
      of(taskId: taskId, date: date, index: index, kind: ReminderKind.followup);
}
