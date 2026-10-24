import 'package:famdaily/data/sync/sync_merge.dart';
import 'package:famdaily/data/sync/sync_protocol.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart';
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart';
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:flutter_test/flutter_test.dart';

const _t0 = 1700000000000;

domain.Member _member(
  String name, {
  int updatedAtMs = _t0,
  int? deletedAtMs,
  int sortOrder = 0,
  String? avatarId,
}) => domain.Member(
  id: 'm1',
  name: name,
  avatarId: avatarId,
  sortOrder: sortOrder,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs,
  deletedAtMs: deletedAtMs,
);

MemberDto _memberDto(
  String name, {
  int updatedAtMs = _t0,
  int? deletedAtMs,
  int sortOrder = 0,
  String? avatarId,
}) => MemberDto(
  id: 'm1',
  name: name,
  avatarId: avatarId,
  sortOrder: sortOrder,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs,
  deletedAtMs: deletedAtMs,
);

domain.Task _task(
  String name, {
  int updatedAtMs = _t0,
  int? deletedAtMs,
  String memberId = 'm1',
  TaskStatus status = TaskStatus.active,
}) => domain.Task(
  id: 't1',
  memberId: memberId,
  name: name,
  repeat: const domain.RepeatRule(),
  time: domain.FixedTimesRule([LocalTime(8, 0)]),
  course: domain.Course.none,
  status: status,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs,
  deletedAtMs: deletedAtMs,
);

TaskDto _taskDto(
  String name, {
  int updatedAtMs = _t0,
  int? deletedAtMs,
  String memberId = 'm1',
  TaskStatus status = TaskStatus.active,
}) => TaskDto(
  id: 't1',
  memberId: memberId,
  name: name,
  repeatJson: '{"v":1}',
  timeJson: '{"v":1,"type":"fixed","times":["08:00"]}',
  status: status,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs,
  deletedAtMs: deletedAtMs,
);

domain.CheckinRecord _checkin(
  CheckinState state, {
  int? doneAtMs = _t0,
  int? dueAtMinuteOfDay = 480,
  String? note,
}) => domain.CheckinRecord(
  id: 'c1',
  taskId: 't1',
  date: LocalDate(2025, 3, 1),
  slotIndex: 0,
  state: state,
  doneAtMs: doneAtMs,
  dueAtMinuteOfDay: dueAtMinuteOfDay,
  note: note,
);

CheckinDto _checkinDto(
  CheckinState state, {
  int? doneAtMs = _t0,
  int? dueAtMinuteOfDay = 480,
  String? note,
  bool deleted = false,
}) => CheckinDto(
  taskId: 't1',
  date: '2025-03-01',
  slotIndex: 0,
  state: state,
  doneAtMs: doneAtMs,
  dueAtMinuteOfDay: dueAtMinuteOfDay,
  note: note,
  updatedAtMs: _t0,
  deleted: deleted,
);

void main() {
  group('时间戳判定（members / tasks 共用）', () {
    test('远端更晚 → 远端胜', () {
      expect(
        pickByTimestamp(localUpdatedAtMs: 100, remoteUpdatedAtMs: 200),
        MergeWinner.remote,
      );
    });

    test('本地更晚 → 本地胜', () {
      expect(
        pickByTimestamp(localUpdatedAtMs: 300, remoteUpdatedAtMs: 200),
        MergeWinner.local,
      );
    });

    test('完全相等 → 远端胜（可复现）', () {
      // 相等时选远端不是因为它更"对"，而是因为两端都能算出同一个结果。
      // 选本地的话，A 认为 B 该赢、B 认为 A 该赢，两边永远不同，
      // 每次同步都互相覆盖一次。
      expect(
        pickByTimestamp(localUpdatedAtMs: 200, remoteUpdatedAtMs: 200),
        MergeWinner.remote,
      );
    });
  });

  group('成员合并', () {
    test('本地没有 → 远端', () {
      expect(mergeMember(null, _memberDto('妈妈')), MergeWinner.remote);
    });

    test('远端更晚 → 远端', () {
      expect(
        mergeMember(_member('爸爸', updatedAtMs: 100), _memberDto('爸爸2', updatedAtMs: 200)),
        MergeWinner.remote,
      );
    });

    test('本地更晚 → 本地', () {
      expect(
        mergeMember(_member('爸爸2', updatedAtMs: 300), _memberDto('爸爸', updatedAtMs: 200)),
        MergeWinner.local,
      );
    });

    test('两边完全一样 → identical（省一次写）', () {
      expect(
        mergeMember(_member('爸爸'), _memberDto('爸爸')),
        MergeWinner.identical,
      );
    });

    test('时刻相同但内容不同 → 远端（可复现）', () {
      expect(
        mergeMember(_member('A'), _memberDto('B')),
        MergeWinner.remote,
      );
    });

    group('改 vs 删：比 max(updated, deleted)', () {
      test('本地删得晚，远端改得早 → 保持删', () {
        expect(
          mergeMember(
            _member('爸爸', updatedAtMs: 100, deletedAtMs: 500),
            _memberDto('爸爸', updatedAtMs: 300),
          ),
          MergeWinner.local,
        );
      });

      test('本地删得早，远端改得晚 → 复活', () {
        expect(
          mergeMember(
            _member('爸爸', updatedAtMs: 100, deletedAtMs: 200),
            _memberDto('爸爸（改名）', updatedAtMs: 500),
          ),
          MergeWinner.remote,
        );
      });

      test('本地活着，远端删得晚 → 删', () {
        expect(
          mergeMember(
            _member('爸爸', updatedAtMs: 100),
            _memberDto('爸爸', updatedAtMs: 100, deletedAtMs: 400),
          ),
          MergeWinner.remote,
        );
      });

      test('两边都删，远端更晚 → 远端（都保持删）', () {
        expect(
          mergeMember(
            _member('爸爸', updatedAtMs: 100, deletedAtMs: 200),
            _memberDto('爸爸', updatedAtMs: 100, deletedAtMs: 300),
          ),
          MergeWinner.remote,
        );
      });
    });
  });

  group('项目合并', () {
    test('本地没有 → 远端', () {
      expect(
        mergeTask(null, _taskDto('吃药'), localDeleted: false),
        MergeWinner.remote,
      );
    });

    test('远端更晚 → 远端', () {
      expect(
        mergeTask(_task('吃药', updatedAtMs: 100), _taskDto('吃药2', updatedAtMs: 200),
            localDeleted: false),
        MergeWinner.remote,
      );
    });

    test('两边一致 → identical', () {
      expect(
        mergeTask(_task('吃药'), _taskDto('吃药'), localDeleted: false),
        MergeWinner.identical,
      );
    });

    test('status 不同 → 远端', () {
      expect(
        mergeTask(
          _task('吃药', status: TaskStatus.active),
          _taskDto('吃药', status: TaskStatus.archived),
          localDeleted: false,
        ),
        MergeWinner.remote,
      );
    });

    test('删 vs 改：删得晚保持删，改得晚复活', () {
      expect(
        mergeTask(
          _task('吃药', updatedAtMs: 100, deletedAtMs: 500),
          _taskDto('吃药', updatedAtMs: 300),
          localDeleted: false,
        ),
        MergeWinner.local,
      );
      expect(
        mergeTask(
          _task('吃药', updatedAtMs: 100, deletedAtMs: 200),
          _taskDto('吃药', updatedAtMs: 500),
          localDeleted: false,
        ),
        MergeWinner.remote,
      );
    });
  });

  group('打卡合并：逐格覆盖', () {
    test('本地没有 → 直接采用远端', () {
      final m = mergeCheckin(null, _checkinDto(CheckinState.makeup, doneAtMs: 999));
      expect(m.state, CheckinState.makeup);
      expect(m.doneAtMs, 999);
    });

    group('做过 vs 没做：做过一律赢，不看时间', () {
      test('本地 skipped，远端 done → done', () {
        final m = mergeCheckin(
          _checkin(CheckinState.skipped, doneAtMs: 100),
          _checkinDto(CheckinState.done, doneAtMs: 99999),
        );
        expect(m.state, CheckinState.done);
        expect(m.doneAtMs, 99999);
      });

      test('本地 done，远端 skipped → 保持 done', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 100),
          _checkinDto(CheckinState.skipped, doneAtMs: 99999),
        );
        expect(m.state, CheckinState.done);
        expect(m.doneAtMs, 100);
      });

      test('本地 makeup，远端 skipped → 保持 makeup', () {
        expect(
          mergeCheckin(
            _checkin(CheckinState.makeup, doneAtMs: 100),
            _checkinDto(CheckinState.skipped),
          ).state,
          CheckinState.makeup,
        );
      });

      test('两边都 skipped → skipped', () {
        expect(
          mergeCheckin(
            _checkin(CheckinState.skipped, doneAtMs: 100),
            _checkinDto(CheckinState.skipped, doneAtMs: 200),
          ).state,
          CheckinState.skipped,
        );
      });
    });

    group('两个都算做过：取 doneAtMs 早的（早的是当时真做的）', () {
      test('远端更早 → 用远端', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 5000),
          _checkinDto(CheckinState.done, doneAtMs: 1000),
        );
        expect(m.doneAtMs, 1000);
      });

      test('本地更早 → 用本地', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 1000),
          _checkinDto(CheckinState.done, doneAtMs: 5000),
        );
        expect(m.doneAtMs, 1000);
      });

      test('本地 done 早，远端 makeup 晚 → 保持 done 和早的时刻', () {
        // 这条是"补录不许覆盖当时真做"的核心场景。
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 1000),
          _checkinDto(CheckinState.makeup, doneAtMs: 5000),
        );
        expect(m.state, CheckinState.done);
        expect(m.doneAtMs, 1000);
      });

      test('本地 makeup 晚，远端 done 早 → 变成 done 且用早的时刻', () {
        final m = mergeCheckin(
          _checkin(CheckinState.makeup, doneAtMs: 5000),
          _checkinDto(CheckinState.done, doneAtMs: 1000),
        );
        expect(m.state, CheckinState.done);
        expect(m.doneAtMs, 1000);
      });

      test('同一刻：done 胜过 makeup', () {
        final m = mergeCheckin(
          _checkin(CheckinState.makeup, doneAtMs: 1000),
          _checkinDto(CheckinState.done, doneAtMs: 1000),
        );
        expect(m.state, CheckinState.done);
      });

      test('同一刻反向：本地 done 不被 makeup 拉下来', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 1000),
          _checkinDto(CheckinState.makeup, doneAtMs: 1000),
        );
        expect(m.state, CheckinState.done);
      });

      test('本地没有时刻、远端有 → 用远端的', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: null),
          _checkinDto(CheckinState.done, doneAtMs: 777),
        );
        expect(m.doneAtMs, 777);
      });

      test('远端没有时刻、本地有 → 保留本地的', () {
        final m = mergeCheckin(
          _checkin(CheckinState.done, doneAtMs: 777),
          _checkinDto(CheckinState.done, doneAtMs: null),
        );
        expect(m.doneAtMs, 777);
      });
    });

    group('备注', () {
      test('远端非空 → 覆盖', () {
        expect(
          mergeCheckin(
            _checkin(CheckinState.done, note: '旧'),
            _checkinDto(CheckinState.done, note: '新'),
          ).note,
          '新',
        );
      });

      test('远端为空 → 保留本地的（不能抹掉别人写的）', () {
        expect(
          mergeCheckin(
            _checkin(CheckinState.done, note: '写了备注'),
            _checkinDto(CheckinState.done, note: null),
          ).note,
          '写了备注',
        );
      });

      test('远端空字符串 → 当"没写"，不当"清空"', () {
        expect(
          mergeCheckin(
            _checkin(CheckinState.done, note: '写了备注'),
            _checkinDto(CheckinState.done, note: ''),
          ).note,
          '写了备注',
        );
      });
    });

    test('dueAtMinuteOfDay 取非空的那个（它是"改规则不影响历史"的凭据）', () {
      expect(
        mergeCheckin(
          _checkin(CheckinState.done, dueAtMinuteOfDay: 480),
          _checkinDto(CheckinState.done, dueAtMinuteOfDay: null),
        ).dueAtMinuteOfDay,
        480,
      );
      expect(
        mergeCheckin(
          _checkin(CheckinState.done, dueAtMinuteOfDay: null),
          _checkinDto(CheckinState.done, dueAtMinuteOfDay: 600),
        ).dueAtMinuteOfDay,
        600,
      );
    });
  });

  group('变化的可观测性', () {
    test('合并结果与本地相同 → checkinChanged 为 false', () {
      final local = _checkin(CheckinState.done, doneAtMs: 1000);
      final merged = mergeCheckin(local, _checkinDto(CheckinState.done, doneAtMs: 1000));
      expect(checkinChanged(local, merged), isFalse);
    });

    test('时刻被远端改早 → checkinChanged 为 true，且能给出一句人话', () {
      // 静默改数据是本项目最不该发生的事：用户看到"准时"变成"补"，
      // 没有任何提示，只能靠猜。至少要能在日志里查到
      // "什么时候、从什么变成什么"。
      //
      // 注意这里不能拿 `done` vs `skipped` 当例子：按规则本地 done
      // **不会**被远端 skipped 覆盖，那个场景 `checkinChanged` 本来就该是
      // false。真正会被改的是"两个都算做过、取更早的时刻"这一条。
      final local = _checkin(CheckinState.makeup, doneAtMs: 5000);
      final merged = mergeCheckin(
        local,
        _checkinDto(CheckinState.done, doneAtMs: 1000),
      );
      expect(checkinChanged(local, merged), isTrue);
      final msg = describeChange(local, merged);
      expect(msg, contains('t1'));
      expect(msg, contains('makeup'));
      expect(msg, contains('done'));
      expect(msg, contains('1000'));
    });

    test('本地 done 不会被远端 skipped 覆盖 —— 所以也算"没变化"', () {
      // 这条明确写出来，是为了防止将来有人"顺手优化"成按时间戳合并。
      final local = _checkin(CheckinState.done, doneAtMs: 1000);
      final merged = mergeCheckin(local, _checkinDto(CheckinState.skipped));
      expect(merged.state, CheckinState.done);
      expect(checkinChanged(local, merged), isFalse);
    });
  });

  group('设置合并', () {
    test('本地没有 → 取远端', () {
      expect(
        shouldTakeRemoteSetting(
          localUpdatedAtMs: null,
          remote: const SettingDto(key: 'k', value: 'v', updatedAtMs: 1),
        ),
        isTrue,
      );
    });

    test('远端更新 → 取远端；相等 → 也取远端（可复现）', () {
      expect(
        shouldTakeRemoteSetting(
          localUpdatedAtMs: 5,
          remote: const SettingDto(key: 'k', value: 'v', updatedAtMs: 6),
        ),
        isTrue,
      );
      expect(
        shouldTakeRemoteSetting(
          localUpdatedAtMs: 6,
          remote: const SettingDto(key: 'k', value: 'v', updatedAtMs: 6),
        ),
        isTrue,
      );
    });

    test('本地更新 → 保留本地', () {
      expect(
        shouldTakeRemoteSetting(
          localUpdatedAtMs: 9,
          remote: const SettingDto(key: 'k', value: 'v', updatedAtMs: 6),
        ),
        isFalse,
      );
    });
  });

  group('墓碑', () {
    test('服务端墓碑一律让本地这条消失（判过的判断不重做）', () {
      // 在客户端再判一次"删得晚不晚"，等于把同一套规则实现两遍；
      // 两边不一致时就会出现"一台删得掉、一台删不掉"。
      expect(shouldDropByTombstone(_checkinDto(CheckinState.done, deleted: true)), isTrue);
      expect(shouldDropByTombstone(_checkinDto(CheckinState.done)), isFalse);
    });
  });
}
