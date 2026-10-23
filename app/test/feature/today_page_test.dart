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
import 'package:famdaily/feature/home/today_page.dart';
import 'package:famdaily/feature/home/today_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

domain.Member _member(String id, String name, int sort) => domain.Member(
  id: id,
  name: name,
  sortOrder: sort,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _task(String id, String memberId, String name, int hour) =>
    domain.Task(
      id: id,
      memberId: memberId,
      name: name,
      repeat: const domain.RepeatRule(),
      time: domain.FixedTimesRule([domain.LocalTime(hour, 0)]),
      course: domain.Course.none,
      status: domain.TaskStatus.active,
      createdAtMs: _ts,
      updatedAtMs: _ts,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  late AppDatabase db;
  late TodayService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = TodayService(db);
    await db
        .into(db.members)
        .insert(Mappers.memberToCompanion(_member('m1', '爷爷', 0)));
  });

  tearDown(() async => db.close());

  testWidgets('空状态给出"新建打卡项"入口', (tester) async {
    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));

    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.timeline,
          onLayoutChanged: (_) {},
          onTapRow: (_, {required tappedCircle}) {},
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    expect(find.text('还没有打卡项'), findsOneWidget);
    expect(find.text('新建打卡项'), findsOneWidget);
  });

  testWidgets('时间轴按三组渲染，超时项带"迟 N 分钟"', (tester) async {
    await db.insertTask(_task('t1', 'm1', '早读', 7), nowMs: _ts);
    await db.insertTask(_task('t2', 'm1', '跳绳', 20), nowMs: _ts);

    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));

    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.timeline,
          onLayoutChanged: (_) {},
          onTapRow: (_, {required tappedCircle}) {},
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    expect(find.text('今天漏了'), findsOneWidget);
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('早读'), findsOneWidget);
    expect(find.text('跳绳'), findsOneWidget);
    // 7:00 到 9:00 迟 120 分钟
    expect(find.textContaining('迟 120 分钟'), findsOneWidget);
    // 没有打卡的项，进度应为 0 / 2
    expect(find.text('0 / 2'), findsOneWidget);
  });

  testWidgets('成员视图按人分组，显示各自进度', (tester) async {
    await db
        .into(db.members)
        .insert(Mappers.memberToCompanion(_member('m2', '小宝', 1)));
    await db.insertTask(_task('t1', 'm1', '降压药', 8), nowMs: _ts);
    await db.insertTask(_task('t2', 'm2', '早读', 7), nowMs: _ts);

    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));

    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.members,
          onLayoutChanged: (_) {},
          onTapRow: (_, {required tappedCircle}) {},
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    expect(find.text('爷爷'), findsOneWidget);
    expect(find.text('小宝'), findsOneWidget);
    expect(find.text('0 / 1'), findsNWidgets(2));
  });

  testWidgets('点圆圈会带 tappedCircle=true 回调', (tester) async {
    await db.insertTask(_task('t1', 'm1', '跳绳', 20), nowMs: _ts);
    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));

    bool? circleFlag;
    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.timeline,
          onLayoutChanged: (_) {},
          onTapRow: (row, {required tappedCircle}) {
            circleFlag = tappedCircle;
          },
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    // 点行内文字 → tappedCircle=false
    await tester.tap(find.text('跳绳'));
    await tester.pump();
    expect(circleFlag, isFalse);

    // 点右侧圆圈（InkResponse 在行尾）
    await tester.tap(find.byType(InkResponse).last);
    await tester.pump();
    expect(circleFlag, isTrue);
  });

  testWidgets('五态图标：准时实心勾、补卡空心勾、没做叉', (tester) async {
    for (final (id, h, state) in [
      ('t1', 6, 'done'),
      ('t2', 7, 'makeup'),
      ('t3', 8, 'skipped'),
    ]) {
      await db.insertTask(_task(id, 'm1', 'n$h', h), nowMs: _ts);
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c$id',
          taskId: id,
          date: domain.LocalDate(2025, 3, 1),
          slotIndex: 0,
          state: domain.CheckinState.values.byName(state),
          doneAtMs: _ts,
        ),
        nowMs: _ts,
      );
    }

    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));

    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.timeline,
          onLayoutChanged: (_) {},
          onTapRow: (_, {required tappedCircle}) {},
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    expect(find.text('已完成'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    // 「没做」不许标红（ui-spec 的产品红线），这里靠文案确认它被归到已完成组
    expect(find.textContaining('没做'), findsOneWidget);
  });

  testWidgets('点行文字区走 tappedCircle: false（进详情），点圆圈走 true（打卡）', (tester) async {
    await db.insertTask(_task('t1', 'm1', '早读', 7), nowMs: _ts);

    final view = await service.load(at: DateTime(2025, 3, 1, 9, 0));
    final taps = <bool>[];

    await tester.pumpWidget(
      _wrap(
        TodayPage(
          view: view,
          layout: HomeLayout.timeline,
          onLayoutChanged: (_) {},
          onTapRow: (_, {required tappedCircle}) => taps.add(tappedCircle),
          onNewTask: () {},
          onRefresh: () async {},
          loading: false,
        ),
      ),
    );

    // 点标题文字 → 文字区 → 详情
    await tester.tap(find.text('早读'));
    await tester.pump();
    expect(taps, [false]);

    // 点右边的状态圈 → 打卡。圆圈本身是 Container（不是 Icon），
    // 所以按 InkResponse 找它——那是唯一响应"点圈"的地方。
    await tester.tap(find.byType(InkResponse).first);
    await tester.pump();
    expect(taps, [false, true]);
  });
}
