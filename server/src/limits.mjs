/**
 * 限流参数集中一处，方便调参和写测试。
 *
 * 阈值都是"正常用户永远碰不到、脚本刷立刻被拦住"的量级。
 * 定得太松等于没有；定得太紧会让"手抖点了三次重新生成码"的人被锁在门外。
 */

import { createRateLimiter } from './auth.mjs';

export function createLimiters({ clock = Date.now } = {}) {
  return {
    // 新建家庭：口令保护 + 每分钟 5 次。这不是给正常人用的按钮。
    pairNew: createRateLimiter({ limit: 5, windowMs: 60_000, clock }),
    // 预览：猜码发生在这里，收紧到 10 次/分钟。
    pairPreview: createRateLimiter({ limit: 10, windowMs: 60_000, clock }),
    // claim：码一次性；正常配对一次就够，所以比预览更紧。
    pairClaim: createRateLimiter({ limit: 5, windowMs: 60_000, clock }),
    // 同步：回前台就拉一次的家庭，一小时也就几十次。
    // 给到 60 次/分钟是为了容纳"改一条推一次"的防抖失败情形。
    sync: createRateLimiter({ limit: 60, windowMs: 60_000, clock }),
  };
}
