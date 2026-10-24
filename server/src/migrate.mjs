/**
 * 数据库迁移。
 *
 * 为什么要有这个东西：`openDb()` 原来是"`CREATE TABLE IF NOT EXISTS` 一把梭"，
 * 建表能建，**加列不能加**。`IF NOT EXISTS` 对已存在的表视而不见，所以
 * 往 `SCHEMA` 里加一列，老库照样是旧结构，然后查那一列就报
 * `no such column` —— 而且是启动后才炸，日志里只有一行看不懂的 SQLite 错误。
 *
 * 用 `PRAGMA user_version` 记版本号：它是 SQLite 自带的 4 字节整形，
 * 不额外建表、不占命名空间。每条迁移是一个独立事务，**失败即回滚，
 * 版本号不前进**，下次启动会重试同一条。
 *
 * 约定：
 * - `MIGRATIONS[i]` 把库从版本 `i` 升到 `i + 1`。
 * - 迁移里**不许**用 `IF NOT EXISTS` 图省事。漏建一张表比报错更难查。
 * - 改完 `MIGRATIONS` 之后，`SCHEMA_VERSION` 必须是 `MIGRATIONS.length`。
 *
 * 老库（v0，`SCHEMA` 建出来的那种）走 `MIGRATIONS[0]`，它就是
 * `SCHEMA` 的等价物；但**为了不破坏"已有数据"**，v0 → v1 用的是
 * `IF NOT EXISTS` 形态（见 `LEGACY_SCHEMA`），因为 v0 的库可能已经全建好了，
 * 也可能是个半截库。
 */

/** 一条迁移：接收 db，把结构往前推一版。 */
export const MIGRATIONS = [
  // v0 → v1：初始结构。等价于老版本的 SCHEMA。
  // 这一条**必须**保持 IF NOT EXISTS：v0 的库可能已经是完整的。
  (db) => {
    db.exec(LEGACY_SCHEMA);
  },

  // v1 → v2：成员链接。
  //
  // `members` 加两列而不是新建一张关联表，理由：一个成员最多一条有效链接，
  // 一一对应，单开一张表只会多一次 join 和多一处"两条链接同时有效"的歧义。
  //
  // `web_token_hash` 存哈希不存明文，和设备 token 一个规矩。
  // 前缀不同（`web:` vs `token:`）是硬隔离：把成员 token 塞进 Authorization
  // 头也查不到设备，反之亦然。
  (db) => {
    db.exec(`
      ALTER TABLE members ADD COLUMN web_token_hash TEXT;
      ALTER TABLE members ADD COLUMN web_token_issued_at_ms INTEGER;
      CREATE UNIQUE INDEX idx_members_web_token
        ON members(web_token_hash) WHERE web_token_hash IS NOT NULL;
    `);
    db.exec(WEB_TICKETS_SCHEMA);
  },
];

/** 当前结构版本。等于 `MIGRATIONS.length`。 */
export const SCHEMA_VERSION = MIGRATIONS.length;

/**
 * 把 URL 里的成员 token 换成一个短命 cookie 的凭据。
 *
 * 为什么需要这层：成员链接的 token 必须出现在 URL 里（成员不会去登录），
 * 但 URL 会被浏览器历史、Referer、聊天记录、截图带走。换一次 ticket 之后，
 * 后续请求只认 Cookie，URL 里那段就退化成"目录名"，摘掉也不影响已登录的页面。
 *
 * **为什么不直接存 `members.web_token_hash` 就完事**：那样每次请求都得带着
 * 明文 token，等于把凭据永久钉在地址栏上。ticket 是可以单独作废的一层。
 */
export const WEB_TICKETS_SCHEMA = `
CREATE TABLE IF NOT EXISTS web_tickets (
  ticket_hash   TEXT PRIMARY KEY,
  family_id     TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  member_id     TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  last_seen_ms  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_web_tickets_expiry ON web_tickets(expires_at_ms);
`;

/**
 * v0 的建表语句（历史包袱，只为迁移服务）。
 *
 * 和 `db.mjs` 里当年的 `SCHEMA` 逐字一致 —— 改这里等于改历史，
 * 会让已经升到 v1 的库和新建的库结构不一致。**不要动。**
 */
export const LEGACY_SCHEMA = `
CREATE TABLE IF NOT EXISTS families (
  id            TEXT PRIMARY KEY,
  secret_hash   TEXT NOT NULL,
  name          TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  family_id     TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  token_hash    TEXT NOT NULL UNIQUE,
  label         TEXT,
  created_at_ms INTEGER NOT NULL,
  last_seen_ms  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_devices_family ON devices(family_id);

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
  FOREIGN KEY (family_id, member_id) REFERENCES members(family_id, id)
);
CREATE INDEX IF NOT EXISTS idx_tasks_family_server ON tasks(family_id, server_at_ms);

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
 * 读当前版本。
 *
 * `PRAGMA user_version` 不能用参数绑定，只能拼字符串 —— 好在读的时候不用拼。
 */
export function readVersion(db) {
  const row = db.prepare('PRAGMA user_version').get();
  // node:sqlite 返回的键名是 `user_version`
  const v = row?.user_version ?? 0;
  return Number.isInteger(v) ? v : 0;
}

function writeVersion(db, v) {
  // 拼进 SQL 而不是绑定：PRAGMA 不支持 `= ?`。
  // `v` 来自本模块内部的整数，不接受外部输入。
  db.exec(`PRAGMA user_version = ${Math.trunc(v)}`);
}

/**
 * 把库升到最新版本。已经是新版就什么都不做（幂等）。
 *
 * 每条迁移单独一个事务：中途失败时只回滚这一条，版本号也停在这一条之前。
 * 用 `BEGIN IMMEDIATE` 而不是普通 `BEGIN`：多个进程同时启动时，
 * 后到的那个会在拿写锁时等着，而不是各自读到同一个版本号、然后一起改结构。
 *
 * @returns {number} 迁移后的版本
 */
export function migrate(db, migrations = MIGRATIONS) {
  let version = readVersion(db);
  if (version > migrations.length) {
    // 库比代码新。多半是"用旧代码连了新库"，继续跑会写出结构不一致的数据。
    throw new Error(
      `数据库版本 ${version} 比代码支持的 ${migrations.length} 还新：` +
        '你是不是在用旧版本的服务端连新库？',
    );
  }
  while (version < migrations.length) {
    const step = migrations[version];
    db.exec('BEGIN IMMEDIATE');
    try {
      step(db);
      writeVersion(db, version + 1);
      db.exec('COMMIT');
    } catch (err) {
      try {
        db.exec('ROLLBACK');
      } catch {
        // 已经回滚过了
      }
      throw new Error(`迁移到 v${version + 1} 失败：${err.message}`, { cause: err });
    }
    version += 1;
  }
  return version;
}
