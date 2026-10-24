/**
 * SQLite 层：建表、打开、事务、单调时钟。
 *
 * 用 `node:sqlite`（Node 22 内置，实测 SQLite 3.47.2）而不是 better-sqlite3：
 * 这是家里几个人用的小服务，**少一个原生模块就少一处"换个 Node 版本装不上"**。
 */

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

/**
 * 建表语句。
 *
 * 三条设计要点，都不是随便写的：
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
const SCHEMA = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS families (
  id            TEXT PRIMARY KEY,
  secret_hash   TEXT NOT NULL,
  name          TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL
);

-- 一台设备一条。token 只存 sha256，明文只在发出去那一次存在过。
CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  family_id     TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  token_hash    TEXT NOT NULL UNIQUE,
  label         TEXT,
  created_at_ms INTEGER NOT NULL,
  last_seen_ms  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_devices_family ON devices(family_id);

-- 配对码：一次性、有有效期。存哈希不存明文。
CREATE TABLE IF NOT EXISTS pair_codes (
  code_hash     TEXT PRIMARY KEY,
  family_id     TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  created_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  claimed_at_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_pair_codes_family ON pair_codes(family_id);

CREATE TABLE IF NOT EXISTS members (
  family_id         TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  id                TEXT NOT NULL,
  name              TEXT NOT NULL,
  avatar_id         TEXT,
  sort_order        INTEGER NOT NULL DEFAULT 0,
  created_at_ms     INTEGER NOT NULL,
  updated_at_ms     INTEGER NOT NULL,
  deleted_at_ms     INTEGER,
  server_at_ms      INTEGER NOT NULL,
  PRIMARY KEY (family_id, id)
);
CREATE INDEX IF NOT EXISTS idx_members_family_server ON members(family_id, server_at_ms);

CREATE TABLE IF NOT EXISTS tasks (
  family_id           TEXT NOT NULL,
  id                  TEXT NOT NULL,
  member_id           TEXT NOT NULL,
  name                TEXT NOT NULL,
  note                TEXT,
  icon_id             TEXT,
  repeat_json         TEXT NOT NULL,
  time_json           TEXT NOT NULL,
  course_start        TEXT,
  course_end          TEXT,
  course_total_days   INTEGER,
  status              TEXT NOT NULL DEFAULT 'active',
  reminder_enabled    INTEGER NOT NULL DEFAULT 1,
  sort_order          INTEGER NOT NULL DEFAULT 0,
  rules_effective_from TEXT,
  created_at_ms       INTEGER NOT NULL,
  updated_at_ms       INTEGER NOT NULL,
  deleted_at_ms       INTEGER,
  server_at_ms        INTEGER NOT NULL,
  PRIMARY KEY (family_id, id),
  -- 复合外键：项目只能挂在**同一家庭**的成员上。
  FOREIGN KEY (family_id, member_id) REFERENCES members(family_id, id)
);
CREATE INDEX IF NOT EXISTS idx_tasks_family_server ON tasks(family_id, server_at_ms);

-- 打卡。deleted=1 是"墓碑"：客户端推的是全量当前状态，本地没有这条
-- 就等于"想删"，但服务端得留个记号，否则拉取端无法区分
-- "作者撤销了"和"这条还没同步给我"。
CREATE TABLE IF NOT EXISTS checkins (
  family_id           TEXT NOT NULL,
  task_id             TEXT NOT NULL,
  date                TEXT NOT NULL,
  slot_index          INTEGER NOT NULL,
  state               TEXT NOT NULL,
  done_at_ms          INTEGER,
  due_at_minute_of_day INTEGER,
  note                TEXT,
  deleted             INTEGER NOT NULL DEFAULT 0,
  deleted_at_ms       INTEGER,
  created_at_ms       INTEGER NOT NULL,
  updated_at_ms       INTEGER NOT NULL,
  server_at_ms        INTEGER NOT NULL,
  PRIMARY KEY (family_id, task_id, date, slot_index),
  FOREIGN KEY (family_id, task_id) REFERENCES tasks(family_id, id)
);
CREATE INDEX IF NOT EXISTS idx_checkins_family_server ON checkins(family_id, server_at_ms);

CREATE TABLE IF NOT EXISTS settings (
  family_id     TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  key           TEXT NOT NULL,
  value         TEXT NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  server_at_ms  INTEGER NOT NULL,
  PRIMARY KEY (family_id, key)
);
CREATE INDEX IF NOT EXISTS idx_settings_family_server ON settings(family_id, server_at_ms);
`;

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
  db.exec(SCHEMA);
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
      last = now > last ? now : last + 1;
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
