/**
 * 成员链接的 HTTP 层测试：`POST /members/:id/link`、`/unlink`。
 *
 * 走真 HTTP（`startServer`），因为要验证的东西里有一半在头里：
 * `x-forwarded-host` 拼出来的链接、Bearer 鉴权、404/409 的状态码。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { startServer, pairDevice, member } from './helpers.mjs';

/** 建家庭 + 配对设备 + 推两个成员上去。 */
async function setup() {
  const srv = await startServer();
  const { token, familyId } = await pairDevice(srv);
  const pushed = await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [member('m1', '爷爷', 1000), member('m2', '小明', 1001)],
      tasks: [],
      checkins: [],
      settings: [],
    },
  });
  assert.equal(pushed.status, 200, JSON.stringify(pushed.json));
  return { srv, token, familyId };
}

test('POST /members/:id/link：返回完整链接，token 在路径里', async () => {
  const { srv, token } = await setup();
  const r = await srv.call('POST', '/members/m1/link', { token });

  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.ok, true);
  assert.equal(r.json.memberId, 'm1');
  assert.match(r.json.url, /^http:\/\/127\.0\.0\.1:\d+\/m\/[A-Za-z0-9_-]{40,}$/);
  assert.ok(r.json.issuedAtMs > 0);

  await srv.close();
});

test('POST /members/:id/link：用 x-forwarded-host 拼对外域名（不是 127.0.0.1）', async () => {
  const { srv, token } = await setup();
  const r = await srv.call('POST', '/members/m1/link', {
    token,
    headers: {
      'x-forwarded-host': 'famdaily.example.com',
      'x-forwarded-proto': 'https',
    },
  });

  assert.equal(r.status, 200);
  assert.match(r.json.url, /^https:\/\/famdaily\.example\.com\/m\//);
  await srv.close();
});

test('POST /members/:id/link：x-forwarded-host 有多个值时取第一个', async () => {
  const { srv, token } = await setup();
  const r = await srv.call('POST', '/members/m1/link', {
    token,
    headers: { 'x-forwarded-host': 'a.example.com, b.internal' },
  });
  assert.match(r.json.url, /^http:\/\/a\.example\.com\/m\//);
  await srv.close();
});

test('POST /members/:id/link：没配对 → 401', async () => {
  const { srv } = await setup();
  const r = await srv.call('POST', '/members/m1/link', {});
  assert.equal(r.status, 401);
  assert.equal(r.json.error.code, 'unauthorized');
  await srv.close();
});

test('POST /members/:id/link：成员不存在 → 404', async () => {
  const { srv, token } = await setup();
  const r = await srv.call('POST', '/members/nobody/link', { token });
  assert.equal(r.status, 404);
  assert.equal(r.json.error.code, 'member_not_found');
  await srv.close();
});

test('POST /members/:id/link：已删除的成员 → 409', async () => {
  const { srv, token } = await setup();
  // 把 m2 删掉
  await srv.call('POST', '/sync', {
    token,
    body: {
      deviceId: 'dev-1',
      since: 0,
      members: [{ ...member('m2', '小明', 2000), deletedAtMs: 2000 }],
      tasks: [],
      checkins: [],
      settings: [],
    },
  });
  const r = await srv.call('POST', '/members/m2/link', { token });
  assert.equal(r.status, 409);
  assert.equal(r.json.error.code, 'member_deleted');
  await srv.close();
});

test('重新生成链接 → 旧链接失效，新链接可用', async () => {
  const { srv, token } = await setup();
  const first = await srv.call('POST', '/members/m1/link', { token });
  const second = await srv.call('POST', '/members/m1/link', { token });

  const t1 = first.json.url.split('/m/')[1];
  const t2 = second.json.url.split('/m/')[1];
  assert.notEqual(t1, t2);

  // 直接查库：只有 t2 的哈希在里面
  const { createHash } = await import('node:crypto');
  const h1 = createHash('sha256').update(`web:${t1}`).digest('hex');
  const h2 = createHash('sha256').update(`web:${t2}`).digest('hex');
  const row = srv.app.db
    .prepare('SELECT web_token_hash FROM members WHERE id = ?')
    .get('m1');
  assert.notEqual(row.web_token_hash, h1);
  assert.equal(row.web_token_hash, h2);

  await srv.close();
});

test('POST /members/:id/unlink：作废后 revoked=true，再作废 revoked=false', async () => {
  const { srv, token } = await setup();
  await srv.call('POST', '/members/m1/link', { token });

  const first = await srv.call('POST', '/members/m1/unlink', { token });
  assert.equal(first.status, 200);
  assert.equal(first.json.revoked, true);

  const second = await srv.call('POST', '/members/m1/unlink', { token });
  assert.equal(second.status, 200);
  assert.equal(second.json.revoked, false, '关已关的灯不该失败');

  await srv.close();
});

test('POST /members/:id/unlink：没配对 → 401', async () => {
  const { srv } = await setup();
  const r = await srv.call('POST', '/members/m1/unlink', {});
  assert.equal(r.status, 401);
  await srv.close();
});

test('不同家庭的成员互相看不见（越权）', async () => {
  const { srv, token } = await setup();

  // 第二个家庭
  const other = await srv.call('POST', '/pair/new', {
    body: { name: '另一个家' },
    headers: { 'x-pair-secret': 'test-secret' },
  });
  const claimed = await srv.call('POST', '/pair/claim', {
    body: { code: other.json.code },
  });
  const otherToken = claimed.json.token;

  // 用 B 家的 token 给 A 家的 m1 发链接 → 必须 404
  const r = await srv.call('POST', '/members/m1/link', { token: otherToken });
  assert.equal(r.status, 404, '跨家庭必须查不到');

  await srv.close();
});
