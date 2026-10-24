/**
 * `POST /sync`：推一次 + 拉一次，一个往返。
 *
 * 为什么把推和拉合成一个接口而不是 `/push` + `/pull`：
 * 沙箱会休眠、链路会断，**一次往返的成本远高于一次本地 CPU**，
 * 而且中间断掉的窗口只有一个（就是这一次）。分成两个请求的话，
 * "推成功了拉失败"会让客户端同时握着"我发过了"和"我不知道对面有什么"
 * 两个半截状态，下次得自己推导，推导错了就是数据丢失。
 *
 * 语义：
 * - 请求体是**全量当前状态**，不是变更集。家庭规模下约 150KB，
 *   比维护变更集简单一个数量级，且没有"漏推某种模式"这种 bug。
 * - 响应带 `cursor`（服务端单调时钟）。客户端拿它当下次的 `since`。
 * - 单条失败进 `rejected`，**不回滚整批**：一个坏条目不该让全家 200 条白推一次。
 *   但必须告诉客户端，否则就是静默丢数据。
 */

import { HttpError } from './http.mjs';
import { assertAllowed } from './auth.mjs';

/** 单次推送的条数上限。超过一般是客户端搞错了，不是真的有一万条打卡。 */
const MAX_ROWS_PER_KIND = 5000;

/** 合法打卡状态。不认识的**拒绝**，绝不猜成 done——那等于凭空造出"已完成"。 */
const CHECKIN_STATES = new Set(['done', 'makeup', 'skipped']);

/** 时间规则的四种形态。 */
const TIME_RULE_TYPES = new Set(['fixed', 'meal', 'interval', 'combined']);

function isNonEmptyString(v) {
  return typeof v === 'string' && v !== '';
}

function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

function asInt(v, fallback = null) {
  return Number.isInteger(v) ? v : fallback;
}

function asText(v, max = 500) {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'string') return null;
  return v.length > max ? v.slice(0, max) : v;
}

/**
 * 校验一行成员。返回规范化后的对象，或抛出人话原因。
 *
 * 校验写得这么细，是因为**服务端是最后一道关**：客户端版本不一致时，
 * 一个 1.0 的 App 会推 2.0 的 App 才有的字段名，如果服务端宽容地把
 * 不认识的字段丢掉再写库，两边的数据就悄悄不一致了，而且没有任何日志。
 */
function normalizeMember(raw) {
  if (!isNonEmptyString(raw?.id)) throw new Error('成员缺 id');
  if (raw.id.length > 64) throw new Error('成员 id 太长');
  if (!isNonEmptyString(raw.name)) throw new Error('成员缺名字');
  if (raw.name.length > 40) throw new Error('成员名字太长');
  if (!isFiniteNumber(raw.createdAtMs)) throw new Error('成员缺 createdAtMs');
  if (!isFiniteNumber(raw.updatedAtMs)) throw new Error('成员缺 updatedAtMs');
  return {
    id: raw.id,
    name: raw.name,
    avatarId: asText(raw.avatarId, 40),
    sortOrder: asInt(raw.sortOrder, 0) ?? 0,
    createdAtMs: Math.trunc(raw.createdAtMs),
    updatedAtMs: Math.trunc(raw.updatedAtMs),
    deletedAtMs: isFiniteNumber(raw.deletedAtMs) ? Math.trunc(raw.deletedAtMs) : null,
  };
}

function normalizeRepeatJson(v) {
  // 规则 JSON 由客户端编码，服务端**不解释内容**，只确认它是能装进 TEXT 的字符串。
  // 解释它意味着服务端要跟客户端的规则版本同步演进，那是长期维护成本；
  // 而规则错了的代价是"这个项目排不出来"，客户端自己就会报错，不需要服务端兜。
  if (typeof v !== 'string' || v === '') throw new Error('项目缺 repeatJson');
  if (v.length > 4000) throw new Error('repeatJson 太大');
  let parsed;
  try {
    parsed = JSON.parse(v);
  } catch {
    throw new Error('repeatJson 不是合法 JSON');
  }
  if (parsed === null || typeof parsed !== 'object') {
    throw new Error('repeatJson 必须是对象');
  }
  return v;
}

function normalizeTimeJson(v) {
  if (typeof v !== 'string' || v === '') throw new Error('项目缺 timeJson');
  if (v.length > 4000) throw new Error('timeJson 太大');
  let parsed;
  try {
    parsed = JSON.parse(v);
  } catch {
    throw new Error('timeJson 不是合法 JSON');
  }
  if (parsed === null || typeof parsed !== 'object') {
    throw new Error('timeJson 必须是对象');
  }
  if (!TIME_RULE_TYPES.has(parsed.type)) {
    // 这一条必须拒：不认识的规则类型写进库里，拉取端会按"看不懂"处理，
    // 而这个项目从此在这个家里永远排不出来。
    throw new Error(`不认识的时刻规则类型：${String(parsed.type)}`);
  }
  return v;
}

function normalizeTask(raw) {
  if (!isNonEmptyString(raw?.id)) throw new Error('项目缺 id');
  if (raw.id.length > 64) throw new Error('项目 id 太长');
  if (!isNonEmptyString(raw.memberId)) throw new Error('项目缺 memberId');
  if (!isNonEmptyString(raw.name)) throw new Error('项目缺名字');
  if (raw.name.length > 60) throw new Error('项目名字太长');
  if (!isFiniteNumber(raw.createdAtMs)) throw new Error('项目缺 createdAtMs');
  if (!isFiniteNumber(raw.updatedAtMs)) throw new Error('项目缺 updatedAtMs');
  return {
    id: raw.id,
    memberId: raw.memberId,
    name: raw.name,
    note: asText(raw.note, 500),
    iconId: asText(raw.iconId, 40),
    repeatJson: normalizeRepeatJson(raw.repeatJson),
    timeJson: normalizeTimeJson(raw.timeJson),
    courseStart: asText(raw.courseStart, 10),
    courseEnd: asText(raw.courseEnd, 10),
    courseTotalDays: isFiniteNumber(raw.courseTotalDays)
      ? Math.trunc(raw.courseTotalDays)
      : null,
    status: asText(raw.status, 20) ?? 'active',
    reminderEnabled: raw.reminderEnabled === false ? 0 : 1,
    sortOrder: asInt(raw.sortOrder, 0) ?? 0,
    rulesEffectiveFrom: asText(raw.rulesEffectiveFrom, 10),
    createdAtMs: Math.trunc(raw.createdAtMs),
    updatedAtMs: Math.trunc(raw.updatedAtMs),
    deletedAtMs: isFiniteNumber(raw.deletedAtMs) ? Math.trunc(raw.deletedAtMs) : null,
  };
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function normalizeCheckin(raw) {
  if (!isNonEmptyString(raw?.taskId)) throw new Error('打卡缺 taskId');
  if (typeof raw.date !== 'string' || !DATE_RE.test(raw.date)) {
    throw new Error(`打卡日期格式不对：${String(raw.date)}`);
  }
  if (!Number.isInteger(raw.slotIndex) || raw.slotIndex < 0) {
    throw new Error('打卡 slotIndex 必须是非负整数');
  }
  if (!CHECKIN_STATES.has(raw.state)) {
    throw new Error(`不认识的打卡状态：${String(raw.state)}`);
  }
  return {
    taskId: raw.taskId,
    date: raw.date,
    slotIndex: raw.slotIndex,
    state: raw.state,
    doneAtMs: isFiniteNumber(raw.doneAtMs) ? Math.trunc(raw.doneAtMs) : null,
    dueAtMinuteOfDay: isFiniteNumber(raw.dueAtMinuteOfDay)
      ? Math.trunc(raw.dueAtMinuteOfDay)
      : null,
    note: asText(raw.note, 500),
    createdAtMs: isFiniteNumber(raw.createdAtMs) ? Math.trunc(raw.createdAtMs) : Date.now(),
    updatedAtMs: isFiniteNumber(raw.updatedAtMs) ? Math.trunc(raw.updatedAtMs) : Date.now(),
  };
}

/** 只同步白名单里的设置键。 */
export const SETTING_KEYS = new Set([
  'reminders.enabled',
  'reminders.quietStart',
  'reminders.quietEnd',
  'reminders.followupMinutes',
  'reminders.followupEnabled',
  'ui.layout',
]);

function normalizeSetting(raw) {
  if (!isNonEmptyString(raw?.key)) throw new Error('设置缺 key');
  if (!SETTING_KEYS.has(raw.key)) throw new Error(`这个设置不同步：${raw.key}`);
  if (typeof raw.value !== 'string') throw new Error('设置值必须是字符串');
  if (raw.value.length > 200) throw new Error('设置值太长');
  return {
    key: raw.key,
    value: raw.value,
    updatedAtMs: isFiniteNumber(raw.updatedAtMs) ? Math.trunc(raw.updatedAtMs) : Date.now(),
  };
}

function asArray(v, kind) {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new HttpError(400, 'bad_body', `${kind} 必须是数组`);
  if (v.length > MAX_ROWS_PER_KIND) {
    throw new HttpError(400, 'too_many', `${kind} 一次最多 ${MAX_ROWS_PER_KIND} 条`);
  }
  return v;
}

/**
 * 写入一行成员。冲突解决：`updated_at_ms` 大者胜，相等时**远端胜**。
 *
 * 相等时选远端，不是因为它更"对"，而是因为**它可复现**：
 * 两端都能算出同一个结果，不会出现 A 认为 B 该赢、B 认为 A 该赢，
 * 然后两条数据在两边永远不同、每次同步都互相覆盖一次。
 */
function upsertMember(db, familyId, m, at) {
  const before = db
    .prepare(
      `SELECT updated_at_ms, server_at_ms, name, avatar_id, sort_order, deleted_at_ms
         FROM members WHERE family_id = ? AND id = ?`,
    )
    .get(familyId, m.id);

  // **内容一字不差就不必写**。全量推送意味着每次同步都会把整家数据重发
  // 一遍；如果每一行都刷新 `server_at_ms`，那所有行每次同步都"变新"，
  // 对端永远在拉同样的数据，白耗流量，还会把真正变化的那几行淹掉。
  //
  // 这个判断必须在 INSERT **之前**做。一开始写在后面，等于拿"刚写进去的
  // 行"和"推上来的行"比，永远相等，于是什么都没写 —— 症状是
  // "同步显示成功，但数据没变"。
  if (
    before !== undefined &&
    before.name === m.name &&
    (before.avatar_id ?? null) === (m.avatarId ?? null) &&
    before.sort_order === m.sortOrder &&
    (before.deleted_at_ms ?? null) === (m.deletedAtMs ?? null)
  ) {
    return undefined;
  }

  db.prepare(
    `INSERT INTO members (family_id, id, name, avatar_id, sort_order,
                          created_at_ms, updated_at_ms, deleted_at_ms, server_at_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(family_id, id) DO UPDATE SET
       name = excluded.name,
       avatar_id = excluded.avatar_id,
       sort_order = excluded.sort_order,
       updated_at_ms = excluded.updated_at_ms,
       deleted_at_ms = excluded.deleted_at_ms,
       server_at_ms = excluded.server_at_ms
     WHERE excluded.updated_at_ms >= members.updated_at_ms`,
  ).run(
    familyId,
    m.id,
    m.name,
    m.avatarId,
    m.sortOrder,
    m.createdAtMs,
    m.updatedAtMs,
    m.deletedAtMs,
    at,
  );
  return before === undefined ? at : before.server_at_ms;
}

function upsertTask(db, familyId, t, at) {
  const before = db
    .prepare(
      `SELECT updated_at_ms, server_at_ms, member_id, name, note, icon_id, repeat_json,
              time_json, course_start, course_end, status, reminder_enabled,
              sort_order, rules_effective_from, deleted_at_ms
         FROM tasks WHERE family_id = ? AND id = ?`,
    )
    .get(familyId, t.id);

  if (before !== undefined && taskContentSame(before, t)) {
    return undefined;
  }

  db.prepare(
    `INSERT INTO tasks (family_id, id, member_id, name, note, icon_id,
                        repeat_json, time_json, course_start, course_end,
                        course_total_days, status, reminder_enabled, sort_order,
                        rules_effective_from, created_at_ms, updated_at_ms,
                        deleted_at_ms, server_at_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(family_id, id) DO UPDATE SET
       member_id = excluded.member_id,
       name = excluded.name,
       note = excluded.note,
       icon_id = excluded.icon_id,
       repeat_json = excluded.repeat_json,
       time_json = excluded.time_json,
       course_start = excluded.course_start,
       course_end = excluded.course_end,
       course_total_days = excluded.course_total_days,
       status = excluded.status,
       reminder_enabled = excluded.reminder_enabled,
       sort_order = excluded.sort_order,
       rules_effective_from = excluded.rules_effective_from,
       updated_at_ms = excluded.updated_at_ms,
       deleted_at_ms = excluded.deleted_at_ms,
       server_at_ms = excluded.server_at_ms
     WHERE excluded.updated_at_ms >= tasks.updated_at_ms`,
  ).run(
    familyId,
    t.id,
    t.memberId,
    t.name,
    t.note,
    t.iconId,
    t.repeatJson,
    t.timeJson,
    t.courseStart,
    t.courseEnd,
    t.courseTotalDays,
    t.status,
    t.reminderEnabled,
    t.sortOrder,
    t.rulesEffectiveFrom,
    t.createdAtMs,
    t.updatedAtMs,
    t.deletedAtMs,
    at,
  );
  return before === undefined ? at : before.server_at_ms;
}

/** 与 [upsertMember] 的"内容没变就不写"同一套理由，字段多所以单独一段。 */
function taskContentSame(before, t) {
  return (
    before.member_id === t.memberId &&
    before.name === t.name &&
    (before.note ?? null) === (t.note ?? null) &&
    (before.icon_id ?? null) === (t.iconId ?? null) &&
    before.repeat_json === t.repeatJson &&
    before.time_json === t.timeJson &&
    (before.course_start ?? null) === (t.courseStart ?? null) &&
    (before.course_end ?? null) === (t.courseEnd ?? null) &&
    before.status === t.status &&
    before.reminder_enabled === t.reminderEnabled &&
    before.sort_order === t.sortOrder &&
    (before.rules_effective_from ?? null) === (t.rulesEffectiveFrom ?? null) &&
    (before.deleted_at_ms ?? null) === (t.deletedAtMs ?? null)
  );
}

/**
 * 写入一行打卡。这里**不用时间戳比大小**，规则见 `docs/sync-protocol.zh_CN.md`。
 *
 * 概览：
 * - 已经 `deleted=1` 且撤销时刻晚于这次的写入时刻 → 保持删除（"删得晚"赢）。
 * - 否则：`done`/`makeup` 胜过 `skipped`；两个都算做过时取 `done_at_ms` **早**的
 *   （早的是当时真做的，晚的是后来补录的）。
 * - 文本备注只在本次非空时覆盖。
 *
 * 客户端推的是**全量当前状态**，所以"本地没有这条"就等于"想删"——
 * 由 [applyCheckinDeletes] 处理，不在这里。
 */
function upsertCheckin(db, familyId, c, at) {
  const existing = db
    .prepare(
      `SELECT state, done_at_ms, deleted, deleted_at_ms, server_at_ms, note,
              due_at_minute_of_day, created_at_ms
         FROM checkins WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
    )
    .get(familyId, c.taskId, c.date, c.slotIndex);

  if (!existing) {
    db.prepare(
      `INSERT INTO checkins (family_id, task_id, date, slot_index, state,
                             done_at_ms, due_at_minute_of_day, note, deleted,
                             deleted_at_ms, created_at_ms, updated_at_ms, server_at_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)`,
    ).run(
      familyId,
      c.taskId,
      c.date,
      c.slotIndex,
      c.state,
      c.doneAtMs,
      c.dueAtMinuteOfDay,
      c.note,
      c.createdAtMs,
      c.updatedAtMs,
      at,
    );
    return at;
  }

  // 服务端已经有墓碑。**只有"确实比墓碑更新"的写入才能复活它。**
  //
  // 判据不能只看 `updated_at_ms`。打卡表没有 `updated_at_ms` 列 ——
  // 客户端推上来的 `updatedAtMs` 其实是 `doneAtMs`（见
  // `CheckinDto.fromDomain`），同一格打卡只要状态没变，这个数就一直不变。
  // 于是"撤销 → 另一台设备带着同一条旧打卡来同步"会被判成复活：
  // 撤销之前写入的 `updated_at_ms` == 现在推上来的 `updatedAtMs`，
  // 边界一松（`>=` 写成 `>`，或者两边差一毫秒）就活了。
  //
  // 判据是"这一格**最后一次变动**在墓碑之后"，也就是取两个时间的较大者：
  // - `updated_at_ms`：内容最后改的时刻
  // - `deleted_at_ms`：被撤销的时刻
  // 后者是必须的 —— 撤销发生得晚，它才算"最新的那次变动"。
  //
  // 反过来，墓碑时刻本身也**不能**拿来当唯一判据：早先版本用
  // `deleted_at_ms > c.updatedAtMs`，结果墓碑一建立，任何稍后重打的卡
  // 都是"更旧"，永远复活不了。两个都要看，取大的那个比。
  //
  // 另外别拿"现在"比：B 手机离线一小时再推，它的写入永远"更旧"。
  if (existing.deleted === 1) {
    const lastChange = Math.max(
      existing.updated_at_ms ?? 0,
      existing.deleted_at_ms ?? 0,
    );
    if (lastChange >= c.updatedAtMs) {
      return;
    }
    // 写入更晚 → 这次是"撤销之后又重新打了卡"，复活。
    // 复活必须是整行覆盖，否则会留下"状态是 done 但 deleted=1"的怪行。
    db.prepare(
      `UPDATE checkins SET state = ?, done_at_ms = ?, due_at_minute_of_day = ?, note = ?,
                           deleted = 0, deleted_at_ms = NULL,
                           updated_at_ms = ?, server_at_ms = ?
       WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
    ).run(
      c.state,
      c.doneAtMs,
      c.dueAtMinuteOfDay,
      c.note ?? existing.note,
      c.updatedAtMs,
      at,
      familyId,
      c.taskId,
      c.date,
      c.slotIndex,
    );
    return at;
  }

  const merged = mergeCheckinState(existing, c);
  // 没有实质变化就不刷新 server_at_ms：否则每次同步都让全家所有行"变新"，
  // 对端永远在拉同样的数据，白耗流量，还会掩盖真实的变化。
  const changed =
    merged.state !== existing.state ||
    merged.doneAtMs !== existing.done_at_ms ||
    merged.note !== existing.note ||
    merged.dueAtMinuteOfDay !== existing.due_at_minute_of_day;
  // 返回 `undefined` = **这一行没有被写过**。调用方据此决定要不要
  // 把它算进本次的"最高水位"。不这么做的话，每次全量推送都会把所有行
  // 刷新一遍 server_at_ms，对端永远在拉同样的数据。
  if (!changed) return undefined;

  db.prepare(
    `UPDATE checkins SET state = ?, done_at_ms = ?, due_at_minute_of_day = ?, note = ?,
                         updated_at_ms = ?, server_at_ms = ?
     WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
  ).run(
    merged.state,
    merged.doneAtMs,
    merged.dueAtMinuteOfDay,
    merged.note,
    Math.max(existing.updated_at_ms ?? 0, c.updatedAtMs),
    at,
    familyId,
    c.taskId,
    c.date,
    c.slotIndex,
  );
  return at;
}

/**
 * 打卡状态的合并规则。**单列出来是为了能被测试逐格覆盖。**
 *
 * 这里刻意不看 `updated_at_ms`：打卡不是"最新的话就对"，
 * 而是"做过就是做过"。用时间戳比大小会导致
 * "妈妈晚半小时补录了一次，把爸爸当时真做的 done 覆盖成 makeup"，
 * 准时率就悄悄掉了。
 */
export function mergeCheckinState(existing, incoming) {
  const existingDone =
    existing.state === 'done' || existing.state === 'makeup';
  const incomingDone = incoming.state === 'done' || incoming.state === 'makeup';

  let state;
  let doneAtMs;

  if (existingDone && incomingDone) {
    // 两个都算做过：保留更早的 done_at_ms（早的是当时真做的）。
    const a = existing.done_at_ms;
    const b = incoming.doneAtMs;
    if (a === null || a === undefined) {
      state = incoming.state;
      doneAtMs = b;
    } else if (b === null || b === undefined) {
      state = existing.state;
      doneAtMs = a;
    } else if (b < a) {
      state = incoming.state;
      doneAtMs = b;
    } else if (b > a) {
      state = existing.state;
      doneAtMs = a;
    } else {
      // 时刻完全一样：`done` 比 `makeup` 更"准时"，取更强的那一个。
      state = existing.state === 'done' ? 'done' : incoming.state;
      doneAtMs = a;
    }
  } else if (incomingDone) {
    state = incoming.state;
    doneAtMs = incoming.doneAtMs;
  } else {
    state = existing.state;
    doneAtMs = existing.done_at_ms ?? null;
  }

  return {
    state,
    doneAtMs,
    dueAtMinuteOfDay:
      incoming.dueAtMinuteOfDay ?? existing.due_at_minute_of_day ?? null,
    // 备注：本次非空才覆盖。空字符串当"没写"，不当"清空"——
    // 否则一个人手机上没备注，会把另一个人写的备注抹掉。
    note: incoming.note !== null && incoming.note !== ''
      ? incoming.note
      : existing.note ?? null,
  };
}

/**
 * 撤销声明里的 key：`任务id|日期|序号`。
 *
 * 客户端删掉一行之后就再也反推不出它的日期和槽位了（行没了），
 * 所以只能在撤销那一刻把三元组记下来。分隔符用 `|`，和本地
 * `AppDatabase._checkinKey` 必须一致。
 */
function parseRemovedKey(key) {
  if (typeof key !== 'string') return null;
  const parts = key.split('|');
  if (parts.length !== 3) return null;
  const [taskId, date, slotRaw] = parts;
  if (!taskId || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const slotIndex = Number(slotRaw);
  if (!Number.isInteger(slotIndex) || slotIndex < 0) return null;
  return { taskId, date, slotIndex };
}

/**
 * 删除传播：客户端**明确声明撤销**的打卡 → 存墓碑。
 *
 * 这条规则改过一次，改动的原因值得留着。
 *
 * 最初的规则是"客户端推的全量状态里没有它 = 撤销"：把本批之前存在的行
 * 全部拿来跟客户端推的集合比，缺的就打死。看着自洽，实际把
 * 「我删了」和「我从来就没有」混成了一件事 —— 而正常使用里后者占绝对多数：
 * 冷启动拉一次、回前台拉一次、新手机第一次同步。
 *
 * 端到端接真服务时抓到的就是这个：第二台手机刚配对，本地空库，
 * 推 `checkins: []`，服务端立刻把第一台手机刚推上来的打卡打成墓碑；
 * 第二台拉下来的是"已撤销"，而它本地本来就没有这条，于是永远没有。
 * 日志里两条写入、零拒绝，一切"正常"。
 *
 * 现在的规则：只看 `removedCheckins` 里列出的 key，说删哪条删哪条，
 * 没提的不动。客户端自己记住"我删过什么"（记在本地 `change_logs` 里）。
 *
 * 还留了一层保守：那一行已经不存在、或者已经是墓碑，就什么都不做 ——
 * 不做"复活又删除"的处理，那种情况由后续正常写入的合并规则决定。
 */
function applyCheckinDeletes(db, familyId, removedKeys, deviceId, at) {
  let tombstoned = 0;
  let highest = 0;
  for (const key of removedKeys) {
    const parsed = parseRemovedKey(key);
    if (parsed === null) continue;
    const row = db
      .prepare(
        `SELECT updated_at_ms FROM checkins
          WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?
            AND deleted = 0`,
      )
      .get(familyId, parsed.taskId, parsed.date, parsed.slotIndex);
    if (!row) continue;
    db.prepare(
      `UPDATE checkins SET deleted = 1, deleted_at_ms = ?, server_at_ms = ?
        WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
    ).run(at, at, familyId, parsed.taskId, parsed.date, parsed.slotIndex);
    highest = at;
    tombstoned += 1;
  }
  // **墓碑必须参与本次水位计算**，返回它写下去的那个 `server_at_ms`。
  //
  // 踩得很深：原先这里返回的是"墓碑条数"，水位完全不含墓碑 —— 理由是
  // "`deleted_at_ms` 必须稳定，不能被每次全量推送刷新"。那个顾虑是对的，
  // 但结论错了：墓碑的 `server_at_ms` 只在这一刻定一次，之后再也不动，
  // 稳定性和"计入水位"根本不冲突。
  //
  // 不计入的后果非常隐蔽：本次请求里，写入的行拿到 `t1 < t2 < ... < tN`，
  // 墓碑排在最后拿到 `tN`，而 `cursor = highWater = tN-1`。
  // 客户端下次带 `since = tN-1` 来拉，条件是 `server_at_ms > since` ——
  // **墓碑恰好落在边界上，永远拉不到**。
  // 症状：A 撤销了一条打卡，B 那边一直显示"已完成"，看着像同步坏了，
  // 其实是那条撤销通知卡在水位线下面。
  return { tombstoned, highWater: highest };
}

function upsertSetting(db, familyId, s, at) {
  db.prepare(
    `INSERT INTO settings (family_id, key, value, updated_at_ms, server_at_ms)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(family_id, key) DO UPDATE SET
       value = excluded.value,
       updated_at_ms = excluded.updated_at_ms,
       server_at_ms = excluded.server_at_ms
     WHERE excluded.updated_at_ms >= settings.updated_at_ms`,
  ).run(familyId, s.key, s.value, s.updatedAtMs, at);
  return at;
}

export function createSyncHandler(deps) {
  const { db, clock, limiters } = deps;

  return function handleSync(ctx) {
    const { device, req, body } = ctx;
    if (!device) throw new HttpError(401, 'unauthorized', '需要先配对');

    const ip = req.socket?.remoteAddress ?? 'unknown';
    assertAllowed(limiters.sync.hit(ip));

    const familyId = device.familyId;

    const sinceRaw = body?.since;
    if (sinceRaw !== undefined && sinceRaw !== null && !Number.isInteger(sinceRaw)) {
      throw new HttpError(400, 'bad_since', 'since 必须是整数');
    }
    const since = Number.isInteger(sinceRaw) ? sinceRaw : 0;

    const members = asArray(body?.members, 'members');
    const tasks = asArray(body?.tasks, 'tasks');
    const checkins = asArray(body?.checkins, 'checkins');
    const settings = asArray(body?.settings, 'settings');

    const rejected = [];

    /**
     * 应用一类，逐条 try/catch：一条坏的不该拖累整批。
     *
     * `write` 的返回值是这个"实际生效的水位"：
     * - 数字 = 这一行确实以这个 `server_at_ms` 落库了
     * - `undefined` = 完全没变，什么都没写（不该算进本次水位）
     *
     * 返回的 `cursor` 取**本次真正写进去的最高 server_at_ms**，而不是
     * 时钟当前值。理由：客户端拿 cursor 当下次的 `since`，而 `since` 在
     * 客户端那边**兼作"我推到哪儿了"的标记**（推拉合成一个请求时，
     * `since` 只能是水位，所以这里不能替你记"你已经推过了"）。
     * 用"本次最高"而不是"现在"，是为了让"没写任何东西"的请求也能
     * 安全返回一个不会让客户端跳过别人的行的值。
     */
    let highWater = 0;
    /**
     * 本次请求进来时服务端的最高 `server_at_ms`（空库为 0）。
     *
     * 这个数**在写之前就定死**，作为本次拉取的右边界。为什么要定死：
     * 拉取结果必须是一个"快照"，它要和响应里返回的 `cursor` 严格配套。
     * 如果在写入之后才取边界，就会把"还没被本响应包含的行"算进 `cursor`
     * 覆盖的范围里 —— 那些行永久丢失。
     *
     * 同时也**不能**让本次写入的行推进这个右边界：本批写进去的行
     * `server_at_ms` 都大于 `baseline`，客户端本来就要把它们落库，
     * 这次响应里也会带回去（见下面的 `pull` 的第二个条件）。
     */

    /**
     * 每行一个 `server_at_ms`。**不能整批共用一个**。
     *
     * 踩过一次：一开始整批只取一次 `clock.next()`，于是同一批里 5 行
     * 拿到同一个时间戳；客户端下回用这次返回的 cursor 去拉，
     * 条件是 `server_at_ms > cursor` —— 这 5 行永远拉不到。
     * 表现为"一次建了三个成员，另一台手机上只出现零个"。
     */
    const nextAt = () => clock.next();

    const applyEach = (list, kind, normalize, write) => {
      for (const raw of list) {
        let row;
        try {
          row = normalize(raw);
        } catch (err) {
          rejected.push({ kind, id: raw?.id ?? raw?.taskId ?? null, reason: err.message });
          continue;
        }
        try {
          const used = write(row, nextAt());
          if (typeof used === 'number' && used > highWater) highWater = used;
        } catch (err) {
          rejected.push({
            kind,
            id: row.id ?? `${row.taskId}/${row.date}/${row.slotIndex}` ?? row.key,
            reason: String(err.message ?? err),
          });
        }
      }
    };

    db.exec('BEGIN IMMEDIATE');
    /**
     * 本次请求进来时服务端的最高 `server_at_ms`（空库为 0）。
     *
     * **必须在事务里、在写任何东西之前读**，而且必须从**库里**读，
     * 不能用 `clock.peek()`。两个坑叠在一起：
     *
     * 1. `peek()` 是进程内存里的值，只在 `next()` 时推进。另一个进程
     *    （测试里就是分别跑的服务端进程）往同一个库写过，它就落后了。
     * 2. 读的时机也必须落在 `BEGIN IMMEDIATE` 之后。放在事务外，从读到
     *    开事务之间别的请求可能已经写进去了 —— 那批数据的 `server_at_ms`
     *    比这里读到的 `baseline` 大，就被算进"本批要拉的范围"里；
     *    可它是在本请求的写之前就有的，`cursor` 推进到哪儿都会重复或漏。
     *
     * 症状是 A 撤销了打卡、B 却仍然收到"这条还在"（墓碑之后的那个值
     * 被当成了有效写入）。
     */
    const baseline =
      db
        .prepare(
          `SELECT max(m) AS m FROM (
             SELECT max(server_at_ms) AS m FROM members
             UNION ALL SELECT max(server_at_ms) FROM tasks
             UNION ALL SELECT max(server_at_ms) FROM checkins
             UNION ALL SELECT max(server_at_ms) FROM settings
           )`,
        )
        .get()?.m ?? 0;
    try {
      // 顺序不能变：外键是 RESTRICT，先父后子。
      //
      // **打卡的墓碑判断必须排在三类写入之前**，理由见 `applyCheckinDeletes`：
      // 它要拿"本批之前就已存在的行"去比对，而 `baseline` 给的边界是
      // `server_at_ms <= baseline`；本批自己刚写进去的行 `server_at_ms`
      // 一定大于 `baseline`。一旦顺序颠倒，本批写入的那条如果在比对时还在，
      // 就没问题 —— 但如果**一边 upsert 一边删**（同一批里有 A 的打卡、
      // B 又声明没有它），结果就取决于谁后跑。放在最前面，语义是
      // "先按上一批之后的状态算清谁没了，再接收这一批的新状态"。
      // **撤销只认显式声明。**
      //
      // 早先的做法是"客户端推了 checkins，凡是不在这份全量里的就算撤销"。
      // 这个推断看起来合理，实际是错的：新设备第一次同步推 `checkins: []`
      // （它确实一条都没有），服务端就会把另一台设备刚打的卡全打成墓碑，
      // 而新设备拉下来看到的是"已撤销"——两边一起归零，且日志里
      // "写入 N 行、被拒 0 条"一切正常，极难查。
      //
      // 「我从来没有」和「我撤销了」必须分开表达，所以协议里加了
      // `removedCheckins`：只有列在里面的三元组才真的打墓碑。
      //
      // 顺序仍然必须在三类写入之前，理由见 `applyCheckinDeletes`。
      const removedRaw = body?.removedCheckins;
      const removed = Array.isArray(removedRaw)
        ? removedRaw.filter((k) => typeof k === 'string')
        : [];
      let tombstoned = 0;
      if (removed.length > 0) {
        const r = applyCheckinDeletes(db, familyId, removed, device.deviceId, nextAt());
        tombstoned = r.tombstoned;
        if (r.highWater > highWater) highWater = r.highWater;
      }

      applyEach(members, 'member', normalizeMember, (m, at) => upsertMember(db, familyId, m, at));
      applyEach(tasks, 'task', normalizeTask, (t, at) => upsertTask(db, familyId, t, at));
      applyEach(checkins, 'checkin', normalizeCheckin, (c, at) =>
        upsertCheckin(db, familyId, c, at),
      );
      applyEach(settings, 'setting', normalizeSetting, (s, at) =>
        upsertSetting(db, familyId, s, at),
      );

      db.exec('COMMIT');

      // 拉取：所有 server_at_ms > since 的行（含墓碑——墓碑也要传，
      // 否则对端不知道"这条被撤销了"，会一直显示已打卡）。
      // 拉取的右边界 = 本响应能覆盖到的最高值。
      //
      // `highWater` 是"本批真正写下去的最高值"，`baseline` 是"进来时库里的
      // 最高值"。两者取大：本次什么都没写时 `highWater` 为 0，此时右边界
      // 必须退回 `baseline`，否则 `<= 0` 恒假、一条都拉不到；
      // 写了东西时右边界取 `highWater`，正好把"别人的历史 + 本批自己写的"
      // 一起搬回来。
      const upperBound = Math.max(baseline, highWater);
      const pull = (table, orderBy) =>
        db
          .prepare(
            `SELECT * FROM ${table}
              WHERE family_id = ? AND server_at_ms > ? AND server_at_ms <= ?
              ORDER BY ${orderBy} LIMIT 20000`,
          )
          .all(familyId, since, upperBound);

      const cursor = highWater;

      return {
        ok: true,
        // 拉取水位：客户端用它当下次的 `since`。
        //
        // 语义是"本响应**已经覆盖到**的边界" = `max(baseline, highWater)`：
        // - 落在 `<= baseline` 的行：全在响应里（别人写的）
        // - 落在 `(baseline, highWater]` 的行：全在响应里（本批自己写的）
        // - 落在 `> highWater` 的行：本次之后才写的，留给下次
        //
        // 所以用"现在"是错的（会把响应里没有的行算进去 = 永久丢），
        // 用纯 `baseline` 也是错的（本批写的行已经返回了，却还要再拉一遍）。
        cursor: Math.max(baseline, highWater),
        // `since` 是客户端水位；如果它比服务端当前的还大（换机、时钟回拨），
        // 说明客户端的钟不可信 → 告诉它，并让它下次传 0 全量重来。
        // `highWater` 单独给出来，客户端用它判断"我这条到底写进去没有"。
        writeHighWater: highWater,
        sinceReset: since > Math.max(baseline, highWater),
        pulled: {
          members: pull('members', 'server_at_ms, id'),
          tasks: pull('tasks', 'server_at_ms, id'),
          checkins: pull('checkins', 'server_at_ms, task_id, date, slot_index'),
          settings: pull('settings', 'server_at_ms, key'),
        },
        rejected,
        tombstoned,
        deviceId: device.deviceId,
      };
    } catch (err) {
      try {
        db.exec('ROLLBACK');
      } catch {
        // 已回滚
      }
      throw err;
    }
  };
}
