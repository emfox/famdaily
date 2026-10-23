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
import 'package:famdaily/feature/stats/stats_service.dart';
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

/// 把槽位算出来落库。
///
/// `replaceSlots` 按日期区间整体替换，多个项目必须一次写入——
/// 分两次调第二次会把第一次的删掉。
Future<void> seedSlots(
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
    maxSlots: 5000,
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

Future<void> markDone(
  AppDatabase db,
  String taskId,
  domain.LocalDate date, {
  domain.CheckinState state = domain.CheckinState.done,
}) {
  return db.upsertCheckin(
    domain.CheckinRecord(
      id: 'c-$taskId-$date',
      taskId: taskId,
      date: date,
      slotIndex: 0,
      state: state,
      doneAtMs: _ts,
    ),
    nowMs: _ts,
  );
}

void main() {
  group('区间', () {
    final today = domain.LocalDate(2025, 3, 15);

    test('本月从 1 号截到今天，不把未来算进分母', () {
      final r = DateRange.of(StatsPeriod.thisMonth, today);
      expect(r.from, domain.LocalDate(2025, 3, 1));
      expect(r.to, today);
      expect(r.days, 15);
    });

    test('上月跨年也正确（1 月看 12 月）', () {
      final r = DateRange.of(
        StatsPeriod.lastMonth,
        domain.LocalDate(2025, 1, 10),
      );
      expect(r.from, domain.LocalDate(2024, 12, 1));
      expect(r.to, domain.LocalDate(2024, 12, 31));
    });

    test('近 90 天是含今天往回 90 天', () {
      final r = DateRange.of(StatsPeriod.last90Days, today);
      expect(r.days, 90);
      expect(r.to, today);
    });

    test('今年从 1/1 起', () {
      final r = DateRange.of(StatsPeriod.thisYear, today);
      expect(r.from, domain.LocalDate(2025, 1, 1));
    });
  });

  group('装配', () {
    late AppDatabase db;
    late StatsService service;
    final today = domain.LocalDate(2025, 3, 5);

    setUp(() async {
      db = AppDatabase.forTesting(openTestConnection());
      service = StatsService(db);
      await db.into(db.members).insert(
        Mappers.memberToCompanion(
          const domain.Member(
            id: 'm1',
            name: '爷爷',
            sortOrder: 0,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
      await db.into(db.members).insert(
        Mappers.memberToCompanion(
          const domain.Member(
            id: 'm2',
            name: '小宝',
            sortOrder: 1,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t1', 'm1')),
      );
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(_task('t2', 'm2')),
      );
    });

    tearDown(() async => db.close());

    test('空库时不给一堆 0%，给一句人话', () async {
      final view = await service.load(at: DateTime(2025, 3, 5));
      expect(view.overall.expected, 0);
      expect(view.overall.percent(view.overall.completionRate), '—');
      expect(view.headline, '这段时间没有排过打卡项');
      expect(view.rows, isEmpty);
    });

    test('按成员分行，合计等于各行相加', () async {
      await seedSlots(
        db,
        ['t1', 't2'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );
      // 爷爷 3/1 准时，3/2 补卡，3/3 没做，后面两天悬空。
      await markDone(db, 't1', domain.LocalDate(2025, 3, 1));
      await markDone(
        db,
        't1',
        domain.LocalDate(2025, 3, 2),
        state: domain.CheckinState.makeup,
      );
      await markDone(
        db,
        't1',
        domain.LocalDate(2025, 3, 3),
        state: domain.CheckinState.skipped,
      );

      final view = await service.load(at: DateTime(2025, 3, 5, 12));

      expect(view.rows.map((r) => r.member.name), ['爷爷', '小宝']);
      final grandpa = view.rows.first.summary;
      expect(grandpa.expected, 5);
      expect(grandpa.onTime, 1);
      expect(grandpa.makeup, 1);
      expect(grandpa.skipped, 1);
      expect(grandpa.completionRate, closeTo(0.4, 1e-9));
      expect(grandpa.onTimeRate, closeTo(0.2, 1e-9));

      expect(view.overall.expected, 10);
      expect(view.overall.onTime, 1);
      expect(view.headline, '共 10 次该做，做了 2 次');
    });

    test('筛某个成员时只看他自己，标题跟着变', () async {
      await seedSlots(
        db,
        ['t1', 't2'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );
      await markDone(db, 't1', domain.LocalDate(2025, 3, 1));

      final view = await service.load(
        memberFilter: 'm1',
        at: DateTime(2025, 3, 5, 12),
      );

      expect(view.rows, hasLength(1));
      expect(view.rows.single.member.id, 'm1');
      expect(view.overall.expected, 5);
    });

    test('已删除的成员不占一行，但他的记录也不污染别人的分母', () async {
      await seedSlots(
        db,
        ['t1', 't2'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );
      await db.deleteMember('m2', nowMs: _ts);

      final view = await service.load(at: DateTime(2025, 3, 5, 12));

      expect(view.rows.map((r) => r.member.id), ['m1']);
      expect(view.overall.expected, 5);
    });

    test('归档的项目仍算历史（它当时该做的）', () async {
      await db.setTaskStatus('t1', domain.TaskStatus.archived, nowMs: _ts);
      await seedSlots(
        db,
        ['t1'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );

      final view = await service.load(at: DateTime(2025, 3, 5, 12));

      expect(view.overall.expected, 5, reason: '归档是"以后不用做"，不是"以前没做过"');
    });

    test('换区间后数字跟着变（上月是空的）', () async {
      await seedSlots(
        db,
        ['t1'],
        from: domain.LocalDate(2025, 3, 1),
        to: today,
      );

      final lastMonth = await service.load(
        period: StatsPeriod.lastMonth,
        at: DateTime(2025, 3, 5, 12),
      );

      expect(lastMonth.overall.expected, 0);
      expect(lastMonth.range.from, domain.LocalDate(2025, 2, 1));
      expect(lastMonth.range.to, domain.LocalDate(2025, 2, 28));
    });
  });
}
