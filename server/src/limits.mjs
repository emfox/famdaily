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

    // ---- 网页端 ----

    // 用 URL token 换 ticket：这里等于"验一个凭据"，是猜 token 的入口。
    // 20 次/分钟：正常人一次点开就够；刷新页面不会重复换（已有 Cookie）。
    webTicket: createRateLimiter({ limit: 20, windowMs: 60_000, clock }),
    // 读：成员页首屏一次、打卡后刷新一次。60 次/分钟给足，防止脚本扫。
    webRead: createRateLimiter({ limit: 60, windowMs: 60_000, clock }),
    // 写：打卡是低频动作，但"点了没反应就再点"很常见。
    // 30 次/分钟远高于任何正常使用，又不至于让误触把家里人的额度用光。
    webWrite: createRateLimiter({ limit: 30, windowMs: 60_000, clock }),
  };
}
