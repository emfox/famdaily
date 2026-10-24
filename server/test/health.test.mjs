/**
 * 健康检查与骨架：服务能起来、库能建成、错误码分得清。
 *
 * 这一层的测试不多，但值钱——它们是"到底是我手机的问题还是服务没起来"
 * 这个问题唯一的客观答案。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startServer } from './helpers.mjs';
import { openDb, createServerClock } from '../src/db.mjs';
import { normalizePairCode, generatePairCode, CODE_ALPHABET } from '../src/auth.mjs';

test('GET /health 返回 ok 和家庭数', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const r = await srv.call('GET', '/health');
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.service, 'famdaily-sync');
  assert.equal(r.json.families, 0);
  assert.equal(r.json.pairEnabled, true);
  assert.ok(Number.isInteger(r.json.cursor));
});

test('没配配对口令时 /health 如实说 pairEnabled=false', async (t) => {
  const srv = await startServer({ pairSecret: '' });
  t.after(() => srv.close());

  const r = await srv.call('GET', '/health');
  assert.equal(r.json.pairEnabled, false);
});

test('不存在的路径 404，方法不对 405 —— 两者不能混', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const notFound = await srv.call('GET', '/nope');
  assert.equal(notFound.status, 404);
  assert.equal(notFound.json.error.code, 'not_found');

  // 路径存在但方法不对：必须 405，不能也报 404。
  // 报 404 会让人以为接口改了名，实际只是方法写错。
  const wrongMethod = await srv.call('GET', '/sync');
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.json.error.code, 'method_not_allowed');
});

test('坏 JSON 是 400 不是 500', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const r = await srv.call('POST', '/sync', { raw: '{不是json' });
  assert.equal(r.status, 400);
  assert.equal(r.json.error.code, 'bad_json');
});

test('数组当请求体也是 400（客户端拿错类型要立刻报出来）', async (t) => {
  const srv = await startServer();
  t.after(() => srv.close());

  const r = await srv.call('POST', '/sync', { raw: '[]' });
  assert.equal(r.status, 400);
});

test('建库后六张表都在', async () => {
  const db = openDb(':memory:');
  const names = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .all()
    .map((r) => r.name)
    .filter((n) => !n.startsWith('sqlite_'));

  for (const t of [
    'families',
    'devices',
    'pair_codes',
    'members',
    'tasks',
    'checkins',
    'settings',
  ]) {
    assert.ok(names.includes(t), `缺表 ${t}`);
  }
  db.close();
});

test('server_at_ms 严格单调递增：同毫秒连取十次也不重复', () => {
  const db = openDb(':memory:');
  const clock = createServerClock(db);
  const seen = [];
  for (let i = 0; i < 10; i += 1) seen.push(clock.next());
  for (let i = 1; i < seen.length; i += 1) {
    assert.ok(seen[i] > seen[i - 1], `第 ${i} 个没有比前一个大：${seen}`);
  }
  db.close();
});

test('server_at_ms 跨重启接续：新建时钟不会比库里最大值小', () => {
  // 这是一个真实会发生的场景：沙箱重启进程后，内存里的 last 丢了，
  // 如果从 0 重新开始，客户端手里的 cursor 会比服务端的新值大，
  // 于是 `server_at_ms > cursor` 永远不成立 —— 表现为"重启后再也同步不到东西"。
  const db = openDb(':memory:');
  db.prepare(
    'INSERT INTO families (id, secret_hash, name, created_at_ms) VALUES (?, ?, ?, ?)',
  ).run('f1', 'h', '家', 1);
  db.prepare(
    `INSERT INTO members (family_id, id, name, sort_order, created_at_ms, updated_at_ms, server_at_ms)
     VALUES ('f1', 'm1', '我', 0, 1, 1, ?)`,
  ).run(Date.now() + 10_000);

  const clock = createServerClock(db);
  assert.ok(
    clock.peek() > Date.now(),
    '新建的时钟必须从库里已用的最大值接上，不能从 0 开始',
  );
  assert.ok(clock.next() > Date.now() + 10_000);
  db.close();
});

test('同步码字母表里没有会认错的字符', () => {
  for (const ch of '0O1IL') {
    assert.ok(
      !CODE_ALPHABET.includes(ch),
      `字母表里不该有 ${ch}：这个码要能被念出来、能手输`,
    );
  }
});

test('同步码格式与规范化：宽容输入、严格判定', () => {
  const code = generatePairCode();
  assert.match(code, /^FAM-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);

  // 各种手输花样都要能认出来
  const body = code.replace(/-/g, '');
  assert.equal(normalizePairCode(code), code);
  assert.equal(normalizePairCode(code.toLowerCase()), code);
  assert.equal(normalizePairCode(`  ${code} \n`), code);
  assert.equal(normalizePairCode(code.replace(/-/g, ' ')), code);

  // 长度不对、有字母表外的字符 → null，不做"智能纠错"
  assert.equal(normalizePairCode(`${body}X`), null);
  assert.equal(normalizePairCode(body.slice(0, -1)), null);
  assert.equal(normalizePairCode(body.replace(/^./, 'O')), null, 'O 不在字母表里');
  assert.equal(normalizePairCode(null), null);
});
