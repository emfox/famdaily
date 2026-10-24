/**
 * `GET /export`：把整个家庭的数据导出成一份 JSON，格式**和 App 的备份文件一致**。
 *
 * ## 为什么复用 App 的备份格式，而不是另造一个
 *
 * 两个理由，第二个更重要：
 *
 * 1. **能读回去**。App 里有「覆盖恢复」；只要字段名对得上，用户从网页端
 *    下载的这份文件就能直接在 App 里恢复。要是自创一套格式，导出的东西
 *    只能拿记事本看，那就不叫备份，叫快照。
 * 2. **格式只能有一个定义**。两份格式并存，改一边忘一边，结果是"导出的
 *    备份恢复不了"——而这恰好是最需要它的时候才发现。
 *
 * 契约见 `app/lib/data/backup/backup_data.dart` 的 `BackupData.toJson`。
 * **改字段名要两边一起改**，并在 `server/test/export.test.mjs` 里同步夹具。
 *
 * ## 三个刻意的取舍
 *
 * - **不含照片**：照片只存在 App 本地（`photo_path` 是相对路径），服务端
 *   从来没有二进制。导出里 `photo_path` 保留原值，恢复后指向的仍是 App 那边的
 *   文件；换机恢复时照片自然丢失，这一点在 `includes_photos: false` 里说明了。
 * - **包含软删除的行**：`deleted_at_ms != null` 的成员和项目照样导出。
 *   备份的用途是"回到某个时刻"，把删除这件事本身也带上才是完整的。
 * - **不导出 `web_token_hash`**：成员链接的凭据不进备份文件 —— 备份会被
 *   拷进网盘、发到微信，而链接是可以直接用来打卡的。
 *
 * @module export_data
 */

import { HttpError } from './http.mjs';

/** 与 App 的 `BackupData.formatVersion` 对齐。 */
export const EXPORT_FORMAT_VERSION = 1;

/**
 * 服务端认识的数据库版本。
 *
 * 这个数字**必须**跟着 `migrate.mjs` 的最高版本走：App 用它判断
 * "这份备份来自更新的版本吗"。写死一个旧值会让新版 App 误判。
 */
export function schemaVersionOf(db) {
  const row = db.prepare('PRAGMA user_version').get();
  return Number(row?.user_version ?? 1);
}

/** `repeat_json` / `time_json` 在库里是字符串，备份格式里是**对象**。 */
function jsonOrNull(raw) {
  if (raw == null) return null;
  if (typeof raw === 'object') return raw;
  try {
    return JSON.parse(raw);
  } catch {
    // 解析不出来就给 null，**不抛**：一条坏规则不该让整份备份导不出来。
    // 恢复时 App 会因为缺字段把它当成默认规则，而"少一条规则"比"导不出"好。
    return null;
  }
}

/**
 * `GET /export` 的实现。
 *
 * 只导出**这台设备所属家庭**的数据 —— `family_id` 全部来自
 * `ctx.device.familyId`，不接受任何外部参数。多家庭共用一台服务端时，
 * 这一行错了就是跨家庭泄漏。
 */
export function handleExport(ctx, deps) {
  const { db, clock } = deps;
  const { device } = ctx;
  if (!device) {
    throw new HttpError(401, 'unauthorized', '需要先配对');
  }
  const familyId = device.familyId;

  const members = db
    .prepare(
      `SELECT id, name, avatar_id, sort_order, created_at_ms, updated_at_ms, deleted_at_ms
         FROM members WHERE family_id = ? ORDER BY sort_order, created_at_ms`,
    )
    .all(familyId);

  const tasks = db
    .prepare(
      `SELECT id, member_id, name, note, icon_id, repeat_json, time_json,
              course_start, course_end, course_total_days, status,
              reminder_enabled, sort_order, created_at_ms, updated_at_ms, deleted_at_ms
         FROM tasks WHERE family_id = ? ORDER BY sort_order, created_at_ms`,
    )
    .all(familyId);

  // ⚠️ `deleted = 1` 的行**必须排除**。
  //
  // 服务端的"取消打卡"是软删除（`deleted = 1` + `deleted_at_ms`），不是把行删掉。
  // 而 App 的备份格式里**没有**这个字段 —— 原样导出之后，恢复回来会让
  // 用户明确取消掉的记录重新变成"做了"。这不是理论问题：`/sync` 的合并
  // 逻辑里删除是一个可见的动作，而备份是一条独立的时间线。
  //
  // 删掉的记录本来就不该出现在"这个家庭现在的样子"里。
  const checkins = db
    .prepare(
      `SELECT task_id, date, slot_index, state, done_at_ms, due_at_minute_of_day, note
         FROM checkins
        WHERE family_id = ? AND (deleted IS NULL OR deleted = 0)
        ORDER BY date, slot_index`,
    )
    .all(familyId);

  // 设置项：**排除**本机凭据（`sync.*`）。它们对另一台设备没有意义，
  // 而且带着 token 的文件不该出现在网盘里。
  //
  // ⚠️ 诚实说明：这个过滤**当前测不到效果**。`SyncKeys.all` 里明确写了
  // 那批键"不参与同步"，所以 `settings` 表里本来就不会出现 `sync.*`。
  // 反向验证时把这一行删掉，全部用例照样绿。
  //
  // 留着它是**纵深防御**：万一将来某个 `sync.*` 键被误加进
  // `syncedSettingKeys` 白名单，这里是最后一道。而"删掉这行会不会红"
  // 这个问题的正确答案是"不会"，不是"会" —— 一条假装覆盖了的测试，
  // 比没有测试更糟。
  const settings = {};
  for (const row of db
    .prepare('SELECT key, value FROM settings WHERE family_id = ? ORDER BY key')
    .all(familyId)) {
    if (String(row.key).startsWith('sync.')) continue;
    settings[row.key] = String(row.value);
  }

  const now = Date.now();

  return {
    ok: true,
    // ↓ 以下字段名是**对外契约**，与 `BackupData.toJson` 逐字对应
    backup: {
      format_version: EXPORT_FORMAT_VERSION,
      created_at_ms: now,
      // 服务端版本号和 App 版本号不是一个东西，但备份里这一格是"谁写的"，
      // 写清楚来源比写一个假版本号有用。
      app_version: 'famdaily-server',
      schema_version: schemaVersionOf(db),
      includes_photos: false,
      members: members.map((m) => ({
        id: m.id,
        name: m.name,
        avatar_id: m.avatar_id,
        sort_order: m.sort_order,
        created_at_ms: m.created_at_ms,
        updated_at_ms: m.updated_at_ms,
        deleted_at_ms: m.deleted_at_ms,
      })),
      tasks: tasks.map((t) => ({
        id: t.id,
        member_id: t.member_id,
        name: t.name,
        note: t.note,
        icon_id: t.icon_id,
        repeat: jsonOrNull(t.repeat_json),
        time: jsonOrNull(t.time_json),
        course_start: t.course_start,
        course_end: t.course_end,
        course_total_days: t.course_total_days,
        status: t.status,
        reminder_enabled: t.reminder_enabled === 1,
        sort_order: t.sort_order,
        created_at_ms: t.created_at_ms,
        updated_at_ms: t.updated_at_ms,
        deleted_at_ms: t.deleted_at_ms,
      })),
      // ⚠️ 打卡记录在 App 的备份里有 `id`，而服务端的 `checkins` 表主键是
      // `(family_id, task_id, date, slot_index)`，没有独立的 id 列。
      // 这里**合成**一个稳定的 id：同一行永远得到同一个值，恢复时不会
      // 因为它"看起来像新记录"而被当成重复插入。
      checkins: checkins.map((c) => ({
        id: `srv:${c.task_id}:${c.date}:${c.slot_index}`,
        task_id: c.task_id,
        date: c.date,
        slot_index: c.slot_index,
        state: c.state,
        done_at_ms: c.done_at_ms,
        due_at_minute_of_day: c.due_at_minute_of_day,
        note: c.note,
        /**
         * **永远是 null**，不是漏了。
         *
         * `photo_path` 只存在 App 的本地文件里，服务端的 `checkins` 表
         * 根本没有这一列（照片从不上传）。写 null 而不是省掉这个键，
         * 是为了让字段集和 `BackupCodec.checkinToJson` 完全一致 ——
         * 少一个键在 `fromJson` 那边取到 null，效果一样，但契约上对不齐。
         */
        photo_path: null,
      })),
      settings,
    },
    clock: clock.peek(),
  };
}

/**
 * 建议的文件名。
 *
 * 带日期，因为用户会下载好几次；不带 token / 家庭 id 之类的内部信息。
 * App 侧的 `suggestedFileName` 是 `.zip`（含照片），这里是单个 `.json`，
 * 所以后缀不同 —— **内容格式相同**，App 的恢复能读。
 */
export function exportFileName(nowMs = Date.now()) {
  const d = new Date(nowMs);
  const p = (n) => String(n).padStart(2, '0');
  return `famdaily-backup-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}.json`;
}
