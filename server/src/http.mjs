/**
 * HTTP 层：极小的路由 + 请求体解析 + 统一错误。
 *
 * **零依赖**是刻意的。整个服务只有 7 条路由，40 行分发比引一个框架
 * 更少出错，也不会因为某个包停更而卡住。代价是得自己处理 JSON 解析
 * 和错误码——但这正好逼着我们把"错误是什么"想清楚。
 */

import { createServer } from 'node:http';

/** 请求体上限。全量推送在家庭规模下约 150KB，8MB 是有余量的兜底。 */
export const MAX_BODY_BYTES = 8 * 1024 * 1024;

/** 业务错误。带 HTTP 状态码和机器可读的 `code`，客户端按 code 分类处理。 */
export class HttpError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

/** 读请求体，超过 [MAX_BODY_BYTES] 立刻断开——不把内存读爆。 */
export function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    };
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        fail(new HttpError(413, 'body_too_large', '请求体太大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', fail);
  });
}

/** 读 JSON 请求体。解析失败是 400，不是 500——是客户端发错了。 */
export async function readJson(req) {
  const raw = await readBody(req);
  if (raw.trim() === '') return {};
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new HttpError(400, 'bad_json', '请求体不是合法 JSON');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new HttpError(400, 'bad_json', '请求体必须是 JSON 对象');
  }
  return parsed;
}

/** 发 JSON 响应。所有响应都带 `no-store`：这是数据接口，缓存只会帮倒忙。 */
export function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

/**
 * 建服务。
 *
 * [routes] 是 `{ 'METHOD /path/pattern': handler }`；路径里 `:name` 段会被
 * 解析进 `params`。handler 签名 `(ctx) => void`，抛 [HttpError] 走统一错误响应。
 */
export function createHttpServer({ routes, logger = console }) {
  const compiled = Object.entries(routes).map(([key, handler]) => {
    const [method, pattern] = key.split(' ');
    const names = [];
    const regexSource = pattern
      .split('/')
      .map((seg) => {
        if (seg.startsWith(':')) {
          names.push(seg.slice(1));
          return '([^/]+)';
        }
        return seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      })
      .join('/');
    return {
      method,
      regex: new RegExp(`^${regexSource}/?$`),
      names,
      handler,
    };
  });

  return createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url, 'http://internal');
    // 只取 pathname 匹配路由；query 单独交给 handler。
    const pathname = url.pathname;

    let matched = null;
    let params = null;
    let pathExists = false;
    for (const r of compiled) {
      const m = r.regex.exec(pathname);
      if (!m) continue;
      pathExists = true;
      if (r.method !== req.method) continue;
      matched = r;
      params = Object.fromEntries(
        r.names.map((n, i) => [n, decodeURIComponent(m[i + 1])]),
      );
      break;
    }

    try {
      if (!matched) {
        throw pathExists
          ? new HttpError(405, 'method_not_allowed', '方法不对')
          : new HttpError(404, 'not_found', '没有这个接口');
      }
      await matched.handler({ req, res, params, url });
    } catch (err) {
      if (err instanceof HttpError) {
        sendJson(res, err.status, {
          ok: false,
          error: { code: err.code, message: err.message, ...err.extra },
        });
      } else {
        // 未预期的异常：日志里留全栈，响应里只给一句人话。
        // 把内部错误原样吐给客户端，等于把实现细节当接口。
        logger.error?.('[famdaily-sync] 未处理异常', err);
        if (!res.headersSent) {
          sendJson(res, 500, {
            ok: false,
            error: { code: 'internal', message: '服务端出错了' },
          });
        }
      }
    } finally {
      const ms = Date.now() - started;
      logger.info?.(`${req.method} ${pathname} ${res.statusCode} ${ms}ms`);
    }
  });
}
