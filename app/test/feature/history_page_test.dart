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

  test('历史服务暴露的库就是自己那个', () {
    expect(HistoryService(db).db, same(db));
  });
}
