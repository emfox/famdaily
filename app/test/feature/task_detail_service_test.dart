import 'package:famdaily/data/db/app_database.dart';
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
import 'package:famdaily/feature/task_detail/task_detail_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 2025-03-15 12:00 本地时间。
final DateTime _now = DateTime(2025, 3, 15, 12);
final domain.LocalDate _today = domain.LocalDate(2025, 3, 15);

domain.Task _task({
  String id = 't1',
  String memberId = 'm1',
  String name = '吃药',
  domain.TimeRule? time,
  domain.Course course = domain.Course.none,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: name,
  repeat: const domain.RepeatRule(),
  time: time ?? domain.FixedTimesRule([domain.LocalTime(20, 0)]),
  course: course,
  status: domain.TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

Future<void> _seed(
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

Future<void> _member(AppDatabase db, String id, String name) => db.insertMember(
  domain.Member(
    id: id,
    name: name,
    sortOrder: 0,
    createdAtMs: _ts,
    updatedAtMs: _ts,
  ),
  nowMs: _ts,
);

Future<void> _checkin(
  AppDatabase db, {
  required String id,
  required String taskId,
  required domain.LocalDate date,
  required domain.CheckinState state,
  int slotIndex = 0,
  int? doneAtMs,
  String? note,
  String? photoPath,
}) => db.upsertCheckin(
  domain.CheckinRecord(
    id: id,
    taskId: taskId,
    date: date,
    slotIndex: slotIndex,
    state: state,
    doneAtMs: doneAtMs ?? _ts,
    note: note,
    photoPath: photoPath,
  ),
  nowMs: _ts,
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    await _member(db, 'm1', '爷爷');
  });

  tearDown(() async {
    await db.close();
  });

  test('项目不存在时返回 null，不抛异常', () async {
    final service = TaskDetailService(db);
    expect(await service.load('不存在', at: _now), isNull);
  });

  test('统计分母是这几天真正排出来的槽位，未来不算', () async {
    await db.insertTask(_task(), nowMs: _ts);
    // 只排了 3/13–3/15 三天（含今天）
    await _seed(db, ['t1'], from: domain.LocalDate(2025, 3, 13), to: _today);
    await _checkin(
      db,
      id: 'c1',
      taskId: 't1',
      date: domain.LocalDate(2025, 3, 13),
      state: domain.CheckinState.done,
    );
    await _checkin(
      db,
      id: 'c2',
      taskId: 't1',
      date: domain.LocalDate(2025, 3, 14),
      state: domain.CheckinState.skipped,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.stats.expected, 3);
    expect(detail.stats.onTime, 1);
    expect(detail.stats.skipped, 1);
    // 今天那次还没记
    expect(detail.stats.unrecorded, 1);
    expect(detail.headline, '共 3 次该做，做了 1 次');
  });

  test('最近记录按天倒序，同一天按时刻正序', () async {
    await db.insertTask(
      _task(
        time: domain.FixedTimesRule([
          domain.LocalTime(7, 30),
          domain.LocalTime(12, 30),
          domain.LocalTime(18, 30),
        ]),
      ),
      nowMs: _ts,
    );
    await _seed(db, ['t1'], from: domain.LocalDate(2025, 3, 14), to: _today);

    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.days.map((d) => d.date), [
      _today,
      domain.LocalDate(2025, 3, 14),
    ]);
    expect(detail.days.first.entries.map((e) => e.dueMinuteOfDay), [
      450,
      750,
      1110,
    ]);
  });

  test('补卡那行说清「几点应的」和「几点记的」', () async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, ['t1'], from: domain.LocalDate(2025, 3, 14), to: _today);
    // 3/14 应完成 20:00，实际 3/15 09:12 才补记
    await _checkin(
      db,
      id: 'c1',
      taskId: 't1',
      date: domain.LocalDate(2025, 3, 14),
      state: domain.CheckinState.makeup,
      doneAtMs: DateTime(2025, 3, 15, 9, 12).millisecondsSinceEpoch,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    final entry = detail.days
        .firstWhere((d) => d.date == domain.LocalDate(2025, 3, 14))
        .entries
        .single;
    expect(entry.makeupNote, '补卡（3月15日 09:12 记上）');
  });

  test('当天补记时只写钟点，不写日期（同一天写日期是噪音）', () async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, ['t1'], from: _today, to: _today);
    await _checkin(
      db,
      id: 'c1',
      taskId: 't1',
      date: _today,
      state: domain.CheckinState.makeup,
      doneAtMs: DateTime(2025, 3, 15, 9, 12).millisecondsSinceEpoch,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.days.first.entries.single.makeupNote, '补卡（当天 09:12 记上）');
  });

  test('「没做」也存了时间，但不显示打卡时刻（显示就没意义了）', () async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, ['t1'], from: _today, to: _today);
    await _checkin(
      db,
      id: 'c1',
      taskId: 't1',
      date: _today,
      state: domain.CheckinState.skipped,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.days.first.entries.single.doneAtHm, isNull);
  });

  test('槽位被重排掉但记录还在的，仍然留在最近记录里', () async {
    // 场景：用户把 "每天 20:00" 改成 "每天 8:00"，重排把旧槽位删了，
    // 但上周确实打过卡——那些人做过这件事，不能因为槽位没了就消失。
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, ['t1'], from: domain.LocalDate(2025, 3, 14), to: _today);
    await _checkin(
      db,
      id: 'orphan',
      taskId: 't1',
      date: domain.LocalDate(2025, 3, 10),
      state: domain.CheckinState.done,
      doneAtMs: DateTime(2025, 3, 10, 20, 3).millisecondsSinceEpoch,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    final dates = detail.days.map((d) => d.date).toList();
    expect(dates, contains(domain.LocalDate(2025, 3, 10)));
  });

  test('成员被删除后 member 仍保留（名字是要留住的历史，不是最新状态）', () async {
    // 曾经这里是 `isDeleted ? null : member`，界面上就只剩一句
    // 「已删除的成员」——"这项是谁做的"直接没了。头像画不画是界面决策，
    // 数据层没理由把名字扔掉。
    await db.insertTask(_task(), nowMs: _ts);
    await db.deleteMember('m1', nowMs: _ts);

    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.member, isNotNull);
    expect(detail.member!.name, '爷爷');
    expect(detail.member!.isDeleted, isTrue);
    expect(detail.task.name, '吃药');
  });

  test('最近记录只取 30 天：更早的记录不列（那时也改不动了）', () async {
    await db.insertTask(_task(), nowMs: _ts);
    await _checkin(
      db,
      id: 'old',
      taskId: 't1',
      date: _today.addDays(-45),
      state: domain.CheckinState.done,
    );
    await _checkin(
      db,
      id: 'new',
      taskId: 't1',
      date: _today.addDays(-5),
      state: domain.CheckinState.done,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    final ids = detail.days
        .expand((d) => d.entries)
        .map((e) => e.record?.id)
        .toList();
    expect(ids, contains('new'));
    expect(ids, isNot(contains('old')));
  });

  test('别的项目的记录不会串进来', () async {
    await db.insertTask(_task(), nowMs: _ts);
    await db.insertTask(
      _task(id: 't2', name: '跳绳'),
      nowMs: _ts,
    );
    await _seed(db, ['t1', 't2'], from: _today, to: _today);
    await _checkin(
      db,
      id: 'other',
      taskId: 't2',
      date: _today,
      state: domain.CheckinState.done,
    );

    final detail = (await service(db).load('t1', at: _now))!;
    expect(
      detail.days.expand((d) => d.entries).where((e) => e.record != null),
      isEmpty,
    );
  });

  test('空项目给一句人话，不给 0%', () async {
    await db.insertTask(_task(), nowMs: _ts);
    final detail = (await service(db).load('t1', at: _now))!;
    expect(detail.isEmpty, isTrue);
    expect(detail.headline, '这段时间没有排过');
    expect(detail.stats.percent(detail.stats.completionRate), '—');
  });

  test('日期标签：今年的不写年份，往年的写', () {
    final day = RecordDay(
      date: domain.LocalDate(2025, 3, 12),
      entries: const [],
    );
    expect(day.label(_today), '3月12日 三');
    expect(day.label(domain.LocalDate(2026, 1, 1)), '2025年3月12日 三');
  });
}

TaskDetailService service(AppDatabase db) => TaskDetailService(db);
