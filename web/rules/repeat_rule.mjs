/**
 * 重复规则：**在哪几天做**。
 *
 * 四个条件同时给出时取**交集**，全部为空表示"每天"。
 * 与 `app/lib/domain/model/repeat_rule.dart` 一一对应。
 *
 * @module rules/repeat_rule
 */

import { LocalDate, localEpoch } from './local_date.mjs';

/**
 * ⚠️ 负数取模。
 *
 * Dart 的 `%` **恒返回非负**（`-1 % 3 == 2`），JS 的 `%` 沿被除数的符号
 * （`-1 % 3 == -1`）。`everyNDays` 的判据是 `(date - anchor) % n == 0`，
 * 而 `date` **可以早于 anchor** —— 用户 3 号建了"每 3 天一次"的项目，
 * 回头翻 1 号的日历，那一刻 `diff` 就是负数。
 *
 * 用 `-1 % 3 === -1` 去和 0 比，结果是"不命中"，看起来"跳过了过去"，不报错。
 * 真正会出问题的方向是反过来：如果判据写成 `rem === n - 1` 之类，
 * 负数的 `rem` 永远等于不了正数，那条分支就成了死代码。
 * 这里统一用 floor mod，`((a % n) + n) % n` 恒在 `0..n-1`。
 */
export function mod(a, n) {
  return ((a % n) + n) % n;
}

/** 单双周 / 工作日 / 周末。 */
export const ParityFilter = Object.freeze({
  oddWeeks: 'oddWeeks',
  evenWeeks: 'evenWeeks',
  workdays: 'workdays',
  weekends: 'weekends',
});

const PARITY_ALLOWED_WEEKDAYS = Object.freeze({
  oddWeeks: [1, 2, 3, 4, 5, 6, 7],
  evenWeeks: [1, 2, 3, 4, 5, 6, 7],
  workdays: [1, 2, 3, 4, 5],
  weekends: [6, 7],
});

/** 该筛选允许的周几集合（1 = 周一）。 */
export function allowedWeekdays(parity) {
  const out = PARITY_ALLOWED_WEEKDAYS[parity];
  if (!out) throw new RangeError(`未知的单双周筛选：${parity}`);
  return out;
}

/**
 * 单双周基准：以 1970-01-01（周四）所在的那一周为"第 1 周"，奇数周为单周。
 *
 * 这个基准是**全局固定**的，不是"从今天起算"——否则用户改规则时单双周会整体位移。
 *
 * 对应 Dart：
 * ```dart
 * final mondayBased = date.epochDay - (date.weekday - 1);
 * final weekIndex = (mondayBased - (-3)) ~/ 7;   // 1970-01-01 的周一 = epochDay -3
 * return weekIndex.isEven;
 * ```
 * 这里的 `~/` 用 `Math.floor`：`mondayBased` 可能小于 `-3`（1970 年之前），
 * 此时 `/-7` 是正数除法，`Math.trunc` 和 `Math.floor` 一致；写成 `Math.floor`
 * 是为了负数方向也不错——单双周对不上只会让"单周的项目在双周也提醒"，
 * 静默地错，没人会报 bug。
 */
export function isEvenWeek(date) {
  const mondayBased = date.epochDay - (date.weekday - 1);
  const weekIndex = Math.floor((mondayBased + 3) / 7);
  return weekIndex % 2 === 0;
}

/** 某个单双周筛选是否命中该日期。 */
export function parityMatches(parity, date) {
  switch (parity) {
    case ParityFilter.oddWeeks:
      return !isEvenWeek(date);
    case ParityFilter.evenWeeks:
      return isEvenWeek(date);
    case ParityFilter.workdays:
      return !date.isWeekend;
    case ParityFilter.weekends:
      return date.isWeekend;
    default:
      throw new RangeError(`未知的单双周筛选：${parity}`);
  }
}

/**
 * 重复规则。
 *
 * 字段与 Dart 的命名一致：`weekdays` / `everyNDays` / `anchor` / `parity` / `monthDays`。
 * 全部为 `null` 或空集合 = 每天。
 */
export class RepeatRule {
  /**
   * @param {object} [init]
   * @param {number[]|null} [init.weekdays] 1..7
   * @param {number|null} [init.everyNDays]
   * @param {import('./local_date.mjs').LocalDate|null} [init.anchor]
   * @param {string|null} [init.parity]
   * @param {number[]|null} [init.monthDays] 1..31
   */
  constructor({ weekdays = null, everyNDays = null, anchor = null, parity = null, monthDays = null } = {}) {
    if (everyNDays != null && !(Number.isInteger(everyNDays) && everyNDays > 0)) {
      throw new RangeError(`everyNDays 必须为正：${everyNDays}`);
    }
    this.weekdays = weekdays == null ? null : Object.freeze([...new Set(weekdays)].sort((a, b) => a - b));
    this.everyNDays = everyNDays;
    this.anchor = anchor;
    this.parity = parity;
    this.monthDays = monthDays == null ? null : Object.freeze([...monthDays]);
    Object.freeze(this);
  }

  /** 每天都做。 */
  static get daily() {
    return DAILY;
  }

  /** 是否一项限制都没有（= 每天）。 */
  get isEveryDay() {
    return (
      (this.weekdays == null || this.weekdays.length === 0) &&
      this.everyNDays == null &&
      this.parity == null &&
      (this.monthDays == null || this.monthDays.length === 0)
    );
  }

  /** 判断某一天是否命中本规则。 */
  matches(date) {
    if (this.isEveryDay) return true;

    // 维度 1：周几
    const wd = this.weekdays;
    if (wd != null && wd.length > 0 && !wd.includes(date.weekday)) {
      return false;
    }

    // 维度 2：每隔 N 天
    if (this.everyNDays != null) {
      const from = this.anchor ?? localEpoch;
      // ⚠️ 必须 floor mod：date 早于 anchor 时 diff 是负数，见本文件顶部 mod() 说明。
      if (mod(date.epochDay - from.epochDay, this.everyNDays) !== 0) {
        return false;
      }
    }

    // 维度 3：单双周 / 工作日 / 周末
    if (this.parity != null && !parityMatches(this.parity, date)) {
      return false;
    }

    // 维度 4：每月几号
    const md = this.monthDays;
    if (md != null && md.length > 0 && !md.includes(date.day)) {
      return false;
    }

    return true;
  }

  /**
   * 本规则是否"永远不会触发"（用户配了矛盾条件）。
   *
   * 例：`weekdays: {6,7}` + `parity: workdays` 就是矛盾——
   * UI 应该在保存前拦下，而不是让用户建一个永远不提醒的项目。
   */
  get isSatisfiable() {
    if (this.isEveryDay) return true;
    if (this.parity != null && this.weekdays != null && this.weekdays.length > 0) {
      const allowed = allowedWeekdays(this.parity);
      if (!this.weekdays.some((d) => allowed.includes(d))) return false;
    }
    return true;
  }

  toJSON() {
    return {
      weekdays: this.weekdays,
      everyNDays: this.everyNDays,
      anchor: this.anchor == null ? null : String(this.anchor),
      parity: this.parity,
      monthDays: this.monthDays,
    };
  }
}

const DAILY = new RepeatRule();

/**
 * 从 App 存进数据库的 JSON 解出来。
 *
 * JSON 形状见 `app/lib/data/db/tables.dart` 的 `RuleCodec.encodeRepeat`：
 * `{ v: 1, weekdays, everyNDays, anchor, parity, monthDays }`。
 */
export function decodeRepeat(json) {
  if (json == null) return DAILY;
  let m;
  if (typeof json === 'string') {
    try {
      m = JSON.parse(json);
    } catch (err) {
      throw new RangeError(`repeat 不是合法 JSON：${err.message}`);
    }
  } else {
    m = json;
  }
  if (m == null || typeof m !== 'object') {
    throw new TypeError('repeat 必须是对象');
  }

  const parityName = m.parity ?? null;
  if (parityName != null && !(parityName in ParityFilter)) {
    // Dart 里未知值 fallback 到 workdays。这里**报错**：网页端只读展示，
    // 猜错的后果是"今天该做的事被藏起来"，比报错难查得多。
    throw new RangeError(`未知的 parity：${parityName}`);
  }

  return new RepeatRule({
    weekdays: m.weekdays ?? null,
    everyNDays: m.everyNDays ?? null,
    anchor: m.anchor == null ? null : LocalDate.parse(m.anchor),
    parity: parityName,
    monthDays: m.monthDays ?? null,
  });
}
