/**
 * 访问日志脱敏的**集成**测试。
 *
 * `redact.test.mjs` 测的是纯函数；这里测的是"它真的接进了 HTTP 层"。
 * 分开的理由：早期踩过"写了个正确的工具函数，但调用点没换"——
 * 单测全绿，日志里照样明文。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createApp } from '../index.mjs';

/** 一个像真 token 的 43 字符串。 */
const TOKEN = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abc';

test('访问日志里不出现明文成员 token（路径和查询都算）', async () => {
  const lines = [];
  const logger = { info: (s) => lines.push(s), error: () => {} };
  const app = await createApp({ dbPath: ':memory:', pairSecret: 'x', logger });
  await new Promise((r) => app.server.listen(0, '127.0.0.1', r));
  const { port } = app.server.address();

  try {
    // 404 不要紧：日志在 finally 里打，跟状态码无关。
    await fetch(`http://127.0.0.1:${port}/m/${TOKEN}?t=${TOKEN}`);
    // 等一轮事件循环，让 finally 跑完。
    await new Promise((r) => setTimeout(r, 50));

    assert.ok(lines.length > 0, '应该有日志行');
    for (const line of lines) {
      assert.ok(!line.includes(TOKEN), `日志泄露了明文 token：${line}`);
    }
    assert.ok(
      lines.some((l) => l.includes(`***${TOKEN.length}`)),
      `应该看到打码后的形状：${lines.join(' | ')}`,
    );
  } finally {
    await new Promise((r) => app.server.close(r));
    app.close();
  }
});

test('正常接口的日志保持可读（脱敏不能把排障信息也吃掉）', async () => {
  const lines = [];
  const logger = { info: (s) => lines.push(s), error: () => {} };
  const app = await createApp({ dbPath: ':memory:', pairSecret: 'x', logger });
  await new Promise((r) => app.server.listen(0, '127.0.0.1', r));
  const { port } = app.server.address();

  try {
    await fetch(`http://127.0.0.1:${port}/health`);
    await new Promise((r) => setTimeout(r, 50));
    assert.ok(
      lines.some((l) => l === 'GET /health 200 0ms' || /^GET \/health 200 \d+ms$/.test(l)),
      `日志格式变了：${lines.join(' | ')}`,
    );
  } finally {
    await new Promise((r) => app.server.close(r));
    app.close();
  }
});
