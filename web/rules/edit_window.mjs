/**
 * 时间窗口规则：哪天还能改。
 *
 * 三个数字来自已定的产品决策：
 * - 日历**回看不限**（不是窗口，是"永远能看"）
 * - 补卡 / "没做" **30 天内**可改
 * - 超过期限：只展示，不可改
 *
 * 与 `app/lib/domain/model/checkin.dart` 的 `EditWindow` 一一对应。
 *
 * ⚠️ 这是**客户端与服务端都要各判一次**的规则，不是纯展示。
 * 服务端 `POST /m/api/checkin` 必须自己按自己的"今天"判一遍，
 * 不能信任网页端算出来的 `date` —— 把系统时间调前一天就能无限补卡，
 * 而"可信"是这个产品的全部价值。
 *
 * @module rules/edit_window
 */

/** 补卡与"没做"可回溯的天数。 */
export const EDITABLE_DAYS = 30;

/**
 * `date` 这一天在 `today` 看来是否还能修改。
 *
 * 注意顺序：**先判未来**。未来日期不能预先打卡（不算补卡，也不允许提前勾）。
 * 如果只判 `daysSince <= 30`，未来日期的差值是负数，负数 ≤ 30 恒真，
 * "明天"就成了可打卡状态。
 */
export function canEdit(date, today) {
  if (date.isAfter(today)) return false;
  return today.daysSince(date) <= EDITABLE_DAYS;
}

/** 是否已经超过可修改期限（UI 置灰 + "超出可修改期限"小字）。 */
export function isExpired(date, today) {
  return today.daysSince(date) > EDITABLE_DAYS;
}

/** 距离失去修改权还有几天（0 = 今天是最后一天）；不能改则 null。 */
export function daysLeft(date, today) {
  if (!canEdit(date, today)) return null;
  return EDITABLE_DAYS - today.daysSince(date);
}
