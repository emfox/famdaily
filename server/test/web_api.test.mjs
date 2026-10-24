/**
 * 成员页接口测试：`/m/:token`、`/m/api/today`、`/m/api/checkin`。
 *
 * 这里守的三件事，任何一件破了，成员页就不再可信：
 * 1. **越权**：只能看/改自己的
 * 2. **窗口**：不能给未来的日子打卡，不能改 30 天前的
 * 3. **槽位**：`slotIndex` 必须真的存在（防两端规则引擎算出不同结果时
 *    造出孤儿记录）
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { startServer, pairDevice, member, task } from './helpers.mjs';
import { WEB_COOKIE_NAME } from '../src/web_auth.mjs';

/** 今天的 yyyy-mm-dd（UTC，和服务端一致）。 */
function utcToday(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400_000);
  const p = (v) => String(v).padStart(2, '0');
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`;
}

/**
 * 建家庭 + 配设备 + 推成员和任务 + 给 m1 发链接。
 *
 * 返回 `{ srv, token, url, cookie }`。`cookie` 是 `famdaily_m=...`，
 * 已经走了一次 `/m/<token>` 换好票了。
 */
async function setup({ tasks = null } = {}) {
  const srv = await startServer();
  const { token } = await pairDevice(srv);

  const taskRows = tasks ?? [
    {
      ...task('t1', 'm1', '吃药', 1000),
      timeJson: JSON.stringify({ v: 1, type: 'fixed', times: ['08:00', '20:00'] }),
    },
    {
      ...task('t2', 'm2', '跳绳', 1001),
      timeJson: JSON.stringify({ v: 1, type: 'fixed', times: ['18:00'] }),
    },
  ];

  const pushed = await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [member('m1', '爷爷', 1000), member('m2', '小明', 1001)],
      tasks: taskRows,
      checkins: [],
      settings: [],
    },
  });
  assert.equal(pushed.status, 200, JSON.stringify(pushed.json));

  const link = await srv.call('POST', '/members/m1/link', { token });
  assert.equal(link.status, 200, JSON.stringify(link.json));

  // 走一次入口拿 Cookie
  const tokenPart = link.json.url.split('/m/')[1];
  const entry = await hitEntry(srv, tokenPart);
  assert.equal(entry.status, 302, '入口应该重定向到 /m/');
  assert.ok(entry.setCookie, '应该下发 Cookie');
  const cookie = entry.cookie;
  assert.ok(cookie.startsWith(`${WEB_COOKIE_NAME}=`));

  return { srv, token, url: link.json.url, cookie, tokenPart };
}

/**
 * 访问成员页入口 `/m/<token>`，返回 `{ status, cookie }`。
 *
 * ⚠️ 两处细节，都是踩过的：
 * 1. `redirect: 'manual'` 时必须**把响应体读掉**（哪怕不关心）。不读的话
 *    undici 的连接池会攥着那个 socket，`srv.close()` 等不到它释放，
 *    整个测试文件会挂到 4 分钟的默认超时 —— 表现是"测试卡死"。
 * 2. 显式 `Connection: close`，让服务端主动关。
 */
async function hitEntry(srv, tokenPart) {
  const res = await fetch(`${srv.base}/m/${tokenPart}`, {
    redirect: 'manual',
    headers: { connection: 'close' },
  });
  await res.text(); // 读掉，释放 socket
  const setCookie = res.headers.get('set-cookie');
  return {
    status: res.status,
    location: res.headers.get('location'),
    setCookie,
    cookie: setCookie ? setCookie.split(';')[0] : null,
  };
}

/** 带 Cookie 的 GET。 */
async function getWithCookie(srv, path, cookie) {
  const res = await fetch(`${srv.base}${path}`, { headers: { cookie } });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = { _raw: text };
  }
  return { status: res.status, json, headers: res.headers };
}

/** 带 Cookie 的 POST。 */
async function postWithCookie(srv, path, cookie, body) {
  const res = await fetch(`${srv.base}${path}`, {
    method: 'POST',
    headers: { cookie, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = { _raw: text };
  }
  return { status: res.status, json };
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

test('GET /m/<token>：302 到 /m/ 并下发 HttpOnly Cookie', async () => {
  const srv = await startServer();
  const { token } = await pairDevice(srv);
  await srv.call('POST', '/sync', {
    token,
    body: { deviceId: 'd', since: 0, members: [member('m1', '爷爷')], tasks: [], checkins: [], settings: [] },
  });
  const link = await srv.call('POST', '/members/m1/link', { token });
  const t = link.json.url.split('/m/')[1];

  const entry = await hitEntry(srv, t);
  assert.equal(entry.status, 302);
  assert.equal(entry.location, '/m/');
  assert.ok(entry.setCookie.includes('HttpOnly'));
  assert.ok(entry.setCookie.includes('SameSite=Strict'));
  assert.ok(!entry.setCookie.includes('Secure'), 'http 下不该加 Secure');
  await srv.close();
});

test('GET /m/<bogus>：401，且**不区分**"不存在"和"已作废"', async () => {
  const srv = await startServer();
  const res = await fetch(`${srv.base}/m/this-token-does-not-exist-at-all-1234567890`, {
    redirect: 'manual',
    headers: { connection: 'close' },
  });
  const body = await res.json();
  assert.equal(res.status, 401);
  assert.equal(body.error.code, 'no_identity');
  // 消息里不能出现"已过期"和"不存在"的区分
  assert.ok(!/过期/.test(body.error.message) || /无效或已作废/.test(body.error.message));
  await srv.close();
});

test('GET /m/<token>：作废后旧链接立刻打不开', async () => {
  const { srv, token, tokenPart } = await setup();
  await srv.call('POST', '/members/m1/unlink', { token });

  const entry = await hitEntry(srv, tokenPart);
  assert.equal(entry.status, 401);
  await srv.close();
});

// ---------------------------------------------------------------------------
// /m/api/today
// ---------------------------------------------------------------------------

test('GET /m/api/today：只返回自己的任务，别人的一条都没有', async () => {
  const { srv, cookie } = await setup();
  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday()}`, cookie);

  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.member.id, 'm1');
  assert.equal(r.json.member.name, '爷爷');

  const ids = new Set(r.json.items.map((i) => i.taskId));
  assert.ok(ids.has('t1'), '应该有自己的任务');
  assert.ok(!ids.has('t2'), '不能看到别人的任务（越权）');
  await srv.close();
});

test('GET /m/api/today：两个固定时刻 → 两条，index 0/1', async () => {
  const { srv, cookie } = await setup();
  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday()}`, cookie);
  const items = r.json.items.filter((i) => i.taskId === 't1');
  assert.equal(items.length, 2);
  assert.deepEqual(items.map((i) => i.slotIndex), [0, 1]);
  assert.deepEqual(items.map((i) => i.dueTime), ['08:00', '20:00']);
  assert.equal(items[0].name, '吃药');
  await srv.close();
});

test('GET /m/api/today：不带 date 时用服务端今天，并把 serverDate 写出来', async () => {
  const { srv, cookie } = await setup();
  const r = await getWithCookie(srv, '/m/api/today', cookie);
  assert.equal(r.status, 200);
  assert.equal(r.json.date, utcToday());
  assert.equal(r.json.serverDate, utcToday());
  await srv.close();
});

test('GET /m/api/today：date 格式不对 → 400', async () => {
  const { srv, cookie } = await setup();
  const r = await getWithCookie(srv, '/m/api/today?date=2026-13-45', cookie);
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'bad_date');
  await srv.close();
});

test('GET /m/api/today：没有 Cookie → 401', async () => {
  const { srv } = await setup();
  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday()}`, 'nothing=1');
  assert.equal(r.status, 401);
  assert.equal(r.json.error.code, 'no_identity');
  await srv.close();
});

test('GET /m/api/today：暂停的任务不出现在清单里', async () => {
  const srv = await startServer();
  const { token } = await pairDevice(srv);
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'd',
      since: 0,
      members: [member('m1', '爷爷')],
      tasks: [{ ...task('t1', 'm1', '吃药'), status: 'paused' }],
      checkins: [],
      settings: [],
    },
  });
  const link = await srv.call('POST', '/members/m1/link', { token });
  const t = link.json.url.split('/m/')[1];
  const { cookie } = await hitEntry(srv, t);

  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday()}`, cookie);
  assert.deepEqual(r.json.items, []);
  await srv.close();
});

test('坏规则根本进不了库：/sync 在写入前就拒收，所以 today 里连 hidden 都不会有', async () => {
  // ⚠️ 第一版这条测试断言的是"坏规则任务会出现在 hidden 里"，**它从来没有通过过**，
  // 因为那个场景不可能发生：`/sync` 的 `normalizeTimeJson` 有一道类型白名单，
  // 不认识的 `type` 直接在写入前被 rejected，库里根本不会有这行。
  //
  // 这比"进库了再在网页端 hidden"更好：坏数据不进库，所有读端都不用各自兜底。
  // 那 `today.mjs` 里的 `hidden` 是不是死代码？**不是，是纵深防御**：
  // - 库里可能有历史脏数据（早期版本没这道白名单）
  // - 将来加了白名单没覆盖的新形态
  // 所以那条降级路径要留着，但不能拿它当主路径测。
  const srv = await startServer();
  const { token } = await pairDevice(srv);

  const pushed = await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'd',
      since: 0,
      members: [member('m1', '爷爷')],
      tasks: [{ ...task('bad', 'm1', '坏规则'), timeJson: JSON.stringify({ type: 'cron' }) }],
      checkins: [],
      settings: [],
    },
  });

  assert.equal(pushed.status, 200);
  assert.equal(pushed.json.rejected.length, 1, '坏规则必须被拒收');
  assert.match(pushed.json.rejected[0].reason, /不认识的时刻规则类型/);

  // 库里确实没有这一行
  const rows = srv.app.db.prepare('SELECT id FROM tasks').all();
  assert.deepEqual(rows, [], '坏规则不该落库');

  await srv.close();
});

test('库里已有坏规则（历史脏数据）时，today 把它放进 hidden 而不是静默消失', async () => {
  // 绕过 /sync 直接写库，模拟"这道白名单加上之前就存在的脏数据"。
  // familyId 从 members 表里反查——`pairDevice` 返回的 familyId 是配对的家庭，
  // 但更稳的办法是直接查库里那一行，免得测试依赖返回值的字段名。
  const srv = await startServer();
  const { token } = await pairDevice(srv);
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'd',
      since: 0,
      members: [member('m1', '爷爷')],
      tasks: [task('good', 'm1', '正常任务')],
      checkins: [],
      settings: [],
    },
  });

  const familyId = srv.app.db.prepare('SELECT family_id FROM members LIMIT 1').get().family_id;
  const now = Date.now();
  srv.app.db
    .prepare(
      `INSERT INTO tasks (family_id, id, member_id, name, repeat_json, time_json,
                          status, reminder_enabled, sort_order, created_at_ms,
                          updated_at_ms, server_at_ms)
       VALUES (?, ?, ?, ?, ?, ?, 'active', 1, 0, ?, ?, ?)`,
    )
    .run(
      familyId,
      'legacy-bad',
      'm1',
      '历史坏规则',
      JSON.stringify({ v: 1 }),
      JSON.stringify({ type: 'cron', expr: '*' }),
      now,
      now,
      now,
    );

  const link = await srv.call('POST', '/members/m1/link', { token });
  const t = link.json.url.split('/m/')[1];
  const { cookie } = await hitEntry(srv, t);

  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday()}`, cookie);
  assert.equal(r.status, 200);

  // 正常的那个还在
  assert.ok(
    r.json.items.some((i) => i.taskId === 'good'),
    '坏的那条不该影响好的那条',
  );
  // 坏的进了 hidden，能看见
  assert.equal(r.json.hidden.length, 1);
  assert.equal(r.json.hidden[0].taskId, 'legacy-bad');
  assert.match(r.json.hidden[0].reason, /未知的时刻规则类型/);

  await srv.close();
});

test('GET /m/api/today：未来日期 → editable=false', async () => {
  const { srv, cookie } = await setup();
  const r = await getWithCookie(srv, `/m/api/today?date=${utcToday(1)}`, cookie);
  assert.equal(r.status, 200);
  for (const it of r.json.items) {
    assert.equal(it.editable, false, '未来不该可编辑');
  }
  await srv.close();
});

// ---------------------------------------------------------------------------
// /m/api/checkin
// ---------------------------------------------------------------------------

test('POST /m/api/checkin：打卡成功，能在 today 里读回来', async () => {
  const { srv, cookie } = await setup();
  const today = utcToday();

  const w = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
    note: '吃完药了',
  });
  assert.equal(w.status, 200, JSON.stringify(w.json));
  assert.equal(w.json.state, 'done');
  assert.equal(w.json.note, '吃完药了');
  assert.ok(w.json.serverAtMs > 0);

  const r = await getWithCookie(srv, `/m/api/today?date=${today}`, cookie);
  const item = r.json.items.find((i) => i.taskId === 't1' && i.slotIndex === 0);
  assert.equal(item.checkin.state, 'done');
  assert.equal(item.checkin.note, '吃完药了');
  await srv.close();
});

test('POST /m/api/checkin：连打三次，serverAtMs 严格递增（水位不能撞号）', async () => {
  // 这条原本是**反向验证漏出来的洞**。第一版只断言 `serverAtMs > 0`，
  // 于是把 `clock.next()` 换成 `Date.now()` 之后 27 条测试全绿 ——
  // 但真机上三次点击大概率落在同一毫秒，三行拿到同一个 `server_at_ms`，
  // 而客户端拉取条件是 `server_at_ms > since`：同号的第二、三行永远拉不到，
  // 症状是"手机上勾了两个，另一台手机只看见一个"。
  //
  // ⚠️ **只比较返回值不够**：一次请求要几毫秒，`Date.now()` 自己就会递增，
  // 断言照样全绿（第一版就是这么写的，改坏后仍 28 条全过）。
  // 真正能分辨的手段只有一个 —— **把时钟钉死**。
  // 所以这里直接接管 `app.serverClock`，让它恒返回一个固定值；
  // `clock.next()` 会在这个基础上 +1，`Date.now()` 装作没看见，
  // 立刻露出撞号。这也顺带证明"服务端时钟确实是从 clock 读的"。
  const { srv, cookie } = await setup();
  const today = utcToday();

  const FROZEN = 1_800_000_000_000;
  const realNext = srv.app.deps.clock.next.bind(srv.app.deps.clock);
  srv.app.deps.clock.next = () => FROZEN;

  const seen = [];
  try {
    // 同一槽位连打三次（每次改状态），每次都是一次真实写入。
    for (const state of ['done', 'skipped', 'done']) {
      const w = await postWithCookie(srv, '/m/api/checkin', cookie, {
        taskId: 't1',
        date: today,
        slotIndex: 0,
        state,
      });
      assert.equal(w.status, 200, JSON.stringify(w.json));
      seen.push(w.json.serverAtMs);
    }
  } finally {
    srv.app.deps.clock.next = realNext;
  }

  assert.deepEqual(
    seen,
    [FROZEN, FROZEN, FROZEN],
    '时钟被钉死后，三次写入拿到的必须是同一个桩值（否则说明没走 clock）',
  );

  // 真正的断言在上面那句的反面：用真时钟时三次必须各拿一个不同的号。
  // 用真时钟连打三次（同毫秒概率很高，但撞上了也不能红，所以断言"不相等"而非"递增"）。
  const real = [];
  for (const state of ['skipped', 'done', 'skipped']) {
    const w = await postWithCookie(srv, '/m/api/checkin', cookie, {
      taskId: 't1',
      date: today,
      slotIndex: 0,
      state,
    });
    assert.equal(w.status, 200, JSON.stringify(w.json));
    real.push(w.json.serverAtMs);
  }
  assert.equal(new Set(real).size, 3, `三次写入的 serverAtMs 撞号了：${real.join(' / ')}`);
  for (let i = 1; i < real.length; i += 1) {
    assert.ok(real[i] > real[i - 1], `serverAtMs 没有严格递增：${real.join(' / ')}`);
  }

  // 库里也是这个数，别只信返回值
  const rows = srv.app.db
    .prepare('SELECT server_at_ms FROM checkins WHERE task_id = ?')
    .all('t1');
  assert.equal(rows.length, 1, '同一槽位反复写只应留一行（upsert）');
  assert.equal(rows[0].server_at_ms, real[2]);

  await srv.close();
});

test('POST /m/api/checkin：未来日期 → 403，不能提前打卡', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: utcToday(1),
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'future_date');
  await srv.close();
});

test('POST /m/api/checkin：31 天前 → 403（超窗口）', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: utcToday(-31),
    slotIndex: 0,
    state: 'makeup',
  });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'edit_window_expired');
  await srv.close();
});

test('POST /m/api/checkin：恰好 30 天前 → 允许补卡', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: utcToday(-30),
    slotIndex: 0,
    state: 'makeup',
  });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  await srv.close();
});

test('POST /m/api/checkin：别人的任务 → 403 forbidden（不是 404）', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't2', // 这是 m2 的
    date: utcToday(),
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'forbidden');
  await srv.close();
});

test('POST /m/api/checkin：不存在的任务 → 404', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 'nope',
    date: utcToday(),
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(r.status, 404);
  assert.equal(r.json.error.code, 'task_not_found');
  await srv.close();
});

test('POST /m/api/checkin：slotIndex 不存在 → 409（防孤儿记录）', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: utcToday(),
    slotIndex: 7, // t1 只有 0 和 1
    state: 'done',
  });
  assert.equal(r.status, 409);
  assert.equal(r.json.error.code, 'slot_not_found');
  await srv.close();
});

test('POST /m/api/checkin：state 不合法 → 400，不猜', async () => {
  const { srv, cookie } = await setup();
  for (const bad of ['DONE', 'finished', '', null, 1]) {
    const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
      taskId: 't1',
      date: utcToday(),
      slotIndex: 0,
      state: bad,
    });
    assert.equal(r.status, 400, `state=${JSON.stringify(bad)} 应该被拒`);
    assert.equal(r.json.error.code, 'bad_state');
  }
  await srv.close();
});

test('POST /m/api/checkin：三种状态都能写', async () => {
  const { srv, cookie } = await setup();
  const today = utcToday();
  for (const [i, state] of ['done', 'makeup', 'skipped'].entries()) {
    const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
      taskId: 't1',
      date: today,
      slotIndex: i % 2, // 只有 0/1 两个槽位
      state,
    });
    assert.equal(r.status, 200, `${state}: ${JSON.stringify(r.json)}`);
  }
  await srv.close();
});

test('POST /m/api/checkin：没有 Cookie → 401', async () => {
  const { srv } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', 'nothing=1', {
    taskId: 't1',
    date: utcToday(),
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(r.status, 401);
  await srv.close();
});

test('POST /m/api/checkin：备注超长会被截到 200 字，不是报错', async () => {
  const { srv, cookie } = await setup();
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: utcToday(),
    slotIndex: 0,
    state: 'done',
    note: 'x'.repeat(500),
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.note.length, 200);
  await srv.close();
});

test('POST /m/api/checkin：空备注当"没写"，不会清掉已有的', async () => {
  const { srv, cookie } = await setup();
  const today = utcToday();
  await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
    note: '先写的备注',
  });
  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
    note: '',
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.note, '先写的备注', '空备注不该抹掉已有的');
  await srv.close();
});

// ---------------------------------------------------------------------------
// 与同步的联动
// ---------------------------------------------------------------------------

test('网页端打卡会被设备 /sync 拉到（水位推进）', async () => {
  const { srv, cookie, token } = await setup();
  const today = utcToday();

  const w = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(w.status, 200);

  // 设备从 0 开始拉，应该能看到这条
  const pulled = await srv.call('POST', '/sync', {
    token,
    body: { deviceId: 'dev-1', since: 0, members: [], tasks: [], checkins: [], settings: [] },
  });
  assert.equal(pulled.status, 200, JSON.stringify(pulled.json));
  // ⚠️ 拉取结果用的是**裸列名**（`task_id` / `slot_index`），不是驼峰。
  // `/sync` 的 pull 是 `SELECT *`，没做字段名映射 —— 端到端脚本也踩过这个。
  const found = pulled.json.pulled.checkins.find(
    (c) => c.task_id === 't1' && c.date === today && c.slot_index === 0,
  );
  assert.ok(found, `设备应该拉到网页打的卡：${JSON.stringify(pulled.json.pulled.checkins)}`);
  assert.equal(found.state, 'done');
  await srv.close();
});

test('设备撤销打卡后，网页 reading 到的是空（不被复活）', async () => {
  const { srv, cookie, token } = await setup();
  const today = utcToday();

  // 先让设备打一次
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [],
      tasks: [],
      checkins: [
        {
          taskId: 't1',
          date: today,
          slotIndex: 0,
          state: 'done',
          doneAtMs: Date.now(),
          dueAtMinuteOfDay: 480,
          note: null,
          createdAtMs: Date.now(),
          updatedAtMs: Date.now(),
        },
      ],
      settings: [],
    },
  });

  let r = await getWithCookie(srv, `/m/api/today?date=${today}`, cookie);
  assert.ok(r.json.items.find((i) => i.slotIndex === 0)?.checkin, '应该先有打卡');

  // 设备撤销
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [],
      tasks: [],
      checkins: [],
      removedCheckins: [`t1|${today}|0`],
      settings: [],
    },
  });

  r = await getWithCookie(srv, `/m/api/today?date=${today}`, cookie);
  const item = r.json.items.find((i) => i.slotIndex === 0);
  assert.equal(item.checkin, null, '撤销之后网页也该看到空');
  await srv.close();
});

test('网页打卡后，设备再撤销，网页重新打卡能复活', async () => {
  const { srv, cookie, token } = await setup();
  const today = utcToday();

  await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
  });
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [],
      tasks: [],
      checkins: [],
      removedCheckins: [`t1|${today}|0`],
      settings: [],
    },
  });

  const r = await postWithCookie(srv, '/m/api/checkin', cookie, {
    taskId: 't1',
    date: today,
    slotIndex: 0,
    state: 'done',
  });
  assert.equal(r.status, 200, JSON.stringify(r.json));

  const pulled = await srv.call('POST', '/sync', {
    token,
    body: { deviceId: 'dev-1', since: 0, members: [], tasks: [], checkins: [], settings: [] },
  });
  const found = pulled.json.pulled.checkins.find(
    (c) => c.task_id === 't1' && c.date === today && c.slot_index === 0,
  );
  assert.ok(found, '复活后设备应该拉到');
  await srv.close();
});
