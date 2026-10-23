import 'package:clock/clock.dart';
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
import 'package:famdaily/feature/task_detail/task_detail_page.dart';
import 'package:famdaily/feature/task_detail/task_detail_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 2025-03-15 12:00。固定时钟：页面里"今天"的判断全靠它。
final DateTime _now = DateTime(2025, 3, 15, 12);
final domain.LocalDate _today = domain.LocalDate(2025, 3, 15);

Widget _wrap(Widget child) => MaterialApp(home: child);

domain.Task _task({
  domain.TimeRule? time,
  domain.Course course = domain.Course.none,
  String? note,
}) => domain.Task(
  id: 't1',
  memberId: 'm1',
  name: '降压药',
  note: note,
  iconId: 'pill',
  repeat: const domain.RepeatRule(),
  time: time ?? domain.FixedTimesRule([domain.LocalTime(20, 0)]),
  course: course,
  status: domain.TaskStatus.active,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

Future<void> _seed(
  AppDatabase db, {
  required domain.LocalDate from,
  required domain.LocalDate to,
}) async {
  final t = (await db.findTask('t1'))!;
  final result = Scheduler.expand(
    specs: [
      ScheduleSpec(
        taskId: t.id,
        repeat: t.repeat,
        time: t.time,
        course: t.course,
      ),
    ],
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

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    await db.insertMember(
      const domain.Member(
        id: 'm1',
        name: '爷爷',
        sortOrder: 0,
        createdAtMs: _ts,
        updatedAtMs: _ts,
      ),
      nowMs: _ts,
    );
  });

  tearDown(() async => db.close());

  /// 只在**页面构建这一小段**钉时钟是不够的：`withClock` 的作用域在 await
  /// 返回后就退出了，测试体里后面再 `_seed` / 写记录就拿到真实时间。
  /// 所以把整个用例 body 包进去（见下面的 `testInTime`）。
  Future<void> pump(
    WidgetTester tester, {
    void Function(domain.Task)? onEdit,
  }) async {
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onEdit: onEdit,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 把整个用例跑在固定的"2025-03-15 12:00"里。
  void testInTime(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) {
      return withClock(Clock.fixed(_now), () => body(tester));
    });
  }

  testInTime('头部画出成员、频率、钟点、疗程', (tester) async {
    await db.insertTask(
      _task(
        time: domain.FixedTimesRule([
          domain.LocalTime(7, 30),
          domain.LocalTime(12, 30),
          domain.LocalTime(18, 30),
        ]),
        course: domain.Course.days(domain.LocalDate(2025, 3, 13), 7),
      ),
      nowMs: _ts,
    );
    await pump(tester);

    expect(find.text('降压药'), findsOneWidget);
    expect(find.text('爷爷'), findsOneWidget);
    expect(find.text('每天 3 次'), findsOneWidget);
    expect(find.text('7:30 / 12:30 / 18:30'), findsOneWidget);
    // 库里存的是起止日期（`Course.totalDays` 不落库），所以文案是区间形态：
    // 说"还剩 4 天"比说"第 3/7 天"更必要——用户关心的是还有几天要熬。
    expect(find.text('疗程：3月13日 → 3月19日 · 还剩 4 天'), findsOneWidget);
  });

  testInTime('长期项目只说「长期」，不编造进度', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await pump(tester);

    expect(find.text('疗程：长期'), findsOneWidget);
  });

  testInTime('三个数字：完成率 / 准时率 / 没做', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, from: _today.addDays(-2), to: _today);
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: _today.addDays(-2),
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _ts,
      ),
      nowMs: _ts,
    );
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c2',
        taskId: 't1',
        date: _today.addDays(-1),
        slotIndex: 0,
        state: domain.CheckinState.skipped,
        doneAtMs: _ts,
      ),
      nowMs: _ts,
    );
    await pump(tester);

    expect(find.text('完成率'), findsOneWidget);
    expect(find.text('准时率'), findsOneWidget);
    expect(find.text('没做'), findsWidgets);
    // 3 次里 1 次准时 → 33.3%
    expect(find.text('33.3%'), findsNWidgets(2));
  });

  testInTime('一次都没排过时不画 0%，给一句人话', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await pump(tester);

    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('这段时间没有排过'), findsOneWidget);
    expect(find.text('最近还没排到这项'), findsOneWidget);
  });

  testInTime('最近记录里补卡那行标出「几点记的」', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, from: _today.addDays(-1), to: _today);
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: _today.addDays(-1),
        slotIndex: 0,
        state: domain.CheckinState.makeup,
        doneAtMs: DateTime(2025, 3, 15, 9, 12).millisecondsSinceEpoch,
      ),
      nowMs: _ts,
    );
    await pump(tester);

    // 3月14日那次是 3月15日 09:12 才补记的——跨了一天，所以要带日期。
    // 只有当"应的"和"记的"同一天时才写「当天 xx:xx」。
    expect(find.text('补卡（3月15日 09:12 记上）'), findsOneWidget);
  });

  testInTime('备注显示在记录下方', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await _seed(db, from: _today, to: _today);
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: _today,
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: DateTime(2025, 3, 15, 20, 3).millisecondsSinceEpoch,
        note: '吃了 2 粒',
      ),
      nowMs: _ts,
    );
    await pump(tester);

    expect(find.text('吃了 2 粒'), findsOneWidget);
  });

  testInTime('项目自己的说明（不是打卡备注）显示在头部', (tester) async {
    await db.insertTask(_task(note: '白色药片 2 粒，饭后半小时'), nowMs: _ts);
    await pump(tester);

    expect(find.text('白色药片 2 粒，饭后半小时'), findsOneWidget);
  });

  testInTime('点「编辑」把当前项目交出去', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    domain.Task? edited;
    await pump(tester, onEdit: (t) => edited = t);

    await tester.tap(find.widgetWithText(TextButton, '编辑'));
    await tester.pumpAndSettle();

    expect(edited?.id, 't1');
    expect(edited?.name, '降压药');
  });

  testInTime('没给 onEdit 时不显示编辑按钮（只读场景）', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await pump(tester);

    expect(find.widgetWithText(TextButton, '编辑'), findsNothing);
  });

  testInTime('项目已不存在时给一句人话，不白屏也不崩', (tester) async {
    await tester.pumpWidget(
      _wrap(TaskDetailPage(service: TaskDetailService(db), taskId: '不存在的项目')),
    );
    await tester.pumpAndSettle();

    expect(find.text('这个打卡项已经不在了'), findsOneWidget);
  });

  testInTime('已归档的项目在头上标出来', (tester) async {
    await db.insertTask(
      _task().copyWith(status: domain.TaskStatus.archived),
      nowMs: _ts,
    );
    await pump(tester);

    expect(find.text('已归档'), findsOneWidget);
  });

  testInTime('底部说明只列最近 30 天，告诉用户去哪看更早的', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await pump(tester);

    expect(find.textContaining('只列最近 30 天'), findsOneWidget);
  });

  testInTime('底部三个动作：暂停 / 归档 / 删除', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onStatusChange: (_, _) async {},
          onDelete: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂停这项'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    // 三条的说明文案必须不一样——用户靠这几行区分语义
    expect(find.textContaining('随时恢复'), findsOneWidget);
    expect(find.textContaining('疗程结束就收起来'), findsOneWidget);
    expect(find.textContaining('不能再改'), findsOneWidget);
  });

  testInTime('没给回调时底部不出现这三项（只读场景）', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    await pump(tester);

    expect(find.text('暂停这项'), findsNothing);
    expect(find.text('归档'), findsNothing);
  });

  testInTime('已暂停时按钮变成「恢复这项」，不再是「暂停这项」', (tester) async {
    await db.insertTask(
      _task().copyWith(status: domain.TaskStatus.paused),
      nowMs: _ts,
    );
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onStatusChange: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('恢复这项'), findsOneWidget);
    expect(find.text('暂停这项'), findsNothing);
  });

  testInTime('已归档时按钮变成「再来一轮」', (tester) async {
    await db.insertTask(
      _task().copyWith(status: domain.TaskStatus.archived),
      nowMs: _ts,
    );
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onStatusChange: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('再来一轮'), findsOneWidget);
  });

  testInTime('点「暂停这项」把目标状态交出去', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    domain.TaskStatus? got;
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onStatusChange: (_, s) async => got = s,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('暂停这项'));
    await tester.pumpAndSettle();
    expect(got, domain.TaskStatus.paused);
  });

  testInTime('点「删除」把项目交出去（确认框由调用方负责）', (tester) async {
    await db.insertTask(_task(), nowMs: _ts);
    String? deleted;
    await tester.pumpWidget(
      _wrap(
        TaskDetailPage(
          service: TaskDetailService(db),
          taskId: 't1',
          onDelete: (t) async => deleted = t.id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, 't1');
  });
}
