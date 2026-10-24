/**
 * 静态文件托管：把 `server/public/` 发给浏览器。
 *
 * ## 为什么自己写，不用 express.static
 *
 * 整个服务零依赖。这一层要的逻辑只有 3 行（拼路径、查存在、读文件），
 * 剩下 90% 的代码都在防三件真实会出事的东西：
 *
 * 1. **路径穿越**：`/m/../../etc/passwd`、`/%2e%2e/%2e%2e/…`、`//etc/passwd`。
 *    光靠 `path.resolve` 之后比前缀还不够 —— 符号链接能绕过它，所以还要看 `realpath`。
 * 2. **把源码发出去**：`server/` 目录就在 `public/` 的上一层，
 *    一个写错的 `..` 就能把 `famdaily.db` 发出去。所以**只认白名单扩展名**，
 *    不认的一律 404（`.db` / `.mjs` / `.env` 全在白名单外）。
 * 3. **头一次打开是旧版本**：HTML 缓存了，用户永远看到上一版。
 *    HTML 必须 `no-cache`，带指纹的静态资源才能长缓存。
 *
 * ## 不做 SPA fallback
 *
 * 找不到就 404。理由是**这个页面没有客户端路由**：
 * 成员页只有一个地址 `/m/`，日期靠 query 参数。加了 fallback，
 * 所有手打错的地址都会返回 200 和一个"看起来正常"的页面，
 * 排查问题时反而看不出哪里错了。
 *
 * ## 这块代码踩过的两个坑（都留在这儿当警示）
 *
 * **坑一：`notFound()` 少了 `return`。** 发出 404 之后没 return，继续往下走，
 * `writeHead(200)` 因为头已发而静默失败，接着 `createReadStream(undefined)`
 * 抛错被上层 catch 成 500。表现是"响应体是 '没有这个文件'，状态码是 500"。
 *
 * **坑二：404 在两层各拼了一次。** 修好坑一之后，静态层自己把 404 发出去了，
 * 于是 http 层里的"浏览器请求给 HTML 404"永远轮不到执行 —— 死代码。
 * 现在统一成：**静态层只返回 `'not_found'` / `'sent'`，怎么写响应由 http 层一处决定。**
 *
 * @module static
 */

import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';

/**
 * 允许对外发的扩展名。
 *
 * **白名单，不是黑名单**。黑名单永远漏：`.db`、`.db-journal`、`.map`、
 * `.bak`、编辑器留下的 `.swp`…… 每见到一个新的就补一条，补不完。
 * 白名单的代价只是"加了新类型的资源要来这里登记一次"，而漏登记的
 * 表现是 404 —— 一眼能看见，不会静默泄露。
 */
const MIME = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.webmanifest', 'application/manifest+json; charset=utf-8'],
  ['.svg', 'image/svg+xml'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'],
  ['.ico', 'image/x-icon'],
  ['.woff2', 'font/woff2'],
  ['.txt', 'text/plain; charset=utf-8'],
]);

/**
 * 安全头。
 *
 * - `default-src 'none'` 起步，只放开自己需要的 —— 比 `'self'` 更严，
 *   因为 `'self'` 允许页面加载自己被托管的任意资源。
 * - `frame-ancestors 'none'`：成员页不该被任何页面嵌进 iframe。
 *   微信、QQ 里的"打开链接"不是 iframe，不受影响。
 * - `referrer no-referrer`：**这条是防 token 外泄的关键**。
 *   地址栏里的 token 已经靠 302 洗掉了，但万一哪天漏了，
 *   `no-referrer` 能保证点出去的外链拿不到它。
 * - 不写 `Cross-Origin-Opener-Policy` 等一堆头：它们对本站没有实际作用，
 *   只会让排查问题时多几个可疑变量。
 */
const SECURITY_HEADERS = {
  'content-security-policy': [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "connect-src 'self'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; '),
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
};

/**
 * 把 URL pathname 变成 `public/` 里的相对路径；不合法则返回 null。
 *
 * 任何一道闸不过都直接 null（调用方回 404，不回 400 ——
 * 400 会告诉攻击者"你这个路径我看懂了，只是不接受"，等于给了一根探针）。
 *
 * ## `..` 只能"校验"，不能"拦截"
 *
 * 第一版写在 `new URL()` 之前就把 `..` 拦下来，结果 `/../public/index.html`
 * 被拒了。看着挺对，其实**那条请求根本没带着 `..` 到达这一层** ——
 * WHATWG URL 解析器自己会先做一次路径归一（`/../public/x` → `/public/x`），
 * 所以这个拦截看起来"生效"，实际上从未被执行过。
 *
 * 更糟的是反过来：`/%2e%2e/index.html` 编码后的 `..` 逃过了 URL 解析器的
 * 归一，到了这里被解码成 `..` —— 于是**最标准的那个攻击 payload 被拒，
 * 而它的未编码形式被放行**。测试里那条 `assert(404)` 是绿的，
 * 只是因为它变成了 200 的 index.html，内容恰好不含 `famdaily` 三个字。
 *
 * 结论：这一层唯一能做的事就是**校验**（挡住未经 URL 解析器归一的形式），
 * 真正的"绝对不许越界"由下面 `realpath` + 前缀比对兜底，那是唯一可靠的。
 */
export function safeRelativePath(pathname) {
  // 1. 先解码。**必须在比对 `..` 之前**：不解码的话 `%2e%2e` 能过第一关。
  //    解码失败（畸形百分号）直接拒。
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }

  // 2. NUL 字节截断：`a.html\0.png` 在有些系统调用里会在 \0 处截断，
  //    于是扩展名白名单看的是 `.png`，实际打开的是 `a.html`。
  if (decoded.includes('\0')) return null;

  // 3. 统一分隔符（Windows 上 `\` 也是分隔符）后查 `..` 段。
  //    查的是**段**而不是子串：`app..js` 这种正常文件名不能误杀。
  const unified = decoded.replace(/\\/g, '/');
  const segments = unified.split('/');
  if (segments.some((seg) => seg === '..')) return null;

  // 4. 前导 `/` 要剥掉，否则 `resolve` 会把它当成绝对路径直接逃出 root。
  //    这里**不做 `normalize`**：正常静态路径里不该有 `./` 或 `a//b`，
  //    有就是有人在试探，交给下面的白名单和 realpath 处理更省事。
  const cleaned = unified.replace(/^\/+/, '');
  if (cleaned === '' || cleaned === '.') return null;

  return cleaned;
}

/**
 * 解析一个相对路径到真实文件，不合法或不存在则返回 null。
 *
 * 这里是**唯一**的越界兜底，所以顺序很重要：
 * 先 `realpath`（跟着软链走到底），再和 root 的真实路径做前缀比对。
 * 只比字符串的话，`public/leak.html` 指向 `../famdaily.db` 完全拦不住。
 */
async function resolveFile(rootAbs, rootsReal, rel) {
  // 依次试每个根：前一个根里没有，就看下一个。
  for (let i = 0; i < rootAbs.length; i += 1) {
    if (rootsReal[i] === null) continue;
    const hit = await resolveOne(rootAbs[i], rootsReal[i], rel);
    if (hit) return hit;
  }
  return null;
}

async function resolveOne(root, rootReal, rel) {
  const target = join(root, rel);

  let real;
  try {
    real = await realpath(target);
  } catch {
    return null;
  }

  if (real !== rootReal && !real.startsWith(rootReal + sep)) {
    return null;
  }

  let st;
  try {
    st = await stat(real);
  } catch {
    return null;
  }
  if (!st.isFile()) return null;

  return { real, st };
}

/** 是不是"根路径"：`/`、`//`、`/.` 都算。 */
function isRootPath(pathname) {
  return /^\/[\/.]*$/.test(pathname);
}

/**
 * 造一个静态文件 handler。
 *
 * @param {object} opts
 * @param {string|string[]} opts.root 允许对外发文件的根（一个或多个绝对路径）
 * @param {(rel: string) => boolean} [opts.shouldHide] 额外屏蔽规则（返回 true 则当不存在）
 */
export async function createStaticHandler({ root, shouldHide = () => false }) {
  // ⚠️ **允许的根不止一个**。
  //
  // 网页端分两半：页面在 `server/public/`，规则模块在 `web/rules/`（那里能
  // 直接 `node --test`，不用构建）。如果只认 public 一个根，就得把 rules
  // 复制一份进来 —— 复制出来的那份一定会和源头分叉，而分叉的表现是
  // "网页算出来的槽位和服务器不一致"，最难查。
  //
  // 所以 `root` 可以是数组。每一层都用自己的 rootReal 做前缀比对，
  // 软链和穿越的防护一点没放松：文件必须落在**某一个**根的**真实路径**下。
  const rootList = (Array.isArray(root) ? root : [root]).map((r) => resolve(r));
  const rootsReal = await Promise.all(
    rootList.map((abs) =>
      realpath(abs).catch(() => {
        // 目录不存在不算致命错误：服务照样能跑，只是那些请求 404。
        // 起服务时 `index.mjs` 会打一行警告。
        return null;
      }),
    ),
  );

  return async function serveStatic(ctx) {
    const { res } = ctx;

    if (rootsReal.every((r) => r === null)) {
      // 交回给 http 层统一出错误响应，不自己拼一段纯文本 ——
      // 浏览器打开时该看到的是能读的页面，不是一行 "静态目录不存在"。
      return 'not_found';
    }

    const rel = safeRelativePath(ctx.url.pathname);
    if (rel === null || shouldHide(rel)) {
      // 根路径 `/` 特殊处理：`safeRelativePath('/')` 是 null（它不是文件），
      // 但 `/` 是成员页最常被打开的地址，必须落到 `index.html`。
      if (rel === null && isRootPath(ctx.url.pathname)) {
        // 继续往下，用空串当相对路径
      } else {
        return 'not_found';
      }
    }

    // 目录索引：`/` → `index.html`，`/sub` → `sub/index.html`。
    //
    // **只认 `index.html` 这一个名字**，不做"列出目录 / 挑第一个文件"。
    // 列目录会把整个产物结构告诉对方；挑第一个文件则是完全不可预测的行为
    // （文件系统顺序），上线后某个真实文件会莫名其妙变成首页。
    const base = rel ?? '';
    const candidates = [base, `${base.replace(/\/+$/, '')}/index.html`];

    let picked = null;
    for (const candidate of candidates) {
      if (candidate === '' || candidate.endsWith('/')) continue;
      // eslint-disable-next-line no-await-in-loop -- 最多两个候选，顺序有意义
      const hit = await resolveFile(rootList, rootsReal, candidate);
      if (hit) {
        picked = hit;
        break;
      }
    }

    if (!picked) {
      return 'not_found';
    }

    const { real, st } = picked;
    const ext = extname(real).toLowerCase();
    const type = MIME.get(ext);
    if (!type) {
      // 不在白名单里：当它不存在。**不能**回 403 ——
      // 403 等于确认"这个文件真的在这，只是不给你"，反而泄露了目录结构。
      return 'not_found';
    }

    const etag = `W/"${st.size.toString(16)}-${Math.trunc(st.mtimeMs).toString(16)}"`;
    const headers = {
      ...SECURITY_HEADERS,
      'content-type': type,
      etag,
      // 一律 `no-cache`（**不是** `no-store`：允许存，但每次要拿 ETag 问一下）。
      //
      // 为什么不做"静态资源长缓存"：这一版前端没做文件名指纹。
      // 长缓存 + 没指纹 = 改了 JS 但老用户永远拿旧的，而且**重装都救不回来**。
      // 成员页只有一个 HTML + 一两个 JS，体积按 KB 算，
      // 省下的那点流量远不值这个坑。等以后加了指纹再按扩展名放开。
      'cache-control': 'no-cache',
    };

    // 条件请求：ETag 对上就 304，省掉整个文件的传输。
    const ifNoneMatch = ctx.req.headers['if-none-match'];
    if (ifNoneMatch && ifNoneMatch === etag) {
      res.writeHead(304, headers);
      // 304 **必须** `end()`。少了这一行响应不会结束，浏览器永远转圈，
      // 而 Node 的 http server 有 keep-alive 连接时 close() 也会一直等 ——
      // 表现不是"页面白屏"，而是"测试进程不退出"。
      res.end();
      return;
    }

    headers['content-length'] = st.size;
    // HEAD 只要头，不要体。
    if (ctx.req.method === 'HEAD') {
      res.writeHead(200, headers);
      res.end();
      return;
    }

    res.writeHead(200, headers);
    const stream = createReadStream(real);
    stream.on('error', () => {
      // 已经发了头，改不成 500 了；只能断开，让浏览器看到传输中断。
      res.destroy();
    });
    stream.pipe(res);
    return 'sent';
  };
}

