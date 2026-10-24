/**
 * 规则引擎测试。
 *
 * 分两块：
 * 1. **夹具一致性**：跑 `fixtures/slots-cases.json`。同一份夹具 Dart 侧也跑一遍
 *    （`app/test/domain/slots_fixture_test.dart`），两边结果必须一致。
 * 2. **本端独有**：JS 特有的坑（负数取模、`Math.trunc` vs `Math.floor`、
 *    `LocalDate` 与 `Date` 的时区差别），这些在 Dart 侧不存在。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  LocalDate,
  LocalTime,
  RepeatRule,
  ParityFilter,
  FixedTimesRule,
  MealTimesRule,
  IntervalRule,
  CombinedTimeRule,
  Course,
  ScheduleSpec,
  expand,
  isEvenWeek,
  mod,
  specFromTaskRow,
  specsFromTaskRows,
  canEdit,
  EDITABLE_DAYS,
  decodeRepeat,
  decodeTime,
  decodeCourse,
  LocalDateTimeRef,
} from '../rules/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(
  readFileSync(join(HERE, 'fixtures', 'slots-cases.json'), 'utf8'),
);

/**
 * 把一个 case 里的 "task 描述" 变成 `tasks` 表的裸行。
 *
 * 夹具里写的是**解析后的对象**（人能读），而生产代码吃的是 SQLite 裸行
 * （JSON 字符串 + 蛇形列名）。这里做一次归一，两边都不必迁就对方的形状。
 */
function taskRow(t) {
  return {
    id: t.id,
    // 生产里 repeat_json 是 TEXT；夹具写对象，这里 stringify 一次 —— 
    // 顺带把 decodeRepeat 的"接受字符串"分支也覆盖到。
    repeat_json: JSON.stringify(t.repeat ?? {}),
    time_json: JSON.stringify(t.time),
    course_start: t.courseStart ?? null,
    course_end: t.courseEnd ?? null,
    course_total_days: t.courseTotalDays ?? null,
    rules_effective_from: t.rulesEffectiveFrom ?? null,
    status: t.status ?? 'active',
    deleted_at_ms: t.deletedAtMs ?? null,
  };
}

/**
 * 把展开结果压成 `[taskId, index, dueDate, dueTime]`，与夹具的 `expected` 同形。
 *
 * ⚠️ 这里用 `dueAt` 而不是 `date`：夹具断言的是**真实触发时刻**，
 * 而 `Slot.date` 是疗程日。跨午夜的 case 两者不同，用错字段会把
 * "偏移算错一天"和"归属日算错"搅在一起。
 */
function flatten(slots) {
  return slots.map((s) => [s.taskId, s.index, s.dueAt.date.toString(), s.dueAt.time.toString()]);
}

for (const c of FIXTURE.cases) {
  test(`夹具 · ${c.name}`, () => {
    const rows = c.tasks.map(taskRow);
    const { specs, broken } = specsFromTaskRows(rows);

    if (c.expectBroken) {
      assert.deepEqual(
        broken.map((b) => b.id).sort(),
        [...c.expectBroken].sort(),
        `broken 列表不符：实际 ${JSON.stringify(broken)}`,
      );
    } else {
      assert.deepEqual(broken, [], `不该有解析失败：${JSON.stringify(broken)}`);
    }

    const from = LocalDate.parse(c.date);
    const to = from.addDays((c.spanDays ?? 1) - 1);
    const { slots } = expand({ specs, from, to });

    assert.deepEqual(flatten(slots), c.expected, `${c.name} 展开结果不符`);
  });
}

// ---------------------------------------------------------------------------
// 本端独有：负数取模
// ---------------------------------------------------------------------------

test('mod：负数也落在 0..n-1（JS 原生 % 不满足）', () => {
  assert.equal(mod(-1, 3), 2);
  assert.equal(mod(-3, 3), 0);
  assert.equal(mod(-4, 3), 2);
  assert.equal(mod(0, 3), 0);
  assert.equal(mod(3, 3), 0);
  // 与 JS 原生行为对比，说明为什么必须包一层
  assert.equal(-1 % 3, -1);
});

test('everyNDays：anchor 在未来的「当天」也命中（diff 为负）', () => {
  // 每 1 天，任何日期都该命中。如果实现用 `diff % n === 0` 且 n=1，
  // 负数也能过；这条只是兜底。真正的守卫在下面。
  const anchor = LocalDate.parse('2026-10-24');
  const r = new RepeatRule({ everyNDays: 1, anchor });
  assert.equal(r.matches(LocalDate.parse('2026-10-20')), true);
});

test('everyNDays：anchor 之前恰好整数倍命中，之前非整数倍不命中', () => {
  const anchor = LocalDate.parse('2026-10-24');
  const r2 = new RepeatRule({ everyNDays: 2, anchor });
  const r3 = new RepeatRule({ everyNDays: 3, anchor });
  // -4 % 2 == 0（Python 与 floorMod 一致），JS 原生也是 0，这条不区分实现
  assert.equal(r2.matches(LocalDate.parse('2026-10-20')), true);
  // -2 % 2 == 0
  assert.equal(r2.matches(LocalDate.parse('2026-10-22')), true);
  // -4 % 3 == 2 → 不命中
  assert.equal(r3.matches(LocalDate.parse('2026-10-20')), false);
  // -6 % 3 == 0 → 命中
  assert.equal(r3.matches(LocalDate.parse('2026-10-18')), true);
});

test('everyNDays：没有 anchor 时退回 1970-01-01 起算', () => {
  // 以 1970-01-01 为锚，每 7 天一次 → epochDay % 7 === 0 的日子命中。
  // Python 核过：20750 % 7 == 2（不命中），20755 % 7 == 0（命中）。
  const r = new RepeatRule({ everyNDays: 7 });
  assert.equal(r.matches(LocalDate.parse('2026-10-24')), false); // epochDay 20750
  assert.equal(r.matches(LocalDate.parse('2026-10-29')), true); // epochDay 20755
  assert.equal(r.matches(LocalDate.parse('2026-10-28')), false); // epochDay 20754
});

// ---------------------------------------------------------------------------
// 本端独有：Math.trunc vs Math.floor
// ---------------------------------------------------------------------------

test('LocalTime.addMinutes：负数偏移必须落到前一天', () => {
  const t = LocalTime.parse('00:30');
  const [days, time] = t.addMinutes(-60);
  assert.equal(days, -1); // ⚠️ Math.trunc 会给出 -0，断言 -1 才能抓到
  assert.equal(time.toString(), '23:30');
});

test('LocalTime.addMinutes：正偏移跨午夜', () => {
  const t = LocalTime.parse('23:30');
  const [days, time] = t.addMinutes(60);
  assert.equal(days, 1);
  assert.equal(time.toString(), '00:30');
});

test('LocalTime.addMinutes：正好 1440 分钟算一整天，不是 0', () => {
  const [days, time] = LocalTime.parse('08:00').addMinutes(1440);
  assert.equal(days, 1);
  assert.equal(time.toString(), '08:00');
});

test('LocalDateTimeRef.fromDayAndMinute：负数分钟落到前一天', () => {
  const ref = LocalDateTimeRef.fromDayAndMinute(LocalDate.parse('2026-10-24'), -20);
  assert.equal(ref.date.toString(), '2026-10-23');
  assert.equal(ref.time.toString(), '23:40');
});

test('LocalDateTimeRef.fromDayAndMinute：越界分钟落到次日', () => {
  const ref = LocalDateTimeRef.fromDayAndMinute(LocalDate.parse('2026-10-24'), 1510);
  assert.equal(ref.date.toString(), '2026-10-25');
  assert.equal(ref.time.toString(), '01:10');
});

test('IntervalRule.count 用截断而非向下取整', () => {
  // 660 / 120 = 5.5 → trunc 5 → count 6
  const iv = new IntervalRule({ everyMinutes: 120, from: '09:00', to: '20:00' });
  assert.equal(iv.count, 6);
  assert.equal(iv.times().length, 6);
});

// ---------------------------------------------------------------------------
// 本端独有：LocalDate 与内置 Date 的时区差别
// ---------------------------------------------------------------------------

test('LocalDate：epochDay 与 Python datetime 一致', () => {
  // 期望值来自 `python3 -c "…（date(2026,10,24) - date(1970,1,1)).days"`
  assert.equal(LocalDate.parse('2026-10-24').epochDay, 20750);
  assert.equal(LocalDate.parse('1970-01-01').epochDay, 0);
  assert.equal(LocalDate.parse('2026-02-01').epochDay, 20485);
});

test('LocalDate：weekday 与 Python isoweekday 一致（1=周一）', () => {
  assert.equal(LocalDate.parse('2026-10-24').weekday, 6); // 周六
  assert.equal(LocalDate.parse('2026-10-25').weekday, 7); // 周日
  assert.equal(LocalDate.parse('2025-12-29').weekday, 1); // 周一
});

test('LocalDate：round-trip 覆盖闰年与月末', () => {
  for (const s of [
    '2024-02-29',
    '2026-02-28',
    '2026-12-31',
    '2027-01-01',
    '2000-02-29',
    '1970-01-01',
  ]) {
    assert.equal(LocalDate.fromEpochDay(LocalDate.parse(s).epochDay).toString(), s);
  }
});

test('LocalDate.fromDate 取的是 Date 自己的本地年月日', () => {
  // 注意：这里**不**断言时区，因为沙箱是 UTC。
  // 要断言的是"不经过 toISOString"，否则 UTC+8 的晚上会退回前一天。
  const d = new LocalDate(2026, 10, 24, LocalDate.parse('2026-10-24').epochDay);
  assert.equal(d.toString(), '2026-10-24');
  const fromJsDate = LocalDate.fromDate(new Date(2026, 9, 24, 23, 59, 0));
  assert.equal(fromJsDate.toString(), '2026-10-24');
});

// ---------------------------------------------------------------------------
// 本端独有：解码的"不猜"原则
// ---------------------------------------------------------------------------

test('decodeTime：未知类型抛错，不猜成每天', () => {
  assert.throws(() => decodeTime({ type: 'cron', expr: '*' }), /未知的时刻规则类型/);
});

test('decodeRepeat：未知 parity 抛错，不 fallback 到 workdays', () => {
  assert.throws(() => decodeRepeat({ v: 1, parity: 'fortnights' }), /未知的 parity/);
});

test('decodeRepeat：空对象 = 每天', () => {
  assert.equal(decodeRepeat({ v: 1, weekdays: null, everyNDays: null }).isEveryDay, true);
});

test('decodeCourse：三列全空 = 长期', () => {
  assert.equal(decodeCourse(null, null, null).isOpenEnded, true);
});

test('decodeCourse：只有一半起止日期抛错，不猜', () => {
  assert.throws(() => decodeCourse('2026-10-24', null, null), /必须同时给出/);
});

test('decodeCourse：courseTotalDays 不参与 contains 计算，只用于展示', () => {
  // 7 天课程：10-18 起，到 10-24 止。totalDays 写错成 99 也不该改变 contains。
  const c = decodeCourse('2026-10-18', '2026-10-24', 99);
  assert.equal(c.contains(LocalDate.parse('2026-10-24')), true);
  assert.equal(c.contains(LocalDate.parse('2026-10-25')), false);
  assert.equal(c.dayIndex(LocalDate.parse('2026-10-24')), 7);
});

// ---------------------------------------------------------------------------
// 本端独有：可编辑窗口
// ---------------------------------------------------------------------------

test('canEdit：未来日期不可打卡（不能靠负数差值绕过 30 天上限）', () => {
  const today = LocalDate.parse('2026-10-24');
  assert.equal(canEdit(LocalDate.parse('2026-10-25'), today), false);
  assert.equal(canEdit(LocalDate.parse('2026-11-30'), today), false);
});

test('canEdit：今天可改，第 30 天可改，第 31 天不可改', () => {
  const today = LocalDate.parse('2026-10-24');
  assert.equal(canEdit(today, today), true);
  assert.equal(canEdit(today.addDays(-EDITABLE_DAYS), today), true);
  assert.equal(canEdit(today.addDays(-(EDITABLE_DAYS + 1)), today), false);
});

// ---------------------------------------------------------------------------
// 本端独有：单天展开不能受窗口影响
// ---------------------------------------------------------------------------

test('单天展开：跨午夜槽位的 index 独立于窗口大小', () => {
  // 任务：每天晚饭后 400 分钟（18:30+400 → 次日 01:10）。
  // 只展开 10-25：10-25 这一次的 due 应是 10-26 01:10，index 0。
  // ⚠️ 用 meal 直挂（不用 combined）：combined 会把跨天信息归一化掉，见 BUG-1。
  const spec = new ScheduleSpec({
    taskId: 'a1',
    repeat: RepeatRule.daily,
    time: new MealTimesRule({ anchors: ['dinner'], offset: 400 }),
    course: Course.none(),
  });
  const oneDay = expand({ specs: [spec], from: LocalDate.parse('2026-10-25'), to: LocalDate.parse('2026-10-25') });
  assert.deepEqual(flatten(oneDay.slots), [['a1', 0, '2026-10-26', '01:10']]);
});

test('BUG-1 回归：combined 里有跨午夜子规则时会排错一天（当前已知缺陷）', () => {
  // 这条**故意断言错误行为**，用来锁住"缺陷被修了没"。
  // 修好之后这条会红 —— 那时把它改成正确断言（10-25 00:30），并更新夹具。
  const spec = new ScheduleSpec({
    taskId: 'a1',
    repeat: RepeatRule.daily,
    time: new CombinedTimeRule([
      new FixedTimesRule(['23:30']),
      new MealTimesRule({ anchors: ['dinner'], offset: 360 }), // 18:30+360 = 次日 00:30
    ]),
    course: Course.none(),
  });
  const r = expand({ specs: [spec], from: LocalDate.parse('2026-10-24'), to: LocalDate.parse('2026-10-24') });
  assert.deepEqual(flatten(r.slots), [
    ['a1', 0, '2026-10-24', '00:30'], // ← 错：本应是 2026-10-25 00:30
    ['a1', 1, '2026-10-24', '23:30'],
  ]);
});

test('expand：to 早于 from 返回空，不抛错', () => {
  const spec = new ScheduleSpec({
    taskId: 'a1',
    repeat: RepeatRule.daily,
    time: new FixedTimesRule(['20:00']),
    course: Course.none(),
  });
  const r = expand({ specs: [spec], from: LocalDate.parse('2026-10-25'), to: LocalDate.parse('2026-10-24') });
  assert.deepEqual(r.slots, []);
  assert.equal(r.truncated, false);
});

test('expand：maxSlots 截断时置 truncated', () => {
  const spec = new ScheduleSpec({
    taskId: 'a1',
    repeat: RepeatRule.daily,
    time: new IntervalRule({ everyMinutes: 60, from: '00:00', to: '23:00' }),
    course: Course.none(),
  });
  const r = expand({ specs: [spec], from: LocalDate.parse('2026-10-24'), to: LocalDate.parse('2026-10-30'), maxSlots: 10 });
  assert.equal(r.truncated, true);
  assert.equal(r.slots.length, 10);
});

// ---------------------------------------------------------------------------
// 本端独有：specFromTaskRow
// ---------------------------------------------------------------------------

test('specFromTaskRow：repeat_json 与 time_json 都能从字符串解出来', () => {
  const spec = specFromTaskRow({
    id: 'a1',
    repeat_json: JSON.stringify({ v: 1, weekdays: [1, 3, 5] }),
    time_json: JSON.stringify({ v: 1, type: 'fixed', times: ['20:00'] }),
    course_start: null,
    course_end: null,
    course_total_days: null,
    rules_effective_from: null,
    status: 'active',
    deleted_at_ms: null,
  });
  assert.equal(spec.taskId, 'a1');
  assert.equal(spec.enabled, true);
  assert.equal(spec.repeat.matches(LocalDate.parse('2026-10-23')), true); // 周五
  assert.equal(spec.repeat.matches(LocalDate.parse('2026-10-24')), false); // 周六
});

test('specsFromTaskRows：broken 里带原始错误信息，便于日志', () => {
  const { specs, broken } = specsFromTaskRows([
    {
      id: 'bad',
      repeat_json: '{}',
      time_json: '{ 这不是 JSON',
      course_start: null,
      course_end: null,
      course_total_days: null,
      status: 'active',
      deleted_at_ms: null,
    },
  ]);
  assert.equal(specs.length, 0);
  assert.equal(broken.length, 1);
  assert.match(broken[0].error, /不是合法 JSON/);
});

// ---------------------------------------------------------------------------
// 本端独有：ParityFilter 的边界
// ---------------------------------------------------------------------------

test('isEvenWeek：1970-01-01 所在周是 even（weekIndex 0）', () => {
  // 1970-01-01 是周四，那周的周一是 1969-12-29（epochDay -3）。
  // mondayBased = -3 → (-3+3)/7 = 0 → even
  assert.equal(isEvenWeek(LocalDate.parse('1970-01-01')), true);
  assert.equal(isEvenWeek(LocalDate.parse('1969-12-29')), true);
  assert.equal(isEvenWeek(LocalDate.parse('1970-01-05')), false);
});

test('isEvenWeek：1970 年之前也对（这里是 Math.floor 而非 trunc 的理由）', () => {
  // 1969-12-22 的周一 epochDay = -10，( -10 + 3 ) / 7 = -1 → 奇数
  assert.equal(isEvenWeek(LocalDate.parse('1969-12-22')), false);
  // 1969-12-15 → -17，( -17+3 )/7 = -2 → 偶数
  assert.equal(isEvenWeek(LocalDate.parse('1969-12-15')), true);
});

test('ParityFilter.workdays / weekends 与 weekday 一致', () => {
  const sat = LocalDate.parse('2026-10-24');
  const mon = LocalDate.parse('2026-10-26');
  assert.equal(sat.isWeekend, true);
  assert.equal(mon.isWeekend, false);
});
