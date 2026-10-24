/**
 * HTTP 层：极小的路由 + 请求体解析 + 统一错误。
 *
 * **零依赖**是刻意的。整个服务只有 7 条路由，40 行分发比引一个框架
 * 更少出错，也不会因为某个包停更而卡住。代价是得自己处理 JSON 解析
 * 和错误码——但这正好逼着我们把"错误是什么"想清楚。
 */

import { createServer } from 'node:http';

import { redactRequest } from './redact.mjs';

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
 * 请求方是不是"浏览器地址栏/页面导航"。
 *
 * 判据用 `Accept` 里有没有 `text/html`，不用 User-Agent：
 * UA 谁都能改、且各家格式千奇百怪；`Accept` 是内容协商的正规机制，
 * `fetch()` 默认发的是通配的 `Accept`，浏览器导航必然带 `text/html`。
 *
 * POST/PUT 一律不算：那是程序在调接口，给 HTML 只会让它解析失败。
 */
function wantsHtml(req) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return false;
  const accept = String(req.headers.accept ?? '');
  return accept.includes('text/html');
}

/**
 * 浏览器地址打错时的 404 页面。
 *
 * 三条规矩：
 * - **状态码必须还是 404**，不能为了"好看"改成 200（会被搜索引擎收录成一个正常页面）。
 * - 文案里不出现路径、接口名、内部代号：这些等于把实现细节告诉对方。
 * - 页面上只有一个"回成员页"的链接，把人送到 `/m/`。
 */
function sendHtml404(res) {
  const html = `<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>没有这个页面</title>
<style>
  html, body { margin: 0; height: 100%; }
  body {
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    gap: 1.25rem; padding: 2rem; box-sizing: border-box;
    font: 1.125rem/1.6 system-ui, -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    background: #faf9f6; color: #2c2a26; text-align: center;
  }
  h1 { margin: 0; font-size: 1.5rem; font-weight: 600; }
  p { margin: 0; color: #6b665e; max-width: 22em; }
  a {
    padding: 0.9rem 2rem; border-radius: 999px; background: #3f6b52; color: #fff;
    text-decoration: none; font-size: 1.125rem;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #1c1b19; color: #ece9e3; }
    p { color: #a8a29a; }
    a { background: #6fa383; color: #10201a; }
  }
</style>
<h1>没有这个页面</h1>
<p>地址可能输错了，或者这个链接已经不再使用。</p>
<a href="/m/">回打卡页</a>
</html>
`;
  res.writeHead(404, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': Buffer.byteLength(html),
    'cache-control': 'no-store',
    // 和静态层保持一致：这几条是最低要求，缺一个都可能被嵌走或被嗅探类型。
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  });
  res.end(html);
}

/**
 * 建服务。
 *
 * [routes] 是 `{ 'METHOD /path/pattern': handler }`；路径里 `:name` 段会被
 * 解析进 `params`。handler 签名 `(ctx) => void`，抛 [HttpError] 走统一错误响应。
 *
 * [fallback] 是可选的兜底 handler（静态文件）。**只在一条路由都没匹配上时**调用，
 * 所以它不可能抢走 `/health`、`/sync`、`/m/api/*` 这些接口 —— 接口写错了
 * 依然得到 JSON 错误，不会被一个 404 的 HTML 页面糊弄过去。
 * 路由表里显式注册过的路径走 `405`，也不进 fallback（见下面 `pathExists`）。
 */
export function createHttpServer({ routes, fallback = null, logger = console }) {
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
        // 一行路由都没匹配上时先看 fallback（静态文件）。**放在 405 判断之前**：
        // 静态资源没有"方法不对"这回事 —— `POST /m/app.js` 就是没有，
        // 回 405 会让自动化扫描看出"这条路径确实存在"。
        // 但注意：`/sync` 之类**显式注册过**的路径由 `pathExists` 挡在外面，
        // 它们仍然得到 405，不会被静态层吃掉。
        if (fallback && !pathExists && (req.method === 'GET' || req.method === 'HEAD')) {
          // ⚠️ 这个 `return` 会 return 出**外层的 async 箭头函数**（也就是整个请求
          // 处理器），finally 照样会跑，但下面 catch 里的 `err instanceof HttpError`
          // 分支就再也不会为静态请求执行了。
          //
          // 结果：静态层的 404/401 文案原样发出去了，**可浏览器打错地址时
          // 仍然只能看到一屏 "没有这个文件" 的纯文本**，`sendHtml404` 变成了
          // 一段永远不会被走到的死代码 —— 而"未注册路径返回 JSON 404"的测试
          // 却是绿的（那条测试等的是前面的 `throw new HttpError(404)`）。
          //
          // 正确做法是把结果**带回来**，交给统一的错误出口处理：
          // 静态层只负责"是什么"，怎么写响应由 catch 里那一个地方决定。
          const outcome = await fallback({ req, res, params: {}, url });
          if (outcome === 'not_found') {
            throw new HttpError(404, 'not_found', '没有这个页面');
          }
          return;
        }
        throw pathExists
          ? new HttpError(405, 'method_not_allowed', '方法不对')
          : new HttpError(404, 'not_found', '没有这个接口');
      }
      await matched.handler({ req, res, params, url });
    } catch (err) {
      if (err instanceof HttpError) {
        // 404 且请求方是浏览器（Accept 带 text/html、方法不是 POST）时，
        // 给一段能读的页面而不是一屏 JSON。**状态码不变，永远是 404** ——
        // 降级的只是文案。接口调用方（`fetch()` 默认 `Accept: */*`）
        // 仍然拿到结构化错误，App 的 `error.code` 分流不受影响。
        if (err.status === 404 && wantsHtml(req)) {
          sendHtml404(res);
        } else {
          // 安全头对所有错误响应都要有，不只是走 HTML 的那条路。
          // 少了 `nosniff`，浏览器可以把这个 JSON 当 HTML 渲染 ——
          // 而 404 的文案里如果混进了用户可控内容，那就是 XSS。
          res.setHeader('x-content-type-options', 'nosniff');
          res.setHeader('referrer-policy', 'no-referrer');
          sendJson(res, err.status, {
            ok: false,
            error: { code: err.code, message: err.message, ...err.extra },
          });
        }
      } else {
        // 未预期的异常：日志里留全栈，响应里只给一句人话。
        // 把内部错误原样吐给客户端，等于把实现细节当接口。
        //
        // `headersSent` 要单独判：静态文件已经开始流式下发时出错，
        // 头已经发出去了，再写一次 500 会抛 `ERR_HTTP_HEADERS_SENT`，
        // 把原始错误盖掉，日志里只剩一个 "headers already sent"。
        logger.error?.('[famdaily-sync] 未处理异常', err);
        // 兜底 handler（静态层）自己已经把 404 发出去了。**它不是异常情况**：
        // `/api/nope` 这种打错的地址走的就是这条路。这里如果不管，
        // 会往已经结束的响应上再写一次 500 —— 在 Node 里这是静默失败
        // （不打日志、不抛错），结果是"明明 404 了却报了个没发生的 500"。
        if (res.headersSent || res.writableEnded) {
          if (!res.writableEnded) res.destroy();
        } else {
          sendJson(res, 500, {
            ok: false,
            error: { code: 'internal', message: '服务端出错了' },
          });
        }
      }
    } finally {
      const ms = Date.now() - started;
      // ⚠️ **必须脱敏**。网页端上线后，成员链接 token 就在 pathname 里
      // （`/m/<token>`），原样打日志等于把一份成员链接册子写进日志文件。
      // 早期这里打的是裸 `pathname`，理由只是"调试方便"。
      logger.info?.(
        `${redactRequest(req.method, pathname, url.search)} ${res.statusCode} ${ms}ms`,
      );
    }
  });
}
