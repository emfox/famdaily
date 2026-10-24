/**
 * 入口：装配依赖、注册路由、起服务。
 *
 * 启动时打一行「listening on :PORT, db=/abs/path, families=N」。
 * 这行不是为了好看：沙箱重发后"数据不见了"的第一嫌疑就是
 * 数据库路径换成了另一处，而这行是唯一能一眼看出来的地方。
 */

import { resolve } from 'node:path';
import { openDb, createServerClock } from './src/db.mjs';
import { createHttpServer, sendJson, readJson, HttpError } from './src/http.mjs';
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
 * 装配一个服务实例。测试也走这个函数，**不另写一份**——
 * "测试验证的是假实现"是前几轮最大的返工来源。
 */
export function createApp({
  dbPath = process.env.FAMDAILY_DB ?? defaultDbPath(),
  pairSecret = process.env.FAMDAILY_PAIR_SECRET ?? '',
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
  };

  const server = createHttpServer({ routes, logger });

  return { server, db, deps, close: () => db.close() };
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
