/**
 * `/sync` 推 + 拉。
 *
 * 这一组是整条协议最可能出错的地方，所以逐条对着 `docs/sync-protocol.zh_CN.md`
 * 的合并规则写。重点在四件事：
 * 1. 水位不漏行（同毫秒写两行都要拉得到）
 * 2. 外键顺序错时是 `rejected` 而不是整批失败
 * 3. 打卡的合并**不看时间戳**，按"做过就是做过"
 * 4. 两个不同 id 的同一天只留一行
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, pairDevice, member, task, checkin } from './helpers.mjs';
import { mergeCheckinState } from '../src/sync.mjs';

test('推上去的行，另一次全量拉取能完整拿回', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const push = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [checkin('t1', '2025-03-01', 0, 'done')],
      settings: [{ key: 'reminders.enabled', value: 'true', updatedAtMs: 1000 }],
    },
  });
  assert.equal(push.status, 200);
  assert.deepEqual(push.json.rejected, []);

  // 推的响应里就带着自己刚推的行（客户端不用特判"我自己那条"）
  assert.equal(push.json.pulled.members.length, 1);
  assert.equal(push.json.pulled.members[0].name, '爸爸');

  // 从 0 开始全量拉，也要拿得到
  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members.length, 1);
  assert.equal(pull.json.pulled.members[0].name, '爸爸');
  assert.equal(pull.json.pulled.tasks.length, 1);
  assert.equal(pull.json.pulled.tasks[0].name, '吃药');
  assert.equal(pull.json.pulled.checkins.length, 1);
  assert.equal(pull.json.pulled.checkins[0].state, 'done');
  assert.equal(pull.json.pulled.settings.length, 1);
});

test('水位生效：第二次只拉新行，不重复拉旧的', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const first = await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '爸爸')] },
  });
  const cursor = first.json.cursor;
  assert.ok(Number.isInteger(cursor));
  assert.equal(
    cursor,
    first.json.writeHighWater,
    'cursor 是"本响应已经覆盖到的边界"，本批写了东西就一定等于本批的最高值',
  );
  assert.ok(cursor > 0);

  // 拿 cursor 再拉一次：什么都拿不到（m1 的 server_at_ms 已经被第一轮覆盖）
  const second = await srv.call('POST', '/sync', { token, body: { since: cursor } });
  assert.equal(second.json.pulled.members.length, 0);

  // 加一个新成员：只拉到新的
  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '爸爸'), member('m2', '妈妈')] },
  });
  const third = await srv.call('POST', '/sync', { token, body: { since: cursor } });
  assert.equal(third.json.pulled.members.length, 1);
  assert.equal(third.json.pulled.members[0].id, 'm2');
  assert.ok(third.json.cursor > cursor, 'cursor 必须前进');
});

test('同一批里连写多行，每一行都能被下一次拉取拿到', async (t) => {
  // 用 `> cursor` 做水位时，同一毫秒写的两行会漏掉后一行。
  // server_at_ms 严格递增就是为了这个。这里用 5 行来压。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const push = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [1, 2, 3, 4, 5].map((i) => member(`m${i}`, `成员${i}`, 1000 + i)),
    },
  });
  const stamps = srv.app.db
    .prepare('SELECT server_at_ms FROM members ORDER BY server_at_ms')
    .all()
    .map((r) => r.server_at_ms);
  assert.equal(new Set(stamps).size, 5, `server_at_ms 必须互不相同：${stamps}`);

  // 以第 2 行的水位去拉，应该拿到第 3、4、5 行
  const since = stamps[1];
  const pull = await srv.call('POST', '/sync', { token, body: { since } });
  assert.equal(pull.json.pulled.members.length, 3, '不能用 > 把同毫秒的行漏掉');
  assert.equal(push.json.writeHighWater, stamps[4]);
});

test('记录先到、项目后到：那条进 rejected，不炸整批', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  // 打卡指向一个还不存在的项目 → 外键失败
  const r1 = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      checkins: [checkin('t-not-yet', '2025-03-01', 0, 'done')],
    },
  });
  assert.equal(r1.status, 200, '一条坏条目不该让整批 500');
  assert.equal(r1.json.rejected.length, 1);
  assert.equal(r1.json.rejected[0].kind, 'checkin');
  assert.match(r1.json.rejected[0].reason, /FOREIGN KEY/i);
  // 同批的成员照样写进去了
  assert.equal(r1.json.pulled.members.length, 1);

  // 项目补上再来一次，这条就成了
  const r2 = await srv.call('POST', '/sync', {
    token,
    body: {
      tasks: [task('t-not-yet', 'm1', '吃药')],
      checkins: [checkin('t-not-yet', '2025-03-01', 0, 'done')],
    },
  });
  assert.deepEqual(r2.json.rejected, []);
});

test('坏条目被拒时给出人话原因，且不影响同批其他行', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [
        member('m1', '爸爸'),
        { id: 'm2' }, // 缺名字
        { name: '没 id' },
      ],
    },
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.rejected.length, 2);
  assert.ok(r.json.rejected.some((x) => x.reason.includes('名字')));
  assert.equal(r.json.pulled.members.length, 1, '好的那条要落库');
});

test('不认识的打卡状态被拒，绝不猜成 done', async (t) => {
  // 猜成 done = 凭空造出"已完成"，这比丢一条记录严重得多：
  // 统计数字会不可信，而"可信"是这个产品的全部价值。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [checkin('t1', '2025-03-01', 0, 'DONE')],
    },
  });
  assert.equal(r.json.rejected.length, 1);
  assert.equal(r.json.pulled.checkins.length, 0);
});

test('不认识的时刻规则类型被拒：写进去等于这个项目永远排不出来', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const bad = task('t1', 'm1', '吃药');
  bad.timeJson = JSON.stringify({ v: 1, type: 'cron', expr: '* * * * *' });
  const r = await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '爸爸')], tasks: [bad] },
  });
  assert.equal(r.json.rejected.length, 1);
  assert.match(r.json.rejected[0].reason, /时刻规则/);
});

test('两个不同 id 的同一天只留一行', async (t) => {
  // 这条是整条协议最关键的一条。爸爸手机上的打卡 id 是 A，
  // 妈妈手机上同一条的 id 是 B。如果按 id 存，就是两行，
  // 日历和统计都算两遍。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [
        { ...checkin('t1', '2025-03-01', 0, 'done'), id: 'uuid-from-phone-A' },
        { ...checkin('t1', '2025-03-01', 0, 'done'), id: 'uuid-from-phone-B' },
      ],
    },
  });

  const rows = srv.app.db
    .prepare('SELECT * FROM checkins WHERE task_id = ? AND date = ? AND slot_index = ?')
    .all('t1', '2025-03-01', 0);
  assert.equal(rows.length, 1, '三元组相同必须合并成一行');

  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins.length, 1);
  // 协议里不带 id：拉下来的行没有 id，客户端自己 newId()
  assert.equal(pull.json.pulled.checkins[0].id, undefined);
});

test('不同 slot_index 是不同的事，不能合并', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [
        checkin('t1', '2025-03-01', 0, 'done'),
        checkin('t1', '2025-03-01', 1, 'skipped'),
      ],
    },
  });

  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins.length, 2);
});

test('LWW：updated_at_ms 大的赢，相等时远端（新推上来的）赢', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '旧名字', 1000)] },
  });
  // 更旧的推上来：不该覆盖
  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '更旧', 500)] },
  });
  let pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].name, '旧名字');

  // 更新的推上来：覆盖
  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '新名字', 2000)] },
  });
  pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].name, '新名字');

  // 时间戳相等：远端（后来推的那一次）赢——因为它可复现
  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '同刻A', 3000)] },
  });
  await srv.call('POST', '/sync', {
    token,
    body: { members: [member('m1', '同刻B', 3000)] },
  });
  pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].name, '同刻B');
});

test('软删传整行：deleted_at_ms 非空，对端据此隐藏', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const deleted = { ...member('m1', '爸爸', 1000), deletedAtMs: 5000, updatedAtMs: 5000 };
  await srv.call('POST', '/sync', { token, body: { members: [deleted] } });

  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].deleted_at_ms, 5000);
});

test('改得晚于删 → 复活；删得晚于改 → 保持删', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: { members: [{ ...member('m1', '爸爸', 1000), deletedAtMs: 5000, updatedAtMs: 5000 }] },
  });
  // 一次更晚的编辑：复活
  await srv.call('POST', '/sync', {
    token,
    body: { members: [{ ...member('m1', '爸爸（改名）', 8000), deletedAtMs: null }] },
  });
  let pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].deleted_at_ms, null);
  assert.equal(pull.json.pulled.members[0].name, '爸爸（改名）');

  // 一次更早的编辑推上来：不能把已删的复活
  await srv.call('POST', '/sync', {
    token,
    body: { members: [{ ...member('m1', '更早的名字', 2000), deletedAtMs: null }] },
  });
  pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.members[0].name, '爸爸（改名）', '旧编辑不该覆盖新行');
});

test('新设备推空 checkins 不会把别人的打卡删掉', async (t) => {
  // 这条是端到端接真服务时抓到的，症状极典型：
  //
  // 第二台手机刚配对，本地空库，首次同步推 `checkins: []`。老规则是
  // "推了 checkins 就按全量比对，缺的算撤销"，于是服务端把第一台手机
  // 刚推上来的打卡全打成墓碑；第二台拉下来看到的是"已撤销"，而它本地
  // 本来就没有这条 —— 两边一起归零。日志里两条写入、零拒绝，一切"正常"。
  //
  // 「我从来没有」和「我撤销了」必须分开表达。现在的规则是只看
  // `removedCheckins`；空 checkins 就是没东西要推，不动服务端。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const first = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [checkin('t1', '2025-04-01', 0, 'done', 1000)],
    },
  });
  assert.equal(first.status, 200);
  assert.equal(first.json.tombstoned, 0);
  assert.equal(first.json.pulled.checkins.length, 1);
  assert.equal(first.json.pulled.checkins[0].deleted, 0);

  // 第二台设备配对进来，首次同步只推空数组
  const extra = await srv.call('POST', '/pair/code', { token });
  const second = await srv.call('POST', '/pair/claim', {
    body: { code: extra.json.code, deviceLabel: 'B' },
  });
  const empty = await srv.call('POST', '/sync', {
    token: second.json.token,
    body: { checkins: [] },
  });
  assert.equal(empty.json.tombstoned, 0, '空 checkins 不是撤销声明');
  assert.equal(empty.json.pulled.checkins.length, 1, 'B 应当拉到 A 那条打卡');
  assert.equal(empty.json.pulled.checkins[0].deleted, 0, '另一台手机上必须是有效的打卡');

  // 存档里也仍然是活的
  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins[0].deleted, 0);
});

test('显式声明撤销 → 存墓碑，且墓碑会被拉下去', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [
        checkin('t1', '2025-03-01', 0, 'done', 1000),
        checkin('t1', '2025-03-02', 0, 'done', 1000),
      ],
    },
  });

  // 第二次显式声明撤销 03-02
  const r = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [checkin('t1', '2025-03-01', 0, 'done', 1000)],
      removedCheckins: ['t1|2025-03-02|0'],
    },
  });
  assert.equal(r.json.tombstoned, 1);
  assert.deepEqual(r.json.rejected, []);

  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  const tomb = pull.json.pulled.checkins.find((c) => c.date === '2025-03-02');
  assert.equal(tomb.deleted, 1);
  assert.ok(tomb.deleted_at_ms > 0, '墓碑要带时间，否则对端无法判断"删得晚不晚"');
});

test('墓碑要进水位：下一次带 since 来的设备必须拉到它', async (t) => {
  // 这条守的漏洞非常隐蔽，端到端接真服务才暴露出来：
  // 同一批里写入的行拿到 t1..tN，墓碑排在最后拿到 tN；
  // 如果 `cursor` 只算写入、不算墓碑，客户端下次带 `since = tN-1` 来拉，
  // 条件是 `server_at_ms > since`，**墓碑正好卡在边界上，永远拉不到**。
  // 表现：一台手机撤销了打卡，另一台一直显示"已完成"。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [
        checkin('t1', '2025-05-01', 0, 'done', 1000),
        checkin('t1', '2025-05-02', 0, 'done', 1000),
      ],
    },
  });

  // 第二台设备先拉全量，拿到它自己的水位
  const extra = await srv.call('POST', '/pair/code', { token });
  const b = await srv.call('POST', '/pair/claim', {
    body: { code: extra.json.code, deviceLabel: 'B' },
  });
  const initial = await srv.call('POST', '/sync', { token: b.json.token, body: {} });
  const sinceB = initial.json.cursor;
  assert.equal(initial.json.pulled.checkins.length, 2);

  // A 撤销 05-02（显式声明）
  const revoked = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [member('m1', '爸爸')],
      tasks: [task('t1', 'm1', '吃药')],
      checkins: [checkin('t1', '2025-05-01', 0, 'done', 1000)],
      removedCheckins: ['t1|2025-05-02|0'],
    },
  });
  assert.equal(revoked.json.tombstoned, 1);
  assert.ok(revoked.json.cursor > sinceB, 'cursor 应当覆盖到墓碑');

  // B 用上次的水位来拉，必须能看到那条墓碑
  const delta = await srv.call('POST', '/sync', {
    token: b.json.token,
    body: { since: sinceB },
  });
  const tomb = delta.json.pulled.checkins.find((c) => c.date === '2025-05-02');
  assert.ok(tomb, `B 没拉到撤销通知；返回了 ${JSON.stringify(delta.json.pulled.checkins)}`);
  assert.equal(tomb.deleted, 1);
});

test('打卡合并规则：逐格覆盖 mergeCheckinState', () => {
  const done = (t) => ({ state: 'done', doneAtMs: t, dueAtMinuteOfDay: 480, note: null });
  const makeup = (t) => ({ state: 'makeup', doneAtMs: t, dueAtMinuteOfDay: 480, note: null });
  const skipped = () => ({ state: 'skipped', doneAtMs: 100, dueAtMinuteOfDay: 480, note: null });
  const db = (c) => ({
    state: c.state,
    done_at_ms: c.doneAtMs,
    due_at_minute_of_day: c.dueAtMinuteOfDay,
    note: c.note,
  });

  // done 胜 skipped（不论谁的时间更晚）
  assert.equal(mergeCheckinState(db(skipped()), done(9999)).state, 'done');
  assert.equal(mergeCheckinState(db(done(1)), skipped()).state, 'done');

  // 两个都算做过：取 done_at_ms 早的
  assert.equal(mergeCheckinState(db(done(1000)), done(2000)).doneAtMs, 1000);
  assert.equal(mergeCheckinState(db(done(2000)), done(1000)).doneAtMs, 1000);

  // makeup vs done：早的是事实
  assert.equal(mergeCheckinState(db(makeup(500)), done(900)).state, 'makeup');
  assert.equal(mergeCheckinState(db(makeup(900)), done(500)).state, 'done');

  // 完全同一刻：done 比 makeup 强（准时率不能被一次补录拉下来）
  const same = mergeCheckinState(db(makeup(700)), done(700));
  assert.equal(same.state, 'done');

  // 一个没时间戳：以有时间的为准
  assert.equal(
    mergeCheckinState(db({ ...done(null) }), done(1234)).doneAtMs,
    1234,
  );

  // 备注：本次非空才覆盖；空字符串当"没写"，不当"清空"
  assert.equal(
    mergeCheckinState(db({ ...done(1), note: '写了备注' }), { ...done(1), note: '' }).note,
    '写了备注',
  );
  assert.equal(
    mergeCheckinState(db({ ...done(1), note: '旧' }), { ...done(1), note: '新' }).note,
    '新',
  );
});

test('反方向：撤销后又重新打卡 → 墓碑被复活', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const base = {
    members: [member('m1', '爸爸')],
    tasks: [task('t1', 'm1', '吃药')],
  };
  await srv.call('POST', '/sync', {
    token,
    body: { ...base, checkins: [checkin('t1', '2025-03-01', 0, 'done', 1000)] },
  });
  // 撤销：显式声明
  await srv.call('POST', '/sync', {
    token,
    body: { ...base, checkins: [], removedCheckins: ['t1|2025-03-01|0'] },
  });
  let pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins[0].deleted, 1);

  // 又重新打卡，写入时刻晚于删除时刻 → 复活
  const again = checkin('t1', '2025-03-01', 0, 'done', Date.now() + 1000);
  const r = await srv.call('POST', '/sync', {
    token,
    body: { ...base, checkins: [again] },
  });
  assert.deepEqual(r.json.rejected, []);
  pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins[0].deleted, 0, '删得早于改 → 复活');
  assert.equal(pull.json.pulled.checkins[0].state, 'done');
});

test('撤销之后，另一台带同一条旧打卡来同步 → 不能复活', async (t) => {
  // 端到端抓到的，非常隐蔽：
  //
  // 打卡表没有 `updated_at_ms` 列，客户端推上来的 `updatedAtMs` 其实是
  // `doneAtMs` —— 同一格打卡只要状态没变，这个数**一直不变**。
  // 撤销发生之后，另一台设备（本地还留着这条）来同步，推的还是那个
  // 老的 `updatedAtMs`。如果复活判据只看 `updated_at_ms` 且边界写松了，
  // 这一推就把墓碑翻回"有效"，于是：
  //
  //   A 撤销 → 服务端墓碑 → A 下一轮同步把墓碑拉回去 → 判据放行 → 复活
  //
  // 症状是"撤销了，过一会儿自己又回来了"，而且越同步越确定。
  // 判据必须取 `max(updated_at_ms, deleted_at_ms)`：撤销是最后一次变动。
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const base = {
    members: [member('m1', '爸爸')],
    tasks: [task('t1', 'm1', '吃药')],
  };
  const old = checkin('t1', '2025-06-01', 0, 'done', 1000);
  await srv.call('POST', '/sync', { token, body: { ...base, checkins: [old] } });

  // 撤销
  await srv.call('POST', '/sync', {
    token,
    body: { ...base, checkins: [], removedCheckins: ['t1|2025-06-01|0'] },
  });

  // 另一台设备带着**同一个** doneAtMs 来同步（它本地还留着这条）
  const again = await srv.call('POST', '/sync', {
    token,
    body: { ...base, checkins: [old] },
  });
  const pulled = again.json.pulled.checkins.find((c) => c.date === '2025-06-01');
  assert.equal(pulled.deleted, 1, '撤销必须站得住，不能被同一条旧打卡翻回来');

  const pull = await srv.call('POST', '/sync', { token, body: { since: 0 } });
  assert.equal(pull.json.pulled.checkins[0].deleted, 1);
});

test('没有变化的重复推送不刷新 server_at_ms（否则对端永远在拉同样的数据）', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const body = {
    members: [member('m1', '爸爸')],
    tasks: [task('t1', 'm1', '吃药')],
    checkins: [checkin('t1', '2025-03-01', 0, 'done', 1000)],
  };
  const first = await srv.call('POST', '/sync', { token, body });
  const cursor = first.json.cursor;

  const second = await srv.call('POST', '/sync', { token, body });
  const pull = await srv.call('POST', '/sync', { token, body: { since: cursor } });
  assert.equal(pull.json.pulled.checkins.length, 0, '同一条没变就不该再出现');
  assert.ok(second.json.cursor >= cursor);
});

test('since 比服务端还新时告知 sinceReset（换机/时钟回拨的兜底）', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  await srv.call('POST', '/sync', { token, body: { members: [member('m1', '爸爸')] } });
  const r = await srv.call('POST', '/sync', { token, body: { since: Date.now() + 86_400_000 } });
  assert.equal(r.json.sinceReset, true, '客户端要能知道"你的钟不可信，下次全量重来"');
  assert.equal(r.json.pulled.members.length, 0);
});

test('since 不是整数 → 400', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', { token, body: { since: 'yesterday' } });
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'bad_since');
});

test('没有 token 或 token 错 → 401', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const anon = await srv.call('POST', '/sync', { body: {} });
  assert.equal(anon.status, 401);

  const bad = await srv.call('POST', '/sync', { body: {}, token: 'not-a-real-token' });
  assert.equal(bad.status, 401);

  // X-Famdaily-Token 也能用（给那些 Authorization 被中间层吃掉的客户端留条路）
  const { token } = await pairDevice(srv);
  const alt = await srv.call('POST', '/sync', {
    body: {},
    headers: { 'x-famdaily-token': token },
  });
  assert.equal(alt.status, 200);
});

test('只同步白名单里的设置键', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', {
    token,
    body: {
      settings: [
        { key: 'reminders.enabled', value: 'false', updatedAtMs: 1000 },
        { key: 'secret.stuff', value: 'x', updatedAtMs: 1000 },
      ],
    },
  });
  assert.equal(r.json.rejected.length, 1);
  assert.match(r.json.rejected[0].reason, /不同步/);
  assert.equal(r.json.pulled.settings.length, 1);
});

test('推送条数超上限 → 400，不是静默截断', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', {
    token,
    body: { members: new Array(5001).fill(null).map((_, i) => member(`m${i}`, `人${i}`)) },
  });
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'too_many');
});

test('members 不是数组 → 400', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  const { token } = await pairDevice(srv);

  const r = await srv.call('POST', '/sync', { token, body: { members: {} } });
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'bad_body');
});
