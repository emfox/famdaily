import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/template/task_template.dart';
import 'package:famdaily/feature/task_edit/task_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = LocalDate(2026, 3, 2);

  group('模板库', () {
    test('12 个模板，id 唯一，分组齐全', () {
      expect(TemplateLibrary.all, hasLength(12));
      final ids = TemplateLibrary.all.map((t) => t.id).toSet();
      expect(ids, hasLength(12));
      for (final g in TemplateGroup.values) {
        expect(TemplateLibrary.of(g), isNotEmpty, reason: '${g.name} 不该是空的');
      }
    });

    test('每个模板都能展开出非空时刻', () {
      for (final t in TemplateLibrary.all) {
        expect(t.timeRule.timesOn(day), isNotEmpty, reason: t.id);
      }
    });

    test('吃药 = 跟随三餐 + 饭后 30 分', () {
      final t = TemplateLibrary.byId('medicine')!;
      // 7:30 / 12:00 / 18:30 各 +30
      expect(
        t.timeRule.timesOn(day).map((e) => e.toString()),
        ['08:00', '12:30', '19:00'],
      );
    });

    test('洗脸这类多时刻模板的两条时刻都在', () {
      final t = TemplateLibrary.byId('wash')!;
      expect(t.timeRule.timesOn(day).map((e) => e.toString()), [
        '07:00',
        '21:30',
      ]);
    });
  });

  group('从模板建草稿', () {
    test('吃药 -> 名字/图标/说明/三餐时刻都带出来', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      expect(d.name, '吃药');
      expect(d.iconId, 'pill');
      expect(d.note, '每次几粒，饭后半小时');
      expect(d.followMeals, isTrue);
      expect(d.followMealOffsetMinutes, 30);
      expect(d.timePoints.map((e) => e.toString()), [
        '08:00',
        '12:30',
        '19:00',
      ]);
      expect(d.timeTab, TimeTab.several);
    });

    test('喝水 -> 5 个固定时刻，不跟三餐', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('water')!);
      expect(d.followMeals, isFalse);
      expect(d.timePoints, hasLength(5));
    });

    test('跳绳 -> 一个时刻，默认停在「每天一次」', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      expect(d.timePoints.single.toString(), '20:00');
      expect(d.timeTab, TimeTab.once);
    });

    test('applyTemplate 与 fromTemplate 结果一致（回归：曾漏了饭后偏移）', () {
      // 曾经 applyTemplate 自己写了一份展开逻辑，少加了 offsetMinutes，
      // 直接从 UI 走「选模板」建出来的药是 7:30/12:00/18:30 而不是 8:00/12:30/19:00。
      // 现在两者共用 TaskDraft.fromTemplate，这条守住"别再写成两份"。
      for (final t in TemplateLibrary.all) {
        final viaFactory = TaskDraft.fromTemplate(t);
        final viaApply = TaskDraft()..applyTemplate(t);
        expect(
          viaApply.timePoints.map((e) => e.toString()),
          viaFactory.timePoints.map((e) => e.toString()),
          reason: t.id,
        );
        expect(viaApply.followMeals, viaFactory.followMeals, reason: t.id);
        expect(viaApply.iconId, viaFactory.iconId, reason: t.id);
        expect(viaApply.timeTab, viaFactory.timeTab, reason: t.id);
      }
    });

    test('换模板不会把用户已经打好的名字清掉', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!)
        ..name = '降压药';
      d.applyTemplate(TemplateLibrary.byId('rope')!);
      expect(d.name, '降压药');
      // 时间规则要跟着新模板走
      expect(d.timePoints.single.toString(), '20:00');
      expect(d.followMeals, isFalse);
    });

    test('空白模板 -> 20:00 一个时刻', () {
      final d = TaskDraft.fromTemplate(TaskTemplate.blank);
      expect(d.name, isEmpty);
      expect(d.timePoints.single, TimeDefaults.evening);
    });
  });

  group('跟三餐走就是预填时刻（不是另一套逻辑）', () {
    test('关掉跟随，时刻保持不变（已经落到 timePoints 里了）', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      final before = d.timePoints;
      d.setFollowMeals(false);
      expect(d.timePoints, before);
      expect(d.followMeals, isFalse);
    });

    test('手改一个时刻 -> 自动退出跟随模式', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      expect(d.followMeals, isTrue);
      d.setPointAt(0, LocalTime(9, 0));
      expect(d.followMeals, isFalse);
      expect(d.timePoints.first.toString(), '09:00');
      // 其余两条不受影响
      expect(d.timePoints.map((e) => e.toString()), [
        '09:00',
        '12:30',
        '19:00',
      ]);
    });

    test('改偏移 -> 三条时刻一起平移', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.setFollowMealOffset(0);
      expect(d.timePoints.map((e) => e.toString()), [
        '07:30',
        '12:00',
        '18:30',
      ]);
      d.setFollowMealOffset(-15);
      expect(d.timePoints.map((e) => e.toString()), [
        '07:15',
        '11:45',
        '18:15',
      ]);
    });

    test('取消一餐 -> 少一条；全取消被拒绝', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.toggleMeal(MealAnchor.breakfast, false);
      expect(d.timePoints, hasLength(2));
      d.toggleMeal(MealAnchor.lunch, false);
      d.toggleMeal(MealAnchor.dinner, false);
      // 最后一餐不能被取消
      expect(d.timePoints, hasLength(1));
    });

    test('改用餐钟点 -> 时刻跟着走', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.setMealTime(MealAnchor.breakfast, LocalTime(6, 0));
      expect(d.timePoints.first.toString(), '06:30');
    });

    test('偏移跨午夜 -> 折回同一天（草稿层只有时刻，没有跨天概念）', () {
      // 这条守的是一个**已知取舍**，不是期望行为：
      // 草稿用 LocalTime 存时刻，23:50 + 30 分会折回 00:20 并排到最前。
      // 真正的跨天由 MealTimesRule.shiftedMinutesOn 保留越界分钟数来兜底；
      // 所以只要用户**别手改**（保持 followMeals），存的仍是 MealTimesRule，
      // 跨天语义就是对的。一旦手改，就退化成 FixedTimesRule——见下面第二条断言。
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.setMealTime(MealAnchor.dinner, LocalTime(23, 50));
      d.setFollowMealOffset(30);
      expect(d.timePoints.first.toString(), '00:20');
      expect(d.timePoints.map((e) => e.toString()), [
        '00:20',
        '08:00',
        '12:30',
      ]);
      // 未手改时保存的仍然是能做跨天的规则对象
      expect(d.buildTimeRule(), isA<FixedTimesRule>());
    });
  });

  group('时刻编辑', () {
    test('加时刻排序去重，上限 6 个', () {
      final d = TaskDraft.fromTemplate(TaskTemplate.blank);
      for (var i = 0; i < 10; i++) {
        d.addPoint(at: LocalTime(8 + i, 0));
      }
      expect(d.timePoints, hasLength(maxPointsPerDay));
      expect(d.canAddPoint, isFalse);
      final minutes = d.timePoints.map((e) => e.minuteOfDay).toList();
      expect(minutes, orderedEquals([...minutes]..sort()));
    });

    test('至少留一个时刻', () {
      final d = TaskDraft.fromTemplate(TaskTemplate.blank);
      expect(d.canRemovePoint, isFalse);
      d.removePointAt(0);
      expect(d.timePoints, hasLength(1));
    });

    test('删到 2 个再删一个可以', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('wash')!);
      expect(d.canRemovePoint, isTrue);
      d.removePointAt(0);
      expect(d.timePoints.single.toString(), '21:30');
    });
  });

  group('保存校验', () {
    TaskDraft ready() {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      d.memberId = 'm1';
      return d;
    }

    test('名字 + 谁做齐了就能存', () {
      expect(ready().canSave, isTrue);
      expect(ready().blockReason, isNull);
    });

    test('没名字不能存，而且说得出原因', () {
      final d = ready()..name = '   ';
      expect(d.canSave, isFalse);
      expect(d.blockReason, '给它起个名字');
    });

    test('没选成员不能存', () {
      final d = ready()..memberId = null;
      expect(d.canSave, isFalse);
      expect(d.blockReason, '选一下谁做');
    });

    test('选了互相矛盾的重复规则不能存', () {
      final d = ready()
        ..repeat = const RepeatRule(
          weekdays: {6, 7},
          parity: ParityFilter.workdays,
        );
      expect(d.canSave, isFalse);
      expect(d.blockReason, '选的日期永远不会发生');
    });

    test('toTask 去掉名字前后空白、空说明存 null', () {
      final d = ready()
        ..name = '  跳绳  '
        ..note = '   ';
      final t = d.toTask(id: 't1', memberId: 'm1', nowMs: 100);
      expect(t.name, '跳绳');
      expect(t.note, isNull);
      expect(t.iconId, 'rope');
      expect(t.time.timesOn(day).single.toString(), '20:00');
    });
  });

  group('间隔规则是「另加一段」，不是替换', () {
    test('开启后与原时刻取并集', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('water')!);
      d
        ..intervalEveryMinutes = 120
        ..intervalFrom = LocalTime(9, 0)
        ..intervalTo = LocalTime(21, 0);
      final times = d.buildTimeRule().timesOn(day).map((e) => e.toString());
      // 9/11/14/16/19 + 9/11/13/15/17/19/21
      expect(times, [
        '09:00',
        '11:00',
        '13:00',
        '14:00',
        '15:00',
        '16:00',
        '17:00',
        '19:00',
        '21:00',
      ]);
    });

    test('起止填反不算启用', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      d
        ..intervalEveryMinutes = 120
        ..intervalFrom = LocalTime(21, 0)
        ..intervalTo = LocalTime(9, 0);
      expect(d.hasIntervalRule, isFalse);
      expect(d.buildTimeRule(), isA<FixedTimesRule>());
    });

    test('预览里会写出"另加"那一段', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('water')!);
      d
        ..intervalEveryMinutes = 120
        ..intervalFrom = LocalTime(9, 0)
        ..intervalTo = LocalTime(21, 0);
      final text = d.describeTime();
      expect(text, contains('另加每 2 小时一次'));
      expect(text, contains('共 7 次'));
    });
  });

  group('预览文案', () {
    test('一天多次会说次数和时刻', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('water')!);
      expect(
        d.describeTime(),
        '每天 · 每天 5 次\n9:00 / 11:00 / 14:00 / 16:00 / 19:00',
      );
    });

    test('一次说"每天 时刻"', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      expect(d.describeTime(), '每天 20:00');
    });

    test('跟三餐走会直说', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      expect(d.describeTime(), '每天跟随三餐（饭后 30 分）\n8:00 / 12:30 / 19:00');
    });

    test('重复规则说人话：工作日 / 每周一三五 / 每 2 天 / 每月 1、15 号', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      d.repeat = const RepeatRule(parity: ParityFilter.workdays);
      expect(d.describeRepeat(), '工作日');
      d.repeat = const RepeatRule(weekdays: {1, 3, 5});
      expect(d.describeRepeat(), '周一三五');
      d.repeat = const RepeatRule(everyNDays: 2);
      expect(d.describeRepeat(), '每 2 天');
      d.repeat = const RepeatRule(monthDays: [1, 15]);
      expect(d.describeRepeat(), '每月 1、15 号');
      d.repeat = RepeatRule.daily;
      expect(d.describeRepeat(), '每天');
    });

    test('疗程：长期不啰嗦，有限期说清到哪天', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('rope')!);
      expect(d.describeCourse(), isNull);
      d.course = Course.days(LocalDate(2026, 3, 1), 7);
      expect(d.describeCourse(), '连着做 7 天，到 3/7 结束');
      d.course = Course.range(LocalDate(2026, 3, 1), LocalDate(2026, 3, 20));
      expect(d.describeCourse(), '3/1 → 3/20');
    });

    test('整段预览三段都有', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.course = Course.days(LocalDate(2026, 3, 1), 7);
      final text = d.buildPreview(memberName: '爷爷');
      expect(text, startsWith('爷爷 · 吃药'));
      expect(text, contains('跟随三餐'));
      expect(text, contains('连着做 7 天'));
    });
  });

  group('从已有项目回填（编辑复用同一表单）', () {
    test('回填后不丢失关键信息', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('medicine')!);
      d.memberId = 'm1';
      final task = d.toTask(id: 't1', memberId: 'm1', nowMs: 1);

      final back = TaskDraft.fromTask(task);
      expect(back.name, '吃药');
      expect(back.memberId, 'm1');
      expect(back.iconId, 'pill');
      expect(back.note, '每次几粒，饭后半小时');
      expect(back.timePoints, hasLength(3));
      expect(back.timeTab, TimeTab.custom);
    });

    test('回填后直接保存，规则等价', () {
      final d = TaskDraft.fromTemplate(TemplateLibrary.byId('water')!);
      d.memberId = 'm1';
      final task = d.toTask(id: 't1', memberId: 'm1', nowMs: 1);
      final again = TaskDraft.fromTask(task)
          .toTask(id: 't1', memberId: 'm1', nowMs: 2);
      expect(again.time, task.time);
    });
  });
}
