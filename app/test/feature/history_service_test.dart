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
import 'package:famdaily/feature/history/history_calendar.dart';
import 'package:famdaily/feature/history/history_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

domain.Member _member(String id, String name, int sort) => domain.Member(
  id: id,
  name: name,
  sortOrder: sort,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _task(
  String id,
  String memberId,
  String name,
  List<int> hours, {
  int? everyNDays,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: name,
  repeat: domain.RepeatRule(everyNDays: everyNDays),
  time: domain.FixedTimesRule([for (final h in hours) domain.LocalTime(h, 0)]),
  course: domain.Course.none,
  status: domain.TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

void main() {
  late AppDatabase db;
  late HistoryService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = HistoryService(db);
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m1', '爷爷', 0)),
    );
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m2', '小宝', 1)),
    );
  });

  tearDown(() async => db.close());

  /// 把某个项目在 [from]..[to] 的槽位算出来落库（模拟启动重排的产物）。
  Future<void> seedSlots(
    Object tasks, {
    required domain.LocalDate from,
    required domain.LocalDate to,
  }) async {
    final list = tasks is List ? tasks.cast<domain.Task>() : [tasks as domain.Task];
    final result = Scheduler.expand(
      specs: [
        for (final t in list)
          ScheduleSpec(
            taskId: t.id,
            repeat: t.repeat,
            time: t.time,
            course: t.course,
          ),
      ],
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

  group('月历底色来自真实槽位 + 记录', () {
    test('全做完 = 深绿；有一条没做 = 暖红', () async {
      final task = _task('t1', 'm1', '降压药', [8, 12]);
      await db.insertTask(task, nowMs: _ts);
      await seedSlots(
        task,
        from: domain.LocalDate(2026, 3, 1),
        to: domain.LocalDate(2026, 3, 31),
      );

      // 3/10 两条都准时
      for (var i = 0; i < 2; i++) {
        await db.upsertCheckin(
          domain.CheckinRecord(
            id: 'c10-$i',
            taskId: 't1',
            date: domain.LocalDate(2026, 3, 10),
            slotIndex: i,
            state: domain.CheckinState.done,
            doneAtMs: _ts,
            dueAtMinuteOfDay: i == 0 ? 480 : 720,
          ),
          nowMs: _ts,
        );
      }
      // 3/11 一条准时一条没做
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c11-0',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 11),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c11-1',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 11),
          slotIndex: 1,
          state: domain.CheckinState.skipped,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 720,
        ),
        nowMs: _ts,
      );

      final view = await service.loadMonth(
        year: 2026,
        month: 3,
        at: DateTime(2026, 3, 20, 10),
      );

      DayCell day(int d) =>
          view.grid.cells.firstWhere((c) => c.date == domain.LocalDate(2026, 3, d));

      expect(day(10).tone, DayTone.full);
      expect(day(10).summary.expected, 2);
      expect(day(11).tone, DayTone.warm);
      // 没记过的日子不涂色
      expect(day(12).tone, DayTone.none);
      // 未来的日子不涂色、不进分母
      expect(day(25).isFuture, isTrue);
    });

    test('本月汇总不含未来的日子', () async {
      final task = _task('t1', 'm1', '跳绳', [20]);
      await db.insertTask(task, nowMs: _ts);
      await seedSlots(
        task,
        from: domain.LocalDate(2026, 3, 1),
        to: domain.LocalDate(2026, 3, 31),
      );
      final view = await service.loadMonth(
        year: 2026,
        month: 3,
        at: DateTime(2026, 3, 10, 10),
      );
      // 1..10 号共 10 次应完成，11..31 不算
      expect(view.grid.summary.expected, 10);
    });

    test('补卡不计准时率但计入完成率', () async {
      final task = _task('t1', 'm1', '吃药', [8]);
      await db.insertTask(task, nowMs: _ts);
      await seedSlots(
        task,
        from: domain.LocalDate(2026, 3, 1),
        to: domain.LocalDate(2026, 3, 2),
      );
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'a',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 1),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'b',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 2),
          slotIndex: 0,
          state: domain.CheckinState.makeup,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );

      final view = await service.loadMonth(
        year: 2026,
        month: 3,
        at: DateTime(2026, 3, 5, 10),
      );
      // 本月应完成不止 2 次（3/3-3/5 也排了），但已记录部分：1 准时 + 1 补卡
      expect(view.grid.summary.onTime, 1);
      expect(view.grid.summary.makeup, 1);
    });
  });

  group('某日明细', () {
    test('按成员分组、组内按时间排；能补卡的天数就是 30 天窗口', () async {
      final grandpa = _task('t1', 'm1', '降压药', [8, 12]);
      final kid = _task('t2', 'm2', '早读', [7]);
      await db.insertTask(grandpa, nowMs: _ts);
      await db.insertTask(kid, nowMs: _ts);
      final from = domain.LocalDate(2026, 3, 1);
      final to = domain.LocalDate(2026, 3, 3);
      // 两次 replaceSlots 会互相删掉对方的槽位（它按日期区间整体替换），
      // 所以多个项目要一次写进去。
      await seedSlots([grandpa, kid], from: from, to: to);

      final detail = await service.loadDay(
        domain.LocalDate(2026, 3, 2),
        at: DateTime(2026, 3, 20, 10),
      );

      expect(detail.rows, hasLength(3));
      // 先 m1（爷爷），组内 8 点在前
      expect(detail.rows[0].task.memberId, 'm1');
      expect(detail.rows[0].dueMinuteOfDay, 480);
      expect(detail.rows[1].dueMinuteOfDay, 720);
      // 再 m2
      expect(detail.rows[2].task.memberId, 'm2');
      expect(detail.editable, isTrue);
      expect(detail.summary.expected, 3);
      expect(detail.summary.unrecorded, 3);
    });

    test('超过 30 天就只读', () async {
      final task = _task('t1', 'm1', '吃药', [8]);
      await db.insertTask(task, nowMs: _ts);
      final old = domain.LocalDate(2026, 3, 1);
      await seedSlots(task, from: old, to: old);

      final detail = await service.loadDay(
        old,
        at: DateTime(2026, 5, 15, 10),
      );
      expect(detail.editable, isFalse);
      expect(
        HistoryService.readOnlyHint(old, domain.LocalDate(2026, 5, 15)),
        contains('超过 30 天'),
      );
    });

    test('刚好 30 天还能补，31 天不能', () async {
      final task = _task('t1', 'm1', '吃药', [8]);
      await db.insertTask(task, nowMs: _ts);
      final d = domain.LocalDate(2026, 3, 1);
      await seedSlots(task, from: d, to: d);

      final at30 = await service.loadDay(d, at: DateTime(2026, 3, 31, 10));
      expect(at30.editable, isTrue);
      final at31 = await service.loadDay(d, at: DateTime(2026, 4, 1, 10));
      expect(at31.editable, isFalse);
    });

    test('未来日期不可编辑', () async {
      final task = _task('t1', 'm1', '吃药', [8]);
      await db.insertTask(task, nowMs: _ts);
      final future = domain.LocalDate(2026, 3, 20);
      await seedSlots(
        task,
        from: domain.LocalDate(2026, 3, 19),
        to: future,
      );
      final detail = await service.loadDay(
        future,
        at: DateTime(2026, 3, 15, 10),
      );
      expect(detail.editable, isFalse);
      expect(
        HistoryService.readOnlyHint(future, domain.LocalDate(2026, 3, 15)),
        '还没到的日子',
      );
    });

    test('跨午夜到次日的槽位不算在这一天', () async {
      // 晚饭设成 23:00、饭后 2 小时 → 次日 01:00。槽位的 date 仍是当天，
      // 但 dueDate 落在次日：首页与历史都必须按 dueDate 归属，
      // 否则"宵夜后的药"会被算成当天凌晨该吃。
      final task = domain.Task(
        id: 't1',
        memberId: 'm1',
        name: '宵夜后的药',
        repeat: const domain.RepeatRule(),
        time: domain.MealTimesRule(
          anchors: const [domain.MealAnchor.dinner],
          offsetMinutes: 120,
          anchorOverrides: {domain.MealAnchor.dinner: domain.LocalTime(23, 0)},
        ),
        course: domain.Course.none,
        status: domain.TaskStatus.active,
        createdAtMs: _ts,
        updatedAtMs: _ts,
      );
      await db.insertTask(task, nowMs: _ts);
      final d = domain.LocalDate(2026, 3, 1);
      await seedSlots(task, from: d, to: d);

      final detail = await service.loadDay(d, at: DateTime(2026, 3, 2, 9));
      expect(detail.rows, isEmpty);

      // 次日那天能看到它（归到次日）
      final next = await service.loadDay(
        domain.LocalDate(2026, 3, 2),
        at: DateTime(2026, 3, 2, 9),
      );
      expect(next.rows, hasLength(1));
      expect(next.rows.single.task.name, '宵夜后的药');
    });

    test('没有安排的一天给出空明细', () async {
      final detail = await service.loadDay(
        domain.LocalDate(2026, 3, 2),
        at: DateTime(2026, 3, 2, 10),
      );
      expect(detail.isEmpty, isTrue);
      expect(detail.summary.expected, 0);
    });

    test('撤销一笔后回到未记录', () async {
      final task = _task('t1', 'm1', '吃药', [8]);
      await db.insertTask(task, nowMs: _ts);
      final d = domain.LocalDate(2026, 3, 2);
      await seedSlots(task, from: d, to: d);
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: d,
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );

      final before = await service.loadDay(d, at: DateTime(2026, 3, 2, 20));
      expect(before.summary.onTime, 1);
      expect(before.rows.single.record, isNotNull);

      final ok = await service.undo(row: before.rows.single, today: d);
      expect(ok, isTrue);

      final after = await service.loadDay(d, at: DateTime(2026, 3, 2, 20));
      expect(after.summary.onTime, 0);
      expect(after.rows.single.record, isNull);
    });

    test('分组只包含当天真正有行的成员', () async {
      final grandpa = _task('t1', 'm1', '降压药', [8]);
      await db.insertTask(grandpa, nowMs: _ts);
      final d = domain.LocalDate(2026, 3, 2);
      await seedSlots(grandpa, from: d, to: d);

      final detail = await service.loadDay(d, at: DateTime(2026, 3, 2, 20));
      final grouped = HistoryService.groupByMember(detail.rows);
      expect(grouped.keys, ['m1']);
    });
  });

  group('有记录但没槽位（孤儿记录）', () {
    // 真机反馈："历史里当天已完成的好像没有记录"。
    //
    // 槽位是调度器算出来的，会重排、会清理；记录是用户真做过的事。
    // 新建完项目立刻打卡、而重排还没跑完时，那天就没有槽位。
    // 旧实现只遍历槽位，这条打卡就凭空消失了。
    test('打了卡但没有槽位，历史里也要列出来', () async {
      final task = _task('t1', 'm1', '跳绳', [8]);
      await db.insertTask(task, nowMs: _ts);
      // 故意不 seedSlots

      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 10),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );

      final detail = await service.loadDay(
        domain.LocalDate(2026, 3, 10),
        at: DateTime(2026, 3, 10, 9),
      );

      expect(detail.rows, hasLength(1), reason: '打过卡的记录不能因为没槽位就丢掉');
      expect(detail.rows.single.record?.state, domain.CheckinState.done);
      expect(detail.rows.single.dueMinuteOfDay, 480);
    });

    test('有槽位也有记录时不会重复列两遍', () async {
      final task = _task('t1', 'm1', '跳绳', [8]);
      await db.insertTask(task, nowMs: _ts);
      await seedSlots(
        task,
        from: domain.LocalDate(2026, 3, 1),
        to: domain.LocalDate(2026, 3, 31),
      );
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 10),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );

      final detail = await service.loadDay(
        domain.LocalDate(2026, 3, 10),
        at: DateTime(2026, 3, 10, 9),
      );

      expect(detail.rows, hasLength(1));
    });

    test('孤儿记录也计入当天的完成数', () async {
      final task = _task('t1', 'm1', '跳绳', [8]);
      await db.insertTask(task, nowMs: _ts);
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: domain.LocalDate(2026, 3, 10),
          slotIndex: 0,
          state: domain.CheckinState.done,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
        nowMs: _ts,
      );

      final detail = await service.loadDay(
        domain.LocalDate(2026, 3, 10),
        at: DateTime(2026, 3, 10, 9),
      );
      expect(detail.summary.onTime + detail.summary.makeup, 1);
    });
  });
}
