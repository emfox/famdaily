/**
 * 静态托管的测试。
 *
 * 这一层的每条断言背后都是一个**真的会出事**的场景（发出去不该发的文件、
 * 被别人的页面嵌走），不是为了覆盖率。
 *
 * 两个测试根：
 * - `test/fixtures/public`：造好的夹具，包含 `.db`/`.env` 这些**绝对不能发**的文件
 * - 临时目录：需要造符号链接，放仓库里不合适
 */

import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, describe, test } from 'node:test';

import { createApp } from '../index.mjs';
import { safeRelativePath } from '../src/static.mjs';

const FIXTURE_ROOT = new URL('./fixtures/public/', import.meta.url).pathname;

/**
 * 真实的静态产物目录（`server/public/`）。
 *
 * 少数用例必须用真目录：比如 `/rules/*` 的第二个根是按 publicDir 推出来的，
 * 拿夹具根去测会算到一个不存在的位置，测出来的 404 是假的。
 */
const REAL_PUBLIC_ROOT = new URL('../public/', import.meta.url).pathname;

/** 安静 logger。 */
const silent = { info() {}, error() {} };

/**
 * 起一个服务，静态根指向 [publicDir]。
 *
 * **刻意走 `createApp` 而不是直接 `createHttpServer`**：静态托管最容易出的
 * 问题是"路由和 fallback 的优先级装错了"，只有从真实装配入口起才测得出来。
 */
async function start({ publicDir = FIXTURE_ROOT } = {}) {
  const app = await createApp({
    dbPath: ':memory:',
    pairSecret: 'test-secret',
    publicDir,
    logger: silent,
  });
  await new Promise((r) => app.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${app.server.address().port}`;

  // ⚠️ **每次请求都必须能被超时打断**。
  //
  // 踩过：把静态层改坏之后，`await res.arrayBuffer()` 永远不返回 ——
  // 服务端发了头却断了流，undici 就一直等。表现不是"测试失败"，
  // 而是**整个文件挂到 Node 默认的 4 分钟超时**，反向验证脚本因此超时退出，
  // 看上去像"脚本写错了"。加超时之后，坏掉的那条会如实变成红的。
  const get = async (path, init = {}) => {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 5000);
    try {
      const res = await fetch(`${base}${path}`, {
        headers: { connection: 'close' },
        signal: ac.signal,
        ...init,
      });
      const buf = Buffer.from(await res.arrayBuffer());
      return { status: res.status, headers: res.headers, body: buf.toString('utf8'), buf };
    } finally {
      clearTimeout(timer);
    }
  };

  return {
    base,
    get,
    app,
    close: async () => {
      // 服务端 close 同样要有上限：一个卡住的连接就能让它永远等下去。
      await Promise.race([
        new Promise((r) => app.server.close(r)),
        new Promise((r) => setTimeout(r, 2000)),
      ]);
      app.close();
      // closeAllConnections 兜底：close() 等的是"所有连接都空闲"，
      // 一个已经发了头却没 end() 的响应会让它永远等不到。
      // 不主动掐断的话，测试进程不退出 → `node --test` 挂到默认 4 分钟。
      app.server.closeAllConnections?.();
    },
  };
}

// ---------------------------------------------------------------------------
// safeRelativePath：纯函数，先把这一层打穿
// ---------------------------------------------------------------------------

describe('safeRelativePath', () => {
  test('正常路径原样保留', () => {
    assert.equal(safeRelativePath('/index.html'), 'index.html');
    assert.equal(safeRelativePath('/m/app.js'), join('m', 'app.js'));
    assert.equal(safeRelativePath('/'), null, '根目录本身不是文件');
  });

  test('`..` 一律拒，不管写成什么花样', () => {
    // 每一条都是真实攻击 payload。漏一条就是一次任意文件读取。
    const payloads = [
      '/../famdaily.db',
      '/m/../../famdaily.db',
      '/..%2ffamdaily.db',
      '/%2e%2e/famdaily.db',
      '/%2E%2E%2Ffamdaily.db',
      '/..\\famdaily.db',
      '/m/..\\..\\famdaily.db',
      '/./../famdaily.db',
      '/a/b/../../../etc/passwd',
    ];
    for (const p of payloads) {
      assert.equal(safeRelativePath(p), null, `应当拒绝：${p}`);
    }
  });

  test('NUL 字节截断拒掉', () => {
    // `a.html\0.png` 在白名单里看的是 `.png`，实际打开的是 `a.html`。
    assert.equal(safeRelativePath('/app.js%00.png'), null);
  });

  test('畸形的百分号编码拒掉而不是抛', () => {
    assert.equal(safeRelativePath('/%zz'), null);
    assert.equal(safeRelativePath('/%E4%B8'), null);
  });

  test('多个前导斜杠不会被当成绝对路径', () => {
    // `//etc/passwd` 在某些库里会被当作 UNC 路径（Windows）跳盘。
    assert.equal(safeRelativePath('//app.js'), 'app.js');
  });
});

// ---------------------------------------------------------------------------
// 正常取文件
// ---------------------------------------------------------------------------

describe('取静态文件', () => {
  test('GET /index.html 返回 HTML + 正确的 content-type', async () => {
    const srv = await start();
    const r = await srv.get('/index.html');
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('content-type'), 'text/html; charset=utf-8');
    assert.match(r.body, /<title>t<\/title>/);
    await srv.close();
  });

  test('GET / 落到 index.html', async () => {
    // `/` 经 safeRelativePath 是 null，但静态 handler 要能当目录索引处理。
    const srv = await start();
    const r = await srv.get('/');
    assert.equal(r.status, 200);
    assert.match(r.body, /<title>t<\/title>/);
    await srv.close();
  });

  test('子目录的 index.html', async () => {
    const srv = await start();
    const r = await srv.get('/sub/index.html');
    assert.equal(r.status, 200);
    assert.match(r.body, /sub page/);
    await srv.close();
  });

  test('各类型 content-type 都对', async () => {
    const srv = await start();
    const cases = [
      ['/app.css', 'text/css; charset=utf-8'],
      ['/app.js', 'text/javascript; charset=utf-8'],
      ['/data.json', 'application/json; charset=utf-8'],
      ['/icon.png', 'image/png'],
      ['/logo.svg', 'image/svg+xml'],
      ['/note.txt', 'text/plain; charset=utf-8'],
    ];
    for (const [path, type] of cases) {
      const r = await srv.get(path);
      assert.equal(r.status, 200, path);
      assert.equal(r.headers.get('content-type'), type, path);
    }
    await srv.close();
  });

  test('HEAD 只要头，不要体', async () => {
    const srv = await start();
    const r = await srv.get('/index.html', { method: 'HEAD' });
    assert.equal(r.status, 200);
    assert.equal(r.body, '');
    assert.ok(Number(r.headers.get('content-length')) > 0);
    await srv.close();
  });
});

// ---------------------------------------------------------------------------
// 不发出去的东西
// ---------------------------------------------------------------------------

describe('不该发的文件', () => {
  test('.db / .env / 无扩展名 一律 404（不是 403）', async () => {
    const srv = await start();
    for (const path of ['/famdaily.db', '/.env', '/noext']) {
      const r = await srv.get(path);
      assert.equal(r.status, 404, `${path} 必须 404`);
      assert.ok(
        !r.body.includes('SECRET-PLAINTEXT-DB'),
        `${path} 绝对不能把内容发出去`,
      );
    }
    await srv.close();
  });

  test('扩展名大小写不影响判断（.DB 也拒）', async () => {
    const srv = await start();
    // 大写 .DB 不在白名单里 —— 白名单匹配走 toLowerCase，
    // 但 `.db` 本来就不在白名单，所以小写大写都拒。
    const r = await srv.get('/famdaily.DB');
    assert.equal(r.status, 404);
    await srv.close();
  });

  test('路径穿越打不到上层文件', async () => {
    // 夹具目录的上层就是 test/fixtures，再上一层是仓库里的 server/src。
    const srv = await start();
    const payloads = [
      '/../public/index.html',
      '/%2e%2e/index.html',
      '/..%2f..%2fpackage.json',
      '/../../server/src/static.mjs',
    ];
    for (const p of payloads) {
      const r = await srv.get(p);
      // ⚠️ 这里**不能只断言 404**。第一版只断言了 404，其中
      // `/%2e%2e/index.html` 实际返回 200 —— 因为 URL 解析器把 `/%2e%2e/`
      // 归一成了 `/`，于是拿到了 index.html，而断言只查内容里有没有
      // "famdaily" 三个字，夹具的 index.html 恰好不含，于是绿的。
      // 一个"看起来在防穿越"的用例，实际上什么都没防住。
      //
      // 真正该断言的是：**要么 404，要么返回的就是 root 自己的 index.html**
      // （即越界没有发生）。两者都算安全，但只承认这两种。
      const wentOutside = r.status === 200 && r.body.includes('SECRET-PLAINTEXT-DB');
      assert.ok(!wentOutside, `${p} 读到了 public 外面的文件`);
      assert.ok(
        r.status === 404 || /<title>t<\/title>/.test(r.body),
        `${p} 返回了意料之外的东西：${r.status} ${r.body.slice(0, 40)}`,
      );
    }
    await srv.close();
  });

  test('编码后的 `..` 不会读到上层（回归：这条曾经 200）', async () => {
    // 单独拎出来是因为它在第一版里是**假绿**的，必须有一条明确的用例盯着。
    const srv = await start();
    for (const p of ['/%2e%2e/index.html', '/%2e%2e%2findex.html', '/%2E%2E/index.html']) {
      const r = await srv.get(p);
      assert.ok(
        r.status === 404 || /<title>t<\/title>/.test(r.body),
        `${p} 期望 404 或 root 的 index.html，实际 ${r.status}`,
      );
    }
    await srv.close();
  });

  test('指向 public 外部的符号链接不发', async () => {
    // `join` 的结果在字符串上确实在 root 里，只有 realpath 能看出来。
    const dir = await mkdtemp(join(tmpdir(), 'famdaily-static-'));
    const pub = join(dir, 'public');
    await mkdir(pub);
    await writeFile(join(pub, 'ok.html'), '<p>fine</p>');
    // 秘密文件放在 public 的**外面**，再用软链指进来。
    const secret = join(dir, 'outside-secret.html');
    await writeFile(secret, '<p>SECRET</p>');
    await symlink(secret, join(pub, 'leak.html'));
    // 指向目录的软链同样要挡住（能顺着它读到整个目录）。
    await symlink(join(dir), join(pub, 'updir'));

    try {
      const srv = await start({ publicDir: pub });
      const ok = await srv.get('/ok.html');
      assert.equal(ok.status, 200);

      const leak = await srv.get('/leak.html');
      assert.equal(leak.status, 404, '软链指到 root 外必须 404');
      assert.ok(!leak.body.includes('SECRET'));

      const up = await srv.get('/updir/outside-secret.html');
      assert.equal(up.status, 404, '顺着软链目录也必须 404');

      await srv.close();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('目录本身不列目录，且 `/sub` 只落到它自己的 index.html', async () => {
    const srv = await start();
    const r = await srv.get('/sub');
    // 这一条**不是**断言 404。第一版写的是 `assert.equal(r.status, 404)`，
    // 理由是"目录不是文件"—— 但 `/sub` 后面没有任何东西，浏览器该看到的就是
    // `sub/index.html`（和 `/` → `index.html` 一个道理）。真正的风险不是"能进"，
    // 是"把目录里的文件名列出来"，所以断言放在**内容**上。
    assert.equal(r.status, 200);
    assert.match(r.body, /sub page/);
    assert.ok(!/index of/i.test(r.body), '不能返回目录列表');
    assert.ok(!r.body.includes('..'), '不能把上级路径写进页面');
    await srv.close();
  });

  test('目录里没有 index.html 时 404，不挑别的文件顶上', async () => {
    // "挑第一个文件"看起来友好，实际是灾难：文件系统顺序一变，
    // 某个真实存在的资源就会莫名其妙变成这个目录的首页。
    const dir = await mkdtemp(join(tmpdir(), 'famdaily-noidx-'));
    await mkdir(join(dir, 'bare'));
    await writeFile(join(dir, 'bare', 'a.html'), 'aaa');
    await writeFile(join(dir, 'bare', 'b.html'), 'bbb');
    try {
      const srv = await start({ publicDir: dir });
      const r = await srv.get('/bare');
      assert.equal(r.status, 404, '没有 index.html 就是 404，别猜');
      assert.ok(!r.body.includes('aaa') && !r.body.includes('bbb'));
      await srv.close();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test('静态目录不存在时，接口照常可用', async () => {
    // 沙箱重发后产物没拷进来 —— 不能因此让 App 连不上同步服务。
    const srv = await start({ publicDir: '/tmp/definitely-not-here-famdaily' });
    const api = await srv.get('/health');
    assert.equal(api.status, 200, '静态目录没了，接口必须照常');
    const page = await srv.get('/index.html');
    assert.equal(page.status, 404);
    await srv.close();
  });
});

// ---------------------------------------------------------------------------
// 和接口的关系
// ---------------------------------------------------------------------------

describe('静态层不能吃掉接口', () => {
  test('/health 仍然是 JSON', async () => {
    const srv = await start();
    const r = await srv.get('/health');
    assert.equal(r.status, 200);
    assert.match(r.headers.get('content-type'), /application\/json/);
    assert.equal(JSON.parse(r.body).service, 'famdaily-sync');
    await srv.close();
  });

  test('未注册路径返回 404，默认是 JSON（浏览器请求可降级成一段人话）', async () => {
    // App 端按 `error.code` 分类处理；给一坨 HTML 会让它解析失败，
    // 表现成"网络错误"而不是"接口不存在"，排查时南辕北辙。
    //
    // 但浏览器直接输错地址时，吐一屏 JSON 更没用。所以按 `Accept` 分流：
    // `fetch()` 默认 `Accept: */*`（走 JSON），地址栏 `Accept` 带 `text/html`
    // （走一段能读的 HTML）。**降级的是文案，不是状态码**——永远是 404。
    const srv = await start();
    const r = await srv.get('/api/nope');
    assert.equal(r.status, 404);
    assert.match(r.headers.get('content-type'), /application\/json/);
    assert.equal(JSON.parse(r.body).error.code, 'not_found');
    await srv.close();
  });

  test('浏览器（Accept: text/html）的 404 是一段能读的页面', async () => {
    const srv = await start();
    const r = await srv.get('/api/nope', {
      headers: { connection: 'close', accept: 'text/html,application/xhtml+xml' },
    });
    assert.equal(r.status, 404);
    assert.match(r.headers.get('content-type'), /text\/html/);
    assert.match(r.body, /没有这个页面/);
    // 文案里不能出现内部路径/接口名：那等于把实现细节当接口
    assert.ok(!r.body.includes('/m/api'));
    await srv.close();
  });

  test('POST 请求的 404 永远走 JSON（不管 Accept）', async () => {
    // 表单/接口调用方拿到的必须是结构化错误。
    const srv = await start();
    const r = await srv.get('/api/nope', {
      method: 'POST',
      headers: { connection: 'close', accept: 'text/html' },
    });
    assert.equal(r.status, 404);
    assert.match(r.headers.get('content-type'), /application\/json/);
    await srv.close();
  });

  test('注册过的路径用错方法还是 405，不会被静态层接走', async () => {
    const srv = await start();
    const r = await srv.get('/sync', { method: 'GET' });
    // `/sync` 只注册了 POST。以前这里会 405；加了静态层之后
    // 如果 fallback 抢在前面，会变成"找 /sync 这个文件 → 404"。
    assert.equal(r.status, 405);
    await srv.close();
  });

  test('POST 一个存在的静态文件 → 404（不是 405）', async () => {
    // 静态资源没有"方法不对"这回事。回 405 等于告诉扫描器"这条路径确实存在"。
    const srv = await start();
    const r = await srv.get('/app.js', { method: 'POST' });
    assert.equal(r.status, 404);
    await srv.close();
  });

  test('/m/<token> 仍然是入口重定向，没有被静态层改成找文件', async () => {
    const srv = await start();
    const r = await srv.get('/m/some-invalid-token-1234567890abcdef');
    assert.equal(r.status, 401);
    assert.match(r.headers.get('content-type'), /application\/json/);
    await srv.close();
  });

  test('/m/api/today 没 Cookie → 401 JSON', async () => {
    const srv = await start();
    const r = await srv.get('/m/api/today');
    assert.equal(r.status, 401);
    assert.equal(JSON.parse(r.body).error.code, 'no_identity');
    await srv.close();
  });
});

// ---------------------------------------------------------------------------
// 头与缓存
// ---------------------------------------------------------------------------

describe('安全头与缓存', () => {
  test('关键安全头都在', async () => {
    const srv = await start();
    const r = await srv.get('/index.html');
    const csp = r.headers.get('content-security-policy');
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /frame-ancestors 'none'/);
    assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
    // referrer-policy 是防 token 外泄的最后一层：地址栏已经靠 302 洗过了，
    // 但万一哪天漏了，这条能保证点出去的外链拿不到 token。
    assert.equal(r.headers.get('referrer-policy'), 'no-referrer');
    await srv.close();
  });

  test('404 也带安全头', async () => {
    const srv = await start();
    const r = await srv.get('/nope.html');
    assert.equal(r.status, 404);
    assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
    await srv.close();
  });

  test('cache-control 是 no-cache（允许存但要协商），不是 no-store', async () => {
    const srv = await start();
    const r = await srv.get('/app.js');
    assert.equal(r.headers.get('cache-control'), 'no-cache');
    await srv.close();
  });

  test('ETag 协商：第二次带 If-None-Match 得到 304 且没有体', async () => {
    const srv = await start();
    const first = await srv.get('/app.js');
    const etag = first.headers.get('etag');
    assert.ok(etag, '必须发 ETag');

    const second = await srv.get('/app.js', { headers: { 'if-none-match': etag, connection: 'close' } });
    assert.equal(second.status, 304);
    assert.equal(second.body, '');
    await srv.close();
  });

  test('304 也必须结束响应体（否则浏览器一直转圈）', async () => {
    // 用**原始 socket** 读，不经过 fetch 的容错。
    // 走 fetch 时，`await res.arrayBuffer()` 在连接被掐断时也会"成功"返回空，
    // 于是一个漏了 `res.end()` 的 304 看起来完全正常 —— 只有原始 socket
    // 能看出"响应结束了没有"。这条测试是为它写的。
    //
    // ⚠️ **必须自己带超时**。漏了 end() 时这条测试本身就是会挂住的那条，
    // 而 Node 的测试默认超时是 4 分钟：整个文件挂 4 分钟，看起来像"卡死"，
    // 而不是"这条断言失败了"。
    const srv = await start();
    try {
      const first = await srv.get('/app.js');
      const etag = first.headers.get('etag');

      const raw = await new Promise((resolve, reject) => {
        const socket = net.connect(new URL(srv.base).port, '127.0.0.1', () => {
          socket.write(
            `GET /app.js HTTP/1.1\r\nHost: x\r\nIf-None-Match: ${etag}\r\nConnection: close\r\n\r\n`,
          );
        });
        const chunks = [];
        const timer = setTimeout(() => {
          socket.destroy();
          // 注意：这里 reject 而不是 resolve，这条测试才叫"抓到 bug"
          reject(new Error('304 之后连接 3 秒内没有断开 —— 响应体没 end()'));
        }, 3000);
        socket.on('data', (c) => chunks.push(c));
        socket.on('end', () => {
          clearTimeout(timer);
          resolve(Buffer.concat(chunks).toString('utf8'));
        });
        socket.on('error', (e) => {
          clearTimeout(timer);
          reject(e);
        });
      });

      assert.match(raw, /^HTTP\/1\.1 304/);
      // 服务端在 304 之后主动断开了 —— 说明 end() 被调到了。
      assert.ok(raw.length > 0);
    } finally {
      await srv.close();
    }
  });

  test('文件变了 ETag 就变（否则用户永远看旧版）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'famdaily-etag-'));
    await writeFile(join(dir, 'a.html'), 'v1');
    try {
      const srv = await start({ publicDir: dir });
      const a = await srv.get('/a.html');
      // mtimeMs 精度可能只有 1ms，等一下确保 mtime 真的变了。
      await new Promise((r) => setTimeout(r, 12));
      await writeFile(join(dir, 'a.html'), 'v2-longer');
      const b = await srv.get('/a.html');
      assert.notEqual(a.headers.get('etag'), b.headers.get('etag'));
      assert.equal(b.body, 'v2-longer');
      await srv.close();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// 路由 ↔ 静态层的"让路"
// ---------------------------------------------------------------------------

describe('路由给静态层让路（STATIC_PASSTHROUGH）', () => {
  /**
   * `/m/:token` 的正则是 `[^/]+`，`app.js` 完全符合"一段 token"的形状。
   * 第一版就是这样：`/m/` 页面 200，但脚本和样式全 401 —— 表现是
   * "白屏 + 一个空标题"，从现象根本想不到是路由冲突。
   *
   * 这一组把"名单里的资源名必须落到静态层"钉住。
   */
  test('/m/app.js、/m/app.css 不是 token，能取到（200 + 正确类型）', async () => {
    const srv = await start();
    for (const [path, type] of [
      ['/m/app.js', /javascript/],
      ['/m/app.css', /text\/css/],
    ]) {
      const r = await srv.get(path);
      assert.equal(r.status, 200, `${path} 应该是 200，实际 ${r.status}`);
      assert.match(r.headers.get('content-type'), type, `${path} 的 content-type 不对`);
      assert.ok(r.body.length > 0, `${path} 不该是空文件`);
    }
    await srv.close();
  });

  test('/m/ 下的 HTML 入口也是静态文件', async () => {
    const srv = await start();
    const r = await srv.get('/m/');
    assert.equal(r.status, 200);
    assert.match(r.headers.get('content-type'), /text\/html/);
    await srv.close();
  });

  test('让路之后仍然是"没有就 404"，不能变成 200 空壳', async () => {
    // `/m/favicon.ico` 在名单里但文件不存在。如果让路后不把
    // 'not_found' 翻译成异常，就会出现"200 + 空 body"—— 浏览器会把
    // 空响应当成坏图标，而排查时看到 200 会一直怀疑是不是缓存问题。
    const srv = await start();
    const r = await srv.get('/m/favicon.ico');
    assert.equal(r.status, 404);
    await srv.close();
  });

  test('真正的 token 仍然走入口（没被让路顺手放过）', async () => {
    // 反过来的误伤：名单加了之后，如果判断写成"前缀匹配"或"含点就算资源"，
    // 所有 token 都会被当成文件 → 全部 404，用户点链接进不来。
    const srv = await start();
    const r = await srv.get('/m/abcdefghijklmnopqrstuvwxyz');
    assert.equal(r.status, 401);
    assert.equal(JSON.parse(r.body).error.code, 'no_identity');
    await srv.close();
  });

  test('让路的判定只认名单，不认"带扩展名"', async () => {
    // **写成"结尾是 .js/.css 就让路"也能过前几条**，但会误伤真实 token。
    // 成员链接 token 是 base64url 随机串，**完全可能以 `x.png` 这类形状结尾**
    // （`/m/QWERTY...x.png`），这时页面会去静态层找文件、拿到 404，
    // 而用户看到的又是"链接失效"——和真的失效长得一样，排查时根本不会怀疑路由。
    //
    // 下面四个探测值都是**名单外**的，必须继续被当作 token。
    // 关键是后两个：token 是 base64url 随机串，**完全可能以 `.js` / `.css`
    // 结尾**（`…Zm9v.js`），这时"看扩展名就让路"的写法会把真链接送去
    // 静态层找文件 → 404，和"链接已作废"长得一模一样，排查时根本不会
    // 怀疑到路由头上。前两个则是把判定写成"包含点"就会踩的。
    const srv = await start();
    for (const path of [
      '/m/app.js.bak',
      '/m/x.png',
      '/m/dGhpcy1pcy1hLXRva2Vu.js',
      '/m/dGhpcy1pcy1hLXRva2Vu.css',
    ]) {
      const r = await srv.get(path);
      assert.equal(r.status, 401, `${path} 应该仍被当作 token，实际 ${r.status}`);
    }
    await srv.close();
  });

  test('让路后仍然守目录穿越（多根没有多开一扇门）', async () => {
    const srv = await start();
    for (const path of ['/rules/../../server/index.mjs', '/rules/../package.json']) {
      const r = await srv.get(path);
      assert.equal(r.status, 404, `${path} 不该能读到`);
    }
    await srv.close();
  });

  test('/rules/* 映射到仓库 web/rules，且只能取白名单类型', async () => {
    // ⚠️ 这里**不能用 start() 默认的夹具根**。
    // 第二个根是按 `publicDir/../../web/rules` 算出来的：夹具根算出来是
    // `test/fixtures/web/rules`（不存在），于是所有 /rules/* 都是 404 ——
    // 而 404 恰好也是这条用例后半段期望的结果，很容易被误读成"守卫生效了"。
    // 所以前半段用真实的 public 目录起，确认它**确实能取到**。
    const srv = await start({ publicDir: REAL_PUBLIC_ROOT });
    const ok = await srv.get('/rules/member_view.mjs');
    assert.equal(ok.status, 200, '/rules/member_view.mjs 应该能取到（这是页面真正依赖的模块）');
    assert.match(ok.headers.get('content-type'), /javascript/);
    // web/rules 目录里根本没有 .db；这条是防"第二个根被放宽了白名单"。
    const bad = await srv.get('/rules/x.db');
    assert.equal(bad.status, 404);
    await srv.close();
  });
});

// ---------------------------------------------------------------------------
// 访问日志
// ---------------------------------------------------------------------------

describe('访问日志', () => {
  test('静态请求也会打日志（能看出有人打开了页面）', async () => {
    const lines = [];
    const app = await createApp({
      dbPath: ':memory:',
      pairSecret: 'test-secret',
      publicDir: FIXTURE_ROOT,
      logger: { info: (m) => lines.push(m), error() {} },
    });
    await new Promise((r) => app.server.listen(0, '127.0.0.1', r));
    const base = `http://127.0.0.1:${app.server.address().port}`;
    await (await fetch(`${base}/index.html`, { headers: { connection: 'close' } })).text();
    await new Promise((r) => app.server.close(r));
    app.close();

    assert.ok(
      lines.some((l) => l.includes('GET /index.html 200')),
      `日志里该有这条，实际：${lines.join(' | ')}`,
    );
  });
});

after(() => {
  // 这一层是**给反向验证用的保险**。
  //
  // 把某个守卫拆掉之后，测试本身可能留下一个没结束的响应。那种情况下
  // `node --test` 的子进程不会退出 —— 拿不到任何结果，只能等外部 timeout
  // 把整个进程杀掉（退出码 124，输出里一条 `not ok` 都看不到）。
  // 表现是"测试挂死"而不是"这条断言失败了"，排查时会被误导很久。
  //
  // 这里在一秒后强制退出：所有用例已经跑完，剩下的只有残留句柄。
  // 不设 `FAMDAILY_NO_FORCE_EXIT` 时生效；排查残留句柄时设上它就不强制了。
  //
  // ⚠️ **只在测试文件里这么做**。生产代码绝不能用它掩盖没关的连接。
  if (process.env.FAMDAILY_NO_FORCE_EXIT) return;
  setTimeout(() => process.exit(process.exitCode ?? 0), 1000).unref();
});
