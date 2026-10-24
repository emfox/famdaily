/**
 * 入口：装配依赖、注册路由、起服务。
 *
 * 启动时打一行「listening on :PORT, db=/abs/path, families=N」。
 * 这行不是为了好看：沙箱重发后"数据不见了"的第一嫌疑就是
 * 数据库路径换成了另一处，而这行是唯一能一眼看出来的地方。
 */

import { resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { openDb, createServerClock } from './src/db.mjs';
import { createHttpServer, sendJson, readJson, HttpError } from './src/http.mjs';
import { createStaticHandler } from './src/static.mjs';
import { createLimiters } from './src/limits.mjs';
import { extractToken } from './src/auth.mjs';
import {
  handlePairNew,
  handlePairPreview,
  handlePairClaim,
  handlePairRotate,
  handlePairCode,
  resolveDevice,
} from './src/pair.mjs';
import { createSyncHandler } from './src/sync.mjs';
import { handleMemberLink, handleMemberUnlink } from './src/web_link.mjs';
import { handleToday, handleCheckin } from './src/web_api.mjs';
import {
  WEB_TICKET_TTL_MS,
  buildClearCookie,
  buildSetCookie,
  isHttps,
  resolveWebIdentity,
} from './src/web_auth.mjs';

/**
 * 数据库路径**必须是绝对路径**。
 *
 * 默认落在 `server/data/famdaily.db`（用本文件位置推算，而不是 cwd）——
 * 沙箱重发可能换工作目录，相对路径会把数据库丢到某个临时目录里，
 * 表现就是"发布之后家里的数据全空了"，而且旧的还在磁盘某个角落躺着。
 */
export function defaultDbPath() {
  const here = new URL('.', import.meta.url).pathname;
  return resolve(here, 'data', 'famdaily.db');
}

/**
 * 静态产物目录：`server/public/`。
 *
 * 同样按**本文件位置**推算，不看 cwd —— 沙箱重发可能换工作目录。
 * 网页端产物是 `web/` 下的源码，构建时拷进这里（或直接放源文件），
 * 两者都不该跟着 cwd 漂。
 */
export function defaultPublicDir() {
  const here = new URL('.', import.meta.url).pathname;
  return resolve(here, 'public');
}

/**
 * 装配一个服务实例。测试也走这个函数，**不另写一份**——
 * "测试验证的是假实现"是前几轮最大的返工来源。
 */
export function createApp({
  dbPath = process.env.FAMDAILY_DB ?? defaultDbPath(),
  pairSecret = process.env.FAMDAILY_PAIR_SECRET ?? '',
  publicDir = process.env.FAMDAILY_PUBLIC ?? defaultPublicDir(),
  logger = console,
  clock = Date.now,
} = {}) {
  const db = openDb(dbPath);
  const serverClock = createServerClock(db);
  const limiters = createLimiters({ clock });

  const deps = { db, clock: serverClock, limiters, config: { pairSecret }, logger };

  const syncHandler = createSyncHandler(deps);

  /** 需要 Bearer 的 handler 统一在这里解析设备身份。 */
  const authed = (handler) => (ctx) => {
    const token = extractToken(ctx.req);
    ctx.device = resolveDevice(db, token);
    if (!ctx.device && !handler.allowAnonymous) {
      throw new HttpError(401, 'unauthorized', '配对已失效，请重新配对');
    }
    return handler(ctx);
  };

  /**
   * 成员页的鉴权：Cookie 里的 ticket 优先，`?t=` 兜底。
   *
   * 两种凭据**互不通用**（见 `web_auth.mjs` 的"两套凭据硬隔离"），
   * 所以这里不碰 `resolveDevice`，也不碰 Authorization 头。
   */
  const memberAuthed = (handler) => (ctx) => {
    const { identity, freshTicket } = resolveWebIdentity(
      db,
      ctx.req,
      ctx.url.searchParams.get('t'),
      Date.now(),
    );
    ctx.identity = identity;
    if (freshTicket) {
      // Cookie 要在这里落，否则下一次请求又得靠 URL。
      ctx.res.setHeader(
        'set-cookie',
        buildSetCookie({
          ticket: freshTicket.ticket,
          maxAgeSec: Math.floor((freshTicket.expiresAtMs - Date.now()) / 1000),
          secure: isHttps(ctx.req),
        }),
      );
    }
    return handler(ctx);
  };

  const routes = {
    'GET /health': ({ res }) =>
      sendJson(res, 200, {
        ok: true,
        service: 'famdaily-sync',
        version: 1,
        families: db.prepare('SELECT count(*) AS n FROM families').get().n,
        // 服务端时钟：客户端可以据此判断"是不是我校准错了"。
        cursor: serverClock.peek(),
        nowMs: Date.now(),
        pairEnabled: pairSecret !== '',
      }),

    'POST /pair/new': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      sendJson(ctx.res, 200, handlePairNew(ctx, deps));
    },

    'GET /pair/:code': (ctx) => {
      sendJson(ctx.res, 200, handlePairPreview(ctx, deps));
    },

    'POST /pair/claim': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      sendJson(ctx.res, 200, handlePairClaim(ctx, deps));
    },

    // 先解析再鉴权：`/sync` / `rotate` 都是 Bearer 接口，客户端发的 JSON
    // 有问题时要报 400 而不是 401 —— 401 会把"字段写错了"误导成"配对丢了"。
    'POST /pair/code': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      authed((c) => {
        sendJson(c.res, 200, handlePairCode(c, deps));
      })(ctx);
    },
    'POST /pair/rotate': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      authed((c) => {
        sendJson(c.res, 200, handlePairRotate(c, deps));
      })(ctx);
    },
    'POST /sync': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      authed((c) => {
        sendJson(c.res, 200, syncHandler(c));
      })(ctx);
    },

    // ---- 成员链接（App 侧，走设备 Bearer）----
    //
    // 路径用 `/members/:id/link` 而不是 `/link/new?member=`：
    // 成员 id 是路径的一部分，URL 本身就是完整意图，日志里一眼能看出
    // "谁被发了链接"。（token 不在这里，它由响应体返回。）
    'POST /members/:id/link': (ctx) => {
      authed((c) => {
        sendJson(c.res, 200, handleMemberLink(c, deps));
      })(ctx);
    },
    'POST /members/:id/unlink': (ctx) => {
      authed((c) => {
        sendJson(c.res, 200, handleMemberUnlink(c, deps));
      })(ctx);
    },

    // ---- 成员页（走 URL token / Cookie，不走 Bearer）----
    //
    // `/m/api/*` 用 `memberAuthed`：它认 Cookie 里的 ticket，也认 `?t=`
    // （用于"链接第一次打开、Cookie 还没落地"的极端情况）。
    'GET /m/api/today': (ctx) => {
      memberAuthed((c) => {
        sendJson(c.res, 200, handleToday(c, deps));
      })(ctx);
    },
    'POST /m/api/checkin': async (ctx) => {
      ctx.body = await readJson(ctx.req);
      memberAuthed((c) => {
        sendJson(c.res, 200, handleCheckin(c, deps));
      })(ctx);
    },

    // 成员页入口：`/m/<token>`。
    //
    // 拿到 token 就换票、落 Cookie，然后**重定向到不带 token 的地址**。
    // 为什么非要重定向：地址栏里留着 token，用户复制页面地址/截图时
    // 就把它一起带走了。洗一次之后地址栏只剩 `/m/`，靠 Cookie 认人。
    // 用 302 不用 301：301 会被浏览器永久缓存，"作废链接"之后就再也改不回来了。
    'GET /m/:token': (ctx) => {
      const { identity, freshTicket } = resolveWebIdentity(
        db,
        ctx.req,
        ctx.params.token,
        Date.now(),
      );
      if (!identity) {
        // 不区分"不存在"和"已作废"，见 web_auth.mjs 的说明。
        sendJson(ctx.res, 401, {
          ok: false,
          error: {
            code: 'no_identity',
            message: '这个链接无效或已作废，请让家里人重新发一个给你',
          },
        });
        return;
      }
      const headers = { location: '/m/' };
      if (freshTicket) {
        headers['set-cookie'] = buildSetCookie({
          ticket: freshTicket.ticket,
          maxAgeSec: Math.floor((freshTicket.expiresAtMs - Date.now()) / 1000),
          secure: isHttps(ctx.req),
        });
      }
      ctx.res.writeHead(302, headers);
      ctx.res.end();
    },
  };

  const server = createHttpServer({
    routes,
    fallback: createStaticHandler({ root: publicDir }),
    logger,
  });

  return { server, db, deps, publicDir, close: () => db.close() };
}

/** 直接 `node index.mjs` 时起服务。 */
if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8787);
  const app = createApp();
  app.server.listen(port, '0.0.0.0', () => {
    const families = app.db
      .prepare('SELECT count(*) AS n FROM families')
      .get().n;
    const dbPath = process.env.FAMDAILY_DB ?? defaultDbPath();
    console.log(
      `[famdaily-sync] listening on :${port}, db=${resolve(dbPath)}, families=${families}`,
    );
    if (!existsSync(resolve(app.publicDir))) {
      // 不打这一行的话，网页端表现为"接口都通，页面 404"，
      // 而原因（产物没拷进来 / 路径算错了）在这一行里一目了然。
      console.log(
        `[famdaily-sync] 警告：静态目录不存在 ${resolve(app.publicDir)}，网页端会 404（接口不受影响）`,
      );
    }
    if (!process.env.FAMDAILY_PAIR_SECRET) {
      console.log(
        '[famdaily-sync] 警告：没设 FAMDAILY_PAIR_SECRET，/pair/new 会拒绝——已配对的设备照常同步',
      );
    }
  });

  const shutdown = () => {
    console.log('[famdaily-sync] 收到退出信号，关服务');
    app.server.close(() => {
      app.close();
      process.exit(0);
    });
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
