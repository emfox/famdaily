/**
 * 成员链接鉴权测试。
 *
 * 直接测 `src/web_auth.mjs`（不经 HTTP），因为这一层的每条规则都是
 * "库里的状态怎么变"，走 HTTP 反而看不清。HTTP 层的接线在
 * `web_api.test.mjs` 里测。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { openDb } from '../src/db.mjs';
import {
  buildSetCookie,
  buildClearCookie,
  exchangeTokenForTicket,
  generateWebToken,
  hashWebToken,
  hashWebTicket,
  issueWebToken,
  readCookie,
  resolveWebIdentity,
  resolveWebTicket,
  revokeWebToken,
  WEB_COOKIE_NAME,
  WEB_TICKET_TTL_MS,
} from '../src/web_auth.mjs';

/** 建一个内存库 + 一个家庭 + 一个成员。 */
function setup() {
  const db = openDb(':memory:');
  db.prepare(
    'INSERT INTO families (id, secret_hash, name, created_at_ms) VALUES (?, ?, ?, ?)',
  ).run('fam1', 'x', '我的家', 1000);
  db.prepare(
    'INSERT INTO members (family_id, id, name, sort_order, created_at_ms, updated_at_ms, server_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)',
  ).run('fam1', 'm1', '爷爷', 0, 1000, 1000, 1000);
  return db;
}

const NOW = 1_700_000_000_000;

test('issueWebToken：返回明文 token，库里只存哈希', () => {
  const db = setup();
  const { token, issuedAtMs } = issueWebToken(db, 'fam1', 'm1', NOW);

  assert.equal(issuedAtMs, NOW);
  assert.ok(token.length >= 40, `token 太短：${token.length}`);

  const row = db
    .prepare('SELECT web_token_hash, web_token_issued_at_ms FROM members WHERE id = ?')
    .get('m1');
  assert.equal(row.web_token_hash, hashWebToken(token));
  assert.notEqual(row.web_token_hash, token, '不能存明文');
  assert.equal(row.web_token_issued_at_ms, NOW);

  // 明文在整个库里一处都不该有。这条是"别把库变成密码本"的最后一道守卫。
  const dump = JSON.stringify(db.prepare('SELECT * FROM members').all());
  assert.ok(!dump.includes(token), '明文 token 出现在 members 表里');
});

test('issueWebToken：成员不存在 → 404', () => {
  const db = setup();
  assert.throws(() => issueWebToken(db, 'fam1', 'nobody', NOW), /没有这个成员/);
});

test('issueWebToken：已删除的成员 → 409，不给你发一个幽灵入口', () => {
  const db = setup();
  db.prepare('UPDATE members SET deleted_at_ms = ? WHERE id = ?').run(NOW, 'm1');
  assert.throws(() => issueWebToken(db, 'fam1', 'm1', NOW), /已删除/);
});

test('issueWebToken：重复签发会顶掉旧 token', () => {
  const db = setup();
  const first = issueWebToken(db, 'fam1', 'm1', NOW);
  const second = issueWebToken(db, 'fam1', 'm1', NOW + 1);

  assert.notEqual(first.token, second.token);
  // 旧 token 换不到票了
  assert.equal(exchangeTokenForTicket(db, first.token, NOW + 2), null);
  // 新的可以
  assert.ok(exchangeTokenForTicket(db, second.token, NOW + 2));
});

test('issueWebToken：重新签发会作废旧 ticket（否则"作废链接"是假的）', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const ex = exchangeTokenForTicket(db, token, NOW);
  assert.ok(resolveWebTicket(db, ex.ticket, NOW));

  issueWebToken(db, 'fam1', 'm1', NOW + 1);
  assert.equal(
    resolveWebTicket(db, ex.ticket, NOW + 2),
    null,
    '换链接之后老 Cookie 必须失效',
  );
});

test('exchangeTokenForTicket：token 不对返回 null', () => {
  const db = setup();
  issueWebToken(db, 'fam1', 'm1', NOW);
  assert.equal(exchangeTokenForTicket(db, 'not-the-token', NOW), null);
  assert.equal(exchangeTokenForTicket(db, '', NOW), null);
  assert.equal(exchangeTokenForTicket(db, null, NOW), null);
});

test('exchangeTokenForTicket：成员在发链接后被删除 → 换不到票', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  db.prepare('UPDATE members SET deleted_at_ms = ? WHERE id = ?').run(NOW + 1, 'm1');
  assert.equal(exchangeTokenForTicket(db, token, NOW + 2), null);
});

test('exchangeTokenForTicket：返回成员名与过期时间', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const ex = exchangeTokenForTicket(db, token, NOW);

  assert.equal(ex.familyId, 'fam1');
  assert.equal(ex.memberId, 'm1');
  assert.equal(ex.memberName, '爷爷');
  assert.equal(ex.expiresAtMs, NOW + WEB_TICKET_TTL_MS);
  assert.ok(ex.ticket.length >= 40);
});

test('resolveWebTicket：有效 ticket 认出身份，并刷新 last_seen_ms', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const { ticket } = exchangeTokenForTicket(db, token, NOW);

  const id = resolveWebTicket(db, ticket, NOW + 1000);
  assert.deepEqual(id, { familyId: 'fam1', memberId: 'm1', memberName: '爷爷' });

  const row = db
    .prepare('SELECT last_seen_ms FROM web_tickets WHERE ticket_hash = ?')
    .get(hashWebTicket(ticket));
  assert.equal(row.last_seen_ms, NOW + 1000);
});

test('resolveWebTicket：过期就失效，并把过期行删掉', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const { ticket } = exchangeTokenForTicket(db, token, NOW);

  assert.equal(resolveWebTicket(db, ticket, NOW + WEB_TICKET_TTL_MS - 1)?.memberId, 'm1');
  assert.equal(resolveWebTicket(db, ticket, NOW + WEB_TICKET_TTL_MS), null, '到期那一毫秒就失效');

  const left = db
    .prepare('SELECT count(*) AS n FROM web_tickets WHERE ticket_hash = ?')
    .get(hashWebTicket(ticket));
  assert.equal(left.n, 0, '过期行应该被顺手删掉');
});

test('resolveWebTicket：成员被删 → ticket 立刻失效，不给窗口', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const { ticket } = exchangeTokenForTicket(db, token, NOW);

  db.prepare('UPDATE members SET deleted_at_ms = ? WHERE id = ?').run(NOW + 1, 'm1');
  assert.equal(resolveWebTicket(db, ticket, NOW + 2), null);
});

test('resolveWebTicket：ticket 不对返回 null', () => {
  const db = setup();
  assert.equal(resolveWebTicket(db, 'nope', NOW), null);
  assert.equal(resolveWebTicket(db, '', NOW), null);
});

test('revokeWebToken：作废后 token 换不到票、旧 ticket 也失效', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const { ticket } = exchangeTokenForTicket(db, token, NOW);

  const r = revokeWebToken(db, 'fam1', 'm1');
  assert.equal(r.revoked, true);

  assert.equal(exchangeTokenForTicket(db, token, NOW + 1), null);
  assert.equal(resolveWebTicket(db, ticket, NOW + 1), null, '作废要连老 Cookie 一起废');
});

test('revokeWebToken：本来就没有链接 → revoked: false，不报错', () => {
  const db = setup();
  const r = revokeWebToken(db, 'fam1', 'm1');
  assert.equal(r.revoked, false);
});

test('revokeWebToken：成员不存在 → 404', () => {
  const db = setup();
  assert.throws(() => revokeWebToken(db, 'fam1', 'nobody'), /没有这个成员/);
});

test('作废之后可以重新发一条，而且能正常用', () => {
  const db = setup();
  issueWebToken(db, 'fam1', 'm1', NOW);
  revokeWebToken(db, 'fam1', 'm1');
  const again = issueWebToken(db, 'fam1', 'm1', NOW + 1);
  const ex = exchangeTokenForTicket(db, again.token, NOW + 2);
  assert.equal(ex?.memberId, 'm1');
});

// ---------------------------------------------------------------------------
// 两套凭据硬隔离
// ---------------------------------------------------------------------------

test('成员 token 的哈希和设备 token 的哈希在同一个命名空间里撞不上', () => {
  // 同一个字符串，两种前缀 → 两个不同的哈希。
  const s = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abc';
  assert.notEqual(hashWebToken(s), `token:${s}`);
  // 而且 web: 前缀确实生效（不是裸 sha256）
  assert.notEqual(hashWebToken(s), hashWebTicket(s));
});

test('把成员 token 塞进 Authorization: Bearer 查不到设备', async () => {
  // 这一条在 web_api.test.mjs 里走真 HTTP 更有说服力，这里先守哈希层。
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  // 模拟 resolveDevice 的查询
  const device = db
    .prepare('SELECT id FROM devices WHERE token_hash = ?')
    .get(hashWebToken(token));
  assert.equal(device, undefined);
});

// ---------------------------------------------------------------------------
// Cookie 工具
// ---------------------------------------------------------------------------

test('readCookie：正常解析', () => {
  assert.equal(readCookie('a=1; famdaily_m=abc; b=2', WEB_COOKIE_NAME), 'abc');
  assert.equal(readCookie('famdaily_m=abc', WEB_COOKIE_NAME), 'abc');
});

test('readCookie：没有 / 空 / 格式错都返回 null，不抛', () => {
  assert.equal(readCookie(undefined, WEB_COOKIE_NAME), null);
  assert.equal(readCookie('', WEB_COOKIE_NAME), null);
  assert.equal(readCookie('other=1', WEB_COOKIE_NAME), null);
  assert.equal(readCookie('no-equals-sign', WEB_COOKIE_NAME), null);
  assert.equal(readCookie(42, WEB_COOKIE_NAME), null);
});

test('readCookie：值里有 = 也能取到（ticket 是 base64url，不该有，但别脆）', () => {
  assert.equal(readCookie('famdaily_m=a=b=c', WEB_COOKIE_NAME), 'a=b=c');
});

test('buildSetCookie：HttpOnly + SameSite=Strict + Path=/ + Max-Age', () => {
  const c = buildSetCookie({ ticket: 'abc', maxAgeSec: 3600, secure: false });
  assert.ok(c.startsWith(`${WEB_COOKIE_NAME}=abc`));
  assert.ok(c.includes('HttpOnly'));
  assert.ok(c.includes('SameSite=Strict'));
  assert.ok(c.includes('Path=/'));
  assert.ok(c.includes('Max-Age=3600'));
  assert.ok(!c.includes('Secure'), 'http 下加 Secure 会让浏览器直接丢弃 Cookie');
});

test('buildSetCookie：https 时加 Secure', () => {
  const c = buildSetCookie({ ticket: 'abc', maxAgeSec: 60, secure: true });
  assert.ok(c.includes('Secure'));
});

test('buildClearCookie：Max-Age=0，值是空', () => {
  const c = buildClearCookie({ secure: false });
  assert.ok(c.startsWith(`${WEB_COOKIE_NAME}=;`));
  assert.ok(c.includes('Max-Age=0'));
});

test('WEB_TICKET_TTL_MS 是 7 天', () => {
  assert.equal(WEB_TICKET_TTL_MS, 7 * 24 * 60 * 60 * 1000);
});

test('generateWebToken：两次不一样，且够长', () => {
  const a = generateWebToken();
  const b = generateWebToken();
  assert.notEqual(a, b);
  assert.ok(a.length >= 40);
});

// ---------------------------------------------------------------------------
// resolveWebIdentity：Cookie 优先、URL 兜底
// ---------------------------------------------------------------------------

/** 造一个假 req，只带 headers。 */
function fakeReq(cookie) {
  return { headers: cookie ? { cookie } : {} };
}

test('resolveWebIdentity：有 Cookie 时用它，不回 URL token', () => {
  const db = setup();
  const { token } = issueWebToken(db, 'fam1', 'm1', NOW);
  const { ticket } = exchangeTokenForTicket(db, token, NOW);

  const r = resolveWebIdentity(db, fakeReq(`${WEB_COOKIE_NAME}=${ticket}`), token, NOW + 1);
  assert.equal(r.identity?.memberId, 'm1');
  assert.equal(r.freshTicket, null, '已有 Cookie 不该再发一张票');
});

test('resolveWebIdentity：Cookie 无效但 URL token 有效 → 换票成功', () => {
  // 这正是"重新生成链接后，浏览器里还留着旧 Cookie"的场景。
  const db = setup();
  issueWebToken(db, 'fam1', 'm1', NOW);
  const fresh = issueWebToken(db, 'fam1', 'm1', NOW + 1);

  const r = resolveWebIdentity(
    db,
    fakeReq(`${WEB_COOKIE_NAME}=stale-ticket-from-old-link`),
    fresh.token,
    NOW + 2,
  );
  assert.equal(r.identity?.memberId, 'm1');
  assert.ok(r.freshTicket, '应该发一张新票覆盖旧 Cookie');
});

test('resolveWebIdentity：都没有 → identity null', () => {
  const db = setup();
  const r = resolveWebIdentity(db, fakeReq(), null, NOW);
  assert.equal(r.identity, null);
  assert.equal(r.freshTicket, null);
});

test('resolveWebIdentity：URL token 不对 → identity null，不抛', () => {
  const db = setup();
  const r = resolveWebIdentity(db, fakeReq(), 'bogus-token-value-here', NOW);
  assert.equal(r.identity, null);
});
