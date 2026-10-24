/**
 * 配对：建家庭、预览、换 token、轮换。
 *
 * 配对这件事的**真实使用场景**是：一个人在自己手机上建好家庭，
 * 然后要把另外两三个人的手机接进来。所以设计围绕"怎么把凭据安全地
 * 从 A 手机传到 B 手机"展开：
 *
 * - 不用二维码（要相机权限 + 要画图，收益是省 12 次输入）
 * - 不用账号密码（家人不该为打卡记第二个密码）
 * - 用一个**能念出来**的短码，且**一次性**：念出去、用过就废。
 *
 * 一次性是这里最重要的性质。码会被截图（截图会进相册、进聊天记录），
 * 会被念给家人（可能开着免提）。用完即废，泄露的窗口就只有那几分钟。
 */

import { randomUUID } from 'node:crypto';
import { HttpError } from './http.mjs';
import {
  assertAllowed,
  generatePairCode,
  generateToken,
  hashPairCode,
  hashToken,
  normalizePairCode,
  safeEqualHex,
} from './auth.mjs';

/** 同步码有效期。10 分钟：够走到另一个房间，不够挂到明天。 */
export const PAIR_CODE_TTL_MS = 10 * 60 * 1000;

/** 单个家庭同时有效的码上限。多换几次不该把旧码全留着。 */
const MAX_LIVE_CODES = 5;

/**
 * `POST /pair/new`：建一个家庭，发一个同步码。
 *
 * 用 `X-Pair-Secret` 口令保护：这个接口能让任何人凭空建家庭、
 * 占满磁盘。口令来自环境变量 `FAMDAILY_PAIR_SECRET`；没配就拒绝对外建家庭
 * （但已配对设备的 `/sync` 照常工作——不能因为配错环境变量把全家断了）。
 */
export function handlePairNew(ctx, deps) {
  const { db, clock, config, limiters } = deps;
  const { req } = ctx;

  assertAllowed(
    limiters.pairNew.hit(req.socket?.remoteAddress ?? 'unknown'),
  );

  if (!config.pairSecret) {
    throw new HttpError(
      503,
      'pair_disabled',
      '服务端没配置配对口令，暂时不能新建家庭',
    );
  }
  const given = req.headers['x-pair-secret'];
  if (typeof given !== 'string' || !safeEqualHex(hashToken(given), hashToken(config.pairSecret))) {
    throw new HttpError(403, 'bad_pair_secret', '配对口令不对');
  }

  const familyId = randomUUID();
  const name = typeof ctx.body?.name === 'string' && ctx.body.name.trim() !== ''
    ? ctx.body.name.trim().slice(0, 60)
    : '我的家';
  const now = Date.now();

  const code = generatePairCode();
  const codeHash = hashPairCode(code);

  db.exec('BEGIN IMMEDIATE');
  try {
    db.prepare(
      'INSERT INTO families (id, secret_hash, name, created_at_ms) VALUES (?, ?, ?, ?)',
    ).run(familyId, hashToken(config.pairSecret), name, now);

    // 清掉这个家庭过期的码，再看还剩几个有效的。
    db.prepare(
      'DELETE FROM pair_codes WHERE family_id = ? AND (claimed_at_ms IS NOT NULL OR expires_at_ms <= ?)',
    ).run(familyId, now);
    const live = db
      .prepare('SELECT count(*) AS n FROM pair_codes WHERE family_id = ?')
      .get(familyId).n;
    if (live >= MAX_LIVE_CODES) {
      db.prepare(
        'DELETE FROM pair_codes WHERE family_id = ? AND expires_at_ms <= ?',
      ).run(familyId, now);
    }

    db.prepare(
      'INSERT INTO pair_codes (code_hash, family_id, created_at_ms, expires_at_ms) VALUES (?, ?, ?, ?)',
    ).run(codeHash, familyId, now, now + PAIR_CODE_TTL_MS);
    db.exec('COMMIT');
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // 已回滚
    }
    throw err;
  }

  // 码只在这里出现一次。之后任何接口都不再返回它。
  return {
    ok: true,
    familyId,
    familyName: name,
    code,
    expiresAtMs: now + PAIR_CODE_TTL_MS,
    clock: clock.peek(),
  };
}

/**
 * `GET /pair/:code`：配对前预览。
 *
 * **只回成员名，不回 id、不回 token、不回家庭 id**。
 * 目的是让用户在输入码之后、真正接入之前，能确认一句"没错，这是我家的那几个人"。
 * 顺手多回一个 id，就等于给猜码的人提供了进一步侦察的素材。
 */
export function handlePairPreview(ctx, deps) {
  const { db, limiters } = deps;
  const { params, req } = ctx;

  assertAllowed(limiters.pairPreview.hit(req.socket?.remoteAddress ?? 'unknown'));

  const code = normalizePairCode(params.code);
  if (code === null) {
    throw new HttpError(404, 'bad_code', '同步码格式不对');
  }

  const row = db
    .prepare(
      `SELECT c.family_id, c.expires_at_ms, c.claimed_at_ms, f.name AS family_name
         FROM pair_codes c JOIN families f ON f.id = c.family_id
        WHERE c.code_hash = ?`,
    )
    .get(hashPairCode(code));

  if (!row) {
    throw new HttpError(404, 'bad_code', '同步码不对或已经用过了');
  }
  if (row.claimed_at_ms !== null) {
    throw new HttpError(404, 'code_used', '这个同步码已经用过了');
  }
  if (row.expires_at_ms <= Date.now()) {
    throw new HttpError(410, 'code_expired', '同步码过期了，重新生成一个');
  }

  const members = db
    .prepare(
      `SELECT name, avatar_id FROM members
        WHERE family_id = ? AND deleted_at_ms IS NULL
        ORDER BY sort_order, created_at_ms`,
    )
    .all(row.family_id)
    .map((m) => ({ name: m.name, avatarId: m.avatar_id }));

  return {
    ok: true,
    familyName: row.family_name,
    members,
    expiresAtMs: row.expires_at_ms,
  };
}

/**
 * `POST /pair/claim`：码换 token。
 *
 * 成功后码立刻作废（`claimed_at_ms`），无论这次请求是否被网络切断——
 * 服务端已经认过它了。客户端拿不到 token 就重新生成一个码，这是可接受的：
 * 重生成的成本远低于"一个泄露的码能反复用"的成本。
 */
export function handlePairClaim(ctx, deps) {
  const { db, clock, limiters } = deps;
  const { req, body } = ctx;

  const ip = req.socket?.remoteAddress ?? 'unknown';
  assertAllowed(limiters.pairClaim.hit(ip));

  const code = normalizePairCode(body?.code);
  if (code === null) {
    throw new HttpError(400, 'bad_code', '同步码格式不对');
  }

  const now = Date.now();
  const row = db
    .prepare(
      'SELECT family_id, expires_at_ms, claimed_at_ms FROM pair_codes WHERE code_hash = ?',
    )
    .get(hashPairCode(code));

  if (!row) {
    throw new HttpError(404, 'bad_code', '同步码不对或已经用过了');
  }
  if (row.claimed_at_ms !== null) {
    throw new HttpError(409, 'code_used', '这个同步码已经用过了，重新生成一个');
  }
  if (row.expires_at_ms <= now) {
    throw new HttpError(410, 'code_expired', '同步码过期了，重新生成一个');
  }

  const token = generateToken();
  const deviceId = randomUUID();
  const label =
    typeof body?.deviceLabel === 'string' ? body.deviceLabel.slice(0, 60) : null;

  db.exec('BEGIN IMMEDIATE');
  try {
    // 先占坑：`claimed_at_ms IS NULL` 放进 WHERE，两个请求同时来只有一个能成功。
    const claim = db
      .prepare(
        'UPDATE pair_codes SET claimed_at_ms = ? WHERE code_hash = ? AND claimed_at_ms IS NULL',
      )
      .run(now, hashPairCode(code));
    if (claim.changes !== 1) {
      throw new HttpError(409, 'code_used', '这个同步码已经用过了，重新生成一个');
    }
    db.prepare(
      'INSERT INTO devices (id, family_id, token_hash, label, created_at_ms) VALUES (?, ?, ?, ?, ?)',
    ).run(deviceId, row.family_id, hashToken(token), label, now);
    db.exec('COMMIT');
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // 已回滚
    }
    throw err;
  }

  limiters.pairClaim.reset(ip);

  return {
    ok: true,
    token,
    deviceId,
    familyId: row.family_id,
    clock: clock.peek(),
  };
}

/**
 * `POST /pair/rotate`：轮换 token，旧的全部失效。
 *
 * "手机丢了"的应急出口。**旧 token 全失效**而不是只加一个：
 * 用户点这个按钮时的心态是"我不能确定还有谁拿着它"，只加不减解决不了这个不安。
 */
export function handlePairRotate(ctx, deps) {
  const { db, device } = deps;
  if (!device) {
    throw new HttpError(401, 'unauthorized', '需要先配对');
  }

  const token = generateToken();
  const now = Date.now();

  db.exec('BEGIN IMMEDIATE');
  try {
    db.prepare('UPDATE devices SET token_hash = ? WHERE id = ?').run(
      hashToken(token),
      device.deviceId,
    );
    db.prepare(
      'DELETE FROM devices WHERE family_id = ? AND id <> ?',
    ).run(device.familyId, device.deviceId);
    db.exec('COMMIT');
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // 已回滚
    }
    throw err;
  }

  return { ok: true, token, deviceId: device.deviceId, familyId: device.familyId, clock: now };
}

/**
 * 校验 Bearer token，返回 `{ deviceId, familyId }`；不通过返回 null。
 *
 * 顺手更新 `last_seen_ms`——"哪个设备多久没同步了"是排查
 * "妈妈手机上的打卡怎么没过来"时唯一有用的线索。
 */
export function resolveDevice(db, token) {
  if (typeof token !== 'string' || token === '') return null;
  const hash = hashToken(token);
  const row = db
    .prepare('SELECT id, family_id FROM devices WHERE token_hash = ?')
    .get(hash);
  if (!row) return null;
  db.prepare('UPDATE devices SET last_seen_ms = ? WHERE id = ?').run(
    Date.now(),
    row.id,
  );
  return { deviceId: row.id, familyId: row.family_id };
}
