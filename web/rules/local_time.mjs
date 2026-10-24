/**
 * 本地时刻：只有时分，没有日期、没有时区。
 *
 * 唯一表示是"当天第几分钟"（`minuteOfDay`），比较、排序、加偏移全是整数运算。
 * 与 `app/lib/domain/model/local_time.dart` 一一对应。
 *
 * @module rules/local_time
 */

/**
 * ⚠️ 这个文件里最容易踩的坑：**两种除法不能混用**。
 *
 * | 场景 | 数学语义 | Dart | JS |
 * |---|---|---|---|
 * | `addMinutes` 折算跨了几天 | 向下取整 | `(total / 1440).floor()` | `Math.floor` |
 * | `LocalDateTimeRef.fromDayAndMinute` | 向下取整 | `floorDiv(m, 1440)` | `Math.floor` |
 * | 一般整除（Dart `~/`） | **向零截断** | `a ~/ b` | `Math.trunc` |
 *
 * 只有"负数"时两者才不同：`Math.trunc(-0.02)` 是 `-0`，`Math.floor(-0.02)` 是 `-1`。
 * 而"饭前 30 分钟"这个偏移会让分钟数变成负数，所以**每个跨天折算都必须用 floor**，
 * 用 `Math.trunc` 的话 07:30 前 60 分钟会被算成 07:30（同一天），
 * 而不是前一天的 06:30，症状是"提醒在饭后就响"。
 */

/** 一天多少分钟。 */
const MINUTES_PER_DAY = 1440;

/** 校验小时/分钟范围。 */
function assertInRange(value, lo, hi, label) {
  if (!Number.isInteger(value) || value < lo || value > hi) {
    throw new RangeError(`${label} 必须在 ${lo}..${hi}：${value}`);
  }
}

/** 一个本地时刻（0:00 – 23:59）。不可变。 */
export class LocalTime {
  /**
   * @param {number} hour 0..23
   * @param {number} minute 0..59
   */
  constructor(hour, minute) {
    assertInRange(hour, 0, 23, '小时');
    assertInRange(minute, 0, 59, '分钟');
    this.hour = hour;
    this.minute = minute;
    this.minuteOfDay = hour * 60 + minute;
    Object.freeze(this);
  }

  /** 从"当天第几分钟"还原（0..1439）。 */
  static fromMinuteOfDay(minuteOfDay) {
    assertInRange(minuteOfDay, 0, MINUTES_PER_DAY - 1, 'minuteOfDay');
    return new LocalTime(Math.floor(minuteOfDay / 60), minuteOfDay % 60);
  }

  /** 解析 `08:05`。 */
  static parse(s) {
    if (typeof s !== 'string') {
      throw new TypeError(`不是合法时刻：${s}`);
    }
    const parts = s.split(':');
    if (parts.length !== 2) {
      throw new RangeError(`不是合法时刻：${s}`);
    }
    return new LocalTime(Number(parts[0]), Number(parts[1]));
  }

  static isValid(s) {
    try {
      LocalTime.parse(s);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * 加分钟偏移，**会跨天**：返回 `[跨过的天数, 结果时刻]`。
   *
   * 例：23:30 + 60 → `[1, 00:30]`；00:30 − 60 → `[-1, 23:30]`。
   * 调用方必须处理 `days`，否则"饭后 30 分钟"在跨午夜时会静默算错。
   */
  addMinutes(minutes) {
    const total = this.minuteOfDay + minutes;
    const days = Math.floor(total / MINUTES_PER_DAY);
    const rem = total - days * MINUTES_PER_DAY;
    return [days, LocalTime.fromMinuteOfDay(rem)];
  }

  /**
   * 加分钟偏移，返回**未归一到 0..1439** 的"当天第几分钟"。
   *
   * 跨天的偏移要保留越界值（+240 分钟 → 1540），交给排程器按 floor 除法
   * 折成"第几天 + 几点"。先归一化就把跨天信息丢了。
   */
  shiftedMinuteOfDay(minutes) {
    return this.minuteOfDay + minutes;
  }

  isBetween(from, to) {
    return this.minuteOfDay >= from.minuteOfDay && this.minuteOfDay <= to.minuteOfDay;
  }

  isBefore(other) {
    return this.minuteOfDay < other.minuteOfDay;
  }

  isAfter(other) {
    return this.minuteOfDay > other.minuteOfDay;
  }

  /** `08:05`。 */
  toString() {
    const p = (v) => String(v).padStart(2, '0');
    return `${p(this.hour)}:${p(this.minute)}`;
  }

  toJSON() {
    return this.toString();
  }
}

/**
 * 三餐锚点及其默认时刻。
 *
 * 顺序即 Dart `MealAnchor` 的 `index`（breakfast=0, lunch=1, dinner=2），
 * 用来给"跟随三餐"的结果排序。
 */
export const MealAnchor = Object.freeze({
  breakfast: 'breakfast',
  lunch: 'lunch',
  dinner: 'dinner',
});

/** 三餐锚点的索引，与 Dart `MealAnchor.index` 一致。 */
export const MEAL_ANCHOR_INDEX = Object.freeze({
  breakfast: 0,
  lunch: 1,
  dinner: 2,
});

/** 所有合法的三餐锚点。 */
export const MEAL_ANCHORS = Object.freeze(['breakfast', 'lunch', 'dinner']);

/** 出厂默认时刻（设置里可改，这里只是初始值）。对应 Dart 的 `TimeDefaults`。 */
export const TimeDefaults = Object.freeze({
  breakfast: new LocalTime(7, 30),
  lunch: new LocalTime(12, 0),
  dinner: new LocalTime(18, 30),
  /** 新建项目时的默认时刻。 */
  evening: new LocalTime(20, 0),
});

/**
 * 三餐锚点的默认时刻。
 *
 * 与服务端 `members`/`settings` 无关：用户改过三餐时刻的话，
 * App 会把它随任务规则一起同步上来（`anchorOverrides`），网页端只读任务里的值。
 */
export function defaultTimeForAnchor(anchor) {
  return TimeDefaults[anchor];
}
