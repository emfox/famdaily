/**
 * 服务端的 `tasks` 行 → 排程规格。
 *
 * 这层是**胶水**，但胶水的位置决定了正确性：App 里 `Task` 是一个本来就
 * 解析好的对象，网页端拿到的是 SQLite 的裸行（`repeat_json` 是字符串、
 * `course_start` 是三列、`status` 是裸字符串）。把解析放在这里，
 * 上层（`today.mjs`）就只面对领域对象，不会到处都是 `JSON.parse`。
 *
 * @module rules/task_spec
 */

import { decodeCourse } from './course.mjs';
import { LocalDate } from './local_date.mjs';
import { decodeRepeat } from './repeat_rule.mjs';
import { ScheduleSpec } from './scheduler.mjs';
import { decodeTime } from './time_rule.mjs';

/** 只有 `active` 才算"要出提醒"。 */
export const LIVE_STATUS = 'active';

/**
 * 一行 `tasks` 是否参与排程。
 *
 * 与 Dart 的 `Task.isLive`（`status.isLive && deletedAtMs == null`）一致。
 * 特别注意 `deleted_at_ms != null` 时**即使 status 还是 active 也要排除**：
 * 删除是"打标记 + 翻状态"两步，中间有一瞬间状态没翻。
 */
export function isTaskLive(row) {
  return row.status === LIVE_STATUS && (row.deleted_at_ms == null || row.deleted_at_ms === 0);
}

/**
 * 解析一行 `tasks`，得到 `ScheduleSpec`。
 *
 * 解析失败**抛错**，不吞。理由：服务端的数据是 App 自己写进来的，
 * 解析不出来说明版本不兼容或数据损坏，此时"少显示一条"比"报错"危险得多 ——
 * 用户会以为今天真的没这件事，然后漏掉吃药。
 *
 * @param {Record<string, unknown>} row `tasks` 表的一行
 * @returns {ScheduleSpec}
 */
export function specFromTaskRow(row) {
  const repeat = decodeRepeat(row.repeat_json);
  const time = decodeTime(row.time_json);
  const course = decodeCourse(row.course_start, row.course_end, row.course_total_days);

  return new ScheduleSpec({
    taskId: row.id,
    repeat,
    time,
    course,
    fromDate: row.rules_effective_from ? LocalDate.parse(row.rules_effective_from) : null,
    enabled: isTaskLive(row),
  });
}

/**
 * 把一批行转成规格，**跳过不参与排程的**，并收集解析失败的。
 *
 * 跳过是在这里做的（而不是让 `expand` 内部过滤）：`enabled: false` 的 spec
 * 塞进去只会让 `appliesOn` 每次都白算一遍。
 *
 * @param {Record<string, unknown>[]} rows
 * @returns {{ specs: ScheduleSpec[], broken: {id: string, error: string}[] }}
 */
export function specsFromTaskRows(rows) {
  const specs = [];
  const broken = [];
  for (const row of rows) {
    if (!isTaskLive(row)) continue;
    try {
      specs.push(specFromTaskRow(row));
    } catch (err) {
      broken.push({ id: String(row.id), error: err.message });
    }
  }
  return { specs, broken };
}
