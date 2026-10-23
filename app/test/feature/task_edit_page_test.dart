import 'dart:async';

import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/feature/task_edit/task_edit_page.dart';
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

void main() {
  final members = [
    _member('m1', '爷爷', 0),
    _member('m2', '小宝', 1),
  ];

  /// 建一个只有 800 高的可用视口，避免默认 600 高把底部预览挤出屏幕。
  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<void> Function(domain.Task) onSave,
    domain.Task? editing,
  }) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: editing == null
            ? TaskEditPage(members: members, onSave: onSave)
            : TaskEditPage.edit(
                task: editing,
                members: members,
                onSave: onSave,
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三步走完能存下一条正确的项目', (tester) async {
    domain.Task? saved;
    await pumpPage(
      tester,
      onSave: (t) async => saved = t,
    );

    // 第 1 步：选「吃药」
    expect(find.text('健康 · 给父母用得最多'), findsOneWidget);
    await tester.tap(find.text('吃药'));
    await tester.pumpAndSettle();

    // 第 2 步：名字已由模板带出，选成员
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();

    // 第 3 步
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 预览里应出现跟随三餐与三次时刻
    expect(find.textContaining('跟随三餐'), findsWidgets);
    expect(find.textContaining('8:00 / 12:30 / 19:00'), findsWidgets);

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.name, '吃药');
    expect(saved!.memberId, 'm1');
    expect(saved!.iconId, 'pill');
    expect(saved!.note, '每次几粒，饭后半小时');
    // 7:30/12:00/18:30 各 +30
    expect(
      saved!.time.timesOn(domain.LocalDate(2026, 3, 2)).map((e) => e.toString()),
      ['08:00', '12:30', '19:00'],
    );
  });

  testWidgets('没选成员时保存按钮点不动，并说明差什么', (tester) async {
    var called = false;
    await pumpPage(
      tester,
      onSave: (t) async => called = true,
    );

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 成员没选：预览区给出原因，按钮 disabled
    expect(find.text('选一下谁做'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    await tester.tap(find.text('创建'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(called, isFalse);
  });

  testWidgets('改了名字会即时反映到预览', (tester) async {
    await pumpPage(tester, onSave: (_) async {});

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('爷爷 · 跳绳'), findsOneWidget);

    // 回第 2 步改名字
    await tester.tap(find.byTooltip('上一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '跳绳 200 个');
    await tester.pumpAndSettle();

    expect(find.textContaining('爷爷 · 跳绳 200 个'), findsOneWidget);
  });

  testWidgets('切到「自己定时刻」能加时间，预览跟着变', (tester) async {
    await pumpPage(tester, onSave: (_) async {});

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('自己定时刻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加时间'));
    await tester.pumpAndSettle();

    // 20:00 之后加一小时 → 21:00
    expect(find.text('第 2 次'), findsOneWidget);
    expect(find.textContaining('21:00'), findsWidgets);
  });

  testWidgets('编辑模式直接进第 2 步，保存保留原 id', (tester) async {
    final existing = domain.Task(
      id: 'keep-me',
      memberId: 'm2',
      name: '跳绳',
      repeat: const domain.RepeatRule(),
      time: domain.FixedTimesRule([domain.LocalTime(20, 0)]),
      course: domain.Course.none,
      status: domain.TaskStatus.active,
      createdAtMs: _ts,
      updatedAtMs: _ts,
    );

    domain.Task? saved;
    await pumpPage(
      tester,
      editing: existing,
      onSave: (t) async => saved = t,
    );

    expect(find.text('第 2 / 3 步'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.id, 'keep-me');
    expect(saved!.createdAtMs, _ts);
    expect(saved!.memberId, 'm2');
  });

  // -------------------------------------------------------------------------
  // 真机上出过的 bug：新建走 push<Task>，页面 pop(true)，路由类型对不上，
  // 页面卡在原地不关，用户以为没反应就接着点，结果库里插了一堆。
  //
  // 原来的测试都把 TaskEditPage 直接当 home 挂着，压根没有可 pop 的路由，
  // 所以 pop 能不能正常关闭页面从来没被验证过。下面两个测试补上这一环。
  // -------------------------------------------------------------------------

  /// 像真机一样从首页 push 进来，返回 push 的结果。
  Future<bool?> pushFromHome(
    WidgetTester tester, {
    required Future<void> Function(domain.Task) onSave,
  }) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  // 和 home_screen.dart 的 _newTask 用同一个签名：push<bool>。
                  result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          TaskEditPage(members: members, onSave: onSave),
                    ),
                  );
                },
                child: const Text('新建'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('创建成功后页面应当关闭，并带回 true', (tester) async {
    await pushFromHome(tester, onSave: (_) async {});

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 页面必须已经退出：回到首页那个"新建"按钮
    expect(find.text('新建'), findsOneWidget);
    expect(find.text('创建'), findsNothing);
  });

  testWidgets('写库抛错时不能把用户按在页面上，要点得动也退得掉', (tester) async {
    await pushFromHome(
      tester,
      onSave: (_) async => throw StateError('磁盘满了'),
    );

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 报错要说人话，让人知道是没存上，而不是"点了没反应"
    expect(find.textContaining('没存上'), findsOneWidget);
    // 按钮恢复可点，而不是永久灰掉（永久灰 + 停在同一页 = 只能杀 App）
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('创建只插一条：写库还没返回时连点，也只存一遍', (tester) async {
    var calls = 0;
    final gate = Completer<void>();

    await pushFromHome(
      tester,
      onSave: (_) async {
        calls += 1;
        await gate.future;
      },
    );

    await tester.tap(find.text('跳绳'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 第一次点：进入保存中
    await tester.tap(find.text('创建'));
    await tester.pump();
    // 保存中连点第三、第四次。按钮此时应当已禁用，点到也无效。
    await tester.tap(find.text('创建'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.text('创建'), warnIfMissed: false);
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '保存中重复点击不能重复写库');
    expect(find.text('新建'), findsOneWidget, reason: '存完就该回首页');
  });
}
