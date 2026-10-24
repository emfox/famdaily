import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/data/sync/sync_protocol.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:flutter_test/flutter_test.dart';

import 'sync_harness.dart';

/// 两个**真的** `AppDatabase` 互推。
///
/// 这一层的价值在于「落库」：`sync_merge_test.dart` 已经证明"谁该赢"算得对，
/// 这里要证明"赢了之后库里那行长对了"——外键、唯一索引、
/// `rules_effective_from` 的转换器、照片字段，全都是只有真库才会报错的东西。

const _t0 = 1735689600000; // 2025-01-01T00:00:00Z
final _today = domain.LocalDate(2025, 1, 1);

var _idSeq = 0;
String _newId() => 'gen-${_idSeq++}';

domain.Member _member(
  String id,
  String name, {
  int? updatedAtMs,
  int? deletedAtMs,
}) => domain.Member(
  id: id,
  name: name,
  avatarId: 'dad',
  sortOrder: 0,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs ?? _t0,
  deletedAtMs: deletedAtMs,
);

domain.Task _task(
  String id, {
  String memberId = 'm1',
  String name = '吃药',
  domain.TaskStatus status = domain.TaskStatus.active,
  domain.Course course = domain.Course.none,
  int? updatedAtMs,
  int? deletedAtMs,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: name,
  note: '饭后半小时',
  repeat: const domain.RepeatRule(weekdays: {1, 3, 5}),
  time: domain.FixedTimesRule([domain.LocalTime(8, 0), domain.LocalTime(20, 0)]),
  course: course,
  status: status,
  createdAtMs: _t0,
  updatedAtMs: updatedAtMs ?? _t0,
  deletedAtMs: deletedAtMs,
);

domain.CheckinRecord _checkin(
  String id, {
  String taskId = 't1',
  int slotIndex = 0,
  domain.CheckinState state = domain.CheckinState.done,
  int? doneAtMs,
  String? note,
  String? photoPath,
}) => domain.CheckinRecord(
  id: id,
  taskId: taskId,
  date: _today,
  slotIndex: slotIndex,
  state: state,
  doneAtMs: doneAtMs ?? _t0,
  dueAtMinuteOfDay: 480,
  note: note,
  photoPath: photoPath,
);

void main() {
  // 这个文件**刻意**同时开两个 AppDatabase 互推。drift 见到同一个
  // QueryExecutor 被用两次会警告"可能数据损坏"，但两个内存库各有各的
  // executor（openTestConnection 每次新建），警告是误报。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase a;
  late AppDatabase b;

  setUp(() async {
    a = AppDatabase.forTesting(openTestConnection());
    b = AppDatabase.forTesting(openTestConnection());
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  /// A → B 推一次。
  Future<int> aToB() async {
    final bundle = await bundleOf(a);
    return applyBundle(b, bundle, nowMs: _t0, newId: _newId);
  }

  /// B → A 推一次。
  Future<int> bToA() async {
    final bundle = await bundleOf(b);
    return applyBundle(a, bundle, nowMs: _t0, newId: _newId);
  }

  /// 造一份 A 侧的基线数据：一个成员、一个项目、一条打卡、一个设置。
  Future<void> seedA() async {
    await a.into(a.members).insert(Mappers.memberToCompanion(_member('m1', '我')));
    await a.into(a.tasks).insert(Mappers.taskToCompanion(_task('t1')));
    await a
        .into(a.checkins)
        .insert(Mappers.checkinToCompanion(_checkin('c1'), _t0));
    await a.setSetting('reminders.enabled', 'true', nowMs: _t0);
  }

  group('双向互推后逐行相等', () {
    test('A 有数据、B 是空的：推过去之后两边一模一样', () async {
      await seedA();

      await aToB();

      final sa = await snapshotOf(a);
      final sb = await snapshotOf(b);
      expect(sb, isNotEmpty);
      expect(sb, sa);
    });

    test('推两次不会变成两份（幂等）', () async {
      await seedA();
      await aToB();
      final afterFirst = await snapshotOf(b);

      final writes = await aToB();

      expect(await snapshotOf(b), afterFirst);
      // 第二次推的是完全一样的内容，一行都不该写。
      expect(writes, 0);
    });

    test('B 改过之后再 A→B→A 推一圈，两边仍然相等', () async {
      await seedA();
      await aToB();

      // B 侧真改：成员改名（时间更新）
      await b.updateMember(_member('m1', '爸爸', updatedAtMs: _t0 + 1000),
          nowMs: _t0 + 1000);

      await bToA(); // A 拿到改名
      await aToB(); // A 再推回去（此时两边一样，应当零写入）

      expect(await snapshotOf(a), await snapshotOf(b));
      expect((await a.findMember('m1'))!.name, '爸爸');
    });

    test('两端各自新增不同的成员，互推一轮后两边都有两个', () async {
      await a.into(a.members).insert(Mappers.memberToCompanion(_member('m1', '我')));
      await b.into(b.members).insert(Mappers.memberToCompanion(_member('m2', '妈妈')));

      await aToB();
      await bToA();

      // 两边都在本地"追加到末尾"，所以 m1/m2 各自 sortOrder=0。
      // 同步**不重新编号**：编号是本地展示顺序，硬掰成一致会让用户在
      // 两台手机上看到的顺序和自己在任一台上调的顺序都不一样。
      // 断言"两个成员两边都有"就够了，顺序由各端的 sortOrder 自己决定。
      expect((await a.listMembers()).map((m) => m.id).toSet(), {'m1', 'm2'});
      expect((await b.listMembers()).map((m) => m.id).toSet(), {'m1', 'm2'});
      expect(await snapshotOf(a), await snapshotOf(b));
    });
  });

  group('改后删 / 删后改', () {
    test('A 改、B 删：删除更晚 → 两边都是删', () async {
      await seedA();
      await aToB();

      // A 先改名（t+1000）
      await a.updateMember(_member('m1', '爸爸', updatedAtMs: _t0 + 1000),
          nowMs: _t0 + 1000);
      // B 后删（t+2000）
      await b.deleteMember('m1', nowMs: _t0 + 2000);

      await aToB();
      await bToA();
      await aToB();

      final ma = await a.findMember('m1');
      final mb = await b.findMember('m1');
      expect(ma!.deletedAtMs, _t0 + 2000);
      expect(mb!.deletedAtMs, _t0 + 2000);
      expect(await snapshotOf(a), await snapshotOf(b));
    });

    test('A 删、B 改：改更晚 → 两边都复活，名字是改后的', () async {
      await seedA();
      await aToB();

      // A 先删（t+1000）
      await a.deleteMember('m1', nowMs: _t0 + 1000);
      // B 后改名（t+2000）
      await b.updateMember(_member('m1', '爸爸', updatedAtMs: _t0 + 2000),
          nowMs: _t0 + 2000);

      await aToB();
      await bToA();
      await aToB();

      final ma = (await a.findMember('m1'))!;
      final mb = (await b.findMember('m1'))!;
      expect(ma.isDeleted, isFalse);
      expect(mb.isDeleted, isFalse);
      expect(mb.name, '爸爸');
      expect(await snapshotOf(a), await snapshotOf(b));
    });

    test('一端删成员、另一端还没见过这个成员 → 另一端不该"复活"它', () async {
      // A 侧：m1 已删；B 侧：什么都没有
      await a.into(a.members).insert(
        Mappers.memberToCompanion(_member('m1', '我', deletedAtMs: _t0 + 5)),
      );

      await aToB();

      // B 侧要看到这条"已删"，而不是看到一个人。看得到墓碑，
      // 下次才对得上号；看不到就会在 B 上新建成"活着"的人。
      final row = await b.findMember('m1');
      expect(row, isNotNull);
      expect(row!.isDeleted, isTrue);
      expect(await b.listMembers(), isEmpty);
    });
  });

  group('项目：规则与疗程', () {
    test('规则 JSON、疗程起止、生效日、状态都原样搬过去', () async {
      await a.into(a.members).insert(Mappers.memberToCompanion(_member('m1', '我')));
      await a.into(a.tasks).insert(Mappers.taskToCompanion(_task(
            't1',
            course: domain.Course.days(domain.LocalDate(2025, 1, 1), 7),
            status: domain.TaskStatus.paused,
          )));
      // 生效日是 updateTask 才管的列，直接写库模拟"编辑过一次规则"。
      await (a.update(a.tasks)..where((t) => t.id.equals('t1'))).write(
        TasksCompanion(
          rulesEffectiveFrom: Value(domain.LocalDate(2024, 12, 20)),
        ),
      );

      await aToB();

      final row = await (b.select(b.tasks)..where((t) => t.id.equals('t1')))
          .getSingle();
      expect(row.courseStart, domain.LocalDate(2025, 1, 1));
      expect(row.courseEnd, domain.LocalDate(2025, 1, 7));
      expect(row.courseTotalDays, 7);
      expect(row.rulesEffectiveFrom, domain.LocalDate(2024, 12, 20));
      expect(row.status, 'paused');
      // 规则内容：走 domain 比，比字节可靠。
      final t = Mappers.taskFromRow(row);
      expect(t.repeat.weekdays, {1, 3, 5});
      expect((t.time as domain.FixedTimesRule).times, [
        domain.LocalTime(8, 0),
        domain.LocalTime(20, 0),
      ]);
    });

    test('B 侧把项目删了：软删除 + status 一起过去，打卡记录不动', () async {
      await seedA();
      await aToB();

      await b.deleteTask('t1', nowMs: _t0 + 1000);

      await bToA();

      final ta = await a.findTask('t1');
      expect(ta!.status, domain.TaskStatus.deleted);
      expect(ta.deletedAtMs, _t0 + 1000);
      expect(ta.isLive, isFalse);
      // 打卡还在（历史不能因为删项目而消失）
      expect(await a.checkinsOn(_today), hasLength(1));
    });
  });

  group('打卡', () {
    test('远端新打卡：本地没有就新建一条，id 是本机生成的', () async {
      await seedA();

      await aToB();

      final onB = await b.checkinsOn(_today);
      expect(onB, hasLength(1));
      expect(onB.single.state, domain.CheckinState.done);
      // 本地 id 是 B 自己生成的，不是 A 的 c1
      expect(onB.single.id, isNot('c1'));
      expect(onB.single.dueAtMinuteOfDay, 480);
    });

    test('本地已有的打卡被远端改状态：沿用本地 id，不新建', () async {
      await seedA();
      // A 侧那条本来就不是 done，这样"远端更强"是干净的。
      // 不能走 upsertCheckin：它按"已完成优先"会拒绝把 done 降成 skipped。
      await (a.update(a.checkins)..where((t) => t.id.equals('c1'))).write(
        const CheckinsCompanion(
          state: Value('skipped'),
          doneAtMs: Value(null),
        ),
      );
      await aToB();
      final local = (await b.checkinsOn(_today)).single;
      expect(local.state, domain.CheckinState.skipped);

      // A 侧改做补卡
      await a.upsertCheckin(
        _checkin('c1', state: domain.CheckinState.makeup, doneAtMs: _t0 + 60_000),
        nowMs: _t0,
      );

      await aToB();

      final onB = await b.checkinsOn(_today);
      expect(onB, hasLength(1));
      expect(onB.single.id, local.id);
      expect(onB.single.state, domain.CheckinState.makeup);
      expect(onB.single.doneAtMs, _t0 + 60_000);
    });

    test('照片是本地路径，不会被远端覆盖，也不会被远端抹掉', () async {
      await seedA();
      // A 侧没照片
      await aToB();
      // 给 B 本地那条加上照片
      final local = (await b.checkinsOn(_today)).single;
      await b.upsertCheckin(
        domain.CheckinRecord(
          id: local.id,
          taskId: local.taskId,
          date: local.date,
          slotIndex: local.slotIndex,
          state: local.state,
          doneAtMs: local.doneAtMs,
          dueAtMinuteOfDay: local.dueAtMinuteOfDay,
          photoPath: 'photos/2025/01/x.jpg',
        ),
        nowMs: _t0 + 1,
      );

      // A 侧换个 note 再推下来
      await a.upsertCheckin(
        _checkin('c1', note: '血压 120/80'),
        nowMs: _t0,
      );
      await aToB();

      final after = (await b.checkinsOn(_today)).single;
      expect(after.photoPath, 'photos/2025/01/x.jpg');
      expect(after.note, '血压 120/80');
    });

    test('A 撤销打卡后 B 仍留着（直到服务端判墓碑）—— 记录已知边界', () async {
      // 这条**不是**在夸当前行为，是把边界钉住。
      //
      // 客户端推的是"我的全量当前状态"，A 撤销后那句 clearCheckin 是真删行，
      // 于是 A 的推里根本没有这条；而 B 的这条是 B 自己库里已有的。
      // 光靠"推的内容里没有"没法表达"我删了"—— 那是服务端按
      // `updated_at_ms` 判墓碑之后再发下来的事（见协议文档 §7）。
      //
      // 所以这里断言：A 撤销后 A 空、B 还在。真正的清理在同步服务里由
      // 服务端墓碑完成，见下一条用例。
      await seedA();
      await aToB();
      expect(await b.checkinsOn(_today), hasLength(1));

      await a.clearCheckin(
        taskId: 't1',
        date: _today,
        slotIndex: 0,
        today: _today,
        nowMs: _t0 + 10,
      );
      await aToB();

      expect(await a.checkinsOn(_today), isEmpty);
      expect(await b.checkinsOn(_today), hasLength(1));
    });

    test('A 推来的墓碑（deleted）会把 B 那条删掉', () async {
      await seedA();
      await aToB();
      expect(await b.checkinsOn(_today), hasLength(1));

      // 直接构造一个墓碑：服务端在"别人更晚地撤销过"时会发这个
      final tombstone = SyncBundle(
        members: const [],
        tasks: const [],
        checkins: [
          CheckinDto(
            taskId: 't1',
            date: _today.toString(),
            slotIndex: 0,
            state: domain.CheckinState.done,
            updatedAtMs: _t0 + 9000,
            deleted: true,
          ),
        ],
        settings: const [],
      );
      await applyBundle(b, tombstone, nowMs: _t0, newId: _newId);

      expect(await b.checkinsOn(_today), isEmpty);
    });

    test('打卡合并走"做过优先"：本地 done 不会被远端 skipped 抹掉', () async {
      await seedA();
      await aToB();

      // A 侧把它标成 skipped（A 上本来是 done，先改成 skipped）
      await a.upsertCheckin(
        _checkin('c1', state: domain.CheckinState.skipped, doneAtMs: _t0 + 5000),
        nowMs: _t0,
      );

      // 但 B 上仍是 done。A 推过来时 mergeCheckin 判"远端不更强"，
      // 于是 B 保持 done。
      await aToB();

      expect((await b.checkinsOn(_today)).single.state, domain.CheckinState.done);
    });
  });

  group('设置', () {
    test('远端更新的设置会覆盖本地，且时间戳用远端的', () async {
      await seedA();
      await aToB();

      await a.setSetting('reminders.enabled', 'false', nowMs: _t0 + 5000);
      await aToB();

      expect(await b.getSetting('reminders.enabled'), 'false');
      expect(await b.settingUpdatedAt('reminders.enabled'), _t0 + 5000);
    });

    test('本地更新更晚时远端覆盖不了', () async {
      await seedA();
      await aToB();

      // B 侧更晚地改成 false
      await b.setSetting('reminders.enabled', 'false', nowMs: _t0 + 9000);

      await aToB(); // A 的 t0 版本来势更早

      expect(await b.getSetting('reminders.enabled'), 'false');
      expect(await b.settingUpdatedAt('reminders.enabled'), _t0 + 9000);
    });

    test('不在白名单里的设置（sync.* 自己）不参与同步', () async {
      await a.setSetting('sync.cursor', '123', nowMs: _t0);
      await a.setSetting('reminders.lastScheduledFor', '2025-01-01', nowMs: _t0);

      final bundle = await bundleOf(a);

      expect(bundle.settings, isEmpty);
    });
  });
}
