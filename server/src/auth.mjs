/**
 * 鉴权：口令哈希、同步码、设备 token、限流。
 *
 * 三条底线：
 * 1. **库里不存任何明文凭据**。token 只存 `sha256`，配对码也存哈希。
 *    原因是"沙箱数据文件没有备份承诺"，那至少别让它变成一份密码本。
 * 2. **凭据走 header 不走 URL**。URL 会进日志、进浏览器历史、进 Referer。
 * 3. **token 用定长比较**。虽然本服务的威胁模型很宽松，但 `===` 比字符串
 *    是那种"改了不费事、不改也没人发现"的缺陷，顺手写对。
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { HttpError } from './http.mjs';

/**
 * 同步码的字母表：去掉 `0O1IL`。
 *
 * 这不是审美选择。同步码的**唯一存在理由**是"爸爸能把它念给妈妈听、
 * 妈妈能手输进去"。只要有一个字符在纸上会被认错，这个理由就没了，
 * 一家人就得靠截图互传——而截图会被存进相册，比手输更不安全。
 */
export const CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

/** 同步码分 3 组、每组 4 位，共 12 位 ≈ 59 bit。够念、够难猜。 */
const CODE_GROUPS = 3;
const CODE_GROUP_LEN = 4;

/** 生成一个同步码，形如 `FAM-7K2M-9XQ4-3TBH`。 */
export function generatePairCode() {
  const bytes = randomBytes(CODE_GROUPS * CODE_GROUP_LEN);
  const chars = [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]);
  const groups = [];
  for (let i = 0; i < CODE_GROUPS; i += 1) {
    groups.push(chars.slice(i * CODE_GROUP_LEN, (i + 1) * CODE_GROUP_LEN).join(''));
  }
  return `FAM-${groups.join('-')}`;
}

/**
 * 规范化用户输入的码。
 *
 * **`FAM-` 前缀只用于展示**，不参与校验：真正的码是 12 个字符。
 * 第一版把前缀算进了 12 位里，结果生成的码自己都过不了自己的校验——
 * 这种"写和读各按一套规则算长度"的错，看起来像手残，其实是没把
 * "前缀是装饰"这件事想清楚。
 *
 * 手输一定会带上各种花样：`fam 7k2m 9xq4 3tbh`、`FAM7K2M9XQ43TBH`、
 * 末尾多一个换行。**宽容输入、严格校验**——宽容的是格式，不是判定。
 */
export function normalizePairCode(raw) {
  if (typeof raw !== 'string') return null;
  let body = raw.toUpperCase().replace(/[^0-9A-Z]/g, '');
  if (body.startsWith('FAM')) body = body.slice(3);

  const expected = CODE_GROUPS * CODE_GROUP_LEN;
  if (body.length !== expected) return null;
  // 逐字符确认都在字母表里。**不做"智能纠错"**（比如把 0 当 O）——
  // 那会把两个不同的码纠成同一个，等于把可以猜的空间缩小一个数量级。
  for (const ch of body) {
    if (!CODE_ALPHABET.includes(ch)) return null;
  }
  const groups = [];
  for (let i = 0; i < CODE_GROUPS; i += 1) {
    groups.push(body.slice(i * CODE_GROUP_LEN, (i + 1) * CODE_GROUP_LEN));
  }
  return `FAM-${groups.join('-')}`;
}

function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

/** 配对码 → 库里存的哈希。 */
export function hashPairCode(code) {
  return sha256Hex(`pair:${code}`);
}

/** 随机 token（32 字节 → base64url，43 字符）。 */
export function generateToken() {
  return randomBytes(32).toString('base64url');
}

/** token → 库里存的哈希。 */
export function hashToken(token) {
  return sha256Hex(`token:${token}`);
}

/** 定长比较两个 hex 摘要。 */
export function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ba = Buffer.from(a, 'hex');
  const bb = Buffer.from(b, 'hex');
  if (ba.length !== bb.length || ba.length === 0) return false;
  return timingSafeEqual(ba, bb);
}

/**
 * 从 `Authorization: Bearer xxx` 里取 token。
 *
 * 同时兼容 `X-Famdaily-Token`：有些 HTTP 客户端/代理对 Authorization
 * 的处理不透明，多一条路少一类"不知道为什么 401"。
 */
export function extractToken(req) {
  const auth = req.headers['authorization'];
  if (typeof auth === 'string') {
    const m = /^Bearer\s+(\S+)$/i.exec(auth.trim());
    if (m) return m[1];
  }
  const alt = req.headers['x-famdaily-token'];
  if (typeof alt === 'string' && alt.trim() !== '') return alt.trim();
  return null;
}

/**
 * 固定窗口限流：内存计数，按 key 分桶。
 *
 * 用固定窗口不用滑动窗口，因为目的不是精确计费，而是"别让人暴力猜码"。
 * 一个 12 位、31 字母表的码暴力猜是不现实的，限流防的是脚本刷和
 * "手误重试 50 次"把日志刷满。
 *
 * **只放内存**：进程重启就清零。这是刻意的——重启后正常用户能立刻重试，
 * 而不是被一个自己都不记得的计数锁在门外。
 */
export function createRateLimiter({ limit, windowMs, clock = Date.now }) {
  const buckets = new Map();

  return {
    /** 记一次，返回 `{ allowed, retryAfterMs }`。 */
    hit(key) {
      const now = clock();
      const bucket = buckets.get(key);
      if (!bucket || now - bucket.start >= windowMs) {
        buckets.set(key, { start: now, count: 1 });
        return { allowed: true, retryAfterMs: 0 };
      }
      bucket.count += 1;
      if (bucket.count > limit) {
        return {
          allowed: false,
          retryAfterMs: windowMs - (now - bucket.start),
        };
      }
      return { allowed: true, retryAfterMs: 0 };
    },
    /** 清空某个 key（成功之后调用，避免"猜对一次也算进配额"）。 */
    reset(key) {
      buckets.delete(key);
    },
    /** 测试用：清空全部。 */
    clear() {
      buckets.clear();
    },
  };
}

/** 取客户端 IP。沙箱端口映射通常会带 `x-forwarded-for`。 */
export function clientIp(req) {
  const fwd = req.headers['x-forwarded-for'];
  if (typeof fwd === 'string' && fwd.trim() !== '') {
    return fwd.split(',')[0].trim();
  }
  return req.socket?.remoteAddress ?? 'unknown';
}

/** 限流不通过 → 抛 429，并告诉客户端多久后能重试。 */
export function assertAllowed(result) {
  if (!result.allowed) {
    throw new HttpError(429, 'rate_limited', '试得太频繁了，等一下再试', {
      retryAfterMs: result.retryAfterMs,
    });
  }
}
