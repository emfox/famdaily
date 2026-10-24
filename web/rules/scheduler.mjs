/**
 * 排程展开器：把"重复规则 × 时刻规则 × 疗程"折成具体时刻列表。
 *
 * 与 `app/lib/domain/scheduling/scheduler.dart` 一一对应。
 * **这是全项目唯一有真正算法复杂度的地方**，网页端必须算出和手机一样的结果，
 * 否则同一个"今天"在两端显示不同条数。
 *
 * @module rules/scheduler
 */

import { LocalDate } from './local_date.mjs';
import { LocalTime } from './local_time.mjs';

const MINUTES_PER_DAY = 1440;

/**
 * 向下取整除法。
 *
 * ⚠️ 不要用 `Math.trunc`：`Math.trunc(-30 / 1440)` 是 `-0`（等于 0），
 * 而 `Math.floor` 是 `-1`。跨午夜/饭前偏移全靠这个函数把 -30 折成"前一天 23:30"。
 * Dart 那边用的是 `(a / b).floor()`，语义一致。
 */
export function floorDiv(a, b) {
  return Math.floor(a / b);
}

/** 一个"日期 + 时刻"，可跨天（不做时区换算，纯本地墙钟概念）。 */
export class LocalDateTimeRef {
  /**
   * @param {LocalDate} date
   * @param {LocalTime} time
   */
  constructor(date, time) {
    this.date = date;
    this.time = time;
    Object.freeze(this);
  }

  /**
   * 从"疗程当天 + 当天第几分钟"构造，自动处理跨午夜进位。
   *
   * `minuteOfDay` 可以超出 0..1439（跨到次日）或为负（跨到前日）。
   */
  static fromDayAndMinute(date, minuteOfDay) {
    const dayShift = floorDiv(minuteOfDay, MINUTES_PER_DAY);
    const rem = minuteOfDay - dayShift * MINUTES_PER_DAY;
    return new LocalDateTimeRef(date.addDays(dayShift), LocalTime.fromMinuteOfDay(rem));
  }

  /** 与 1970-01-01 00:00 的"墙钟分钟差"，用于跨天比较。 */
  get minutes() {
    return this.date.epochDay * MINUTES_PER_DAY + this.time.minuteOfDay;
  }

  compareTo(other) {
    return this.minutes - other.minutes;
  }

  toString() {
    return `${this.date} ${this.time}`;
  }
}

/** 一个待做槽位：某项目在某天的第 n 次，应完成于 `dueAt`。 */
export class Slot {
  /**
   * @param {object} init
   * @param {string} init.taskId
   * @param {LocalDate} init.date 归属的**疗程日**，不是提醒落在哪一天
   * @param {number} init.index 当天第几次（0 起）
   * @param {LocalDateTimeRef} init.dueAt 应完成时刻（已含偏移，可能跨天）
   * @param {number} init.dueMinuteOfDay 冗余的"当天第几分钟"，跨天时越界
   */
  constructor({ taskId, date, index, dueAt, dueMinuteOfDay }) {
    this.taskId = taskId;
    this.date = date;
    this.index = index;
    this.dueAt = dueAt;
    this.dueMinuteOfDay = dueMinuteOfDay;
    Object.freeze(this);
  }

  /** 唯一键：`taskId|date|index`。与 App 的 `Slots` 主键同构。 */
  get key() {
    return `${this.taskId}|${this.date.epochDay}|${this.index}`;
  }

  compareTo(other) {
    const byTime = this.dueAt.compareTo(other.dueAt);
    if (byTime !== 0) return byTime;
    return this.key < other.key ? -1 : this.key > other.key ? 1 : 0;
  }

  toString() {
    return `Slot(${this.taskId} @ ${this.date} #${this.index} → ${this.dueAt})`;
  }
}

/** 展开器的输入：一个项目的排程配置。 */
export class ScheduleSpec {
  /**
   * @param {object} init
   * @param {string} init.taskId
   * @param {import('./repeat_rule.mjs').RepeatRule} init.repeat
   * @param {import('./time_rule.mjs').TimeRule} init.time
   * @param {import('./course.mjs').Course} init.course
   * @param {LocalDate|null} [init.fromDate] 规则生效日（含）
   * @param {boolean} [init.enabled]
   */
  constructor({ taskId, repeat, time, course, fromDate = null, enabled = true }) {
    this.taskId = taskId;
    this.repeat = repeat;
    this.time = time;
    this.course = course;
    this.fromDate = fromDate;
    this.enabled = enabled;
    Object.freeze(this);
  }

  /** 某天是否可能产出槽位（不考虑时刻规则的跨天）。 */
  appliesOn(day) {
    if (!this.enabled || !this.course.contains(day)) return false;
    if (this.fromDate != null && day.isBefore(this.fromDate)) return false;
    return this.repeat.matches(day);
  }
}

/**
 * 展开 `[from, to]`（闭区间）内的所有槽位。
 *
 * `maxSlots` 是硬上限：达到后立即停止，并在结果里标记 `truncated`。
 *
 * ## 两趟排序，顺序不能换
 *
 * 1. 先按 **(疗程日, 越界分钟)** 收集。偏移可能把时刻推到次日或前日
 *    （21:00 饭后 4 小时 → 次日 01:00），此时 "越界分钟" 是 1500。
 * 2. 再按 **真实触发时刻** 折算后整体排序。
 *
 * 换成"边收集边编号"，`slot_index` 就会随偏移抖动：用户把提醒从 20:00
 * 改到次日 01:00，同一件事的 index 会从 0 变成 1，已落库的 `checkins`
 * 的 `(taskId, date, slotIndex)` 就对不上了 —— 表现是"改完时间，历史里那天的记录消失了"。
 */
export function expand({ specs, from, to, maxSlots = 512 }) {
  if (to.isBefore(from)) {
    return { slots: [], truncated: false };
  }

  /** @type {{day: LocalDate, minute: number, taskId: string}[]} */
  const pending = [];
  let truncated = false;

  let day = from;
  while (!day.isAfter(to)) {
    for (const spec of specs) {
      if (!spec.appliesOn(day)) continue;
      for (const m of spec.time.shiftedMinutesOn(day)) {
        if (pending.length >= maxSlots) {
          truncated = true;
          break;
        }
        pending.push({ day, minute: m, taskId: spec.taskId });
      }
      if (truncated) break;
    }
    if (truncated) break;
    day = day.addDays(1);
  }

  const expanded = pending
    .map((p) => ({
      ref: LocalDateTimeRef.fromDayAndMinute(p.day, p.minute),
      day: p.day,
      minute: p.minute,
      taskId: p.taskId,
    }))
    // 排序必须**全序**：时刻 → taskId → 疗程日。少最后一项时，
    // 跨午夜的两条（疗程日不同但触发时刻相同）在 V8 里是稳定排序、
    // 在别的引擎里不保证，index 就会和手机对不上。
    .sort((a, b) => {
      const byTime = a.ref.compareTo(b.ref);
      if (byTime !== 0) return byTime;
      if (a.taskId !== b.taskId) return a.taskId < b.taskId ? -1 : 1;
      return a.day.epochDay - b.day.epochDay;
    });

  /** @type {Map<string, number>} */
  const indexByTaskDay = new Map();
  const slots = [];
  for (const e of expanded) {
    const groupKey = `${e.taskId}|${e.day.epochDay}`;
    const index = indexByTaskDay.get(groupKey) ?? 0;
    indexByTaskDay.set(groupKey, index + 1);
    slots.push(
      new Slot({
        taskId: e.taskId,
        date: e.day,
        index,
        dueAt: e.ref,
        dueMinuteOfDay: e.minute,
      }),
    );
  }

  slots.sort((a, b) => a.compareTo(b));
  return { slots, truncated };
}

/** 估算"平均每天几条"，用于滚动窗口自适应。 */
export function estimateDailyCount(specs, { from, sampleDays = 7 } = {}) {
  const result = expand({ specs, from, to: from.addDays(sampleDays - 1), maxSlots: 100000 });
  return Math.ceil(result.slots.length / sampleDays);
}

/** 计算滚动窗口应该覆盖到哪一天。 */
export function suggestWindowEnd({ specs, from, maxSlots = 60, maxDays = 7, minDays = 3 }) {
  const daily = estimateDailyCount(specs, { from });
  const days =
    daily <= 0 ? maxDays : Math.min(maxDays, Math.max(minDays, Math.floor(maxSlots / daily)));
  return from.addDays(days - 1);
}
