import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
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
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:famdaily/domain/stats/stats.dart' as domain;
import 'package:famdaily/feature/members/member_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

domain.Task _task(String id, String memberId) => domain.Task(
  id: id,
  memberId: memberId,
  name: '吃药',
  repeat: const domain.RepeatRule(),
  time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
  course: domain.Course.none,
  status: domain.TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

/// 把项目的槽位算出来落库（模拟启动重排的产物）。
///
/// `replaceSlots` 按日期区间**整体替换**，所以多个项目必须一次性写入——
/// 分两次调，第二次会把第一次的槽位删掉。这个坑真的踩过。
Future<void> _seedSlots(
  AppDatabase db,
  List<String> taskIds, {
  required domain.LocalDate from,
  required domain.LocalDate to,
}) async {
  final specs = <ScheduleSpec>[];
  for (final id in taskIds) {
    final t = await db.findTask(id);
    if (t != null) {
      specs.add(
        ScheduleSpec(
          taskId: t.id,
          repeat: t.repeat,
          time: t.time,
          course: t.course,
        ),
      );
    }
  }
  final result = Scheduler.expand(
    specs: specs,
    from: from,
    to: to,
    maxSlots: 2000,
  );
  await db.replaceSlots(
    [
      for (final s in result.slots)
        SlotsCompanion.insert(
          taskId: s.taskId,
          date: s.date,
          slotIndex: s.index,
          dueDate: s.dueAt.date,
          dueTime: s.dueAt.time,
        ),
    ],
    from: from,
    to: to,
    nowMs: _ts,
  );
}

void main() {
  late AppDatabase db;
  late MemberService service;
  var rescheduled = 0;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    rescheduled = 0;
    service = MemberService(db: db, onDataChanged: () async => rescheduled++);
  });

  tearDown(() async => db.close());

  Future<void> seed() async {
    for (final (i, name) in ['我', '妈妈', '爷爷'].indexed) {
      await db.into(db.members).insert(
        Mappers.memberToCompanion(
          domain.Member(
            id: 'm$i',
            name: name,
            sortOrder: i,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
    }
  }

  group('列表', () {
    test('按 sortOrder 排，带上各自的项目数', () async {
      await seed();
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t1', 'm1')),
      );
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t2', 'm1')),
      );

      final rows = await service.list();

      expect(rows.map((r) => r.member.name), ['我', '妈妈', '爷爷']);
      expect(rows.map((r) => r.taskCount), [0, 2, 0]);
      expect(rows.first.taskCountLabel, '还没安排打卡项');
      expect(rows[1].taskCountLabel, '2 项');
    });

    test('软删除的成员不出现在列表里', () async {
      await seed();
      await service.remove('m1', nowMs: _ts);

      final rows = await service.list();

      expect(rows.map((r) => r.member.id), ['m0', 'm2']);
    });
  });

  group('新增 / 修改', () {
    test('新增排到末尾，并触发一次重排', () async {
      await seed();
      await service.create(
        const domain.Member(
          id: 'm9',
          name: '小宝',
          sortOrder: 0, // 故意给 0：数据库应改写成末尾
          createdAtMs: _ts,
          updatedAtMs: _ts,
        ),
      );

      final rows = await service.list();
      expect(rows.map((r) => r.member.name), ['我', '妈妈', '爷爷', '小宝']);
      expect(rescheduled, 1);
    });

    test('改名之后重排（名字会进通知文案）', () async {
      await seed();
      final m = await service.find('m2');
      await service.update(m!.copyWith(name: '外公'), nowMs: _ts);

      expect((await service.find('m2'))!.name, '外公');
      expect(rescheduled, 1);
    });

    test('换头像落库', () async {
      await seed();
      final m = await service.find('m1');
      await service.update(m!.copyWith(avatarId: 'grandma'), nowMs: _ts);

      expect((await service.find('m1'))!.avatarId, 'grandma');
    });

    test('没有 onDataChanged 时写操作照常成功（不崩）', () async {
      final bare = MemberService(db: db);
      await bare.create(
        const domain.Member(
          id: 'x',
          name: '独自',
          sortOrder: 0,
          createdAtMs: _ts,
          updatedAtMs: _ts,
        ),
      );
      expect((await bare.list()).single.member.name, '独自');
    });
  });

  group('删除', () {
    test('软删除：历史记录还在，member 行还在（deletedAtMs 非空）', () async {
      await seed();
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t1', 'm2')),
      );
      // 先排槽位再打卡，验证删除不会连带抹掉记录。
      final day = domain.LocalDate(2025, 3, 3);
      await _seedSlots(db, ['t1'], from: day, to: day);
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: day,
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
        ),
        nowMs: _ts,
      );

      await service.remove('m2', nowMs: _ts);

      final row = await db.findMember('m2');
      expect(row, isNotNull);
      expect(row!.isDeleted, isTrue);
      expect(await db.listMembers(), hasLength(2));
      // 记录还在：日历翻回去仍能看到"爷爷 吃药 准时"。
      expect(await db.checkinsBetween(day, day), hasLength(1));
    });

    test('删除不存在的 id 不抛（幂等）', () async {
      await seed();
      await service.remove('nope', nowMs: _ts);
      expect((await service.list()), hasLength(3));
    });
  });

  group('排序', () {
    test('moved 上移/下移一位', () {
      expect(MemberService.moved(['a', 'b', 'c'], 2, 1), ['a', 'c', 'b']);
      expect(MemberService.moved(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a']);
    });

    test('moved 越界或原地不动时原样返回', () {
      expect(MemberService.moved(['a', 'b'], 0, 0), ['a', 'b']);
      expect(MemberService.moved(['a', 'b'], -1, 1), ['a', 'b']);
      expect(MemberService.moved(['a', 'b'], 0, 5), ['a', 'b']);
      // 返回的是新列表，改它不会污染入参。
      final src = ['a', 'b'];
      MemberService.moved(src, 0, 5).add('c');
      expect(src, ['a', 'b']);
    });

    test('reorder 落库后列表顺序跟着变', () async {
      await seed();
      await service.reorder(['m2', 'm0', 'm1'], nowMs: _ts);

      final rows = await service.list();
      expect(rows.map((r) => r.member.id), ['m2', 'm0', 'm1']);
      expect(rescheduled, 1);
    });
  });

  group('本月统计', () {
    test('只算自己的槽位，且不含未来日期', () async {
      await seed();
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t1', 'm1')),
      );
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t2', 'm2')),
      );

      final today = domain.LocalDate(2025, 3, 3);
      await _seedSlots(
        db,
        ['t1', 't2'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );

      // m1 只有 3/1 那天做了，3/2、3/3 悬空。
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: domain.LocalDate(2025, 3, 1),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
        ),
        nowMs: _ts,
      );

      final stats = await service.monthStats('m1', today: today);

      // 分母只有 m1 的 3 天，m2 的三条不掺进来。
      expect(stats.expected, 3);
      expect(stats.onTime, 1);
      expect(stats.unrecorded, 2);
    });

    test('没有项目时给空统计，完成率文本是「—」而不是 0%', () async {
      await seed();
      final stats = await service.monthStats('m0', today: domain.LocalDate(2025, 3, 3));

      expect(stats.expected, 0);
      expect(stats.percent(stats.completionRate), '—');
    });
  });

  group('一句话标题', () {
    test('有活也有数字', () {
      const summary = MemberSummary(
        member: domain.Member(
          id: 'm',
          name: '爷爷',
          sortOrder: 0,
          createdAtMs: 0,
          updatedAtMs: 0,
        ),
        taskCount: 3,
      );
      const stats = domain.StatsSummary(
        expected: 10,
        onTime: 8,
        makeup: 1,
        skipped: 1,
        unrecorded: 0,
      );

      expect(
        MemberService.headline(summary, stats),
        '3 个打卡项 · 本月完成 90.0%',
      );
    });

    test('一个项目都没排', () {
      const summary = MemberSummary(
        member: domain.Member(
          id: 'm',
          name: '小宝',
          sortOrder: 0,
          createdAtMs: 0,
          updatedAtMs: 0,
        ),
        taskCount: 0,
      );
      expect(
        MemberService.headline(summary, domain.StatsSummary.empty),
        '还没安排打卡项',
      );
    });
  });

  group('头像库', () {
    test('AvatarLibrary.ids 与 MemberAvatars.all 一一对应', () {
      // 两处任一处加了人忘了另一处，就会存进去一个查不到的 id，
      // 头像悄悄退回首字色块——这种 bug 不报错，最难发现。
      expect(
        MemberAvatars.all.map((a) => a.id).toList(),
        domain.AvatarLibrary.ids,
      );
    });

    test('未知 id 返回 null，交给首字兜底', () {
      expect(MemberAvatars.find('不存在的头像'), isNull);
      expect(MemberAvatars.find(null), isNull);
    });

    test('首字兜底色稳定：同名永远同色', () {
      const a = domain.Member(
        id: '1',
        name: '爷爷',
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0,
      );
      const b = domain.Member(
        id: '2',
        name: '爷爷',
        sortOrder: 5,
        createdAtMs: 9,
        updatedAtMs: 9,
      );
      expect(MemberAvatars.fallbackColor(a), MemberAvatars.fallbackColor(b));
      expect(a.initial, '爷');
    });
  });
}
