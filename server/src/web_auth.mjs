/**
 * 成员链接：发、校验、作废、换 Cookie。
 *
 * ## 为什么成员链接必须存在
 *
 * 家里不会用 App 的那个人（爷爷、上小学的孩子）不会装 App、不会配对、
 * 更不会记密码。他手上应该只有一样东西：**一个能点开的网址**。
 *
 * 这就是"链接即凭据"——点开就进去了，不用登录。
 *
 * ## 链接里带凭据，所以处处是坑
 *
 * URL 会被带走：浏览器历史、书签、微信聊天记录、截图、Referer 头、
 * 家里的共享电脑。所以做两件事把它**降级**：
 *
 * 1. **换票**：URL 里的 token 只用来换一次短命 ticket（写进 HttpOnly Cookie），
 *    之后所有请求都靠 Cookie。这样即使用户后来把地址栏里那段删了，
 *    页面照样能用；反过来，链接被别人看到，也只有"第一次打开"那一下有效。
 * 2. **Cookie 是 HttpOnly + SameSite=Strict**。HttpOnly 让页面脚本读不到；
 *    Strict 让它不随第三方站点的请求发出去（防 CSRF，也防止有人把成员页
 *    嵌到自己的页面里偷打卡）。
 *
 * ## 两套凭据硬隔离
 *
 * 设备 token 的哈希前缀是 `token:`，成员 token 是 `web:`。同一个字符串
 * 拿去做两种 identity 的哈希，结果一定不同 —— 所以把成员链接塞进
 * `Authorization: Bearer` 也查不到设备，反之亦然。这不是"多加一层保险"，
 * 是本来就该分开的两个东西各自有一套命名空间。
 *
 * @module web_auth
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { HttpError } from './http.mjs';

/** 成员链接 token 的哈希前缀。与设备的 `token:` 刻意不同。 */
const WEB_HASH_PREFIX = 'web:';

/** Cookie 名。带前缀是因为同一域名下可能还跑着别的东西。 */
export const WEB_COOKIE_NAME = 'famdaily_m';

/** ticket 有效期。7 天：够一个不会用手机的老人"点开一次，用一个月"。 */
export const WEB_TICKET_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * ticket 的清理阈值。
 *
 * 过期 ticket 不删也能用（查询时带 `expires_at_ms > now`），但会一直堆着。
 * 每次签发票时顺手清一批**已经过期超过一天**的：留一天是为了让
 * "刚过期"的 ticket 能给出准确错误（"链接过期了"而不是"不存在"）。
 */
const TICKET_SWEEP_GRACE_MS = 24 * 60 * 60 * 1000;

function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

/** 成员 token → 库里存的哈希。 */
export function hashWebToken(token) {
  return sha256Hex(`${WEB_HASH_PREFIX}${token}`);
}

/** 成员 ticket → 库里存的哈希。前缀再分开一层，别和 token 混用同一个空间。 */
export function hashWebTicket(ticket) {
  return sha256Hex(`webticket:${ticket}`);
}

/** 生成一个成员链接 token（32 字节 → base64url，43 字符）。 */
export function generateWebToken() {
  return randomBytes(32).toString('base64url');
}

/** 生成一个 ticket。长度和 token 一样，但它存在 Cookie 里，不进 URL。 */
export function generateWebTicket() {
  return randomBytes(32).toString('base64url');
}

/**
 * 给某个成员发一个新链接 token，返回**明文**（只此一次）。
 *
 * 库里只存哈希，所以明文在这里丢不出去就永远找不回来了 —— 这是故意的：
 * 库文件"没有备份承诺"，不能让它变成一本成员链接册子。
 *
 * 重复签发会**顶掉旧的**（`web_token_hash` 是唯一列，直接覆盖）：
 * 一个成员同时最多一条有效链接。理由和"一个成员最多一条有效同步关系"一样，
 * 多留一条只是多一个能进门的口子。想保留旧链接就别重新生成。
 *
 * @param {import('node:sqlite').DatabaseSync} db
 * @param {string} familyId
 * @param {string} memberId
 * @param {number} nowMs
 * @returns {{ token: string, issuedAtMs: number }}
 */
export function issueWebToken(db, familyId, memberId, nowMs) {
  const member = db
    .prepare(
      'SELECT id, deleted_at_ms FROM members WHERE family_id = ? AND id = ?',
    )
    .get(familyId, memberId);
  if (!member) {
    throw new HttpError(404, 'member_not_found', '没有这个成员');
  }
  if (member.deleted_at_ms != null) {
    // 给已删除的成员发链接等于留一个"幽灵入口"：他点进来什么都看不到，
    // 而家里人以为链接是坏的。直接拒绝，让人先去恢复成员。
    throw new HttpError(409, 'member_deleted', '这个成员已删除，先恢复再发链接');
  }

  const token = generateWebToken();
  db.prepare(
    `UPDATE members SET web_token_hash = ?, web_token_issued_at_ms = ?
     WHERE family_id = ? AND id = ?`,
  ).run(hashWebToken(token), nowMs, familyId, memberId);

  // 换 token 之后旧 ticket 也必须作废，否则"作废链接"是假的：
  // 拿着老 Cookie 的人照样能进。这条不做的话，整个作废功能就是个摆设。
  db.prepare('DELETE FROM web_tickets WHERE family_id = ? AND member_id = ?').run(
    familyId,
    memberId,
  );

  return { token, issuedAtMs: nowMs };
}

/**
 * 作废某个成员的链接。
 *
 * 返回 `{ revoked: boolean }`：本来就没链接时返回 false（不报错）——
 * "关灯"这个动作用在已关的灯上不该失败。
 */
export function revokeWebToken(db, familyId, memberId) {
  const member = db
    .prepare('SELECT id FROM members WHERE family_id = ? AND id = ?')
    .get(familyId, memberId);
  if (!member) {
    throw new HttpError(404, 'member_not_found', '没有这个成员');
  }
  const had = db
    .prepare(
      'SELECT web_token_hash FROM members WHERE family_id = ? AND id = ?',
    )
    .get(familyId, memberId);
  db.prepare(
    'UPDATE members SET web_token_hash = NULL, web_token_issued_at_ms = NULL WHERE family_id = ? AND id = ?',
  ).run(familyId, memberId);
  db.prepare('DELETE FROM web_tickets WHERE family_id = ? AND member_id = ?').run(
    familyId,
    memberId,
  );
  return { revoked: had?.web_token_hash != null };
}

/**
 * 用 URL 里的 token 换一个 ticket。
 *
 * 返回 `{ ticket, expiresAtMs, familyId, memberId, memberName }`；
 * token 不对、成员已删、链接已作废都返回 `null`（**不区分**原因）。
 *
 * 为什么不区分：区分了就等于给攻击者一个"这个 token 存在但过期了"的探针，
 * 可以拿它筛出哪些 token 曾经有效。对外只给一句"链接无效或已作废"。
 */
export function exchangeTokenForTicket(db, token, nowMs) {
  if (typeof token !== 'string' || token === '') return null;

  const row = db
    .prepare(
      `SELECT family_id, id, name, deleted_at_ms
       FROM members WHERE web_token_hash = ?`,
    )
    .get(hashWebToken(token));
  if (!row) return null;
  if (row.deleted_at_ms != null) return null;

  // 顺手清一批早已过期的 ticket。
  db.prepare('DELETE FROM web_tickets WHERE expires_at_ms < ?').run(
    nowMs - TICKET_SWEEP_GRACE_MS,
  );

  const ticket = generateWebTicket();
  const expiresAtMs = nowMs + WEB_TICKET_TTL_MS;
  db.prepare(
    `INSERT INTO web_tickets (ticket_hash, family_id, member_id, created_at_ms, expires_at_ms, last_seen_ms)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    hashWebTicket(ticket),
    row.family_id,
    row.id,
    nowMs,
    expiresAtMs,
    nowMs,
  );

  return {
    ticket,
    expiresAtMs,
    familyId: row.family_id,
    memberId: row.id,
    memberName: row.name,
  };
}

/**
 * 用 Cookie 里的 ticket 认人。
 *
 * 每次都回库查：ticket 是可以被单独作废的（见 [revokeWebToken]），
 * 如果缓存到内存里，作废之后老进程还认，作废就不算数了。
 *
 * 返回 `{ familyId, memberId, memberName }` 或 `null`。
 * 失效的 ticket（过期）会被顺手删掉。
 */
export function resolveWebTicket(db, ticket, nowMs) {
  if (typeof ticket !== 'string' || ticket === '') return null;

  const row = db
    .prepare(
      `SELECT t.family_id, t.member_id, t.expires_at_ms, m.name, m.deleted_at_ms
       FROM web_tickets t
       JOIN members m ON m.family_id = t.family_id AND m.id = t.member_id
       WHERE t.ticket_hash = ?`,
    )
    .get(hashWebTicket(ticket));
  if (!row) return null;

  if (row.expires_at_ms <= nowMs) {
    db.prepare('DELETE FROM web_tickets WHERE ticket_hash = ?').run(
      hashWebTicket(ticket),
    );
    return null;
  }
  // 成员在链接有效期内被删除了 —— 立刻失效，不给"删了还能进"的窗口。
  if (row.deleted_at_ms != null) return null;

  db.prepare('UPDATE web_tickets SET last_seen_ms = ? WHERE ticket_hash = ?').run(
    nowMs,
    hashWebTicket(ticket),
  );

  return {
    familyId: row.family_id,
    memberId: row.member_id,
    memberName: row.name,
  };
}

/**
 * 从请求里取成员身份：Cookie 优先，其次 URL 里的 `?t=`。
 *
 * 返回 `{ identity, freshTicket }`：
 * - 有 Cookie 且有效 → `{ identity, freshTicket: null }`
 * - 只有 URL token → `{ identity, freshTicket: { ticket, expiresAtMs } }`，
 *   调用方要把这个 ticket 写进 Cookie，并**把 URL 里的 token 洗掉**
 *   （用 302 跳到不带 token 的地址，见 `web_page.mjs`）。
 * - 都没有 / 都无效 → `{ identity: null, freshTicket: null }`
 *
 * @param {import('node:sqlite').DatabaseSync} db
 * @param {import('node:http').IncomingMessage} req
 * @param {string|null} urlToken 从 `?t=` 取到的明文 token
 * @param {number} nowMs
 */
export function resolveWebIdentity(db, req, urlToken, nowMs) {
  const cookieTicket = readCookie(req.headers['cookie'], WEB_COOKIE_NAME);
  if (cookieTicket) {
    const identity = resolveWebTicket(db, cookieTicket, nowMs);
    if (identity) return { identity, freshTicket: null };
    // Cookie 无效就继续往下看 URL —— 用户可能就是从一条**新**链接点进来的，
    // 而浏览器里还留着这个成员**旧**的（已作废的）Cookie。
    // 不这么做的话，重新生成链接之后用户永远进不去，只能手动清 Cookie。
  }

  if (urlToken) {
    const exchanged = exchangeTokenForTicket(db, urlToken, nowMs);
    if (exchanged) {
      return {
        identity: {
          familyId: exchanged.familyId,
          memberId: exchanged.memberId,
          memberName: exchanged.memberName,
        },
        freshTicket: {
          ticket: exchanged.ticket,
          expiresAtMs: exchanged.expiresAtMs,
        },
      };
    }
  }

  return { identity: null, freshTicket: null };
}

/** 从 `Cookie` 头里取某个键。解析失败一律当没有。 */
export function readCookie(header, name) {
  if (typeof header !== 'string' || header === '') return null;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    if (part.slice(0, idx).trim() !== name) continue;
    const raw = part.slice(idx + 1).trim();
    try {
      return decodeURIComponent(raw);
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * 拼 `Set-Cookie`。
 *
 * `SameSite=Strict` 而不是 `Lax`：成员页不需要从别的站点跳进来，
 * 而从微信里点链接属于"跨站导航"，`Lax` 会把 Cookie 带过去、`Strict` 不带 ——
 * 这一条直接决定了从聊天里点开链接能不能用。
 *
 * 那为什么还选 Strict？因为**链接第一次打开本来就走 URL 里的 token**，
 * 不依赖 Cookie；Cookie 是从第二次请求开始的。所以 Strict 不影响从微信点进来，
 * 只影响"在微信内置浏览器里已经打开过、又从微信里点第二次"这种边角情形，
 * 而那种情形下 URL 里通常还带着 token（用户是从聊天记录里点的），照样能进。
 *
 * `Secure` 看请求是不是 https：沙箱里可能是 http，写死 Secure 会让 Cookie
 * 被浏览器直接丢弃，症状是"登录了但下一页又让我登录"，极难查。
 */
export function buildSetCookie({ ticket, maxAgeSec, secure }) {
  const parts = [
    `${WEB_COOKIE_NAME}=${encodeURIComponent(ticket)}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Strict',
    `Max-Age=${Math.max(0, Math.trunc(maxAgeSec))}`,
  ];
  if (secure) parts.push('Secure');
  return parts.join('; ');
}

/** 清 Cookie（作废 / 主动退出时用）。 */
export function buildClearCookie({ secure }) {
  return buildSetCookie({ ticket: '', maxAgeSec: 0, secure });
}

/** 请求是不是走的 https（沙箱端口映射会带 `x-forwarded-proto`）。 */
export function isHttps(req) {
  const proto = req.headers['x-forwarded-proto'];
  if (typeof proto === 'string') return proto.split(',')[0].trim() === 'https';
  return Boolean(req.socket?.encrypted);
}

/**
 * 定长比较两个字符串（用于极少数需要比明文的地方）。
 *
 * 成员的 token 比较走哈希查表，本来不需要这个。留着是因为**别处会用到**
 * （将来如果要"用固定口令开一个只读看板"），而"临时写个 `===`"是那种
 * 事后没人回头改的缺陷。
 */
export function safeEqualText(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  if (ba.length !== bb.length || ba.length === 0) return false;
  return timingSafeEqual(ba, bb);
}
