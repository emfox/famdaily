/// 行为类规格：返回键、导航、防重入。
///
/// 对应 `docs/e2e-test-spec.zh_CN.md` 里的 G-17、N-14、N-27、N-37。
library;

import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/feature/task_edit/task_edit_page.dart';
import 'package:famdaily/main.dart';
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
  final members = [_member('m1', '爷爷', 0), _member('m2', '小宝', 1)];

  /// 把新建页 push 进来，而不是当 `home`。
  ///
  /// 根路由不能被弹出（`canPop` 恒为 false），用 `home:` 就测不到
  /// "返回到底做了什么"——这正是最开始写错的地方。
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: famdailyTheme(Brightness.light),
        home: const Scaffold(body: Text('上一页')),
      ),
    );
    final ctx = tester.element(find.text('上一页'));
    unawaitedPush(ctx, TaskEditPage(members: members, onSave: (_) async {}));
    await tester.pumpAndSettle();
  }

  group('G-17 返回 = 退一层，顶栏 ‹ 与系统返回键行为一致', () {
    testWidgets('第 1 步按系统返回：直接关页面，不弹「还没保存」', (tester) async {
      await pump(tester);

      // 第 1 步选中一个模板会自动跳到第 2 步，所以这里什么都不点，
      // 直接模拟系统返回。
      final popped = await simulateSystemBack(tester);

      expect(popped, isTrue, reason: '第 1 步应当直接退出');
      expect(find.text('还没保存'), findsNothing);
    });

    testWidgets('第 2 步按系统返回：退回第 1 步，不是退整个页面', (tester) async {
      await pump(tester);
      // 点第一个模板 → 自动进第 2 步
      await tester.tap(find.text('吃药').first);
      await tester.pumpAndSettle();
      expect(find.text('基本信息'), findsOneWidget);

      final popped = await simulateSystemBack(tester);

      expect(popped, isFalse, reason: '页面不该关掉');
      expect(find.text('选模板'), findsOneWidget, reason: '应回到第 1 步');
      expect(find.text('基本信息'), findsNothing);
    });

    testWidgets('顶栏 ‹ 与系统返回给出同一个结果', (tester) async {
      await pump(tester);
      await tester.tap(find.text('吃药').first);
      await tester.pumpAndSettle();

      final popped = await simulateSystemBack(tester);
      expect(popped, isFalse);
      expect(find.text('选模板'), findsOneWidget);

      // 再点一次模板回到第 2 步，这回用顶栏的 ‹
      await tester.tap(find.text('吃药').first);
      await tester.pumpAndSettle();
      expect(find.text('基本信息'), findsOneWidget);
      await tester.tap(find.byTooltip('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('选模板'), findsOneWidget, reason: '两个入口结果必须一致');
    });
  });

  group('N-07 按钮文字恒定', () {
    testWidgets('第 2 步缺成员时按钮仍叫「下一步」，不是别的', (tester) async {
      await pump(tester);
      await tester.tap(find.text('吃药').first);
      await tester.pumpAndSettle();

      expect(find.text('下一步'), findsOneWidget);
    });
  });
}

/// 从当前页面推入一个新页面（不 await，因为 push 要等页面关掉才完成）。
void unawaitedPush(BuildContext context, Widget page) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => page),
  );
}

/// 模拟系统返回键，返回"页面是否被真的关掉了"。
///
/// 两步判断：先看 `maybePop()` 的返回值（false = 被 PopScope 拦下了），
/// 再看页面还在不在——只看前者会漏掉"拦截了但又自己 pop 了"的情况。
Future<bool> simulateSystemBack(WidgetTester tester) async {
  final ctx = tester.element(find.byType(Scaffold).first);
  final nav = Navigator.of(ctx);
  expect(nav.canPop(), isTrue, reason: '测试需要页面在一个可弹出的路由里');

  await nav.maybePop();
  await tester.pumpAndSettle();

  // 新建页还在 = 没被关掉。
  return find.byType(TaskEditPage).evaluate().isEmpty;
}
