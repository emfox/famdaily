/// 同步的合并规则。**纯函数，不碰数据库、不碰 Flutter。**
///
/// 单独一个文件是因为：这些规则是"两个人的两台手机都改过同一条"时
/// 唯一能决定结果的地方，而它们错了不会有任何异常 —— 只会让某个数字
/// 悄悄不对。所以每一条都要能被单独测到，一格一格地测。
library;

import 'dart:math' as math;

import '../../domain/model/checkin.dart' as domain;
import '../../domain/model/checkin_state.dart';
import '../../domain/model/member.dart' as domain;
import '../../domain/model/task.dart' as domain;

import 'sync_protocol.dart';

/// 合并的胜者。
enum MergeWinner {
  /// 本地赢：远端那条应当被丢弃。
  local,

  /// 远端赢：应当把远端那条写进本地。
  remote,

  /// 完全相同：什么都不用做（但**不算错**，只是省一次写）。
  identical,
}

/// members / tasks 的 LWW 判定。
///
/// 规则：`updated_at_ms` 大者胜；**相等时远端胜**。
///
/// 相等时选远端不是因为它更"对"，而是因为**它可复现**：两端都能算出
/// 同一个结果，不会出现 A 认为 B 赢、B 认为 A 赢，然后两边永远不同、
/// 每次同步都互相覆盖一次。
MergeWinner pickByTimestamp({
  required int localUpdatedAtMs,
  required int remoteUpdatedAtMs,
}) {
  if (remoteUpdatedAtMs > localUpdatedAtMs) {
    return MergeWinner.remote;
  }
  if (remoteUpdatedAtMs < localUpdatedAtMs) {
    return MergeWinner.local;
  }
  return MergeWinner.remote;
}

/// 成员合并。远端一定被采纳时返回 [MergeWinner.remote]。
///
/// 「改 vs 删」：比 `max(updated_at_ms, deleted_at_ms)`。
/// 改得晚 → 复活；删得晚 → 保持删。
MergeWinner mergeMember(domain.Member? local, MemberDto remote) {
  if (local == null) {
    return MergeWinner.remote;
  }
  final localAt = math.max(local.updatedAtMs, local.deletedAtMs ?? 0);
  final remoteAt = math.max(remote.updatedAtMs, remote.deletedAtMs ?? 0);
  if (remoteAt > localAt) {
    return MergeWinner.remote;
  }
  if (remoteAt < localAt) {
    return MergeWinner.local;
  }
  // 时刻完全一样：比内容。内容也一样就是 identical，省一次写。
  final same =
      local.name == remote.name &&
      local.avatarId == remote.avatarId &&
      local.sortOrder == remote.sortOrder &&
      (local.deletedAtMs ?? 0) == (remote.deletedAtMs ?? 0);
  return same ? MergeWinner.identical : MergeWinner.remote;
}

/// 项目合并。规则同 [mergeMember]。
///
/// 这里**故意不比较规则 JSON 的内容**：`repeatJson`/`timeJson` 可能因为
/// 字段顺序不同而字符串不同，但语义一样。按时间戳判定已经足够 ——
/// 两台设备在同一毫秒改了同一个项目，取远端（可复现）就行。
MergeWinner mergeTask(
  domain.Task? local,
  TaskDto remote, {
  required bool localDeleted,
}) {
  if (local == null) {
    return MergeWinner.remote;
  }
  final localAt = math.max(local.updatedAtMs, local.deletedAtMs ?? 0);
  final remoteAt = math.max(remote.updatedAtMs, remote.deletedAtMs ?? 0);
  if (remoteAt > localAt) {
    return MergeWinner.remote;
  }
  if (remoteAt < localAt) {
    return MergeWinner.local;
  }
  final same =
      local.name == remote.name &&
      local.memberId == remote.memberId &&
      (local.note ?? '') == (remote.note ?? '') &&
      (local.iconId ?? '') == (remote.iconId ?? '') &&
      local.status == remote.status &&
      local.reminderEnabled == remote.reminderEnabled &&
      local.sortOrder == remote.sortOrder &&
      (local.deletedAtMs ?? 0) == (remote.deletedAtMs ?? 0) &&
      localDeleted == (remote.deletedAtMs != null);
  return same ? MergeWinner.identical : MergeWinner.remote;
}

/// 打卡合并后的结果。
final class MergedCheckin {
  const MergedCheckin({
    required this.state,
    required this.doneAtMs,
    required this.dueAtMinuteOfDay,
    required this.note,
  });

  final CheckinState state;
  final int? doneAtMs;
  final int? dueAtMinuteOfDay;
  final String? note;

  bool sameAs(MergedCheckin other) =>
      state == other.state &&
      doneAtMs == other.doneAtMs &&
      dueAtMinuteOfDay == other.dueAtMinuteOfDay &&
      note == other.note;
}

/// 打卡状态的合并。
///
/// **不看时间戳。** 打卡不是"最新的话就对"，而是"做过就是做过"。
/// 用时间戳会导致"妈妈晚半小时补录了一次，把爸爸当时真做的 done 覆盖成
/// makeup"，准时率就悄悄掉了 —— 而用户完全不知道发生了什么。
///
/// 四条规则：
/// 1. `done`/`makeup` 胜过 `skipped`。
/// 2. 两个都算"做过"时，取 `doneAtMs` **早**的（早的是当时真做的，
///    晚的是后来补录的）。
/// 3. 时刻完全相同时，`done` 胜过 `makeup`（准时率不能被一次补录拉下来）。
/// 4. `note` 只在远端非空时覆盖；空字符串当"没写"，不当"清空"。
MergedCheckin mergeCheckin(domain.CheckinRecord? local, CheckinDto remote) {
  if (local == null) {
    return MergedCheckin(
      state: remote.state,
      doneAtMs: remote.doneAtMs,
      dueAtMinuteOfDay: remote.dueAtMinuteOfDay,
      note: remote.note,
    );
  }

  final localDone = local.state.countsAsDone;
  final remoteDone = remote.state.countsAsDone;

  CheckinState state;
  int? doneAtMs;

  if (localDone && remoteDone) {
    final a = local.doneAtMs;
    final b = remote.doneAtMs;
    if (a == null) {
      state = remote.state;
      doneAtMs = b;
    } else if (b == null) {
      state = local.state;
      doneAtMs = a;
    } else if (b < a) {
      state = remote.state;
      doneAtMs = b;
    } else if (b > a) {
      state = local.state;
      doneAtMs = a;
    } else {
      // 同一刻：done 比 makeup 强。
      state = local.state == CheckinState.done
          ? CheckinState.done
          : remote.state;
      doneAtMs = a;
    }
  } else if (remoteDone) {
    state = remote.state;
    doneAtMs = remote.doneAtMs;
  } else {
    state = local.state;
    doneAtMs = local.doneAtMs;
  }

  return MergedCheckin(
    state: state,
    doneAtMs: doneAtMs,
    // `dueAtMinuteOfDay` 是"改规则不影响历史"的凭据，不该被一次
    // 没有它的推送抹掉。所以取非空的那个。
    dueAtMinuteOfDay: remote.dueAtMinuteOfDay ?? local.dueAtMinuteOfDay,
    note: (remote.note != null && remote.note!.isNotEmpty)
        ? remote.note
        : local.note,
  );
}

/// 服务端墓碑该不该让本地的这条消失。
///
/// **不做"删得晚不晚"的判断**：那是服务端的事，它已经判过了才发墓碑下来。
/// 客户端只需要知道"这条被撤销了"。在这里再判一次，等于把同一套规则
/// 实现两遍，两边不一致时就会出现"一台删得掉、一台删不掉"。
bool shouldDropByTombstone(CheckinDto remote) => remote.deleted;

/// 设置合并：`updatedAtMs` 大者胜，相等时远端胜（与 members 同理）。
bool shouldTakeRemoteSetting({
  required int? localUpdatedAtMs,
  required SettingDto remote,
}) {
  if (localUpdatedAtMs == null) {
    return true;
  }
  return remote.updatedAtMs >= localUpdatedAtMs;
}

/// 判断一条远端打卡是否"真的和本地不一样"，用来决定要不要写库 + 打日志。
///
/// 静默改状态是本项目最不该发生的事：用户勾了却显示没做，没有任何提示，
/// 只能靠猜。所以合并结果与本地不同时，必须能留痕（[describeChange]）。
bool checkinChanged(domain.CheckinRecord local, MergedCheckin merged) =>
    local.state != merged.state ||
    local.doneAtMs != merged.doneAtMs ||
    local.dueAtMinuteOfDay != merged.dueAtMinuteOfDay ||
    (local.note ?? '') != (merged.note ?? '');

/// 人话描述一次静默的状态变化，给调试日志用。
String describeChange(domain.CheckinRecord local, MergedCheckin merged) {
  final where = '${local.taskId} ${local.date} #${local.slotIndex}';
  return '$where: ${local.state.dbValue}(doneAt=${local.doneAtMs}) '
      '→ ${merged.state.dbValue}(doneAt=${merged.doneAtMs})';
}
