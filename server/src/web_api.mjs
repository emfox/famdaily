/**
 * 成员页的接口：`/m/api/*`。
 *
 * ## 为什么不复用 `/sync`
 *
 * `/sync` 的**请求体本身就是一个写操作**（推全量 + `removedCheckins` 打墓碑）。
 * 把它开给成员页等于：任何一个成员的链接泄露，就能改写全家的数据、
 * 甚至把别人的打卡删掉。成员页要的能力只有两件——看今天的、勾自己的。
 * 给一把能开所有门的钥匙，然后指望前端"只调那几个接口"，是自欺欺人。
 *
 * ## 服务端必须自己判一遍
 *
 * 网页端会把 `date` 发上来。**不能信**。理由：
 * - 把系统时间往前调一年，就能无限补卡；
 * - 服务端跑在沙箱（UTC），用户在 UTC+8，服务器算的"今天"每天早上 8 点前是错的。
 *
 * 所以规则是：日期由客户端给（它是唯一知道自己在哪个时区的人），
 * 但**服务端拿自己的时钟校验**：未来日期一律拒绝，超过 30 天一律拒绝。
 * 时区偏差最多 1 天，落在 30 天窗口的边缘上不会误伤。
 *
 * @module web_api
 */

import { HttpError } from './http.mjs';
import { assertAllowed } from './auth.mjs';
import { mergeCheckinState } from './sync.mjs';
import { EDITABLE_DAYS, LocalDate, canEdit, isExpired } from '../../web/rules/index.mjs';
import { buildToday, indexCheckins } from '../../web/rules/today.mjs';

/** 备注长度上限。够写"水温 40 度，喝完了"，不至于把库撑爆。 */
const MAX_NOTE_LEN = 200;

/** 合法的打卡状态。**只有这三个**，别的值一律拒绝。 */
const VALID_STATES = new Set(['done', 'makeup', 'skipped']);

/** 从 `?date=yyyy-mm-dd` 取日期；不给就用服务端的今天。 */
function parseDateParam(raw, nowMs) {
  if (raw == null || raw === '') {
    return todayOnServer(nowMs);
  }
  if (!LocalDate.isValid(raw)) {
    throw new HttpError(400, 'bad_date', `日期格式不对：${raw}`);
  }
  return LocalDate.parse(raw);
}

/**
 * 服务端的"今天"（UTC）。
 *
 * 只在客户端没给日期时兜底。它可能和用户那边的日期差一天 —— 所以
 * **响应里会把用的是哪一天明确写出来**，前端据此判断要不要带自己的日期。
 */
export function todayOnServer(nowMs) {
  return LocalDate.fromDate(new Date(nowMs));
}

/**
 * `GET /m/api/today?date=yyyy-mm-dd`
 *
 * 返回某成员某一天的待办 + 已有打卡。
 *
 * 只给**这个人自己的**任务：`tasks.member_id = 链接对应的 member`。
 * 越权不是靠前端藏起来，是查询里就带死了条件。
 */
export function handleToday(ctx, deps) {
  const { db, clock, limiters } = deps;
  const { req, url, identity } = ctx;
  if (!identity) throw new HttpError(401, 'no_identity', '链接无效或已作废');

  assertAllowed(
    limiters.webRead.hit(`${identity.memberId}:${req.socket?.remoteAddress ?? ''}`),
  );

  const now = Date.now();
  const date = parseDateParam(url.searchParams.get('date'), now);

  const taskRows = db
    .prepare(
      `SELECT * FROM tasks
        WHERE family_id = ? AND member_id = ?
        ORDER BY sort_order ASC, created_at_ms ASC`,
    )
    .all(identity.familyId, identity.memberId);

  const checkinRows = db
    .prepare(
      `SELECT * FROM checkins
        WHERE family_id = ? AND date = ? AND deleted = 0`,
    )
    .all(identity.familyId, date.toString());

  const today = buildToday({
    taskRows,
    date,
    checkins: indexCheckins(checkinRows),
  });

  // 任务名和备注不来自 buildToday（它只算槽位），在这里补上。
  const byId = new Map(taskRows.map((r) => [r.id, r]));
  const items = today.items.map((it) => {
    const t = byId.get(it.taskId);
    return {
      ...it,
      name: t?.name ?? '',
      taskNote: t?.note ?? null,
      iconId: t?.icon_id ?? null,
      // 这一天还能不能改。前端据此置灰，**但服务端在写接口里还会再判一次**。
      editable: canEdit(date, todayOnServer(now)) && !isExpired(date, todayOnServer(now)),
    };
  });

  return {
    ok: true,
    member: { id: identity.memberId, name: identity.memberName },
    date: date.toString(),
    // 服务端认为的今天。前端如果发现自己算的和这个差得多，说明时区设置有鬼。
    serverDate: todayOnServer(now).toString(),
    items,
    // 规则解析失败的任务：前端要提示出来，不能静默少显示一条。
    hidden: today.hidden,
    // 这一天的记录还能不能改（整页置灰用）。逐条还有 `items[].editable`，
    // 两个都要给：翻到 40 天前时前端要一句"只能看，不能改"的说明，
    // 而逐条判断只能得出"每一条都灰"，说不出原因。
    dayEditable: canEdit(date, todayOnServer(now)),
    clock: clock.peek(),
  };
}

/**
 * `POST /m/api/checkin`
 *
 * body: `{ taskId, date, slotIndex, state, note? }`
 *
 * 三条校验，缺一不可：
 * 1. **任务必须属于这个成员**（越权 403，而不是 404 —— 成员看得见自己的
 *    任务列表，看不到别人的，所以"存在但不是你的"和"不存在"必须区分，
 *    否则前端只能显示"这任务不存在"，用户会以为自己的任务丢了）
 * 2. **日期必须在可编辑窗口内**（未来拒绝、超 30 天拒绝）
 * 3. **槽位必须真的存在**（`slotIndex` 落在当天算出来的范围内）
 *
 * 第 3 条容易被忽略，但它是"网页端多算出一个槽位"的兜底：
 * 如果哪天规则引擎两端不一致，网页端多出来的那个 index 会在这里被挡下，
 * 而不是变成一条手机上永远看不到的孤儿记录。
 */
export function handleCheckin(ctx, deps) {
  const { db, clock, limiters } = deps;
  const { identity, req } = ctx;
  if (!identity) throw new HttpError(401, 'no_identity', '链接无效或已作废');

  assertAllowed(
    limiters.webWrite.hit(`${identity.memberId}:${req.socket?.remoteAddress ?? ''}`),
  );

  const body = ctx.body ?? {};
  const taskId = body.taskId;
  const slotIndex = body.slotIndex;
  const state = body.state;
  const rawDate = body.date;

  if (typeof taskId !== 'string' || taskId === '') {
    throw new HttpError(400, 'bad_request', '缺 taskId');
  }
  if (!Number.isInteger(slotIndex) || slotIndex < 0 || slotIndex > 999) {
    throw new HttpError(400, 'bad_request', `slotIndex 不合法：${slotIndex}`);
  }
  if (typeof state !== 'string' || !VALID_STATES.has(state)) {
    throw new HttpError(
      400,
      'bad_state',
      `state 只能是 done / makeup / skipped，收到 ${JSON.stringify(state)}`,
    );
  }
  if (typeof rawDate !== 'string' || !LocalDate.isValid(rawDate)) {
    throw new HttpError(400, 'bad_date', `日期格式不对：${rawDate}`);
  }

  let note = null;
  if (body.note != null) {
    if (typeof body.note !== 'string') {
      throw new HttpError(400, 'bad_request', 'note 必须是字符串');
    }
    note = body.note.trim().slice(0, MAX_NOTE_LEN);
    if (note === '') note = null;
  }

  const date = LocalDate.parse(rawDate);
  const now = Date.now();
  const serverToday = todayOnServer(now);

  // ---- 校验 1：未来日期 ----
  // 必须**单独判一次**。`canEdit` 内部虽然也是"先判未来"，但它把
  // 未来和过期都归成 `false`，对外只能给出一句含糊的"不能改"。
  // 前端要据此决定是"提示还没到那天"还是"提示超出期限"，所以分开抛。
  if (date.isAfter(serverToday)) {
    throw new HttpError(403, 'future_date', '还没到那一天，不能提前打卡');
  }

  // ---- 校验 2：可编辑窗口 ----
  if (!canEdit(date, serverToday)) {
    throw new HttpError(
      403,
      'edit_window_expired',
      `只能改最近 ${EDITABLE_DAYS} 天的记录`,
    );
  }

  // ---- 校验 3：任务归属（越权）----
  const task = db
    .prepare(
      `SELECT id, member_id, status, deleted_at_ms, repeat_json, time_json,
              course_start, course_end, course_total_days, rules_effective_from
         FROM tasks WHERE family_id = ? AND id = ?`,
    )
    .get(identity.familyId, taskId);
  if (!task) {
    throw new HttpError(404, 'task_not_found', '没有这个打卡项');
  }
  if (task.member_id !== identity.memberId) {
    throw new HttpError(403, 'forbidden', '这不是你的打卡项');
  }

  // ---- 校验 4：槽位存在 ----
  const { items } = buildToday({ taskRows: [task], date, checkins: {} });
  const slot = items.find((it) => it.slotIndex === slotIndex);
  if (!slot) {
    // 两种情况都会走到这里：真的没这个槽位（前端算错），
    // 或者任务当天不生效（暂停/疗程外）。对外一句"这一项今天不需要打卡"，
    // 别把内部原因吐给用户 —— 他改不了一样。
    throw new HttpError(
      409,
      'slot_not_found',
      '这一项当天没有这次打卡（可能已暂停或疗程外）',
    );
  }

  const nowMs = now;
  const existing = db
    .prepare(
      `SELECT state, done_at_ms, deleted, deleted_at_ms, server_at_ms, note,
              due_at_minute_of_day, created_at_ms, updated_at_ms
         FROM checkins WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
    )
    .get(identity.familyId, taskId, date.toString(), slotIndex);

  // 合并规则和 `/sync` **用的是同一个函数**。这一点很重要：
  // 网页端和 App 各写一套合并逻辑，就会出现"网页上勾了，手机上还是没勾"。
  const merged = mergeCheckinState(
    existing ?? {
      state: null,
      done_at_ms: null,
      note: null,
      due_at_minute_of_day: null,
    },
    {
      state,
      // 补卡和"没做"也要记时间（何时点的），和 App 一致。
      doneAtMs: nowMs,
      dueAtMinuteOfDay: slot.dueAtMinuteOfDay,
      note,
    },
  );

  // 服务端时钟：**必须用 deps.clock**，不能用 Date.now()。
  // `server_at_ms` 是增量拉取的水位，同一毫秒内写两行会让后者永远拉不到。
  const at = clock.next();

  db.prepare(
    `INSERT INTO checkins (family_id, task_id, date, slot_index, state,
                           done_at_ms, due_at_minute_of_day, note, deleted,
                           deleted_at_ms, created_at_ms, updated_at_ms, server_at_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)
     ON CONFLICT (family_id, task_id, date, slot_index) DO UPDATE SET
       state = excluded.state,
       done_at_ms = excluded.done_at_ms,
       due_at_minute_of_day = excluded.due_at_minute_of_day,
       note = excluded.note,
       deleted = 0,
       deleted_at_ms = NULL,
       updated_at_ms = excluded.updated_at_ms,
       server_at_ms = excluded.server_at_ms`,
  ).run(
    identity.familyId,
    taskId,
    date.toString(),
    slotIndex,
    merged.state,
    merged.doneAtMs,
    merged.dueAtMinuteOfDay,
    merged.note,
    existing?.created_at_ms ?? nowMs,
    nowMs,
    at,
  );

  return {
    ok: true,
    taskId,
    date: date.toString(),
    slotIndex,
    state: merged.state,
    doneAtMs: merged.doneAtMs,
    note: merged.note,
    // 让网页端知道"这条已经进同步队列了"，不用它自己算水位。
    serverAtMs: at,
    clock: clock.peek(),
  };
}
