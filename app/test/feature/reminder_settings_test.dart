import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/notification/notification_ids.dart';
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:famdaily/feature/settings/reminder_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  group('设置存储', () {
    late AppDatabase db;
    late ReminderSettingsStore store;

    setUp(() {
      db = AppDatabase.forTesting(openTestConnection());
      store = ReminderSettingsStore(db);
    });

    tearDown(() async => db.close());

    test('空库时给默认值：全开、15 分钟、免打扰关', () async {
      final s = await store.load();

      expect(s.enabled, isTrue);
      expect(s.followupEnabled, isTrue);
      expect(s.followupMinutes, 15);
      expect(s.quietEnabled, isFalse);
      expect(s.summary, contains('顺延'));
    });

    test('写进去再读回来一模一样', () async {
      final s = ReminderSettings(
        enabled: true,
        followupEnabled: false,
        followupMinutes: 30,
        quietStart: LocalTime(22, 30),
        quietEnd: LocalTime(7, 0),
      );
      await store.save(s, at: DateTime(2025, 3, 3));

      expect(await store.load(), s);
    });

    test('关免打扰是真的删键，不是写 00:00', () async {
      await store.save(
        ReminderSettings(
          enabled: true,
          followupEnabled: true,
          followupMinutes: 15,
          quietStart: LocalTime(22, 0),
          quietEnd: LocalTime(7, 0),
        ),
        at: DateTime(2025, 3, 3),
      );
      await store.save(
        ReminderSettings.defaults,
        at: DateTime(2025, 3, 3),
      );

      expect(await db.getSetting('reminders.quietStart'), isNull);
      expect(await db.getSetting('reminders.quietEnd'), isNull);
    });

    test('只有半条区间时当成没启用，而不是造出一条坏区间', () async {
      await db.setSetting('reminders.quietStart', '22:00', nowMs: _ts);

      final s = await store.load();
      expect(s.quietEnabled, isFalse);
    });

    test('库里的时刻是乱码时也不崩', () async {
      await db.setSetting('reminders.quietStart', '乱写的', nowMs: _ts);
      await db.setSetting('reminders.quietEnd', '07:00', nowMs: _ts);

      expect((await store.load()).quietEnabled, isFalse);
    });

    test('免打扰的显示文案是 22:30 – 7:00（分钟补零，小时不补）', () async {
      final s = ReminderSettings(
        enabled: true,
        followupEnabled: true,
        followupMinutes: 15,
        quietStart: LocalTime(22, 30),
        quietEnd: LocalTime(7, 0),
      );
      expect(s.quietLabel, '22:30 – 7:00');
    });
  });

  group('催办开关（领域层）', () {
    final day = LocalDate(2025, 3, 3);
    final now = LocalDateTimeRef(day, LocalTime(7, 0));

    List<PlannedNotification> plan({required bool followupEnabled}) {
      final expanded = Scheduler.expand(
        specs: [
          ScheduleSpec(
            taskId: 't1',
            repeat: const RepeatRule(),
            time: FixedTimesRule([LocalTime(8, 0)]),
            course: Course.none,
          ),
        ],
        from: day,
        to: day,
      );
      return NotificationPlanner.plan(
        expanded: expanded.slots,
        labels: const {'t1': (taskName: '吃药', memberName: '爷爷')},
        now: now,
        filters: PlannedFilters(followupEnabled: followupEnabled),
      );
    }

    test('开着时一个槽位产生两条（提醒 + 催办）', () {
      final out = plan(followupEnabled: true);
      expect(out, hasLength(2));
      expect(out.map((p) => p.kind), [ReminderKind.due, ReminderKind.followup]);
    });

    test('关掉后只剩到点提醒', () {
      final out = plan(followupEnabled: false);
      expect(out, hasLength(1));
      expect(out.single.kind, ReminderKind.due);
    });
  });

  group('提醒设置页', () {
    late AppDatabase db;
    late ReminderSettingsStore store;
    var rescheduled = 0;

    setUp(() {
      db = AppDatabase.forTesting(openTestConnection());
      store = ReminderSettingsStore(db);
      rescheduled = 0;
    });

    tearDown(() async => db.close());

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          ReminderSettingsPage(
            store: store,
            reschedule: () async => rescheduled++,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('三个开关都画出来，默认状态跟库里一致', (tester) async {
      await pumpPage(tester);

      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      // adaptive 在测试平台（fuchsia/android）上是 SwitchListTile 子类，
      // 用 value 断言比 byType 更稳。
      expect(switches.map((s) => s.value), [true, true, false]);
      expect(find.text('到点提醒'), findsOneWidget);
      expect(find.text('没打卡再催一次'), findsOneWidget);
      expect(find.text('免打扰时段'), findsOneWidget);
    });

    testWidgets('关掉催办后立刻落库并重排，说明文字跟着变', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('没打卡再催一次'));
      await tester.pumpAndSettle();

      expect((await store.load()).followupEnabled, isFalse);
      expect(rescheduled, 1);
      expect(find.textContaining('只提醒一次'), findsOneWidget);
      // 延迟选择器收起来了。
      expect(find.text('15 分钟'), findsNothing);
    });

    testWidgets('换延迟到 30 分钟', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('30 分钟'));
      await tester.pumpAndSettle();

      expect((await store.load()).followupMinutes, 30);
      expect(rescheduled, 1);
      expect(find.textContaining('30 分钟后再提醒'), findsOneWidget);
    });

    testWidgets('打开免打扰给一对默认值 22:30 – 7:00', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('免打扰时段'));
      await tester.pumpAndSettle();

      final s = await store.load();
      expect(s.quietEnabled, isTrue);
      expect(s.quietStart, LocalTime(22, 30));
      expect(s.quietEnd, LocalTime(7, 0));
      expect(rescheduled, 1);
      expect(find.text('从 22:30'), findsOneWidget);
      expect(find.text('到 7:00'), findsOneWidget);
    });

    testWidgets('再关掉免打扰时键被删掉', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('免打扰时段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('免打扰时段'));
      await tester.pumpAndSettle();

      expect(await db.getSetting('reminders.quietStart'), isNull);
      expect((await store.load()).quietEnabled, isFalse);
    });

    testWidgets('总开关关掉后，下面两项变灰并给一句说明', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('到点提醒'));
      await tester.pumpAndSettle();

      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches[1].onChanged, isNull);
      expect(switches[2].onChanged, isNull);
      expect(find.textContaining('提醒总开关关着'), findsOneWidget);
    });

    testWidgets('改完设置后离开页面（返回上一页）不崩', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ReminderSettingsPage(
                      store: store,
                      reschedule: () async {},
                    ),
                  ),
                ),
                child: const Text('进提醒设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('进提醒设置'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('30 分钟'));
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('进提醒设置'), findsOneWidget);
    });
  });
}
