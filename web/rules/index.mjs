/**
 * 规则引擎的公开入口。
 *
 * App 里的规则引擎分散在 `domain/model/*.dart` 和 `domain/scheduling/*.dart`，
 * 因为 Flutter 按功能分目录。这里没这个负担，一个入口全导出，
 * 调用方只写 `import { expand, LocalDate } from '../rules/index.mjs'`。
 *
 * @module rules
 */

export { LocalDate, localEpoch, daysInMonth, isLeapYear, floorDiv } from './local_date.mjs';
export {
  LocalTime,
  MealAnchor,
  MEAL_ANCHORS,
  MEAL_ANCHOR_INDEX,
  TimeDefaults,
  defaultTimeForAnchor,
} from './local_time.mjs';
export {
  RepeatRule,
  ParityFilter,
  decodeRepeat,
  isEvenWeek,
  parityMatches,
  allowedWeekdays,
  mod,
} from './repeat_rule.mjs';
export {
  TimeRule,
  FixedTimesRule,
  MealTimesRule,
  IntervalRule,
  CombinedTimeRule,
  decodeTime,
} from './time_rule.mjs';
export { Course, decodeCourse } from './course.mjs';
export {
  expand,
  estimateDailyCount,
  suggestWindowEnd,
  floorDiv as schedulerFloorDiv,
  ScheduleSpec,
  Slot,
  LocalDateTimeRef,
} from './scheduler.mjs';
export { EDITABLE_DAYS, canEdit, isExpired, daysLeft } from './edit_window.mjs';
export { specFromTaskRow, specsFromTaskRows, isTaskLive, LIVE_STATUS } from './task_spec.mjs';
