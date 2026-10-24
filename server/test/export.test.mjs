/**
 * `GET /export` 的测试。
 *
 * 这一层最重要的断言不是"能导出"，而是**字段名和 App 的备份格式对得上**。
 * 导出的东西读不回去，等于没有备份 —— 而这件事只有在真的需要恢复那天
 * 才会发现。
 *
 * 所以下面专门有一组"契约"用例，逐字段核对 `BackupData.toJson` 的形状。
 * 那边改了字段名，这边会红；反过来也一样。
 */

import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';

import { startServer, pairDevice, member, task, checkin } from './helpers.mjs';
import { exportFileName, EXPORT_FORMAT_VERSION } from '../src/export_data.mjs';

/** 造一个有两名成员、三个项目、几条记录的家庭。 */
async function seed(srv, token) {
  const m1 = member('m1', '爸爸', 1000);
  const m2 = member('m2', '妈妈', 2000);
  m2.sortOrder = 1;
  const t1 = task('t1', 'm1', '降压药', 1000);
  const t2 = task('t2', 'm1', '钙片', 1500);
  const t3 = task('t3', 'm2', '维生素', 2000);
  const push = await srv.call('POST', '/sync', {
    token,
    body: {
      members: [m1, m2],
      tasks: [t1, t2, t3],
      checkins: [
        checkin('t1', '2026-10-20', 0, 'done'),
        checkin('t1', '2026-10-21', 0, 'skipped'),
        checkin('t3', '2026-10-21', 1, 'makeup'),
      ],
      settings: [{ key: 'reminders.enabled', value: 'false', updatedAtMs: 1000 }],
    },
  });
  assert.equal(push.status, 200);
  assert.deepEqual(push.json.rejected, []);
  return { m1, m2, t1, t2, t3 };
}

/** 带鉴权地取导出结果。 */
async function getExport(srv, token) {
  const res = await fetch(`${srv.base}/export`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const text = await res.text();
  return { res, text, json: text ? JSON.parse(text) : null };
}

describe('鉴权和边界', () => {
  test('没有 Bearer → 401，不是空文件', async () => {
    const srv = await startServer();
    const res = await fetch(`${srv.base}/export`);
    // 401 必须发生**在**开始写 body 之前：如果先 writeHead(200) 再检查，
    // 浏览器会下载到一个内容是错误信息的 .json 文件。
    assert.equal(res.status, 401);
    assert.match(res.headers.get('content-type'), /application\/json/);
    const body = await res.json();
    assert.equal(body.error.code, 'unauthorized');
    await srv.close();
  });

  test('错的 token → 401', async () => {
    const srv = await startServer();
    const r = await srv.call('GET', '/export', { token: 'nope-nope-nope' });
    assert.equal(r.status, 401);
    await srv.close();
  });

  test('POST /export → 405（只读的东西不该能写）', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    const r = await srv.call('POST', '/export', { token, body: {} });
    assert.equal(r.status, 405);
    await srv.close();
  });
});

describe('响应头', () => {
  test('浏览器会存成文件，而不是铺一大段 JSON', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    const { res } = await getExport(srv, token);
    const cd = res.headers.get('content-disposition');
    assert.match(cd, /^attachment;/);
    assert.match(cd, /filename="famdaily-backup-\d{4}-\d{2}-\d{2}\.json"/);
    await srv.close();
  });

  test('不允许缓存（备份里有全家人的名字和记录）', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    const { res } = await getExport(srv, token);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    await srv.close();
  });

  test('文件名里不含 token / 家庭 id', async () => {
    const srv = await startServer();
    const { token, familyId } = await pairDevice(srv);
    const { res } = await getExport(srv, token);
    const cd = res.headers.get('content-disposition');
    assert.ok(!cd.includes(token), '文件名里不能有设备 token');
    assert.ok(!cd.includes(familyId), '文件名里不能有家庭 id');
    await srv.close();
  });

  test('exportFileName 用本地日期，月和日补零', () => {
    assert.equal(exportFileName(new Date(2026, 0, 5, 13, 0).getTime()), 'famdaily-backup-2026-01-05.json');
    assert.equal(exportFileName(new Date(2026, 11, 31, 23, 59).getTime()), 'famdaily-backup-2026-12-31.json');
  });
});

describe('内容完整性', () => {
  test('成员、项目、记录、设置都导出来了', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    const b = json.backup;
    assert.equal(b.members.length, 2);
    assert.equal(b.tasks.length, 3);
    assert.equal(b.checkins.length, 3);
    assert.equal(b.settings['reminders.enabled'], 'false');
    await srv.close();
  });

  test('三名成员的家庭不会串到别人家（按 family_id 隔离）', async () => {
    const srv = await startServer();
    const a = await pairDevice(srv, { name: 'A 家' });
    const b = await pairDevice(srv, { name: 'B 家' });
    await seed(srv, a.token);
    const { json } = await getExport(srv, b.token);
    // B 家什么都没推过，导出里必须是空的 —— 这条错了就是跨家庭泄漏。
    assert.equal(json.backup.members.length, 0);
    assert.equal(json.backup.tasks.length, 0);
    assert.equal(json.backup.checkins.length, 0);
    await srv.close();
  });

  test('软删除的成员和项目仍然导出（备份是"回到那一刻"）', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    // 通过 /sync 把 m2 标记删除
    const gone = member('m2', '妈妈', 3000);
    gone.sortOrder = 1;
    gone.deletedAtMs = 3000;
    await srv.call('POST', '/sync', { token, body: { members: [gone] } });

    const { json } = await getExport(srv, token);
    const m2 = json.backup.members.find((m) => m.id === 'm2');
    assert.ok(m2, '删掉的成员也该在备份里');
    assert.equal(m2.deleted_at_ms, 3000);
    await srv.close();
  });

  test('**取消掉的打卡不出现在导出里**', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);

    // 协议里的"取消"不是推一行 `deleted: true`，而是在 `removedCheckins`
    // 里列出 key（见 `applyCheckinDeletes`）。用对形状才测得准。
    const del = await srv.call('POST', '/sync', {
      token,
      body: { removedCheckins: ['t1|2026-10-20|0'] },
    });
    assert.equal(del.status, 200);

    const { json } = await getExport(srv, token);
    const hit = json.backup.checkins.find(
      (c) => c.task_id === 't1' && c.date === '2026-10-20',
    );
    // App 的备份格式里没有 `deleted` 字段。原样导出的话，恢复回来会让
    // 用户明确取消的记录重新变成"做了"。所以只能在导出时过滤掉。
    assert.equal(hit, undefined, '取消掉的记录不该出现在备份里');
    assert.equal(json.backup.checkins.length, 2);
    await srv.close();
  });

  test('本机同步凭据不出现（靠白名单保证，不是靠导出时过滤）', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    const keys = Object.keys(json.backup.settings);
    assert.ok(
      keys.every((k) => !k.startsWith('sync.')),
      `这些键不该出现：${keys.filter((k) => k.startsWith('sync.'))}`,
    );
    // 这条断言**不能**用来验证 `export_data.mjs` 里的 `sync.` 过滤：
    // 那批键根本没进 `settings` 表（`SyncKeys.all` 注明不参与同步）。
    // 删掉导出层的过滤，这条照样绿。这里测的是"结果里没有"，
    // 不是"过滤器有效" —— 后者压根没有可观测的入口。
    await srv.close();
  });

  test('成员链接的 token 哈希不导出', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    // 给 m1 发一个链接，让哈希进库
    const link = await srv.call('POST', '/members/m1/link', { token });
    assert.equal(link.status, 200);

    const { text } = await getExport(srv, token);
    // 备份会被拷进网盘、发到微信，而链接是可以直接用来打卡的。
    assert.ok(!text.includes('web_token_hash'), '导出里不该有 web_token_hash 这个键');
    assert.ok(!text.includes(link.json.url), '导出里不该有成员链接');
    await srv.close();
  });
});

describe('与 App 备份格式的契约', () => {
  /**
   * 逐字段核对。**这一组是整份文件里最重要的**：
   * 字段名对不上，导出的文件在 App 的「覆盖恢复」里会被
   * `BackupFormatException` 拒收，而那正是用户最需要它的时候。
   */
  test('顶层字段与 BackupData.toJson 一致', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    const b = json.backup;

    assert.deepEqual(
      Object.keys(b).sort(),
      [
        'app_version',
        'checkins',
        'created_at_ms',
        'format_version',
        'includes_photos',
        'members',
        'schema_version',
        'settings',
        'tasks',
      ].sort(),
    );
    assert.equal(b.format_version, EXPORT_FORMAT_VERSION);
    assert.equal(typeof b.created_at_ms, 'number');
    assert.equal(typeof b.app_version, 'string');
    assert.equal(typeof b.schema_version, 'number');
    assert.equal(b.includes_photos, false);
    assert.equal(typeof b.settings, 'object');
    await srv.close();
  });

  test('成员字段名一致', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    for (const m of json.backup.members) {
      assert.deepEqual(
        Object.keys(m).sort(),
        [
          'avatar_id',
          'created_at_ms',
          'deleted_at_ms',
          'id',
          'name',
          'sort_order',
          'updated_at_ms',
        ].sort(),
      );
      assert.ok('deleted_at_ms' in m, 'deleted_at_ms 可以 null，但键必须在');
    }
    await srv.close();
  });

  test('项目字段名一致，且规则是**对象**不是字符串', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    for (const t of json.backup.tasks) {
      assert.deepEqual(
        Object.keys(t).sort(),
        [
          'course_end',
          'course_start',
          'course_total_days',
          'created_at_ms',
          'deleted_at_ms',
          'icon_id',
          'id',
          'member_id',
          'name',
          'note',
          'reminder_enabled',
          'repeat',
          'sort_order',
          'status',
          'time',
          'updated_at_ms',
        ].sort(),
      );
      // 库里这两列是 **JSON 字符串**，备份格式里必须是对象。
      // 直接 `t.repeat` 下去，App 的 `_map()` 会抛"规则字段格式不对"。
      assert.equal(typeof t.repeat, 'object');
      assert.equal(typeof t.time, 'object');
      assert.equal(t.time.type, 'fixed');
      assert.deepEqual(t.time.times, ['08:00']);
      assert.equal(t.reminder_enabled, true);
      assert.equal(typeof t.reminder_enabled, 'boolean');
    }
    await srv.close();
  });

  test('打卡记录字段名一致', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const { json } = await getExport(srv, token);
    for (const c of json.backup.checkins) {
      assert.deepEqual(
        Object.keys(c).sort(),
        [
          'date',
          'done_at_ms',
          'due_at_minute_of_day',
          'id',
          'note',
          'photo_path',
          'slot_index',
          'state',
          'task_id',
        ].sort(),
      );
      assert.match(c.date, /^\d{4}-\d{2}-\d{2}$/);
      assert.ok(['done', 'skipped', 'makeup'].includes(c.state));
      // 照片只存在 App 本地，服务端没有这一列。给 null 坚持写上这个键。
      assert.equal(c.photo_path, null);
    }
    await srv.close();
  });

  test('合成的打卡 id 稳定（同一行每次导出都一样）', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    const a = await getExport(srv, token);
    const b = await getExport(srv, token);
    const idsA = a.json.backup.checkins.map((c) => c.id).sort();
    const idsB = b.json.backup.checkins.map((c) => c.id).sort();
    // 不稳定的话，同一份数据导出两次会得到两份"不同的备份"，
    // 恢复时会因为 id 不同而插重。
    assert.deepEqual(idsA, idsB);
    assert.equal(idsA.length, 3);
    await srv.close();
  });

  test('schema_version 跟着数据库真实版本走', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    const { json } = await getExport(srv, token);
    const real = srv.app.db.prepare('PRAGMA user_version').get().user_version;
    // 写死一个常数会在下次迁移之后过期，而 App 拿它判断"要不要提示版本较新"。
    assert.equal(json.backup.schema_version, real);
    assert.ok(real >= 2);
    await srv.close();
  });

  test('坏掉的规则 JSON 不会让整份备份导不出来', async () => {
    const srv = await startServer();
    const { token } = await pairDevice(srv);
    await seed(srv, token);
    // 直接把库里的 repeat_json 改成一段坏 JSON（模拟版本不兼容/数据损坏）
    srv.app.db
      .prepare("UPDATE tasks SET repeat_json = 'not json at all' WHERE id = 't1'")
      .run();

    const { res, json } = await getExport(srv, token);
    assert.equal(res.status, 200, '一条坏规则不该让整个导出失败');
    const t1 = json.backup.tasks.find((t) => t.id === 't1');
    assert.equal(t1.repeat, null);
    await srv.close();
  });
});

// 反向验证时，这一层可能留下没结束的响应（导出是大 body）。
// 和 static.test.mjs 一样：一秒后强制退出，避免"守卫坏了"被误读成"测试挂死"。
after(() => {
  if (process.env.FAMDAILY_NO_FORCE_EXIT) return;
  setTimeout(() => process.exit(process.exitCode ?? 0), 1000).unref();
});
