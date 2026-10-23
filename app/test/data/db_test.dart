import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'package:flutter_test/flutter_test.dart';

const _now = 1735689600000; // 2025-01-01T00:00:00Z

domain.Member _member(String id, String name) => domain.Member(
  id: id,
  name: name,
  sortOrder: 0,
  createdAtMs: _now,
  updatedAtMs: _now,
);

domain.Task _task(
  String id, {
  String memberId = 'm1',
  domain.TimeRule? time,
  domain.Course course = domain.Course.none,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: '吃药',
  repeat: const domain.RepeatRule(),
  time: time ?? domain.FixedTimesRule([domain.LocalTime(8, 0)]),
  course: course,
  status: domain.TaskStatus.active,
  createdAtMs: _now,
  updatedAtMs: _now,
);

domain.CheckinRecord _checkin(
  String id, {
  String taskId = 't1',
  domain.LocalDate? date,
  int slotIndex = 0,
  domain.CheckinState state = domain.CheckinState.done,
  String? note,
}) => domain.CheckinRecord(
  id: id,
  taskId: taskId,
  date: date ?? domain.LocalDate(2025, 1, 1),
  slotIndex: slotIndex,
  state: state,
  doneAtMs: _now,
  dueAtMinuteOfDay: 480,
  note: note,
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m1', '我')),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('成员', () {
    test('新增时排序追加到末尾', () async {
      await db.insertMember(_member('m2', '妈妈'), nowMs: _now);
      await db.insertMember(_member('m3', '小明'), nowMs: _now);

      final list = await db.listMembers();
      expect(list.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(list.map((m) => m.sortOrder), [0, 1, 2]);
    });

    test('软删除后 listMembers 看不到，但行还在', () async {
      await db.insertMember(_member('m2', '妈妈'), nowMs: _now);
      await db.deleteMember('m2', nowMs: _now);

      expect((await db.listMembers()).map((m) => m.id), ['m1']);

      final row = await (db.select(
        db.members,
      )..where((t) => t.id.equals('m2'))).getSingle();
      expect(row.deletedAtMs, isNotNull);
    });

    test('拖拽排序按传入顺序重写', () async {
      await db.insertMember(_member('m2', '妈妈'), nowMs: _now);
      await db.insertMember(_member('m3', '小明'), nowMs: _now);

      await db.reorderMembers(['m3', 'm1', 'm2'], nowMs: _now);

      expect((await db.listMembers()).map((m) => m.id), ['m3', 'm1', 'm2']);
    });

    test('外键生效：项目指向不存在的成员会被拒绝', () async {
      expect(
        () => db.insertTask(_task('t1', memberId: '不存在'), nowMs: _now),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('项目', () {
    test('规则 JSON 往返无损', () async {
      final t = _task(
        't1',
        time: domain.MealTimesRule(
          anchors: [domain.MealAnchor.breakfast, domain.MealAnchor.dinner],
          offsetMinutes: 30,
        ),
      );
      await db.insertTask(t, nowMs: _now);

      final back = (await db.findTask('t1'))!;
      expect(back.time, isA<domain.MealTimesRule>());
      final meal = back.time as domain.MealTimesRule;
      expect(meal.anchors, [
        domain.MealAnchor.breakfast,
        domain.MealAnchor.dinner,
      ]);
      expect(meal.offsetMinutes, 30);
    });

    test('重复规则的四个维度都能存回来', () async {
      final t = domain.Task(
        id: 't1',
        memberId: 'm1',
        name: '跳绳',
        repeat: domain.RepeatRule(
          weekdays: {1, 3, 5},
          everyNDays: 2,
          anchor: domain.LocalDate(2025, 1, 1),
          parity: domain.ParityFilter.oddWeeks,
          monthDays: const [1, 15],
        ),
        time: domain.IntervalRule(
          everyMinutes: 120,
          from: domain.LocalTime(9, 0),
          to: domain.LocalTime(21, 0),
        ),
        course: domain.Course.none,
        status: domain.TaskStatus.active,
        createdAtMs: _now,
        updatedAtMs: _now,
      );
      await db.insertTask(t, nowMs: _now);

      final back = (await db.findTask('t1'))!;
      expect(back.repeat.weekdays, {1, 3, 5});
      expect(back.repeat.everyNDays, 2);
      expect(back.repeat.anchor, domain.LocalDate(2025, 1, 1));
      expect(back.repeat.parity, domain.ParityFilter.oddWeeks);
      expect(back.repeat.monthDays, [1, 15]);
      expect(back.time, isA<domain.IntervalRule>());
    });

    test('疗程起止日往返', () async {
      final t = _task(
        't1',
        course: domain.Course.fromRange(
          domain.LocalDate(2025, 1, 1),
          domain.LocalDate(2025, 1, 7),
        ),
      );
      await db.insertTask(t, nowMs: _now);

      final back = (await db.findTask('t1'))!;
      expect(back.course.start, domain.LocalDate(2025, 1, 1));
      expect(back.course.end, domain.LocalDate(2025, 1, 7));
    });

    test('删除是软删，日历里还查得到历史打卡', () async {
      await db.insertTask(_task('t1'), nowMs: _now);
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);

      await db.deleteTask('t1', nowMs: _now);

      expect(await db.listAllTasks(), isEmpty);
      final history = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(history, hasLength(1));
    });

    test('暂停后不在活跃列表里，但行还在', () async {
      await db.insertTask(_task('t1'), nowMs: _now);
      await db.setTaskStatus(
        't1',
        domain.TaskStatus.paused,
        nowMs: _now,
      );

      final t = (await db.findTask('t1'))!;
      expect(t.status, domain.TaskStatus.paused);
      expect(t.isLive, isFalse);
    });
  });

  group('打卡记录', () {
    setUp(() async {
      await db.insertTask(_task('t1'), nowMs: _now);
    });

    test('同一 (task, date, slot) 重复写入不会变成两条', () async {
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);
      await db.upsertCheckin(
        _checkin('c1', state: domain.CheckinState.makeup),
        nowMs: _now,
      );

      final rows = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(rows, hasLength(1));
      expect(rows.single.state, domain.CheckinState.makeup);
    });

    test('已完成优先：done 不会被 skipped 抹掉', () async {
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);
      await db.upsertCheckin(
        _checkin('c2', state: domain.CheckinState.skipped),
        nowMs: _now,
      );

      final rows = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(rows.single.state, domain.CheckinState.done);
    });

    test('已完成优先：makeup 也不会被 skipped 抹掉', () async {
      await db.upsertCheckin(
        _checkin('c1', state: domain.CheckinState.makeup),
        nowMs: _now,
      );
      await db.upsertCheckin(
        _checkin('c2', state: domain.CheckinState.skipped),
        nowMs: _now,
      );

      final rows = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(rows.single.state, domain.CheckinState.makeup);
    });

    test('反向允许：用户改主意，skipped → done', () async {
      await db.upsertCheckin(
        _checkin('c1', state: domain.CheckinState.skipped),
        nowMs: _now,
      );
      await db.upsertCheckin(_checkin('c2'), nowMs: _now);

      final rows = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(rows.single.state, domain.CheckinState.done);
    });

    test('不同 slotIndex 是两条独立记录', () async {
      await db.upsertCheckin(_checkin('c1', slotIndex: 0), nowMs: _now);
      await db.upsertCheckin(_checkin('c2', slotIndex: 1), nowMs: _now);

      final rows = await db.checkinsOn(domain.LocalDate(2025, 1, 1));
      expect(rows, hasLength(2));
    });

    test('撤销打卡在 30 天内有效、超期拒绝', () async {
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);
      final date = domain.LocalDate(2025, 1, 1);

      final ok = await db.clearCheckin(
        taskId: 't1',
        date: date,
        slotIndex: 0,
        today: domain.LocalDate(2025, 1, 31),
        nowMs: _now,
      );
      expect(ok, isTrue);
      expect(await db.checkinsOn(date), isEmpty);

      // 再写一条，然后从 32 天后回来看
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);
      final denied = await db.clearCheckin(
        taskId: 't1',
        date: date,
        slotIndex: 0,
        today: domain.LocalDate(2025, 3, 1),
        nowMs: _now,
      );
      expect(denied, isFalse);
      expect(await db.checkinsOn(date), hasLength(1));
    });

    test('区间查询含首含尾', () async {
      await db.upsertCheckin(
        _checkin('c1', date: domain.LocalDate(2025, 1, 1)),
        nowMs: _now,
      );
      await db.upsertCheckin(
        _checkin('c2', date: domain.LocalDate(2025, 1, 5)),
        nowMs: _now,
      );
      await db.upsertCheckin(
        _checkin('c3', date: domain.LocalDate(2025, 1, 9)),
        nowMs: _now,
      );

      final rows = await db.checkinsBetween(
        domain.LocalDate(2025, 1, 1),
        domain.LocalDate(2025, 1, 5),
      );
      expect(rows.map((c) => c.id).toSet(), {'c1', 'c2'});
    });

    test('非法状态值读取时抛错，不当成已完成', () async {
      await db.customStatement(
        'INSERT INTO checkins (id, task_id, date, slot_index, state, '
        'created_at_ms, updated_at_ms) VALUES (\'bad\', \'t1\', '
        '\'2025-01-01\', 0, \'看不懂\', $_now, $_now)',
      );

      expect(
        () => db.checkinsOn(domain.LocalDate(2025, 1, 1)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('排程槽位', () {
    setUp(() async {
      await db.insertTask(_task('t1'), nowMs: _now);
    });

    SlotsCompanion slot(domain.LocalDate date, int index, {bool withFollowup = true}) =>
        SlotsCompanion.insert(
          taskId: 't1',
          date: date,
          slotIndex: index,
          dueDate: date,
          dueTime: domain.LocalTime(8, 0),
          remindId: Value(1000 + index),
          followupId: Value(withFollowup ? 2000 + index : null),
        );

    test('整体替换窗口（幂等重排）', () async {
      await db.replaceSlots(
        [slot(domain.LocalDate(2025, 1, 1), 0)],
        from: domain.LocalDate(2025, 1, 1),
        to: domain.LocalDate(2025, 1, 7),
        nowMs: _now,
      );
      await db.replaceSlots(
        [slot(domain.LocalDate(2025, 1, 2), 0)],
        from: domain.LocalDate(2025, 1, 1),
        to: domain.LocalDate(2025, 1, 7),
        nowMs: _now,
      );

      final rows = await db.slotsBetween(
        domain.LocalDate(2025, 1, 1),
        domain.LocalDate(2025, 1, 7),
      );
      expect(rows, hasLength(1));
      expect(rows.single.date, domain.LocalDate(2025, 1, 2));
    });

    test('按通知 ID 反查槽位（提醒 / 催办都能查到）', () async {
      await db.replaceSlots(
        [slot(domain.LocalDate(2025, 1, 1), 0)],
        from: domain.LocalDate(2025, 1, 1),
        to: domain.LocalDate(2025, 1, 7),
        nowMs: _now,
      );

      expect((await db.slotByNotificationId(1000))?.slotIndex, 0);
      expect((await db.slotByNotificationId(2000))?.slotIndex, 0);
      expect(await db.slotByNotificationId(9999), isNull);
    });

    test('槽位不进 change_log（派生数据）', () async {
      final before = await db.pendingSyncCount();
      await db.replaceSlots(
        [slot(domain.LocalDate(2025, 1, 1), 0)],
        from: domain.LocalDate(2025, 1, 1),
        to: domain.LocalDate(2025, 1, 7),
        nowMs: _now,
      );
      expect(await db.pendingSyncCount(), before);
    });

    test('标记催办已发', () async {
      await db.replaceSlots(
        [slot(domain.LocalDate(2025, 1, 1), 0)],
        from: domain.LocalDate(2025, 1, 1),
        to: domain.LocalDate(2025, 1, 7),
        nowMs: _now,
      );
      await db.markFollowupSent(
        't1',
        domain.LocalDate(2025, 1, 1),
        0,
      );

      final rows = await db.slotsBetween(
        domain.LocalDate(2025, 1, 1),
        domain.LocalDate(2025, 1, 7),
      );
      expect(rows.single.followupSent, isTrue);
    });
  });

  group('设置与变更日志', () {
    test('设置幂等写入', () async {
      await db.setSetting('theme', 'light', nowMs: _now);
      await db.setSetting('theme', 'dark', nowMs: _now);
      expect(await db.getSetting('theme'), 'dark');
      expect(await db.getSetting('不存在'), isNull);
    });

    test('写操作都留下 change_log', () async {
      final before = await db.pendingSyncCount();
      await db.insertMember(_member('m2', '妈妈'), nowMs: _now);
      await db.insertTask(_task('t1'), nowMs: _now);
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);

      expect(await db.pendingSyncCount(), before + 3);
    });

    test('被拒绝的降级写入不产生 change_log', () async {
      await db.insertTask(_task('t1'), nowMs: _now);
      await db.upsertCheckin(_checkin('c1'), nowMs: _now);
      final afterDone = await db.pendingSyncCount();

      await db.upsertCheckin(
        _checkin('c2', state: domain.CheckinState.skipped),
        nowMs: _now,
      );
      expect(await db.pendingSyncCount(), afterDone);
    });
  });
}
