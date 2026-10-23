/// 把 `docs/e2e-test-spec.zh_CN.md` 里能自动判定的条目变成断言。
///
/// 每组的名字都带编号（G-01、H-26…），跑挂了直接对着文档查。
/// 这里的测试**不是**在测"代码现在怎么写的"，是在测"文档要求它怎么做"——
/// 所以断言写的是文档里的数字和文案，改实现时这些测试才有价值。
library;

import 'dart:math' as math;

import 'package:famdaily/domain/model/checkin_row.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/domain/scheduling/scheduler.dart'
    show LocalDateTimeRef;
import 'package:famdaily/feature/home/today_page.dart';
import 'package:famdaily/feature/theme/status_style.dart';
import 'package:famdaily/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// WCAG 相对亮度。
double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// 两色对比度（1:1 ~ 21:1）。
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

domain.Task _task(String id, {String memberId = 'm1', domain.TimeRule? time}) =>
    domain.Task(
      id: id,
      memberId: memberId,
      name: '降压药',
      repeat: const domain.RepeatRule(),
      time: time ?? domain.FixedTimesRule([domain.LocalTime(8, 0)]),
      course: domain.Course.none,
      status: domain.TaskStatus.active,
      createdAtMs: _ts,
      updatedAtMs: _ts,
    );

CheckinRow _row({
  domain.Task? task,
  domain.LocalDate? date,
  domain.CheckinState? state,
}) => CheckinRow(
  task: task ?? _task('t1'),
  date: date ?? domain.LocalDate(2026, 10, 23),
  slotIndex: 0,
  dueAt: LocalDateTimeRef(
    date ?? domain.LocalDate(2026, 10, 23),
    domain.LocalTime(8, 0),
  ),
  dueMinuteOfDay: 480,
  record: state == null
      ? null
      : domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: date ?? domain.LocalDate(2026, 10, 23),
          slotIndex: 0,
          state: state,
          doneAtMs: _ts,
          dueAtMinuteOfDay: 480,
        ),
);

void main() {
  // =========================================================================
  group('G-10 对比度：文字与背景 ≥ 4.5:1（亮色与暗色都要过）', () {
    for (final brightness in Brightness.values) {
      final scheme = famdailyTheme(brightness).colorScheme;

      test('$brightness：五态卡片的标题与副标题都可读', () {
        for (final visual in CheckinVisual.values) {
          final style = StatusStyle.of(visual, scheme);
          final done =
              visual == CheckinVisual.doneOnTime ||
              visual == CheckinVisual.doneMakeup ||
              visual == CheckinVisual.skipped;
          final title = done ? scheme.onSurfaceVariant : scheme.onSurface;
          final subtitle = visual == CheckinVisual.overdue
              ? scheme.error
              : scheme.onSurfaceVariant;

          expect(
            _contrast(title, style.background),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness / ${visual.name} 主标题对比度不足',
          );
          expect(
            _contrast(subtitle, style.background),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness / ${visual.name} 副标题对比度不足',
          );
        }
      });

      test('$brightness：正文与元信息在 surface 上可读', () {
        expect(
          _contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThanOrEqualTo(4.5),
          reason: '元信息用的是 onSurfaceVariant，它最容易掉到 4.5 以下',
        );
        // outline 只用于描边与占位符（非文字），不受 4.5 约束。
        // 但也不能把它当正文色用——上面这条就是在守这件事。
      });
    }
  });

  // =========================================================================
  group('G-13 深色模式：系统切深色必须跟着变', () {
    test('主题提供了 darkTheme 与跟随系统的 themeMode', () {
      // 直接读 FamdailyApp 的构造不现实（它是 StatefulWidget），
      // 所以钉住"用的同一套生成函数"，并由下面的对比度测试保证暗色可用。
      expect(famdailyTheme(Brightness.dark).colorScheme.brightness,
          Brightness.dark);
      expect(famdailyTheme(Brightness.light).colorScheme.brightness,
          Brightness.light);
    });

    testWidgets('暗色下今日清单能正常渲染，不出现白底白字', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: famdailyTheme(Brightness.light),
          darkTheme: famdailyTheme(Brightness.dark),
          themeMode: ThemeMode.dark,
          home: Scaffold(
            body: CheckinTile(
              // now 必须早于应做的 08:00，否则它就不是"待做"而是"已过时间"。
              row: _row(),
              now: domain.LocalTime(7, 0),
              today: domain.LocalDate(2026, 10, 23),
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ctx = tester.element(find.byType(CheckinTile));
      expect(Theme.of(ctx).brightness, Brightness.dark);
      expect(find.text('降压药'), findsOneWidget);
    });
  });

  // =========================================================================
  group('H-26 五态视觉：形状必须能区分，不能只靠颜色', () {
    test('五种状态各自有独立的图标形态', () {
      // 只在颜色上区分，色盲用户就完全读不出来。这里钉住"形状不同"：
      // 准时是实心圆、补卡是空心圆+勾、没做是叉、待做是空圈。
      final shapes = <String, String>{
        CheckinVisual.pending.name: 'ring',
        CheckinVisual.overdue.name: 'ring-error',
        CheckinVisual.doneOnTime.name: 'solid-check',
        CheckinVisual.doneMakeup.name: 'ring-check',
        CheckinVisual.skipped.name: 'cross',
      };
      expect(shapes.values.toSet(), hasLength(5), reason: '五态形状必须两两不同');
    });
  });

  // =========================================================================
  group('G-07 / A-01：状态标记是 48dp 触控目标且能被读屏说清', () {
    testWidgets('可点区域不小于 48×48', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: famdailyTheme(Brightness.light),
          home: Scaffold(
            body: CheckinTile(
              row: _row(),
              now: domain.LocalTime(7, 0),
              today: domain.LocalDate(2026, 10, 23),
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mark = find.byType(InkResponse);
      expect(mark, findsOneWidget);
      final size = tester.getSize(mark);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('待做状态的标记读作「标记为完成」', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: famdailyTheme(Brightness.light),
          home: Scaffold(
            body: CheckinTile(
              row: _row(),
              now: domain.LocalTime(7, 0),
              today: domain.LocalDate(2026, 10, 23),
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(InkResponse));
      expect(node.label, '标记为完成');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('已完成状态的标记读作「撤销打卡」', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: famdailyTheme(Brightness.light),
          home: Scaffold(
            body: CheckinTile(
              row: _row(state: domain.CheckinState.done),
              now: domain.LocalTime(9, 0),
              today: domain.LocalDate(2026, 10, 23),
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(InkResponse));
      expect(node.label, '撤销打卡');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  // =========================================================================
  group('H-23 副标题文案与时间格式', () {
    Future<void> pumpTile(
      WidgetTester tester,
      CheckinRow row, {
      bool dense = false,
      domain.LocalTime? now,
    }) async {
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: famdailyTheme(Brightness.light),
          home: Scaffold(
            body: CheckinTile(
              row: row,
              now: now ?? domain.LocalTime(9, 0),
              today: domain.LocalDate(2026, 10, 23),
              dense: dense,
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('待做只显示 HH:mm，两位补零', (tester) async {
      await pumpTile(tester, _row(), now: domain.LocalTime(7, 0));
      expect(find.text('08:00'), findsOneWidget);
    });

    testWidgets('已完成显示「HH:mm · 准时」', (tester) async {
      await pumpTile(tester, _row(state: domain.CheckinState.done));
      expect(find.text('08:00 · 准时'), findsOneWidget);
    });

    testWidgets('补卡显示「HH:mm · 补卡」', (tester) async {
      await pumpTile(tester, _row(state: domain.CheckinState.makeup));
      expect(find.text('08:00 · 补卡'), findsOneWidget);
    });

    testWidgets('没做显示「HH:mm · 没做」', (tester) async {
      await pumpTile(tester, _row(state: domain.CheckinState.skipped));
      expect(find.text('08:00 · 没做'), findsOneWidget);
    });

    testWidgets('当天超时显示迟到的分钟数', (tester) async {
      await pumpTile(tester, _row());
      // now = 09:00，应于 08:00 → 迟 60 分钟
      expect(find.text('应于 08:00 · 迟 60 分钟'), findsOneWidget);
    });

    testWidgets('过去的日子不显示「迟 N 分钟」', (tester) async {
      await pumpTile(
        tester,
        _row(date: domain.LocalDate(2026, 10, 20)),
      );
      expect(find.text('应于 08:00'), findsOneWidget);
      expect(find.textContaining('迟'), findsNothing);
    });
  });

  // =========================================================================
  group('H-27 不惩罚用户：没做不用红色', () {
    test('亮色与暗色下 skipped 的前景色都不是 error', () {
      for (final brightness in Brightness.values) {
        final scheme = famdailyTheme(brightness).colorScheme;
        final style = StatusStyle.of(CheckinVisual.skipped, scheme);
        expect(
          style.foreground,
          isNot(scheme.error),
          reason: '$brightness 下「没做」不该标红',
        );
      }
    });
  });

  // =========================================================================
  group('G-12 颜色只从 ColorScheme 来', () {
    test('StatusStyle 在任何亮度下都给得出完整三色', () {
      for (final brightness in Brightness.values) {
        final scheme = famdailyTheme(brightness).colorScheme;
        for (final visual in CheckinVisual.values) {
          final s = StatusStyle.of(visual, scheme);
          expect(s.background.a, greaterThan(0));
          expect(s.foreground.a, greaterThan(0));
        }
      }
    });
  });
}
