import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_row.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/feature/home/today_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000; // 2025-03-01

domain.Member _member(String id, String name, int sort) => domain.Member(
  id: id,
  name: name,
  sortOrder: sort,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _task(
  String id, {
  required String memberId,
  required String name,
  domain.TimeRule? time,
  domain.TaskStatus status = domain.TaskStatus.active,
  int sort = 0,
}) => domain.Task(
  id: id,
  memberId: memberId,
  name: name,
  repeat: const domain.RepeatRule(),
  time: time ?? domain.FixedTimesRule([domain.LocalTime(8, 0)]),
  course: domain.Course.none,
  status: status,
  sortOrder: sort,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

void main() {
  late AppDatabase db;
  late TodayService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = TodayService(db);
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m1', '爷爷', 0)),
    );
    await db.into(db.members).insert(
      Mappers.memberToCompanion(_member('m2', '小宝', 1)),
    );
  });

  tearDown(() async => db.close());

  /// 固定"现在"为 2025-03-01 09:00。
  Future<TodayView> load() =>
      service.load(at: DateTime(2025, 3, 1, 9, 0));

  test('没有项目时返回空视图', () async {
    final v = await load();
    expect(v.isEmpty, isTrue);
    expect(v.totalCount, 0);
  });

  test('超时的排最前，按超时时长倒序', () async {
    await db.insertTask(
      _task(
        't1',
        memberId: 'm1',
        name: '早读',
        time: domain.FixedTimesRule([domain.LocalTime(7, 0)]),
      ),
      nowMs: _ts,
    );
    await db.insertTask(
      _task(
        't2',
        memberId: 'm2',
        name: '降压药',
        time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
      ),
      nowMs: _ts,
    );

    final v = await load();

    expect(v.overdue, hasLength(2));
    // 7:00 迟 120 分钟，8:00 迟 60 分钟 → 早读在前
    expect(v.overdue.first.task.name, '早读');
    expect(v.upcoming, isEmpty);
  });

  test('未到时间的进"接下来"，按时间正序', () async {
    for (final (id, h) in [('t1', 20), ('t2', 12), ('t3', 15)]) {
      await db.insertTask(
        _task(
          id,
          memberId: 'm1',
          name: 'p$h',
          time: domain.FixedTimesRule([domain.LocalTime(h, 0)]),
        ),
        nowMs: _ts,
      );
    }

    final v = await load();

    expect(v.upcoming.map((r) => r.task.name), ['p12', 'p15', 'p20']);
  });

  test('一天三次的药展开成 3 行', () async {
    await db.insertTask(
      _task(
        't1',
        memberId: 'm1',
        name: '降压药',
        time: domain.MealTimesRule(
          anchors: [
            domain.MealAnchor.breakfast,
            domain.MealAnchor.lunch,
            domain.MealAnchor.dinner,
          ],
        ),
      ),
      nowMs: _ts,
    );

    final v = await load();

    expect(v.totalCount, 3);
    // 9:00 时：早饭后（7:30+30=8:00）已超时，午饭/晚饭还没到
    expect(v.overdue, hasLength(1));
    expect(v.upcoming, hasLength(2));
  });

  test('暂停的项目不进今日清单', () async {
    await db.insertTask(
      _task('t1', memberId: 'm1', name: '跳绳', status: domain.TaskStatus.paused),
      nowMs: _ts,
    );

    final v = await load();
    expect(v.isEmpty, isTrue);
  });

  test('成员视图：空成员不出现，进度按各自统计', () async {
    await db.insertTask(
      _task(
        't1',
        memberId: 'm1',
        name: '喝水',
        time: domain.FixedTimesRule([domain.LocalTime(7, 0)]),
      ),
      nowMs: _ts,
    );

    final v = await load();

    expect(v.sections, hasLength(1));
    expect(v.sections.single.member.name, '爷爷');
    expect(v.sections.single.totalCount, 1);
    expect(v.sections.single.doneCount, 0);
  });

  test('成员顺序按 sortOrder', () async {
    for (final (id, m) in [('t1', 'm2'), ('t2', 'm1')]) {
      await db.insertTask(
        _task(id, memberId: m, name: 'n$id'),
        nowMs: _ts,
      );
    }

    final v = await load();
    expect(v.sections.map((s) => s.member.name), ['爷爷', '小宝']);
  });

  test('完成数只算准时与补卡，「没做」不计入', () async {
    for (final (id, h) in [('t1', 7), ('t2', 6), ('t3', 5)]) {
      await db.insertTask(
        _task(
          id,
          memberId: 'm1',
          name: 'n$h',
          time: domain.FixedTimesRule([domain.LocalTime(h, 0)]),
        ),
        nowMs: _ts,
      );
    }

    final date = domain.LocalDate(2025, 3, 1);
    for (final (id, slot, state) in [
      ('t1', 0, domain.CheckinState.done),
      ('t2', 0, domain.CheckinState.makeup),
      ('t3', 0, domain.CheckinState.skipped),
    ]) {
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c$id',
          taskId: id,
          date: date,
          slotIndex: slot,
          state: state,
          doneAtMs: _ts,
        ),
        nowMs: _ts,
      );
    }

    final v = await load();

    expect(v.doneCount, 2, reason: '准时 + 补卡 = 2，「没做」不算完成');
    expect(v.totalCount, 3);
    expect(v.progress, closeTo(2 / 3, 1e-9));
  });

  test('五态判定与 ui-spec 一致', () async {
    await db.insertTask(
      _task(
        't1',
        memberId: 'm1',
        name: '早读',
        time: domain.FixedTimesRule([domain.LocalTime(7, 0)]),
      ),
      nowMs: _ts,
    );
    await db.insertTask(
      _task(
        't2',
        memberId: 'm1',
        name: '跳绳',
        time: domain.FixedTimesRule([domain.LocalTime(20, 0)]),
      ),
      nowMs: _ts,
    );

    final v = await load();

    final overdueRow = v.overdue.single;
    expect(
      overdueRow.visual(v.date!, v.now!),
      domain.CheckinVisual.overdue,
    );
    expect(overdueRow.lateMinutes(v.now!), 120);

    final upcomingRow = v.upcoming.single;
    expect(
      upcomingRow.visual(v.date!, v.now!),
      domain.CheckinVisual.pending,
    );
  });

  test('跨午夜的槽位不算进当天（宵夜后 4 小时的药属于第二天）', () async {
    await db.insertTask(
      _task(
        't1',
        memberId: 'm1',
        name: '宵夜药',
        time: domain.MealTimesRule(
          anchors: [domain.MealAnchor.dinner],
          offsetMinutes: 8 * 60,
        ),
      ),
      nowMs: _ts,
    );

    final v = await load();
    // 18:30 + 8h = 次日 02:30，不属于 3/1
    expect(v.isEmpty, isTrue);
  });
}
