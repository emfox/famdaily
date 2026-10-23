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
import 'package:famdaily/feature/stats/stats_page.dart';
import 'package:famdaily/feature/stats/stats_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

void main() {
  late AppDatabase db;
  late StatsService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = StatsService(db);
  });

  tearDown(() async => db.close());

  testWidgets('空数据时不画 0%，给一句人话', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StatsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('这段时间没有排过打卡项'), findsOneWidget);
    expect(find.text('完成率'), findsOneWidget);
    expect(find.text('准时率'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
    // 只有一个成员都没有时，"按成员"整段不出现。
    expect(find.text('按成员'), findsNothing);
  });

  testWidgets('不出现「连续打卡天数」这类字段', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StatsPage(service: service)));
    await tester.pumpAndSettle();

    // 需求 3.7：连续天数会逼人补卡污染数据，一律不显示。
    expect(find.textContaining('连续'), findsNothing);
    expect(find.textContaining('天数'), findsNothing);
    expect(find.textContaining('排名'), findsNothing);
  });

  testWidgets('区间切换有四个选项', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StatsPage(service: service)));
    await tester.pumpAndSettle();

    for (final label in ['本月', '上月', '近 90 天', '今年']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect(chips.first.selected, isTrue, reason: '默认本月');
  });

  testWidgets('切到「上月」后不影响界面（仍然渲染）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StatsPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '上月'));
    await tester.pumpAndSettle();

    final chips = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .toList();
    expect(chips[1].selected, isTrue);
    expect(find.text('这段时间没有排过打卡项'), findsOneWidget);
  });

  testWidgets('有多个成员时出现「按成员」与筛选下拉', (tester) async {
    for (final (i, name) in ['爷爷', '小宝'].indexed) {
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
    // 排两个项目，但不必打卡——只要槽位存在就够它出一行。
    final today = domain.LocalDate.fromDateTime(DateTime.now());
    for (final (i, memberId) in ['m0', 'm1'].indexed) {
      await db.into(db.tasks).insert(
        Mappers.taskToCompanion(
          domain.Task(
            id: 't$i',
            memberId: memberId,
            name: '吃药',
            repeat: const domain.RepeatRule(),
            time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
            course: domain.Course.none,
            status: domain.TaskStatus.active,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
    }
    await db.replaceSlots(
      [
        for (final id in ['t0', 't1'])
          SlotsCompanion.insert(
            taskId: id,
            date: today,
            slotIndex: 0,
            dueDate: today,
            dueTime: domain.LocalTime(8, 0),
          ),
      ],
      from: today,
      to: today,
      nowMs: _ts,
    );
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't0',
        date: today,
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _ts,
      ),
      nowMs: _ts,
    );

    await tester.pumpWidget(MaterialApp(home: StatsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('按成员'), findsOneWidget);
    expect(find.text('爷爷'), findsWidgets);
    expect(find.text('小宝'), findsWidgets);
    expect(find.byType(DropdownButton<String?>), findsOneWidget);
    // 完成率那一行有 50% / 50%（爷爷 1/1 完成但小宝 0/1 → 合计 50%）。
    expect(find.textContaining('共 2 次该做，做了 1 次'), findsOneWidget);
  });
}
