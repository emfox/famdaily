/**
 * "今天该做哪几件事" —— 网页端唯一的读模型。
 *
 * ## 为什么网页端必须自己算
 *
 * App 里 `slots` 表存的是展开结果，但它**从不参与同步**（架构文档 §4：
 * slots 是派生数据，同步它等于同步一份随时会过期的缓存）。所以网页端
 * 拿到的只有任务规则，槽位必须**按规则现算**。
 *
 * 好消息是这件事是纯函数：给定任务行 + 某一天，结果唯一。
 *
 * ## "今天"是服务器算还是客户端算
 *
 * **客户端给日期，服务端校验格式**。理由：
 * - 沙箱跑在 UTC，用户在东八区，服务器算"今天"会在每天早上 8 点前给错日期；
 * - 但完全信任客户端就能反复打卡未来 —— 所以服务端还有一层
 *   `canEdit(date, today)`（`rules/edit_window.mjs`），权限不靠这一层挡。
 *
 * @module rules/today
 */

import { expand } from './scheduler.mjs';
import { specsFromTaskRows } from './task_spec.mjs';

/**
 * 生成某成员某一天的待办清单。
 *
 * @param {object} init
 * @param {Record<string, unknown>[]} init.taskRows 该成员的 `tasks` 行（未过滤状态）
 * @param {import('./local_date.mjs').LocalDate} init.date 要算哪一天（**疗程日**，不是提醒落地的日期）
 * @param {Record<string, Record<string, unknown>>} [init.checkins]
 *   已有打卡，键是三元组 `taskId|date|index`（与 `checkins` 表主键同构）
 * @param {number} [init.maxSlots]
 * @returns {{
 *   date: string,
 *   items: TodayItem[],
 *   hidden: { taskId: string, reason: string }[],
 * }}
 *
 * - `items`：这一天的所有槽位，按触发时刻排序
 * - `hidden`：规则解析失败被跳过的任务（前端要提示，不能静默吞掉）
 */
export function buildToday({ taskRows, date, checkins = {}, maxSlots = 512 }) {
  const { specs, broken } = specsFromTaskRows(taskRows);

  // ⚠️ **必须只展开这一天**，不能用 expand 展开一个窗口再筛。
  //
  // 理由不是性能，是正确性：`expand` 会按"真实触发时刻"给同一 (taskId, 疗程日)
  // 内的槽位编号。展开窗口时，前一天的跨午夜槽位会混进来参与排序，
  // 导致这一天的 index 起点不是 0 —— 和手机上算出来的对不上，
  // 网页打卡就以一个手机上不存在的 slot_index 落库。
  // 单天展开时，跨午夜的槽位属于"前一天的 index"，只有当天的才是自己的。
  const { slots } = expand({ specs, from: date, to: date, maxSlots });

  const items = slots.map((s) => {
    const key = `${s.taskId}|${s.date.toString()}|${s.index}`;
    const row = checkins[key] ?? null;
    return {
      taskId: s.taskId,
      date: s.date.toString(),
      slotIndex: s.index,
      dueAtMinuteOfDay: s.dueMinuteOfDay,
      dueDate: s.dueAt.date.toString(),
      dueTime: s.dueAt.time.toString(),
      /** 跨午夜：提醒实际落在次日/前日。前端要显示"次日 01:00"。 */
      crossesMidnight: s.dueAt.date.epochDay !== s.date.epochDay,
      checkin: row == null ? null : normalizeCheckin(row),
    };
  });

  return {
    date: date.toString(),
    items,
    hidden: broken.map((b) => ({ taskId: b.id, reason: b.error })),
  };
}

/**
 * 把 `checkins` 行归一成前端能直接用的形状。
 *
 * `state` 一旦出现未知值就**返回 null 并带 raw**，不猜成 done ——
 * 猜成"已完成"等于凭空造出一条用户没做的记录。
 */
function normalizeCheckin(row) {
  const state = row.state;
  const known = state === 'done' || state === 'makeup' || state === 'skipped';
  return {
    state: known ? state : null,
    rawState: known ? null : state,
    doneAtMs: row.done_at_ms ?? null,
    note: row.note ?? null,
    updatedAtMs: row.updated_at_ms ?? null,
  };
}

/**
 * 从 `checkins` 行数组建 `buildToday` 要的索引。
 *
 * @param {Record<string, unknown>[]} rows
 * @returns {Record<string, Record<string, unknown>>}
 */
export function indexCheckins(rows) {
  const out = {};
  for (const r of rows) {
    if (r.deleted === 1) continue;
    out[`${r.task_id}|${r.date}|${r.slot_index}`] = r;
  }
  return out;
}
