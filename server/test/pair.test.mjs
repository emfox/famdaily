/**
 * 配对：建家庭、预览、换 token、轮换，以及它们各自的失败方式。
 *
 * 这一组测试的重点不是"成功路径能跑"，而是**失败路径分得清**：
 * 码不对 / 码用过 / 码过期 / 口令错 / 刷太频——这五种在用户那里
 * 长得完全一样（"配不上"），但对排查的意义完全不同。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, pairDevice, member } from './helpers.mjs';
import { PAIR_CODE_TTL_MS } from '../src/pair.mjs';
import { hashPairCode, generatePairCode } from '../src/auth.mjs';

test('建家庭 → 预览 → 配对，全流程走通', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: { name: '张家' },
    headers: { 'x-pair-secret': 'test-secret' },
  });
  assert.equal(created.status, 200);
  assert.match(created.json.code, /^FAM-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
  assert.equal(created.json.familyName, '张家');
  assert.ok(created.json.expiresAtMs > Date.now());

  // 预览：只回名字，不回 id、不回 token
  const preview = await srv.call('GET', `/pair/${created.json.code}`);
  assert.equal(preview.status, 200);
  assert.equal(preview.json.familyName, '张家');
  assert.deepEqual(preview.json.members, []);
  assert.equal(preview.json.token, undefined, '预览绝不能带 token');
  assert.equal(preview.json.familyId, undefined, '预览不回家庭 id，少给猜码的人一点素材');
  assert.equal(preview.json.deviceId, undefined);

  const claimed = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code, deviceLabel: '爸爸的手机' },
  });
  assert.equal(claimed.status, 200);
  assert.ok(claimed.json.token.length >= 40);
  assert.ok(claimed.json.deviceId);
  assert.equal(claimed.json.familyId, created.json.familyId);

  // health 里家庭数 +1
  const health = await srv.call('GET', '/health');
  assert.equal(health.json.families, 1);
});

test('同步码是一次性的：第二次 claim 被拒', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  const first = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code },
  });
  assert.equal(first.status, 200);

  const second = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code },
  });
  assert.equal(second.status, 409);
  assert.equal(second.json.error.code, 'code_used');
});

test('用过的码连预览都不给：不能确认"这码还算数"', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  await srv.call('POST', '/pair/claim', { body: { code: created.json.code } });

  const preview = await srv.call('GET', `/pair/${created.json.code}`);
  assert.equal(preview.status, 404);
  assert.equal(preview.json.error.code, 'code_used');
});

test('码过期：410 而不是 404，用户需要知道"重新生成"而不是"我记错了"', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  // 直接把有效期改到过去——比 sleep 10 分钟现实。
  srv.app.db
    .prepare('UPDATE pair_codes SET expires_at_ms = ? WHERE code_hash = ?')
    .run(Date.now() - 1000, hashPairCode(created.json.code));

  const preview = await srv.call('GET', `/pair/${created.json.code}`);
  assert.equal(preview.status, 410);
  assert.equal(preview.json.error.code, 'code_expired');

  const claim = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code },
  });
  assert.equal(claim.status, 410);
});

test('码有 10 分钟有效期，不多不少', async () => {
  assert.equal(PAIR_CODE_TTL_MS, 600_000);
});

test('乱猜的码：404，且不回显用户输的那串', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  // 字母表外的字符 → 直接不算码
  const r = await srv.call('GET', '/pair/FAM-0000-0000-0000');
  assert.equal(r.status, 404);
  // 格式对但不存在
  const r2 = await srv.call('GET', `/pair/${generatePairCode()}`);
  assert.equal(r2.status, 404);
  assert.equal(r2.json.error.code, 'bad_code');
});

test('配对口令错：403，且不给任何"差一点"的提示', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const wrong = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'wrong' },
  });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.json.error.code, 'bad_pair_secret');

  const missing = await srv.call('POST', '/pair/new', { body: {} });
  assert.equal(missing.status, 403);
});

test('没配口令时建家庭被拒，但已有设备照常同步', async (t) => {
  // 这条是"别因为配错环境变量把全家断了"的守卫。
  const srv = await startServer({ pairSecret: 'right-secret' });
  t.after(() => srv.close());

  // 先在"有口令"的服务上配好
  const paired = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'right-secret' },
  });
  const claimed = await srv.call('POST', '/pair/claim', {
    body: { code: paired.json.code },
  });
  const token = claimed.json.token;

  // 模拟"运维把环境变量删了"：把运行时的 config 清空
  srv.app.deps.config.pairSecret = '';

  const blocked = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'right-secret' },
  });
  assert.equal(blocked.status, 503);
  assert.equal(blocked.json.error.code, 'pair_disabled');

  // 关键：/sync 不受影响
  const sync = await srv.call('POST', '/sync', { body: {}, token });
  assert.equal(sync.status, 200, '配对口令配错不该把全家断了');
  assert.equal(sync.json.ok, true);
});

test('轮换：新 token 能用，旧的全部失效', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  // 两台设备
  const a = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code, deviceLabel: 'A' },
  });
  // 同一家庭再加一台：走**真实路径**再要一个码。
  //
  // 这里以前是直接往 devices 表插一行，注释写着"模拟第二台手机用同家庭
  // 另一个码接入"——但那条路径当时根本不存在，插行把这个洞盖住了。
  // 端到端一接真服务就露馅：第二台设备只能靠另建一个家庭才能配对，
  // 于是两台手机永远在各自的家庭里互相看不见。
  const extra = await srv.call('POST', '/pair/code', { token: a.json.token });
  assert.equal(extra.status, 200);
  const b = await srv.call('POST', '/pair/claim', {
    body: { code: extra.json.code, deviceLabel: 'B' },
  });
  assert.equal(b.status, 200);
  assert.equal(b.json.familyId, a.json.familyId, '第二台必须落进同一个家庭');

  const rotated = await srv.call('POST', '/pair/rotate', { token: a.json.token });
  assert.equal(rotated.status, 200);
  assert.notEqual(rotated.json.token, a.json.token);

  // 新 token 能用
  const withNew = await srv.call('POST', '/sync', { body: {}, token: rotated.json.token });
  assert.equal(withNew.status, 200);

  // 旧 token 都不行
  const withOldA = await srv.call('POST', '/sync', { body: {}, token: a.json.token });
  assert.equal(withOldA.status, 401);
  const withOldB = await srv.call('POST', '/sync', { body: {}, token: b.json.token });
  assert.equal(withOldB.status, 401, '手机丢了，不能只加不减');
});

test('已配对的设备能给自己家再要一个码，第二台手机接进同一个家', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const first = await pairDevice(srv, { name: '张家' });

  // 这条接口不带 X-Pair-Secret：拿得到本机 token 就等于已经是这个家的人。
  const extra = await srv.call('POST', '/pair/code', { token: first.token });
  assert.equal(extra.status, 200);
  assert.match(extra.json.code, /^FAM-/);
  assert.equal(extra.json.familyId, first.familyId);

  // 新码能预览到**已有**成员（而不是空家庭）
  await srv.call('POST', '/sync', {
    body: { members: [member('m1', '奶奶')] },
    token: first.token,
  });
  const preview = await srv.call('GET', `/pair/${extra.json.code}`);
  assert.equal(preview.status, 200);
  assert.equal(preview.json.familyName, '张家');
  assert.deepEqual(preview.json.members.map((m) => m.name), ['奶奶']);

  // 第二台接进来
  const second = await srv.call('POST', '/pair/claim', {
    body: { code: extra.json.code, deviceLabel: '妈妈手机' },
  });
  assert.equal(second.status, 200);
  assert.equal(second.json.familyId, first.familyId);
  assert.notEqual(second.json.deviceId, first.deviceId);

  // 关键：接进来就看得见家里的数据
  const pulled = await srv.call('POST', '/sync', { body: {}, token: second.json.token });
  assert.deepEqual(pulled.json.pulled.members.map((m) => m.name), ['奶奶']);

  // 第一台没被踢下线
  const stillOk = await srv.call('POST', '/sync', { body: {}, token: first.token });
  assert.equal(stillOk.status, 200, '给第二台发码不该影响第一台');

  // 码照样一次性
  const reuse = await srv.call('POST', '/pair/claim', { body: { code: extra.json.code } });
  assert.equal(reuse.status, 409);

  // 没 token 要不到码
  const anon = await srv.call('POST', '/pair/code', { body: {} });
  assert.equal(anon.status, 401);
});

test('同一家连着要很多码也不会失控，最老的被挤掉', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());
  // 这里验的是「有效码上限」，不是限流。先要一个码本身也要过一次限流，
  // 默认 5 次/分钟会把测试卡在限流上而不是上限上——把闸门放开。
  const first = await pairDevice(srv);
  for (const k of Object.keys(srv.app.deps.limiters)) {
    srv.app.deps.limiters[k] = {
      hit: () => ({ allowed: true }),
      reset: () => {},
    };
  }

  const codes = [];
  for (let i = 0; i < 8; i += 1) {
    const r = await srv.call('POST', '/pair/code', { token: first.token });
    assert.equal(r.status, 200, `第 ${i + 1} 次要码应当成功`);
    codes.push(r.json.code);
  }

  // 最新的仍然可用
  const latest = await srv.call('GET', `/pair/${codes.at(-1)}`);
  assert.equal(latest.status, 200);

  // 最早的已经被挤掉
  const oldest = await srv.call('GET', `/pair/${codes[0]}`);
  assert.equal(oldest.status, 404);
});

test('库里搜不到 token 与配对码的明文', async (t) => {
  // "沙箱数据没有备份承诺"——那至少别让数据文件变成一份密码本。
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  const claimed = await srv.call('POST', '/pair/claim', {
    body: { code: created.json.code },
  });

  const dump = [
    ...srv.app.db.prepare('SELECT * FROM devices').all(),
    ...srv.app.db.prepare('SELECT * FROM pair_codes').all(),
    ...srv.app.db.prepare('SELECT * FROM families').all(),
  ]
    .map((row) => JSON.stringify(row))
    .join('\n');

  assert.ok(!dump.includes(claimed.json.token), 'token 明文出现在库里');
  assert.ok(!dump.includes(created.json.code), '配对码明文出现在库里');
  assert.ok(!dump.includes('test-secret'), '配对口令明文出现在库里');
  // 存的应该是 64 位 hex 摘要
  assert.match(
    srv.app.db.prepare('SELECT token_hash FROM devices').get().token_hash,
    /^[0-9a-f]{64}$/,
  );
});

test('claim 限流：连续错码到第 6 次返回 429', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  let last;
  for (let i = 0; i < 6; i += 1) {
    last = await srv.call('POST', '/pair/claim', {
      body: { code: generatePairCode() },
    });
  }
  assert.equal(last.status, 429);
  assert.equal(last.json.error.code, 'rate_limited');
  assert.ok(last.json.error.retryAfterMs > 0, '要告诉客户端多久后能重试');

  // 限流不能误伤预览：那是另一个桶
  const preview = await srv.call('GET', `/pair/${generatePairCode()}`);
  assert.equal(preview.status, 404);
});

test('预览限流：猜码刷到第 11 次返回 429', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  let last;
  for (let i = 0; i < 11; i += 1) {
    last = await srv.call('GET', `/pair/${generatePairCode()}`);
  }
  assert.equal(last.status, 429);
});

test('手输花样都能认：小写、空格、少连字符、多换行', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const created = await srv.call('POST', '/pair/new', {
    body: {},
    headers: { 'x-pair-secret': 'test-secret' },
  });
  const code = created.json.code;

  // 预览（不改状态，可以多次试）
  for (const variant of [
    code.toLowerCase(),
    code.replace(/-/g, ' '),
    code.replace(/-/g, ''),
    `  ${code}\n`,
    `fam ${code.slice(4).replace(/-/g, ' ')}`,
  ]) {
    const r = await srv.call('GET', `/pair/${encodeURIComponent(variant)}`);
    assert.equal(r.status, 200, `认不出这种写法：${JSON.stringify(variant)}`);
  }
});

test('第二个家庭的数据与第一个完全隔离', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const famA = await pairDevice(srv, { name: 'A 家' });
  const famB = await pairDevice(srv, { name: 'B 家' });

  await srv.call('POST', '/sync', {
    body: { members: [member('m1', '爸爸')] },
    token: famA.token,
  });

  const pulled = await srv.call('POST', '/sync', { body: {}, token: famB.token });
  assert.equal(pulled.json.pulled.members.length, 0, 'B 家不该看到 A 家的成员');
});
