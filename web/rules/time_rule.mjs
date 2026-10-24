/**
 * 时刻规则：**每天在几点做**。
 *
 * 四种基本型可以**相加**（多个时间段），底层数据结构只有这一套；
 * UI 上的"三层规则"只是分组展示，不影响存储。
 *
 * 与 `app/lib/domain/model/time_rule.dart` 一一对应。
 *
 * @module rules/time_rule
 */

import { LocalTime, MEAL_ANCHOR_INDEX, defaultTimeForAnchor } from './local_time.mjs';

const MINUTES_PER_DAY = 1440;

/**
 * 时刻规则基类。
 *
 * 两个方法的分工和 Dart 完全一致：
 *
 * - `timesOn(date)`：**子类必须实现**。展开到当天，已归一化到 0..1439、去重、升序。
 *   给人看、给"每天几次"这种提示用。
 * - `shiftedMinutesOn(date)`：**排程器只用这个**。默认实现从 `timesOn` 派生
 *   （即已归一化），只有真能跨午夜的子类才重写它（目前只有 `MealTimesRule`）。
 */
export class TimeRule {
  /**
   * 展开到某一天的若干时刻（已排序、已去重），落在 0..1439。
   *
   * ⚠️ 排程器**不能**用它：`timesOn` 会把 21:00+4h 折回 01:00，跨天信息就丢了，
   * "宵夜后 4 小时吃药"会被错误地排到同一天凌晨。排程器用 `shiftedMinutesOn`。
   *
   * 和 Dart 一样是抽象方法，子类必须自己实现 —— 不要在这里放一个
   * "从 shiftedMinutesOn 派生"的默认实现：那样基类和子类会互相调用，
   * 没重写 `shiftedMinutesOn` 的子类（如 `CombinedTimeRule`）就会栈溢出。
   */
  timesOn(_date) {
    throw new Error(`${this.constructor.name} 必须实现 timesOn`);
  }

  /**
   * 展开成**未归一化的当天第几分钟**，允许越界以表达跨午夜。
   *
   * 默认实现和 Dart 基类一致：从 `timesOn` 派生（即**已归一化**到 0..1439）。
   * 这不是"图省事"，是照抄语义：`CombinedTimeRule` 靠这个默认实现工作，
   * 也因此带着 BUG-1（见该类的注释）。
   */
  shiftedMinutesOn(date) {
    return this.timesOn(date).map((t) => t.minuteOfDay);
  }

  /** 不用日期就能展开的规则返回 true。 */
  get isDateIndependent() {
    return false;
  }
}

/** 一天 N 次 · 固定时刻（跳绳每晚 20:00、吃药 15:00 和 22:00）。 */
export class FixedTimesRule extends TimeRule {
  /** @param {(LocalTime|string)[]} times 至少一个 */
  constructor(times) {
    super();
    const parsed = times.map((t) => (typeof t === 'string' ? LocalTime.parse(t) : t));
    if (parsed.length === 0) {
      throw new RangeError('FixedTimesRule 至少给一个时刻');
    }
    // 去重 + 升序，和 Dart 的 `(times.toList()..sort()).toSet().toList()` 等价。
    /** @type {LocalTime[]} */
    this.times = Object.freeze(
      [...new Map(parsed.map((t) => [t.minuteOfDay, t])).values()].sort(
        (a, b) => a.minuteOfDay - b.minuteOfDay,
      ),
    );
    Object.freeze(this);
  }

  timesOn(_date) {
    return this.times;
  }

  shiftedMinutesOn(_date) {
    return this.times.map((t) => t.minuteOfDay);
  }

  get isDateIndependent() {
    return true;
  }
}

/**
 * 跟随三餐 ± 偏移（"饭后 30 分钟"）。
 *
 * `offsetMinutes` 可以为负（饭前），也可以很大（跨午夜，如宵夜后 60 分钟）。
 */
export class MealTimesRule extends TimeRule {
  /**
   * @param {object} init
   * @param {string[]} init.anchors breakfast/lunch/dinner 至少一个
   * @param {number} [init.offsetMinutes] 正数=饭后，负数=饭前（规范名，与 Dart 一致）
   * @param {number} [init.offset] `offsetMinutes` 的别名，与 App 数据库 JSON 的键名一致
   * @param {Record<string, LocalTime|string>|Map<string, LocalTime|string>} [init.anchorOverrides]
   */
  constructor({ anchors, offsetMinutes, offset, anchorOverrides = null }) {
    super();
    if (!anchors || anchors.length === 0) {
      throw new RangeError('MealTimesRule 至少选一餐');
    }
    // 两个键名都收：Dart 侧叫 `offsetMinutes`，App 存的 JSON 里叫 `offset`。
    // 只认一个的话，调用方写错键名会**静默变成 0**（偏移失效，提醒提前到饭点），
    // 不报错、不崩，只是悄悄晚/早半小时 —— 这类 bug 最难发现。
    if (offsetMinutes != null && offset != null && offsetMinutes !== offset) {
      throw new RangeError(`offset 和 offsetMinutes 同时给了不同的值：${offset} / ${offsetMinutes}`);
    }
    const resolvedOffset = offsetMinutes ?? offset ?? 0;
    if (!Number.isInteger(resolvedOffset)) {
      throw new TypeError(`offset 必须是整数分钟：${resolvedOffset}`);
    }
    for (const a of anchors) {
      if (!(a in MEAL_ANCHOR_INDEX)) throw new RangeError(`未知的三餐锚点：${a}`);
    }
    // 去重后按 index 排序，与 Dart 的 `..sort((a,b) => a.index.compareTo(b.index))` 等价。
    this.anchors = Object.freeze(
      [...new Set(anchors)].sort((a, b) => MEAL_ANCHOR_INDEX[a] - MEAL_ANCHOR_INDEX[b]),
    );
    this.offsetMinutes = resolvedOffset;

    const overrides = {};
    if (anchorOverrides) {
      const entries =
        anchorOverrides instanceof Map ? anchorOverrides.entries() : Object.entries(anchorOverrides);
      for (const [k, v] of entries) {
        if (!(k in MEAL_ANCHOR_INDEX)) throw new RangeError(`未知的三餐锚点：${k}`);
        overrides[k] = typeof v === 'string' ? LocalTime.parse(v) : v;
      }
    }
    /** @type {Readonly<Record<string, LocalTime>>} */
    this.anchorOverrides = Object.freeze(overrides);
    Object.freeze(this);
  }

  /** 某个锚点的时刻（用户改过的优先）。 */
  timeFor(anchor) {
    return this.anchorOverrides[anchor] ?? defaultTimeForAnchor(anchor);
  }

  /** 每个锚点的原始时刻（未加偏移），升序。 */
  rawAnchors() {
    return this.anchors.map((a) => this.timeFor(a)).sort((a, b) => a.minuteOfDay - b.minuteOfDay);
  }

  /**
   * 与 Dart 的 `MealTimesRule.timesOn` 逐字对应：
   * `shiftedMinutesOn(...).map((m) => fromMinuteOfDay((m % 1440 + 1440) % 1440))`
   * 再去重、升序。
   *
   * ⚠️ 归一化在这里做，所以 `timesOn` 的结果**会丢掉跨天信息**。
   * 排程器不用它，用 `shiftedMinutesOn`。
   */
  timesOn(date) {
    const set = new Set();
    for (const m of this.shiftedMinutesOn(date)) {
      set.add(((m % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY);
    }
    return [...set].sort((a, b) => a - b).map((m) => LocalTime.fromMinuteOfDay(m));
  }

  /**
   * ⚠️ 这里**必须**返回越界值（负数或 > 1439）。
   *
   * "饭前 30 分钟"在 07:30 得到 420，看着正常；但在 00:10 得到 -20，
   * 表示**前一天** 23:40。排程器靠这个负号知道要回退一天。
   * 这里的偏移是加法，不涉及除法，所以没有取整问题。
   */
  shiftedMinutesOn(_date) {
    const out = new Set();
    for (const anchor of this.anchors) {
      out.add(this.timeFor(anchor).shiftedMinuteOfDay(this.offsetMinutes));
    }
    return [...out].sort((a, b) => a - b);
  }

  get isDateIndependent() {
    // 跟着三餐走，三餐时刻本身与日期无关，但语义上属于"按天计算"，与 Dart 保持一致。
    return false;
  }
}

/**
 * 每 N 小时一次，限定起止时段（"每 2 小时喝水，9:00–21:00"）。
 *
 * 语义：**含起含止**。9:00–21:00 每 2 小时 → 9, 11, 13, 15, 17, 19, 21 共 7 条。
 * 不允许跨午夜（`from` 必须早于 `to`）。
 */
export class IntervalRule extends TimeRule {
  /**
   * @param {object} init
   * @param {number} init.everyMinutes 正数
   * @param {LocalTime|string} init.from
   * @param {LocalTime|string} init.to
   */
  constructor({ everyMinutes, from, to }) {
    super();
    const f = typeof from === 'string' ? LocalTime.parse(from) : from;
    const t = typeof to === 'string' ? LocalTime.parse(to) : to;
    if (!(Number.isInteger(everyMinutes) && everyMinutes > 0)) {
      throw new RangeError(`间隔必须为正：${everyMinutes}`);
    }
    if (f.minuteOfDay >= t.minuteOfDay) {
      throw new RangeError('起止时刻不能跨午夜，也不能相等');
    }
    this.everyMinutes = everyMinutes;
    this.from = f;
    this.to = t;
    Object.freeze(this);
  }

  /** 从 `from` 起，每 `everyMinutes` 一次，直到不超过 `to`。 */
  times() {
    const out = [];
    let m = this.from.minuteOfDay;
    while (m <= this.to.minuteOfDay) {
      out.push(LocalTime.fromMinuteOfDay(m));
      m += this.everyMinutes;
    }
    return out;
  }

  /**
   * 一天会生成多少条。
   *
   * ⚠️ Dart 用的是 `~/`（向零截断），这里用 `Math.trunc` 而不是 `Math.floor`。
   * 这里两个数都是正的，两者结果相同 — 但**照抄截断语义**才安全：
   * 将来若允许负数区间，`Math.floor` 会多算一条。
   */
  get count() {
    return Math.trunc((this.to.minuteOfDay - this.from.minuteOfDay) / this.everyMinutes) + 1;
  }

  timesOn(_date) {
    return this.times();
  }

  shiftedMinutesOn(_date) {
    return this.times().map((t) => t.minuteOfDay);
  }

  get isDateIndependent() {
    return true;
  }
}

/**
 * 组合多个时刻规则（"上午 9/11 点，下午 15/17 点"= 两个 FixedTimesRule 相加）。
 *
 * ## ⚠️ 已知缺陷（照抄 Dart 的现状，不是移植失误）
 *
 * Dart 的 `CombinedTimeRule` **只重写了 `timesOn`，没重写 `shiftedMinutesOn`**，
 * 于是 `shiftedMinutesOn` 走基类默认实现 = `timesOn(...).map(minuteOfDay)`，
 * 也就是**先把每个子规则归一化到 0..1439、去重、排序，再交给排程器**。
 *
 * 后果：子规则里的跨午夜信息在 combined 这一层就被抹掉了。
 * 例：`fixed 23:30` + `meal dinner +360`（18:30+6h = 次日 00:30），
 * 归一化后是 1410 和 30，排程器收到 `[30, 1410]`，
 * 会把 00:30 当成**当天**凌晨 → 排到 10-24 00:30，
 * 而正确结果是 10-25 00:30。也就是说：**"加班到很晚后吃药"这类规则
 * 一旦被用户放进 combined（UI 里"再加一个时间段"），就会排错一天。**
 *
 * 本文件与 Dart 保持逐位一致，所以这里同样不重写 `shiftedMinutesOn`。
 * 修的时候两边必须一起改，否则双端又会不一致 —— 详见
 * `docs/architecture.zh_CN.md` 的"已知缺陷"一节。
 */
export class CombinedTimeRule extends TimeRule {
  /** @param {TimeRule[]} rules */
  constructor(rules) {
    super();
    if (!rules || rules.length === 0) {
      throw new RangeError('CombinedTimeRule 至少给一个子规则');
    }
    this.rules = Object.freeze([...rules]);
    Object.freeze(this);
  }

  timesOn(date) {
    const set = new Set();
    for (const r of this.rules) {
      for (const t of r.timesOn(date)) set.add(t.minuteOfDay);
    }
    return [...set].sort((a, b) => a - b).map((m) => LocalTime.fromMinuteOfDay(m));
  }

  /** 所有子规则都与日期无关才算无关。 */
  get isDateIndependent() {
    return this.rules.every((r) => r.isDateIndependent);
  }
}

/**
 * 从 App 存进数据库的 JSON 解出时刻规则。
 *
 * JSON 形状见 `app/lib/data/db/tables.dart` 的 `RuleCodec.encodeTime`：
 *
 * ```jsonc
 * { "v": 1, "type": "fixed",    "times": ["15:00", "22:00"] }
 * { "v": 1, "type": "meal",     "anchors": ["lunch"], "offset": 30,
 *                               "overrides": { "lunch": "12:10" } }
 * { "v": 1, "type": "interval", "every": 120, "from": "09:00", "to": "21:00" }
 * { "v": 1, "type": "combined", "rules": [ ...上面任一 ] }
 * ```
 */
export function decodeTime(json) {
  if (json == null) {
    throw new TypeError('time 不能为空');
  }
  let m;
  if (typeof json === 'string') {
    try {
      m = JSON.parse(json);
    } catch (err) {
      throw new RangeError(`time 不是合法 JSON：${err.message}`);
    }
  } else {
    m = json;
  }
  if (m == null || typeof m !== 'object') {
    throw new TypeError('time 必须是对象');
  }

  switch (m.type) {
    case 'fixed':
      return new FixedTimesRule((m.times ?? []).map((s) => LocalTime.parse(s)));
    case 'meal':
      return new MealTimesRule({
        anchors: m.anchors ?? [],
        offsetMinutes: m.offset ?? 0,
        anchorOverrides: m.overrides ?? null,
      });
    case 'interval':
      return new IntervalRule({
        everyMinutes: m.every,
        from: LocalTime.parse(m.from),
        to: LocalTime.parse(m.to),
      });
    case 'combined':
      return new CombinedTimeRule((m.rules ?? []).map(decodeTime));
    default:
      // Dart 的 `decodeTime` 在这里抛 FormatException。网页端也抛：
      // 未知规则**不能**猜成"每天 20:00"，那会凭空造出一条用户没配的提醒。
      throw new RangeError(`未知的时刻规则类型：${m.type}`);
  }
}
