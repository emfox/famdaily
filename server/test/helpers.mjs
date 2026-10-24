/**
 * 测试辅助：起真服务、说真 HTTP。
 *
 * **不 mock `node:http`**。所有测试打的是监听在 127.0.0.1 随机端口上的真服务，
 * 走真 TCP、真 JSON。代价是每个用例慢几毫秒；收益是"测试全绿、真机不行"
 * 这类问题不会从这一层漏过去。
 */

import { createApp } from '../index.mjs';

/** 安静的 logger：测试输出里只要断言结果。 */
const silent = { info() {}, error() {} };

/**
 * 起一个内存库的服务实例。
 *
 * 返回 `{ base, call, close, app }`：
 * - `base` 形如 `http://127.0.0.1:54321`
 * - `call(method, path, { body, token, headers })` → `{ status, json }`
 */
export async function startServer({ pairSecret = 'test-secret' } = {}) {
  const app = createApp({ dbPath: ':memory:', pairSecret, logger: silent });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  const { port } = app.server.address();
  const base = `http://127.0.0.1:${port}`;

  const call = async (method, path, { body, token, headers = {}, raw } = {}) => {
    const h = { ...headers };
    if (token) h.authorization = `Bearer ${token}`;
    if (body !== undefined) h['content-type'] = 'application/json';
    const res = await fetch(`${base}${path}`, {
      method,
      headers: h,
      body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text === '' ? null : JSON.parse(text);
    } catch {
      json = { _raw: text };
    }
    return { status: res.status, json };
  };

  return {
    base,
    call,
    app,
    close: async () => {
      await new Promise((resolve) => app.server.close(resolve));
      app.close();
    },
  };
}

/** 建一个家庭并配对一台设备，返回 `{ token, code, familyId }`。 */
export async function pairDevice(srv, { name = '我的家', deviceLabel = '测试机' } = {}) {
  const created = await srv.call('POST', '/pair/new', {
    body: { name },
    headers: { 'x-pair-secret': 'test-secret' },
  });
  if (created.status !== 200) {
    throw new Error(`建家庭失败：${JSON.stringify(created.json)}`);
  }
  const claimed = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code, deviceLabel },
  });
  if (claimed.status !== 200) {
    throw new Error(`配对失败：${JSON.stringify(claimed.json)}`);
  }
  return {
    token: claimed.json.token,
    deviceId: claimed.json.deviceId,
    familyId: claimed.json.familyId,
    code: created.json.code,
  };
}

/** 造一行成员。 */
export function member(id, name, t = 1000) {
  return {
    id,
    name,
    avatarId: null,
    sortOrder: 0,
    createdAtMs: t,
    updatedAtMs: t,
    deletedAtMs: null,
  };
}

/** 造一行项目。 */
export function task(id, memberId, name, t = 1000) {
  return {
    id,
    memberId,
    name,
    note: null,
    iconId: null,
    repeatJson: JSON.stringify({ v: 1, weekdays: [1, 2, 3, 4, 5, 6, 7] }),
    timeJson: JSON.stringify({ v: 1, type: 'fixed', times: ['08:00'] }),
    courseStart: null,
    courseEnd: null,
    courseTotalDays: null,
    status: 'active',
    reminderEnabled: true,
    sortOrder: 0,
    rulesEffectiveFrom: null,
    createdAtMs: t,
    updatedAtMs: t,
    deletedAtMs: null,
  };
}

/** 造一行打卡。 */
export function checkin(taskId, date, slotIndex, state, t = 1000) {
  return {
    taskId,
    date,
    slotIndex,
    state,
    doneAtMs: t,
    dueAtMinuteOfDay: 480,
    note: null,
    createdAtMs: t,
    updatedAtMs: t,
  };
}
