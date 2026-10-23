import 'package:clock/clock.dart';
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
import 'package:famdaily/feature/history/day_detail_page.dart';
import 'package:famdaily/feature/history/history_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 页面自己读 `clock.now()` 判断"能不能改"。测试必须把时钟钉住，
/// 否则真实时间的今天会让所有历史日期一律只读（这条曾经真的踩过）。
DateTime? _pinned;

void main() {
  late AppDatabase db;
  late HistoryService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = HistoryService(db);
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
  });

  tearDown(() async => db.close());

  Future<void> seed(domain.LocalDate from, domain.LocalDate to) async {
    final task = domain.Task(
      id: 't1',
      memberId: 'm1',
      name: '降压药',
      repeat: const domain.RepeatRule(),
      time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
      course: domain.Course.none,
      status: domain.TaskStatus.active,
      createdAtMs: _ts,
      updatedAtMs: _ts,
    );
    await db.insertTask(task, nowMs: _ts);
    final result = Scheduler.expand(
      specs: [
        ScheduleSpec(
          taskId: task.id,
          repeat: task.repeat,
          time: task.time,
          course: task.course,
        ),
      ],
      from: from,
      to: to,
      maxSlots: 500,
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

  /// 页面自己读 `clock.now()` 判断"能不能改"，所以测试必须把时钟钉在
  /// 一个接近被测日期的时刻，否则真实时间的今天会让历史日期一律只读。
  Future<void> pumpDetail(
    WidgetTester tester,
    domain.LocalDate date, {
    DateTime? now,
  }) async {
    final at = now ?? date.toDateTime().add(const Duration(hours: 20));
    _pinned = at;
    await withClock(Clock.fixed(at), () async {
      await tester.pumpWidget(
        MaterialApp(
          home: DayDetailPage(service: service, date: date, db: db),
        ),
      );
      await tester.pumpAndSettle();
    });
  }

  /// 点击等交互也要在同一个时钟下——页面每次点击都会重读 `clock.now()`。
  Future<void> interact(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    await withClock(Clock.fixed(_pinned ?? DateTime(2026, 3, 2, 20)), body);
  }

  testWidgets('明细页画出三个统计块与项目行', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seed(d, d);
    await pumpDetail(tester, d);

    expect(find.text('完成'), findsOneWidget);
    expect(find.text('补卡'), findsOneWidget);
    expect(find.text('没做'), findsOneWidget);
    expect(find.text('降压药'), findsOneWidget);
    // 「爷爷」作为分组标题出现
    expect(find.text('爷爷'), findsOneWidget);
  });

  testWidgets('点了可补的行会弹出两个出口（不是直接打卡）', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seed(d, d);
    await pumpDetail(tester, d);

    await interact(tester, () async {
      await tester.tap(find.text('降压药'));
      await tester.pumpAndSettle();
    });

    // 复用首页同一个弹层，文案必须一致
    expect(find.textContaining('这件事最后怎么样'), findsOneWidget);
    expect(find.textContaining('做了，只是当时忘了记'), findsOneWidget);
    expect(find.text('没做'), findsWidgets);
  });

  testWidgets('选「没做」会落成 skipped，而不是 done', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seed(d, d);
    await pumpDetail(tester, d);

    await interact(tester, () async {
      await tester.tap(find.text('降压药'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没做').last);
      await tester.pumpAndSettle();
    });

    final records = await db.checkinsBetween(d, d);
    expect(records, hasLength(1));
    expect(records.single.state, domain.CheckinState.skipped);
  });

  testWidgets('选「做了但忘了记」落成 makeup', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seed(d, d);
    await pumpDetail(tester, d);

    await interact(tester, () async {
      await tester.tap(find.text('降压药'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('做了，只是当时忘了记'));
      await tester.pumpAndSettle();
    });

    final records = await db.checkinsBetween(d, d);
    expect(records.single.state, domain.CheckinState.makeup);
    // 补卡不进准时率
    final detail = await service.loadDay(d);
    expect(detail.summary.onTime, 0);
    expect(detail.summary.completionRate, 1.0);
  });

  testWidgets('已结案的行再点一下是撤销', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seed(d, d);
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
    await pumpDetail(tester, d);

    expect(find.text('准时'), findsOneWidget);
    await interact(tester, () async {
      await tester.tap(find.text('降压药'));
      await tester.pumpAndSettle();
    });

    final records = await db.checkinsBetween(d, d);
    expect(records, isEmpty);
  });

  testWidgets('超过 30 天只读：有提示且点了不弹层', (tester) async {
    final d = domain.LocalDate(2025, 1, 5);
    await seed(d, d);
    // 把"今天"放到 100 天后，这一天自然超出 30 天窗口
    await pumpDetail(tester, d, now: DateTime(2025, 4, 20, 10));

    expect(find.textContaining('只能看不能改'), findsOneWidget);

    await interact(tester, () async {
      await tester.tap(find.text('降压药'));
      await tester.pumpAndSettle();
    });
    // 不该弹出补卡弹层
    expect(find.textContaining('这件事最后怎么样'), findsNothing);
  });
}
