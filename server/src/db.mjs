/**
 * SQLite 层：打开、事务、单调时钟。
 *
 * 用 `node:sqlite`（Node 22 内置，实测 SQLite 3.47.2）而不是 better-sqlite3：
 * 这是家里几个人用的小服务，**少一个原生模块就少一处"换个 Node 版本装不上"**。
 *
 * 建表与加列在 `migrate.mjs`。这里的 [`openDb`] 只管"打开 + 升到最新结构"。
 */

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

import { migrate } from './migrate.mjs';

/**
 * 表结构的三条设计要点（语句在 `migrate.mjs`），都不是随便写的：
 *
 * 1. **`tasks` 对 `members` 的外键是复合 `(family_id, member_id)`**。
 *    只用 `member_id` 的话，A 家的项目能挂到 B 家的成员上——跨家庭串数据，
 *    而且是那种"某天突然发现家里多了个陌生人"的串法。
 * 2. **`checkins` 的主键是 `(family_id, task_id, date, slot_index)`**。
 *    打卡 id 是各端自己生成的 UUID，同一件事在两台手机上 id 不同。
 *    按 id 做主键会让"爸爸勾了、妈妈也勾了"变成两条记录，日历和统计都算两遍。
 *    三元组才是这件事的身份。
 * 3. **每张表都有 `server_at_ms`**，写入时刷新。它是增量拉取的水位，
 *    必须严格单调递增（见 [nextServerAt]）。
 */

/**
 * 打开数据库。
 *
 * 传 `':memory:'` 测试用；否则写文件，且**必须用绝对路径**。
 * 沙箱重发可能换工作目录，相对路径会把数据库丢到某个临时目录里——
 * "沙箱数据没有备份承诺"这条风险有一半就是这么来的。
 */
export function openDb(path) {
  if (path !== ':memory:') {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new DatabaseSync(path);
  // WAL 和外键是连接级开关，每次连接都要设，不归迁移管。
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
  `);
  migrate(db);
  return db;
}

/**
 * 下一个 `server_at_ms`：严格单调递增。
 *
 * **不能直接用 `Date.now()`**：同一毫秒内写两行，两行的 `server_at_ms`
 * 相等，而客户端拉取条件是 `> cursor` —— 后一行会被永久漏掉，
 * 表现为"偶尔少一条打卡，重启也没用"。
 *
 * 做法：记住本进程写过的最大值，每次取 `max(now, last + 1)`。
 * 进程重启后从库里读一次真实的 `max(server_at_ms)` 接上，所以重启也不会倒退。
 */
export function createServerClock(db) {
  let last = 0;
  const row = db
    .prepare(
      `SELECT max(m) AS m FROM (
         SELECT max(server_at_ms) AS m FROM members
         UNION ALL SELECT max(server_at_ms) FROM tasks
         UNION ALL SELECT max(server_at_ms) FROM checkins
         UNION ALL SELECT max(server_at_ms) FROM settings
       )`,
    )
    .get();
  if (row && typeof row.m === 'number') {
    last = row.m;
  }

  return {
    next() {
      const now = Date.now();
      // **必须严格大于 `last`**，不能是 `>=`。
      //
      // 守卫条件以前写的是 `now > last ? now : last + 1`，看起来没问题，
      // 但它把"同一毫秒内还有别人写"这件事漏掉了：本进程发一个号给 A，
      // 另一个进程（或另一个服务实例指向同一个库）在同一毫秒自己写了
      // `server_at_ms = now`，本进程的 `last` 根本不知道。
      // 结果是两行拿到同一个时间戳，而拉取条件是 `server_at_ms > since` ——
      // 同号的第二行永远拉不到。
      //
      // 踩到的正是这个：端到端测试跑在测试进程里，服务端在另一个进程，
      // 客户端在"同一毫秒"推上来的行与服务端自己 next() 出来的墓碑撞号，
      // 症状是"打了个卡，另一台手机拉下来是已撤销"。
      last = now > last + 1 ? now : last + 1;
      return last;
    },
    peek() {
      return last;
    },
  };
}

/**
 * 在一个 `BEGIN IMMEDIATE` 事务里跑 [fn]。
 *
 * 用 `IMMEDIATE` 而不是默认的 `DEFERRED`：两台设备同时推时，
 * `DEFERRED` 会先读到彼此未提交的半个结果再在提交时撞锁报错，
 * `IMMEDIATE` 一开始就拿写锁，第二个请求排队，读到的一定是完整状态。
 *
 * Node 的 `node:sqlite` 是同步 API，单进程单线程内不会真的并行；
 * 但事务仍然是必须的——一次 `/sync` 里要写十几行，中途失败不能留半截。
 */
export function inTransaction(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const out = fn();
    db.exec('COMMIT');
    return out;
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // 回滚失败（事务已经被 SQLite 自己回滚了）不该盖住原始错误。
    }
    throw err;
  }
}
