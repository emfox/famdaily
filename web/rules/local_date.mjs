/**
 * 本地日历日期：`yyyy-mm-dd`，没有时刻、没有时区。
 *
 * ## 为什么要照抄 Dart
 *
 * 网页端要算"今天该做哪几件事"，而"该做哪几件事"由三套正交规则决定
 * （哪天做 × 几点做 × 疗程）。这三套规则在 App 里已经有一份 Dart 实现，
 * 而且是**唯一正确**的那份。网页端必须算出**逐位一致**的结果：
 *
 * - 手机显示"今天 3 次"，网页显示"今天 2 次"——用户会觉得这软件坏了；
 * - 网页多出一个槽位，用户点它打卡，落库的 `slot_index` 是手机上不存在的，
 *   手机上永远看不到这条记录，反过来"改了没生效"。
 *
 * 所以这里的每个函数都和 `app/lib/domain/model/local_date.dart` 一一对应，
 * 连函数名都照抄，方便并排核对。**改一边必须改另一边**，
 * 由 `web/test/fixtures/slots-cases.json` 这份共享夹具守住（见 `web/test/rules.test.mjs`）。
 *
 * ## 为什么不用 `Date`
 *
 * "某一天"是日历概念，不是时间点。`new Date(y, m, d)` 会带上本地时区，
 * 一旦服务器不是用户所在时区（沙箱就是 UTC），
 * `new Date('2026-10-24')` 解析成 UTC 零点，在 UTC+8 里就变成 10-24 08:00，
 * 再取 local 部分还好，但任何一次 `toISOString()` 都会退回前一天。
 * 全程用"自 1970-01-01 起的天数"做整数运算，这类错一个都不会有。
 *
 * @module rules/local_date
 */

/** 每月天数（平年）。 */
const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/** 某年是否闰年（格里高利历规则）。 */
export function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

/** 某年某月的天数。 */
export function daysInMonth(year, month) {
  if (month === 2 && isLeapYear(year)) return 29;
  return DAYS_IN_MONTH[month - 1];
}

/** `Math.floor(a / b)`，负数也向下取整。 */
export function floorDiv(a, b) {
  return Math.floor(a / b);
}

/**
 * Howard Hinnant 的 `days_from_civil`。纯整数，无时区依赖。
 *
 * 与 Dart 的 `LocalDate._toEpochDay` 逐位一致，**包括** `~/.floor` 的写法：
 * Dart 用 `~/` 是向零截断，但这里的被除数在 1583 年之后恒为正，
 * 所以 `Math.trunc` 和 `Math.floor` 等价。用 `Math.floor` 是为了顺手兼容
 * 公元前的年份（用不到，但也不会错）。
 */
export function toEpochDay(y, m, d) {
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor((yy >= 0 ? yy : yy - 399) / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

/**
 * 一个本地日期。
 *
 * 不可变；用 `LocalDate.of(y, m, d)` / `LocalDate.fromEpochDay(n)` /
 * `LocalDate.parse(s)` 造，别直接 new。
 */
export class LocalDate {
  /**
   * @param {number} year
   * @param {number} month 1..12
   * @param {number} day 1..31
   * @param {number} epochDay 自 1970-01-01 起的天数
   */
  constructor(year, month, day, epochDay) {
    this.year = year;
    this.month = month;
    this.day = day;
    this.epochDay = epochDay;
    Object.freeze(this);
  }

  /** 用年月日构造，校验合法性（2 月 30 日抛 `RangeError`）。 */
  static of(year, month, day) {
    if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) {
      throw new TypeError(`LocalDate.of 只接受整数：${year}-${month}-${day}`);
    }
    if (month < 1 || month > 12) {
      throw new RangeError(`月份必须在 1..12：${month}`);
    }
    const max = daysInMonth(year, month);
    if (day < 1 || day > max) {
      throw new RangeError(`${year}-${month} 没有第 ${day} 天`);
    }
    return new LocalDate(year, month, day, toEpochDay(year, month, day));
  }

  /** 从"自 1970-01-01 起的天数"还原（Howard Hinnant 的 `civil_from_days`）。 */
  static fromEpochDay(epochDay) {
    const z = epochDay + 719468;
    const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
    const doe = z - era * 146097;
    const yoe = Math.floor(
      (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    const mp = Math.floor((5 * doy + 2) / 153);
    const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
    const m = mp < 10 ? mp + 3 : mp - 9;
    return new LocalDate(m <= 2 ? y + 1 : y, m, d, epochDay);
  }

  /**
   * 从 `Date` 取**它自己的本地**年月日。
   *
   * 只在"服务端要知道用户那边几号"这一个地方用得到。传进来的 `Date`
   * 必须是**已经按用户时区偏移过**的（服务端拿到的是毫秒时间戳 + 用户时区偏移，
   * 见 `web/rules/today.mjs`），否则算出来的是服务器所在时区的日期。
   */
  static fromDate(date) {
    return LocalDate.of(date.getFullYear(), date.getMonth() + 1, date.getDate());
  }

  /** 解析 `2026-10-24`。 */
  static parse(s) {
    if (typeof s !== 'string') {
      throw new TypeError(`不是合法日期：${s}`);
    }
    const parts = s.split('-');
    if (parts.length !== 3) {
      throw new RangeError(`不是合法日期：${s}`);
    }
    return LocalDate.of(Number(parts[0]), Number(parts[1]), Number(parts[2]));
  }

  static isValid(s) {
    try {
      LocalDate.parse(s);
      return true;
    } catch {
      return false;
    }
  }

  /** 周几，1 = 周一 … 7 = 周日（与 `Date.getDay()` 和 Dart `weekday` 都不同，注意）。 */
  get weekday() {
    return (((this.epochDay + 3) % 7) + 7) % 7 + 1;
  }

  get isWeekend() {
    return this.weekday >= 6;
  }

  get isLeapDay() {
    return this.month === 2 && this.day === 29;
  }

  addDays(days) {
    return LocalDate.fromEpochDay(this.epochDay + days);
  }

  addMonths(months) {
    const total = this.year * 12 + (this.month - 1) + months;
    const y = Math.floor(total / 12);
    const m = (((total % 12) + 12) % 12) + 1;
    // 1 月 31 日 + 1 个月 → 2 月 28/29 日（截断，不溢出到下个月）
    const d = this.day > daysInMonth(y, m) ? daysInMonth(y, m) : this.day;
    return LocalDate.of(y, m, d);
  }

  get lastDayOfMonth() {
    return LocalDate.of(this.year, this.month, daysInMonth(this.year, this.month));
  }

  /** 自 `from` 起差几天（本日期更晚则为正）。 */
  daysSince(from) {
    return this.epochDay - from.epochDay;
  }

  isBefore(other) {
    return this.epochDay < other.epochDay;
  }

  isAfter(other) {
    return this.epochDay > other.epochDay;
  }

  isSameDay(other) {
    return this.epochDay === other.epochDay;
  }

  isBetween(from, to) {
    return this.epochDay >= from.epochDay && this.epochDay <= to.epochDay;
  }

  /** `2026-10-24`。 */
  toString() {
    const p = (v) => String(v).padStart(2, '0');
    return `${this.year}-${p(this.month)}-${p(this.day)}`;
  }

  toJSON() {
    return this.toString();
  }
}

/** 1970-01-01。对应 Dart 的 `localEpoch`。 */
export const localEpoch = LocalDate.fromEpochDay(0);
