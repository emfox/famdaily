/**
 * 日志脱敏测试。
 *
 * 这组测试守的是一件事：**日志文件不能变成凭据册子**。
 * 每一条都对应一个真实会泄露的路径。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { redactPath, redactQuery, redactRequest, maskToken } from '../src/redact.mjs';

/** 一个像真 token 的 43 字符串。 */
const TOKEN = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abc';

test('redactPath：/m/<token> 里的 token 被打码', () => {
  const out = redactPath(`/m/${TOKEN}`);
  assert.equal(out, `/m/***${TOKEN.length}`);
  assert.ok(!out.includes(TOKEN), '不能残留原文');
});

test('redactPath：/m/<token>/ 尾部斜杠不影响', () => {
  const out = redactPath(`/m/${TOKEN}/`);
  assert.equal(out, `/m/***${TOKEN.length}/`);
});

test('redactPath：普通路径不动', () => {
  for (const p of ['/health', '/sync', '/m/api/today', '/m', '/favicon.ico']) {
    assert.equal(redactPath(p), p);
  }
});

test('redactPath：配对码**不该**被打码（排查配对失败全靠它）', () => {
  // FAM-7K2M-9XQ4-3TBH 里有一段 4 字符的组，够不到 21 字符门槛。
  assert.equal(redactPath('/pair/FAM-7K2M-9XQ4-3TBH'), '/pair/FAM-7K2M-9XQ4-3TBH');
});

test('redactPath：静态资源文件名不动', () => {
  assert.equal(redactPath('/m/index.html'), '/m/index.html');
  assert.equal(redactPath('/m/app.0f3a1c9e.js'), '/m/app.0f3a1c9e.js');
});

test('redactQuery：?t= 打码，别的参数保留', () => {
  const out = redactQuery(`t=${TOKEN}&date=2026-10-24`);
  assert.ok(out.includes('date=2026-10-24'), '非敏感参数要留着，否则没法排障');
  assert.ok(!out.includes(TOKEN));
  assert.ok(out.includes(`t=***${TOKEN.length}`));
});

test('redactQuery：sharecode 也打码', () => {
  const out = redactQuery('sharecode=abcdefghijklmnopqrstuvwxyz&x=1');
  assert.ok(!out.includes('abcdefghijklmnopqrstuvwxyz'));
  assert.ok(out.includes('x=1'));
});

test('redactQuery：没有敏感参数时原样返回', () => {
  assert.equal(redactQuery('a=1&b=2'), 'a=1&b=2');
  assert.equal(redactQuery(''), '');
});

test('redactRequest：路径和查询都处理', () => {
  const line = redactRequest('GET', `/m/${TOKEN}`, `?t=${TOKEN}`);
  assert.ok(!line.includes(TOKEN), `不能残留原文：${line}`);
  assert.ok(line.startsWith('GET /m/'));
});

test('redactRequest：search 可以不带前导问号', () => {
  const line = redactRequest('GET', '/m', `t=${TOKEN}`);
  assert.ok(!line.includes(TOKEN));
  assert.ok(line.includes('?'));
});

test('maskToken：保留长度，丢掉内容', () => {
  assert.equal(maskToken('abcdef'), '***6');
  assert.equal(maskToken(''), '***0');
  assert.equal(maskToken(null), '***');
});

test('redactPath：不是字符串时不崩', () => {
  assert.equal(redactPath(''), '');
  assert.equal(redactPath(null), '');
});
