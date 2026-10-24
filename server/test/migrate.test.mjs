import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { migrate, MIGRATIONS, SCHEMA_VERSION, readVersion, LEGACY_SCHEMA } from '../src/migrate.mjs';
import { openDb } from '../src/db.mjs';

/** 一个真实的 v1 库：老结构 + 真实数据，用来验证"老用户升级不丢数据"。 */
function makeLegacyDb() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON');
  // MAX(0, user_version) —— 新建的库是 0，这里显式写 1
  db.exec(LEGACY_SCHEMA);
  db.exec('PRAGMA user_version = 1');

  db.prepare(
    `INSERT INTO families (id, secret_hash, name, created_at_ms) VALUES (?, ?, ?, ?)`,
  ).run('fam1', 'h', '我们家', 1000);
  db.prepare(
    `INSERT INTO devices (id, family_id, token_hash, label, created_at_ms)
     VALUES (?, ?, ?, ?, ?)`,
  ).run('dev1', 'fam1', 'token:abc', 'A', 1000);
  db.prepare(
    `INSERT INTO members (family_id, id, name, avatar_id, sort_order,
                          created_at_ms, updated_at_ms, deleted_at_ms, server_at_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run('fam1', 'm1', '爷爷', 'a1', 0, 1000, 1000, null, 1000);
  return db;
}

test('v1 老库能升到最新，且老数据一行不少', () => {
  const db = makeLegacyDb();
  assert.equal(readVersion(db), 1);

  migrate(db);

  assert.equal(readVersion(db), SCHEMA_VERSION);
  // 老数据完好
  const fam = db.prepare('SELECT name FROM families WHERE id = ?').get('fam1');
  assert.equal(fam.name, '我们家');
  const m = db.prepare('SELECT name, avatar_id FROM members WHERE id = ?').get('m1');
  assert.equal(m.name, '爷爷');
  assert.equal(m.avatar_id, 'a1');

  // 新列存在且为空（不是 0、不是空串 —— 空代表"从没发过链接"）
  const cols = db.prepare('PRAGMA table_info(members)').all().map((c) => c.name);
  assert.ok(cols.includes('web_token_hash'));
  assert.ok(cols.includes('web_token_issued_at_ms'));
  const row = db.prepare('SELECT web_token_hash FROM members WHERE id = ?').get('m1');
  assert.equal(row.web_token_hash, null, '老成员不该凭空获得一条链接');

  // 新表存在
  const tables = db
    .prepare(`SELECT name FROM sqlite_master WHERE type='table'`)
    .all()
    .map((r) => r.name);
  assert.ok(tables.includes('web_tickets'));
});

test('空库（v0）一路升到最新，结构完整', () => {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON');
  assert.equal(readVersion(db), 0);

  migrate(db);

  assert.equal(readVersion(db), SCHEMA_VERSION);
  const tables = db
    .prepare(`SELECT name FROM sqlite_master WHERE type='table'`)
    .all()
    .map((r) => r.name)
    .sort();
  for (const t of [
    'families',
    'devices',
    'pair_codes',
    'members',
    'tasks',
    'checkins',
    'settings',
    'web_tickets',
  ]) {
    assert.ok(tables.includes(t), `缺表 ${t}`);
  }
});

test('迁移是幂等的：连跑两遍不出错，版本不变', () => {
  const db = new DatabaseSync(':memory:');
  migrate(db);
  const v = readVersion(db);
  migrate(db);
  assert.equal(readVersion(db), v);
});

test('库比代码新 → 明确报错，不硬着头皮跑', () => {
  const db = makeLegacyDb();
  db.exec('PRAGMA user_version = 999');
  assert.throws(() => migrate(db), /比代码支持的/);
});

test('某条迁移失败 → 版本号不前进，下次会重试', () => {
  const db = new DatabaseSync(':memory:');
  const boom = [
    () => {},
    () => {
      throw new Error('故意的');
    },
  ];
  assert.throws(() => migrate(db, boom), /迁移到 v2 失败/);
  // 停在 v1：第一条成功了，第二条没成功
  assert.equal(readVersion(db), 1);
});

test('openDb 走的是迁移路径（新建文件库后版本就是最新的）', () => {
  const dir = mkdtempSync(join(tmpdir(), 'famdaily-migrate-'));
  try {
    const path = join(dir, 'sub', 'famdaily.db');
    const db = openDb(path);
    assert.equal(readVersion(db), SCHEMA_VERSION);
    db.close();

    // 再打开一次：不会重复迁移、也不会因为"表已存在"报错
    const again = openDb(path);
    assert.equal(readVersion(again), SCHEMA_VERSION);
    again.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('MIGRATIONS 的条数与 SCHEMA_VERSION 一致', () => {
  // 加迁移忘了改版本号是最容易犯的错：新库建好了，老库停在原地，
  // 然后查新列报 no such column。这里直接钉死。
  assert.equal(SCHEMA_VERSION, MIGRATIONS.length);
  assert.equal(SCHEMA_VERSION, 2);
});
