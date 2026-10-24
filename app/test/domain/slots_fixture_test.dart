/// 双端共享夹具：`web/test/fixtures/slots-cases.json`。
///
/// 同一份 JSON，Dart 这里跑一遍（`flutter test`），JS 那边跑一遍
/// （`node --test web/test/rules.test.mjs`）。两边结果必须一致 ——
/// 网页端和手机算出的"今天"不一样，是这个功能最致命的失败模式：
/// 手机上显示 3 次、网页显示 2 次，用户会认为软件坏了；
/// 更糟的是网页多出一个槽位，用户点它打卡，落库的 `slot_index` 手机上不存在，
/// 那条记录在手机上永远看不到，反过来又像"改了没生效"。
///
/// ## 为什么手工写期望值
///
/// 夹具里的 `expected` 是**手算**的（用 Python 独立算 epochDay / weekday 核对，
/// 再逐条推偏移），不是从任何一侧的实现跑出来导出的。
/// 用实现生成期望值等于让同一段逻辑给自己判卷，两边一起错时永远发现不了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:famdaily/domain/model/course.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// 夹具相对 `app/` 的路径。`flutter test` 的 cwd 是 `app/`。
const _fixturePath = '../web/test/fixtures/slots-cases.json';

void main() {
  // ⚠️ 夹具必须在 **main() 同步阶段**读完，不能放进 setUpAll。
  //
  // 踩过：第一版用 setUpAll 读文件，然后在 `for (final c in cases)` 里
  // 按 case 生成 test() —— 但 `for` 在 main() 里同步执行，
  // 那时 setUpAll 还没跑，`cases` 是空列表，于是 **一条 case 都没生成**，
  // 测试照样"All tests passed"。这比测试失败危险得多。
  //
  // 所以：读文件放在 main 顶层，并留一条数量守卫（见下面 cases.length 断言）。
  final file = File(_fixturePath);
  if (!file.existsSync()) {
    fail(
      '找不到夹具 $_fixturePath（cwd=${Directory.current.path}）。'
      '这个测试必须从 app/ 目录跑；如果仓库结构变了，改 _fixturePath。',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('夹具版本是 1', () {
    expect(fixture['version'], 1);
  });

  test('夹具至少 40 条 case', () {
    // 数量守卫：防止有人在改夹具时不小心删掉一半，测试照样"全绿"。
    expect(cases.length, greaterThanOrEqualTo(40));
  });

  for (final c in cases) {
    final name = c['name'] as String;
    test('夹具 · $name', () {
      final tasks = (c['tasks'] as List).cast<Map<String, dynamic>>();
      final specs = <ScheduleSpec>[];
      final broken = <String>[];

      for (final t in tasks) {
        final id = t['id'] as String;
        final status = t['status'] as String? ?? 'active';
        final deletedAtMs = t['deletedAtMs'] as int?;
        // 与 JS 侧 specsFromTaskRows 同一套过滤：只有 active 且未删除才展开。
        if (status != 'active' || deletedAtMs != null) continue;
        try {
          specs.add(
            ScheduleSpec(
              taskId: id,
              repeat: _decodeRepeat(t['repeat'] as Map<String, dynamic>),
              time: _decodeTime(t['time'] as Map<String, dynamic>),
              course: _decodeCourse(t),
              fromDate: t['rulesEffectiveFrom'] == null
                  ? null
                  : LocalDate.parse(t['rulesEffectiveFrom'] as String),
            ),
          );
        } on FormatException {
          // JS 侧把解析失败收进 broken。这里同样跳过，并在下面核对名单。
          broken.add(id);
        } on ArgumentError {
          broken.add(id);
        }
      }

      final expectBroken = (c['expectBroken'] as List?)?.cast<String>() ?? const [];
      expect(
        broken..sort(),
        expectBroken.toList()..sort(),
        reason: '$name：解析失败的任务名单不符',
      );

      final from = LocalDate.parse(c['date'] as String);
      final spanDays = c['spanDays'] as int? ?? 1;
      final to = from.addDays(spanDays - 1);

      final result = Scheduler.expand(specs: specs, from: from, to: to);
      final actual = result.slots
          .map(
            (s) => [
              s.taskId,
              s.index,
              s.dueAt.date.toString(),
              s.dueAt.time.toString(),
            ],
          )
          .toList();

      expect(actual, c['expected'], reason: '$name：展开结果不符');
    });
  }
}

/// 夹具里的 `repeat` 是**解析后的对象**，形状同 `RuleCodec.encodeRepeat`。
///
/// 这里不复用 `RuleCodec.decodeRepeat`：它在未知 parity 时 fallback 到 workdays，
/// 而夹具要的是"未知就报错"。两边（本文件和 JS 的 `decodeRepeat`）都严格解析。
RepeatRule _decodeRepeat(Map<String, dynamic> m) {
  final parityName = m['parity'] as String?;
  if (parityName != null) {
    final known = ParityFilter.values.where((p) => p.name == parityName);
    if (known.isEmpty) {
      throw FormatException('未知的 parity：$parityName');
    }
  }
  return RepeatRule(
    weekdays: (m['weekdays'] as List?)?.cast<int>().toSet(),
    everyNDays: m['everyNDays'] as int?,
    anchor: m['anchor'] == null ? null : LocalDate.parse(m['anchor'] as String),
    parity: parityName == null
        ? null
        : ParityFilter.values.firstWhere((p) => p.name == parityName),
    monthDays: (m['monthDays'] as List?)?.cast<int>(),
  );
}

/// 夹具里的 `time` 形状同 `RuleCodec.encodeTime`。
TimeRule _decodeTime(Map<String, dynamic> m) {
  switch (m['type'] as String) {
    case 'fixed':
      final times = (m['times'] as List).cast<String>();
      if (times.isEmpty) {
        throw const FormatException('FixedTimesRule 至少给一个时刻');
      }
      return FixedTimesRule(times.map(LocalTime.parse).toList());
    case 'meal':
      final anchors = (m['anchors'] as List).cast<String>();
      if (anchors.isEmpty) {
        throw const FormatException('MealTimesRule 至少选一餐');
      }
      return MealTimesRule(
        anchors: anchors
            .map(
              (n) => MealAnchor.values.firstWhere(
                (a) => a.name == n,
                orElse: () => throw FormatException('未知的三餐锚点：$n'),
              ),
            )
            .toList(),
        offsetMinutes: m['offset'] as int? ?? 0,
        anchorOverrides: (m['overrides'] as Map?)?.map(
          (k, v) => MapEntry(
            MealAnchor.values.firstWhere((a) => a.name == k),
            LocalTime.parse(v as String),
          ),
        ),
      );
    case 'interval':
      return IntervalRule(
        everyMinutes: m['every'] as int,
        from: LocalTime.parse(m['from'] as String),
        to: LocalTime.parse(m['to'] as String),
      );
    case 'combined':
      return CombinedTimeRule(
        (m['rules'] as List)
            .cast<Map<String, dynamic>>()
            .map(_decodeTime)
            .toList(),
      );
    default:
      throw FormatException('未知的时刻规则类型：${m['type']}');
  }
}

/// 夹具里的三列对应 `tasks` 表的 `course_start` / `course_end` / `course_total_days`。
Course _decodeCourse(Map<String, dynamic> t) {
  final startStr = t['courseStart'] as String?;
  final endStr = t['courseEnd'] as String?;
  final totalDays = t['courseTotalDays'] as int?;
  if (startStr == null && endStr == null) {
    if (totalDays != null) {
      throw const FormatException('有 totalDays 但没有 courseStart');
    }
    return Course.none;
  }
  if (startStr == null || endStr == null) {
    throw const FormatException('起止日期必须同时给出或同时为空');
  }
  return Course.range(LocalDate.parse(startStr), LocalDate.parse(endStr));
}
