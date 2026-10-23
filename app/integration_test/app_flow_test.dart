/// 端到端：真 App、真数据库文件、真导航栈。
///
/// 跑法见 `tool/integration_test.sh`（Linux 桌面目标，不需要模拟器）。
///
/// 这里只放**单元测试测不出来**的东西：真实页面构造、真实导航、真实持久化。
/// 排程公式、统计口径、状态机那些该由单元测试保证的，不在这里重复。
///
/// 三条纪律：
///
/// 1. **不许直接构造页面**。必须从 `HomeShell` 起手，点底部导航过去。
///    用户报的「历史里人名变成已删除」正是"真实入口漏传依赖"，而所有页面级
///    Widget 测试都是自己把依赖塞进去的，所以那一层永远测不出来。
///
/// 2. **整个测试体活在同一个假时钟里**，用 `atTime` 而不是 `withClock`。
///    `withClock` 是 zone-scoped 的，而集成测试跑在 live binding 上——
///    页面的 `initState`/`build` 在**引擎那侧的另一个 zone**，读不到塞进
///    zone 的值。症状极迷惑：测试体里 `clock.now()` 明明是 3 月，日历却
///    画成 10 月。`atTime` 钉的是全局变量（见 `lib/app/test_clock.dart`）。
///
/// 3. **交互要跟真人一样"到位"**。这一条是花最多时间踩出来的：
///    - 打卡后会浮出「记一句 / 加张照片」面板，**必须收掉**，否则它的
///      遮罩会吃掉后面所有点击（点了"成功"，但什么都没发生）；
///    - 底部导航要在 `NavigationBar` 里找，不能用 `find.text('历史').last`
///      —— 首页详情里也有一行「历史」，点错地方 tab 不会切；
///    - 点了 tab 要**断言确实到了**（目标页在树上），没到就重点一次；
///    - 新建打卡项时多人家庭不会默认选你想要的成员，要显式点一下头像。
///
///    这些都不是 App 的 bug，是"测试自己走错了路"。它们最坑的地方在于
///    报错位置离真正的原因很远。
library;

import 'package:clock/clock.dart';
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/feature/history/history_page.dart';
import 'package:famdaily/feature/home/home_screen.dart';
import 'package:famdaily/feature/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

/// 固定"现在"：2026-03-02 20:00。
final _now = DateTime(2026, 3, 2, 20);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Harness h;

  setUp(() async => h = await Harness.create());
  tearDown(() async => h.dispose());

  /// 一路返回到带底部导航的根页面。
  ///
  /// 设置里的「成员」「导出备份」是 push 出来的二级页，停在上面时底部导航
  /// 根本不在树上。真人用手机会先按返回再切 tab，测试也得这么做。
  Future<void> popToRoot(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      // 判据用 NavigationBar 本身，不用文案。之前用 `find.text('今日')`，
      // 而首页的日期标题旁边也写着「今天/今日」之类的字，条件被假阳性满足，
      // 于是二级页上以为"已经在根页面"，`nav.pop()` 一次都没执行。
      if (find.byType(NavigationBar).evaluate().isNotEmpty) {
        return;
      }
      final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
      if (!nav.canPop()) {
        return;
      }
      nav.pop();
      await tester.pumpAndSettle();
    }
  }

  /// 起 App 并等首屏稳定。
  ///
  /// **必须在假时钟里 pump**。`HomeShell` 用 `IndexedStack` 预创建全部子页面，
  /// 历史页的月份光标在它的 `initState` 里对齐"今天"——也就是**首帧**。
  /// 若 `pumpWidget` 落在 `atTime` 外面，光标会被真实时钟锁死，
  /// 之后无论怎么切 tab 都停在真实月份（症状：测试找 3 月 2 日，页面上是 10 月）。
  /// 这和 App 的真实行为一致：真机上首帧那一刻的时钟就是它。
  Future<void> bootApp(WidgetTester tester) async {
    await atTime(_now, () async {
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
    });
  }

  /// 点底部导航，并确认真的切过去了。
  ///
  /// 两条踩过的坑：
  /// 1. 不能用 `find.text(label).last`。首页打卡详情里也有一行「历史」，
  ///    `.last` 会点到那个文本上，tab 根本没切，测试继续往下跑——
  ///    症状是"历史页是空的"，很容易误判成日历坏了。所以限定在
  ///    `NavigationBar` 里找。
  /// 2. 点了不等于到了。真机渲染下偶尔第一次点只触发水波纹（页面还在
  ///    过渡/滚动），`pumpAndSettle` 之后仍停在原地。这里断言目标页
  ///    在树上，没到就再点一次——测试宁可多点一次，也不要带着错误状态
  ///    往下跑然后在无关的地方报错。
  Future<void> goToTab(WidgetTester tester, String label) async {
    await popToRoot(tester);
    bool arrived() => switch (label) {
      '今日' => find.byType(HomeScreen).evaluate().isNotEmpty,
      '历史' => find.byType(HistoryPage).evaluate().isNotEmpty,
      '设置' => find.byType(SettingsPage).evaluate().isNotEmpty,
      _ => throw ArgumentError('未知 tab: $label'),
    };

    for (var attempt = 0; attempt < 3; attempt++) {
      final bar = find.byType(NavigationBar);
      expect(bar, findsOneWidget, reason: '根页面应该有底部导航栏');
      final target = find.descendant(of: bar, matching: find.text(label));
      expect(target, findsOneWidget, reason: '底部导航里应该有「$label」');
      await tester.tap(target);
      await tester.pumpAndSettle();
      if (arrived()) {
        return;
      }
    }
    fail('点了三次「$label」，页面还是没切过去');
  }

  /// 走完新建三步，建一条"每天一次"的打卡项。
  /// [forMember] 非空时，在第 2 步把成员换成它。
  ///
  /// 为什么必须显式选：页面对"谁做"有个贴心默认——只有一个成员就直接选上，
  /// 多个成员时沿用"上次建过的那个人"。家里有两个成员时，新建的打卡项会
  /// 默默挂到上一个成员名下。真人会点一下自己的头像，测试也得点，
  /// 否则断言"明细里显示奶奶"必然失败，而失败原因跟要测的东西毫无关系。
  Future<void> createTaskViaUi(
    WidgetTester tester, {
    required String taskName,
    String? forMember,
  }) async {
    // 首页右上角「⋮」→ 新建打卡项
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建打卡项').last);
    await tester.pumpAndSettle();

    // 第 1 步：选模板。
    //
    // 注意：点「都不是？自己起一个」**本身就是"选定了空白模板并进第 2 步"**，
    // 不需要再点「下一步」。多加一次就多走一步、直接跳到第 3 步——
    // 我在这里绕过一圈，症状是"第 2 步找不到"，而 App 完全正常。
    // 这正是集成测试的价值：它逼你看清用户实际点几下会发生什么。
    expect(find.text('选模板'), findsOneWidget);
    final blank = find.text('都不是？自己起一个');
    // 窄窗口下模板墙可能把这一行挤出视口，而 tap 点到够不着的位置
    // 不报错、只是什么都不发生。
    await tester.ensureVisible(blank);
    await tester.pumpAndSettle();
    await tester.tap(blank);
    await tester.pumpAndSettle();

    // 第 2 步：基本信息。用顶栏「第 2 / 3 步」断言，它由步数直接算出。
    expect(find.text('第 2 / 3 步'), findsOneWidget, reason: '没进到第 2 步');
    await tester.enterText(find.byType(TextField).first, taskName);
    await tester.pumpAndSettle();
    if (forMember != null) {
      final pick = find.text(forMember);
      expect(pick, findsWidgets, reason: '第 2 步应该能选「$forMember」');
      await tester.ensureVisible(pick.first);
      await tester.pumpAndSettle();
      await tester.tap(pick.first);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 第 3 步：什么时候做 → 创建。
    expect(find.text('第 3 / 3 步'), findsOneWidget, reason: '没进到第 3 步');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
  }

  /// 关掉打卡后浮出来那个「记一句 / 加张照片」面板。
  ///
  /// 为什么要专门处理：打卡成功会 `showModalBottomSheet` 出一个面板，
  /// 它带着 ModalBarrier 盖住整屏。不收掉的话后面点底部导航全被遮罩吃掉——
  /// 点击"成功"了但什么都没发生，症状是"切不到历史页"。真人会往下一划、
  /// 点一下上方的空白、或者按返回，这里就用「点面板上方的空白」。
  ///
  /// 注意不能用 `find.byType(ModalBarrier)` 的数量来判断是否关掉：
  /// Navigator 自己常驻一层遮罩，数量从 2 变成 1 才是真的关掉了。
  /// 所以判据是「那个面板（BottomSheet）还在不在」。
  Future<void> dismissSheet(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      if (find.byType(BottomSheet).evaluate().isEmpty) {
        return;
      }
      // 面板贴着屏幕底部，点屏幕中间偏上一定落在面板外面。
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.tapAt(Offset(size.width / 2, size.height * 0.15));
      await tester.pumpAndSettle();
    }
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: '打卡后的面板没关掉，后面的点击都会被遮罩吃掉',
    );
  }

  /// 点掉今日列表里第一个"待办"状态圈，然后把浮出来的面板收掉。
  ///
  /// 用无障碍标签找，不用图标：那个圈是**画出来的** Container（空心圆／
  /// 实心圆／叉三种状态共用同一个位置），没有对应 Icon，按图标找必然是 0 个。
  /// 按语义标签找还有个额外好处——它顺便证明了打卡入口对读屏软件可用；
  /// 哪天有人把这个 Semantics 删了，这条测试会一起红。
  ///
  /// **打完必须收面板**：打卡成功会浮出「记一句 / 加张照片」的
  /// `showModalBottomSheet`，它带着一层 ModalBarrier 盖住整屏。不收掉的话
  /// 后面点底部导航全被遮罩吃掉——点击"成功"了但什么都没发生，症状是
  /// "切不到历史页"。真人会往下一划或者按返回，这里按返回。
  Future<void> checkInFirst(WidgetTester tester) async {
    final mark = find.bySemanticsLabel('标记为完成');
    expect(mark, findsWidgets, reason: '今日列表里应该有可打卡的状态圈');
    await tester.tap(mark.first);
    await tester.pumpAndSettle();
    await dismissSheet(tester);
  }

  /// 打开历史页里"某一天"的明细。
  Future<void> openDayInHistory(
    WidgetTester tester,
    domain.LocalDate date,
  ) async {
    await goToTab(tester, '历史');
    // 历史页停在别的月份时，月历上当然找不到这一天。真人会点「今天」回来，
    // 测试也走同一个按钮——而不是去翻月，那样绕过了用户真正的补救路径。
    final wanted = '${date.year} 年 ${date.month} 月';
    if (find.text(wanted).evaluate().isEmpty) {
      final today = find.text('今天');
      expect(today, findsWidgets, reason: '月份不对时，页面上该有「今天」按钮');
      await atTime(_now, () async {
        await tester.tap(today.first);
        await tester.pumpAndSettle();
      });
    }
    expect(
      find.text(wanted),
      findsOneWidget,
      reason: '历史页应该显示 ${date.month} 月',
    );

    final day = find.text('${date.day}');
    expect(day, findsWidgets, reason: '月历上应该有 ${date.month} 月 ${date.day} 日');
    await tester.tap(day.first);
    await tester.pumpAndSettle();
  }

  // ---------------------------------------------------------------------
  // 1. 线上报过的那条路径，一步不抄近路
  // ---------------------------------------------------------------------

  testWidgets('新建成员 → 建打卡项 → 打卡 → 切历史看当天：显示真名', (tester) async {
    await atTime(_now, () async {
      await bootApp(tester);

      // 设置 → 成员 → 新增
      await goToTab(tester, '设置');
      await tester.tap(find.text('成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增'));
      await tester.pumpAndSettle();

      // 成员编辑页：填名字，保存
      await tester.enterText(find.byType(TextField).first, '奶奶');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // 库为凭：新成员必须真的建出来了，否则后面失败会分不清原因
      final members = await h.db.listMembers();
      expect(
        members.map((m) => m.name),
        contains('奶奶'),
        reason: '点「新增」保存后，成员必须落库',
      );

      // 回今日 → 给他建一条卡 → 打卡
      await goToTab(tester, '今日');
      await createTaskViaUi(tester, taskName: '降压药', forMember: '奶奶');
      expect(find.text('降压药'), findsOneWidget, reason: '新建的打卡项要出现在今日');
      await checkInFirst(tester);

      // 切历史 → 点今天
      await openDayInHistory(tester, domain.LocalDate.fromDateTime(_now));

      // 核心断言
      expect(
        find.text('不认识的成员'),
        findsNothing,
        reason: '这个占位文案意味着明细页没读到成员表——真实入口漏了依赖',
      );
      expect(find.text('已删除的成员'), findsNothing);
      expect(find.text('降压药'), findsOneWidget, reason: '明细页要列出那天做的事');
      expect(
        find.textContaining('奶奶'),
        findsWidgets,
        reason: '那天是谁做的，必须显示真名',
      );
    });
  });

  // ---------------------------------------------------------------------
  // 2. 真持久化：杀掉再开，数据还在
  // ---------------------------------------------------------------------

  testWidgets('打卡数据真的落盘：重新打开同一个库文件还能读到', (tester) async {
    // 这条只能在集成测试里做。Widget 测试用内存库，
    // "写进去了"和"存下来了"是两件事。
    await atTime(_now, () async {
      await bootApp(tester);
      await createTaskViaUi(tester, taskName: '跳绳');
      await checkInFirst(tester);

      expect((await h.db.listAllTasks()).map((t) => t.name), contains('跳绳'));

      final today = domain.LocalDate.fromDateTime(_now);
      final records = await h.db.checkinsBetween(today, today);
      expect(records, isNotEmpty, reason: '点过状态圈，库里就该有一条记录');
      expect(records.first.state, domain.CheckinState.done);

      // 关掉，按同一个文件重开
      final file = h.dbFile;
      expect(file.existsSync(), isTrue);
      await h.db.close();

      final reopened = await reopenDatabase(file);
      addTearDown(reopened.close);
      expect(
        (await reopened.listAllTasks()).map((t) => t.name),
        contains('跳绳'),
        reason: '重开之后项目丢了 = 数据其实没落盘',
      );
      expect(
        await reopened.checkinsBetween(today, today),
        isNotEmpty,
        reason: '重开之后打卡记录丢了',
      );
    });
  });

  // ---------------------------------------------------------------------
  // 3. 打卡之后那条提醒不能还响
  // ---------------------------------------------------------------------

  testWidgets('界面点一下打卡，会真的走到提醒层（取消或重排）', (tester) async {
    await atTime(_now, () async {
      await bootApp(tester);
      await createTaskViaUi(tester, taskName: '量血压');

      final appliedBefore = h.gateway.applyCount;
      await checkInFirst(tester);

      final cancelled = h.gateway.cancelledSlotIds.isNotEmpty;
      final rescheduled = h.gateway.applyCount > appliedBefore;
      expect(
        cancelled || rescheduled,
        isTrue,
        reason: '打卡后既没取消槽位、也没重排，系统里那条提醒还会再响一次',
      );
    });
  });

  // ---------------------------------------------------------------------
  // 4. 三个 tab 都能进，不抛异常
  // ---------------------------------------------------------------------

  testWidgets('底部三个 tab 来回切，不抛异常', (tester) async {
    await atTime(_now, () async {
      await bootApp(tester);
      await goToTab(tester, '历史');
      await goToTab(tester, '设置');
      await goToTab(tester, '今日');
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // 5. 删掉的成员：历史里名字还在，并标注「已删除」
  // ---------------------------------------------------------------------

  testWidgets('删掉成员后，历史明细仍显示真名 + 「已删除」', (tester) async {
    await atTime(_now, () async {
      await bootApp(tester);
      await createTaskViaUi(tester, taskName: '散步');
      await checkInFirst(tester);

      final victim = (await h.db.listMembers()).first;
      await h.db.deleteMember(
        victim.id,
        nowMs: clock.now().millisecondsSinceEpoch,
      );

      await openDayInHistory(tester, domain.LocalDate.fromDateTime(_now));

      // 名字要留（历史信息不能被抹掉），标注也在
      expect(
        find.textContaining(victim.name),
        findsWidgets,
        reason: '成员删了，那天是谁做的这条信息仍然要留住',
      );
      expect(find.text('已删除'), findsOneWidget);
      expect(find.text('不认识的成员'), findsNothing);
    });
  });
}
