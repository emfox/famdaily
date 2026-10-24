/**
 * 疗程：**做到哪天为止**。
 *
 * 三种形态，语义互斥：
 * - `Course.none`：长期习惯（跳绳），永不自动结束
 * - `Course.range(start, end)`：起止日期（含两端）
 * - `Course.days(start, n)`：从 `start` 起连续 N 天（N 含首日）
 *
 * 与 `app/lib/domain/model/course.dart` 一一对应。
 *
 * @module rules/course
 */

import { LocalDate } from './local_date.mjs';

/** 项目的时间边界。不可变。 */
export class Course {
  /** @param {{start: import('./local_date.mjs').LocalDate|null, end: import('./local_date.mjs').LocalDate|null, totalDays: number|null}} init */
  constructor({ start = null, end = null, totalDays = null }) {
    if (start == null !== (end == null)) {
      throw new RangeError('起止日期必须同时给出或同时为空');
    }
    if (start != null && end.isBefore(start)) {
      throw new RangeError('结束日期不能早于开始日期');
    }
    this.start = start;
    this.end = end;
    this.totalDays = totalDays;
    Object.freeze(this);
  }

  /** 长期，无期限。 */
  static none() {
    return NONE;
  }

  /** 起止日期（含两端）。 */
  static range(start, end) {
    return new Course({ start, end, totalDays: null });
  }

  /** 从 `start` 起连续 `days` 天（含首日）。 */
  static days(start, days) {
    if (!(Number.isInteger(days) && days > 0)) {
      throw new RangeError(`天数必须为正：${days}`);
    }
    return new Course({ start, end: start.addDays(days - 1), totalDays: days });
  }

  get isOpenEnded() {
    return this.start == null && this.end == null;
  }

  /** 某天是否落在疗程内。长期疗程恒为 true。 */
  contains(date) {
    if (this.isOpenEnded) return true;
    return date.isBetween(this.start, this.end);
  }

  /** 疗程进行到第几天（1-based）；不在疗程内或长期则为 null。 */
  dayIndex(date) {
    if (!this.contains(date) || this.isOpenEnded) return null;
    return date.daysSince(this.start) + 1;
  }

  /** 距离结束还有几天（含当天算 0）；长期为 null。 */
  daysRemaining(date) {
    if (this.isOpenEnded) return null;
    return this.end.daysSince(date);
  }

  /** 是否已到期（严格晚于结束日）。 */
  isExpired(today) {
    return !this.isOpenEnded && today.isAfter(this.end);
  }

  /** 是否快到期（到期前轻提示，默认提前 2 天）。 */
  isEndingSoon(today, { withinDays = 2 } = {}) {
    if (this.isOpenEnded) return false;
    const left = this.daysRemaining(today);
    return left != null && left >= 0 && left <= withinDays;
  }

  toJSON() {
    return {
      start: this.start == null ? null : String(this.start),
      end: this.end == null ? null : String(this.end),
      totalDays: this.totalDays,
    };
  }
}

const NONE = new Course({});

/**
 * 从数据库的三列拼出一个疗程。
 *
 * `tasks` 表里存的是 `course_start` / `course_end` / `course_total_days` 三列
 * （不是 JSON），见 `server/src/migrate.mjs` 的建表语句。
 * 三列全空 = 长期；只有一半 = 脏数据，直接抛错，不猜。
 */
export function decodeCourse(startStr, endStr, totalDays) {
  const hasStart = startStr != null && startStr !== '';
  const hasEnd = endStr != null && endStr !== '';
  if (!hasStart && !hasEnd) {
    if (totalDays != null) {
      // "连续 N 天"没有起点是没法算的，App 侧不可能存出这种值。
      throw new RangeError('有 totalDays 但没有 course_start，数据不合法');
    }
    return NONE;
  }
  if (hasStart !== hasEnd) {
    throw new RangeError('起止日期必须同时给出或同时为空');
  }
  return new Course({
    start: LocalDate.parse(startStr),
    end: LocalDate.parse(endStr),
    totalDays: totalDays ?? null,
  });
}
