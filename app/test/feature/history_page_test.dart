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
import 'package:famdaily/feature/history/history_page.dart';
import 'package:famdaily/feature/history/history_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 历史页**整条链路**的测试：从月历点进去，看明细页到底长什么样。
///
/// 为什么必须有这一层：`day_detail_page_test.dart` 是自己把 `db` 塞给
/// 明细页的，于是"历史页忘了传 db"这种错在那一层永远测不出来——
/// 页面不崩、不报错，只是所有分组标题都变成「不认识的成员」。
/// 组件单测绿 + 真实入口坏，是这类"漏传依赖"故障的典型样子。
void main() {
  late AppDatabase db;
  late HistoryService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = HistoryService(db);
  });

  tearDown(() async => db.close());

  /// 模拟用户真实操作：新建成员 → 给他建一项 → 打上卡。
  Future<void> seedNewMemberCheckedIn(
    domain.LocalDate date, {
    String memberId = 'm1',
    String name = '小明',
    String taskId = 't1',
    String taskName = '刷牙',
  }) async {
    await db.insertMember(
      domain.Member(
        id: memberId,
        name: name,
        sortOrder: 0,
        createdAtMs: _ts,
        updatedAtMs: _ts,
      ),
      nowMs: _ts,
    );
    final task = domain.Task(
      id: taskId,
      memberId: memberId,
      name: taskName,
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
      from: date,
      to: date,
      maxSlots: 50,
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
      from: date,
      to: date,
      nowMs: _ts,
    );
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: task.id,
        date: date,
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _ts,
        dueAtMinuteOfDay: 480,
      ),
      nowMs: _ts,
    );
  }

  /// 打开历史页，点日历上那个日期，进入当天明细。
  Future<void> openDay(WidgetTester tester, domain.LocalDate date) async {
    // 页面自己读 clock.now() 定位"这个月"、判断可编辑窗口，必须钉住时钟。
    final at = date.toDateTime().add(const Duration(hours: 20));
    await withClock(Clock.fixed(at), () async {
      await tester.pumpWidget(
        MaterialApp(home: HistoryPage(service: service, onOpenStats: null)),
      );
      await tester.pumpAndSettle();
      // 点日历格：日期数字是那天唯一一个纯数字文本。
      await tester.tap(find.text('${date.day}').first);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('真实入口：新建成员当天打完卡，从历史页进去看得到他的名字', (tester) async {
    // 用户报的现象：成员是刚新建的、没删过，建一条打卡并打卡，
    // 切到历史看当天，人却显示成"已删除的成员"这类占位。
    //
    // 根因不在统计、也不在成员表，而是历史页打开明细页时**没传 db**：
    // 明细页拿不到成员表，只能把每一组都写成「不认识的成员」。
    final d = domain.LocalDate(2026, 3, 2);
    await seedNewMemberCheckedIn(d);

    await openDay(tester, d);

    expect(find.text('小明'), findsOneWidget);
    expect(
      find.text('不认识的成员'),
      findsNothing,
      reason: '成员还在，名字必须画出来——定位不到成员说明成员表根本没读',
    );
    expect(find.text('已删除'), findsNothing);
    expect(find.text('刷牙'), findsOneWidget);
  });

  testWidgets('真实入口：删掉的成员仍以真名出現，并标注「已删除」', (tester) async {
    final d = domain.LocalDate(2026, 3, 2);
    await seedNewMemberCheckedIn(d);
    await db.deleteMember('m1', nowMs: _ts + 1);

    await openDay(tester, d);

    // 名字照留：历史里"那天是谁做的"不该因为人走了就消失。
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('不认识的成员'), findsNothing);
  });

  testWidgets('历史页交给明细页的库不为空', (tester) async {
    // 直接守住那条约定：service.db 必须是明细页读成员表用的同一个库。
    expect(service.db, same(db));
  });

  group('跨月：挂后台很久再回来，日历要跟上今天', () {
    // 这一组守的是一个**真实会被用户碰到**的毛病：`_cursor` 只在 initState
    // 对齐过"今天"，之后除了翻月永不重算。手机上的 App 一挂后台就是几天，
    // 回来时历史页还停在启动那天所在的月份——最糟的情况是「今天」那格
    // 根本不在当前月里，用户以为当天的记录没了。
    //
    // 冷启动（重启 App）能自愈，所以只在"没杀进程、直接切回来"时暴露。
    Future<void> pumpHistoryAt(WidgetTester tester, DateTime at) async {
      await withClock(Clock.fixed(at), () async {
        await tester.pumpWidget(
          MaterialApp(home: HistoryPage(service: service, onOpenStats: null)),
        );
        await tester.pumpAndSettle();
      });
    }

    /// 模拟切后台再切回来。页面在后台的整段时间里，假时钟是**新的**时间。
    Future<void> resumeAt(WidgetTester tester, DateTime at) async {
      await withClock(Clock.fixed(at), () async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('从 3 月挂到 4 月，回来就显示 4 月', (tester) async {
      await pumpHistoryAt(tester, DateTime(2026, 3, 31, 22));
      expect(find.text('2026 年 3 月'), findsOneWidget);

      await resumeAt(tester, DateTime(2026, 4, 1, 9));

      expect(
        find.text('2026 年 4 月'),
        findsOneWidget,
        reason: '跨月了还停在 3 月，「今天」那格根本不在页面上',
      );
      expect(find.text('2026 年 3 月'), findsNothing);
    });

    testWidgets('跨年也要跟：12 月挂到次年 1 月', (tester) async {
      await pumpHistoryAt(tester, DateTime(2026, 12, 30, 22));
      expect(find.text('2026 年 12 月'), findsOneWidget);

      await resumeAt(tester, DateTime(2027, 1, 2, 9));

      expect(find.text('2027 年 1 月'), findsOneWidget);
    });

    testWidgets('同月回来不动：不打断用户正在看的月份', (tester) async {
      await pumpHistoryAt(tester, DateTime(2026, 3, 2, 8));

      await resumeAt(tester, DateTime(2026, 3, 2, 20));

      expect(find.text('2026 年 3 月'), findsOneWidget);
    });

    testWidgets('用户自己翻过月，回来就别拽他回去', (tester) async {
      // 翻到上个月对比数据，切出去回个微信再回来——被拽回本月很讨厌。
      await pumpHistoryAt(tester, DateTime(2026, 3, 2, 8));
      expect(find.text('2026 年 3 月'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text('2026 年 2 月'), findsOneWidget);

      await resumeAt(tester, DateTime(2026, 4, 3, 9));

      expect(
        find.text('2026 年 2 月'),
        findsOneWidget,
        reason: '用户手动翻的月份必须留住',
      );
    });

    testWidgets('翻过月之后点「今天」，跟着今天的逻辑重新生效', (tester) async {
      await pumpHistoryAt(tester, DateTime(2026, 3, 2, 8));
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text('2026 年 2 月'), findsOneWidget);

      // 点「今天」回本月（此刻还是 3 月 2 日）。
      // 「今天」这个按钮的 onPressed 会读 clock.now()，点击本身也得在假时钟里，
      // 否则它会把光标带到**真实**的今天（跑测试那天），后面全对不上。
      await withClock(Clock.fixed(DateTime(2026, 3, 2, 8)), () async {
        await tester.tap(find.text('今天'));
        await tester.pumpAndSettle();
      });
      expect(find.text('2026 年 3 月'), findsOneWidget);

      await resumeAt(tester, DateTime(2026, 4, 3, 9));

      expect(
        find.text('2026 年 4 月'),
        findsOneWidget,
        reason: '点过「今天」就等于放弃手动翻月，应该重新跟随',
      );
    });
  });

  test('历史服务暴露的库就是自己那个', () {
    expect(HistoryService(db).db, same(db));
  });
}
