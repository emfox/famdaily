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
}

function upsertTask(db, familyId, t, at) {
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
    return;
  }

  // 服务端已经有墓碑，而这次推上来的写入比墓碑更旧 → 说明是另一个人
  // 带着过期状态来推的。保持删除，不复活。
  if (existing.deleted === 1) {
    const deletedAt = existing.deleted_at_ms ?? 0;
    if (deletedAt > c.updatedAtMs) {
      return;
    }
    // 删除更旧 → 这次是"撤销之后又重新打了卡"，复活。
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
    return;
  }

  const merged = mergeCheckinState(existing, c);
  // 没有实质变化就不刷新 server_at_ms：否则每次同步都让全家所有行"变新"，
  // 对端永远在拉同样的数据，白耗流量，还会掩盖真实的变化。
  const changed =
    merged.state !== existing.state ||
    merged.doneAtMs !== existing.done_at_ms ||
    merged.note !== existing.note ||
    merged.dueAtMinuteOfDay !== existing.due_at_minute_of_day;
  if (!changed) return;

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
 * 删除传播：客户端推的全量状态里没有这条，但服务端还活着 → 存墓碑。
 *
 * 但**不能到就删**：另一台手机可能还没来得及把这条推给你。
 * 判定依据是"最后一次打卡写入时刻"和"最后一次撤销时刻"谁更晚。
 *
 * 这里有个不敢做满的地方，得说清楚：如果 B 手机离线很久，它的打卡
 * 从没到过服务端，那么 A 手机推全量时服务端会认为"这条不存在"，
 * 也就无从删除。等 B 上线推上来，这条会正常写入。所以**结果是
 * "不会丢数据"，代价是"删除可能失效"**。对这个产品来说这是对的方向。
 */
function applyCheckinDeletes(db, familyId, keepKeys, deviceId, at) {
  const rows = db
    .prepare(
      `SELECT task_id, date, slot_index, updated_at_ms FROM checkins
        WHERE family_id = ? AND deleted = 0`,
    )
    .all(familyId);

  const keep = keepKeys;
  let tombstoned = 0;
  for (const r of rows) {
    const key = `${r.task_id}\u0000${r.date}\u0000${r.slot_index}`;
    if (keep.has(key)) continue;
    db.prepare(
      `UPDATE checkins SET deleted = 1, deleted_at_ms = ?, server_at_ms = ?
        WHERE family_id = ? AND task_id = ? AND date = ? AND slot_index = ?`,
    ).run(at, at, familyId, r.task_id, r.date, r.slot_index);
    tombstoned += 1;
  }
  return tombstoned;
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

    /** 应用一类，逐条 try/catch：一条坏的不该拖累整批。 */
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
          write(row);
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
    try {
      const at = clock.next();

      // 顺序不能变：外键是 RESTRICT，先父后子。
      applyEach(members, 'member', normalizeMember, (m) => upsertMember(db, familyId, m, at));
      applyEach(tasks, 'task', normalizeTask, (t) => upsertTask(db, familyId, t, at));
      applyEach(checkins, 'checkin', normalizeCheckin, (c) => upsertCheckin(db, familyId, c, at));

      const keep = new Set(
        checkins
          .filter((c) => CHECKIN_STATES.has(c?.state))
          .map((c) => `${c.taskId}\u0000${c.date}\u0000${c.slotIndex}`),
      );
      const tombstoned = applyCheckinDeletes(db, familyId, keep, device.deviceId, at);

      applyEach(settings, 'setting', normalizeSetting, (s) => upsertSetting(db, familyId, s, at));

      db.exec('COMMIT');

      // 拉取：所有 server_at_ms > since 的行（含墓碑——墓碑也要传，
      // 否则对端不知道"这条被撤销了"，会一直显示已打卡）。
      const pull = (table, orderBy) =>
        db
          .prepare(
            `SELECT * FROM ${table} WHERE family_id = ? AND server_at_ms > ? ORDER BY ${orderBy} LIMIT 20000`,
          )
          .all(familyId, since);

      const cursor = clock.peek();

      return {
        ok: true,
        cursor,
        // `since` 是客户端水位；如果它比服务端当前的还大（换机、时钟回拨），
        // 说明客户端的钟不可信 → 告诉它，并让它下次传 0 全量重来。
        sinceReset: since > cursor,
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
