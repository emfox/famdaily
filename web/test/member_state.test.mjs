/**
 * 成员打卡页的状态/重试逻辑测试。
 *
 * 这一层全是纯函数。写在这里而不是"上线后手点"，是因为下面这些判断
 * 错一次的代价**不对称**：多等 30 秒没人受伤，但"链接作废了还在无限重试"
 * 会让一个 70 岁的人盯着转圈十分钟，然后打电话问"是不是手机坏了"。
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  backoffMs,
  shouldRetry,
  describeError,
  applyCheckin,
  nextToggleState,
  crossedMidnight,
} from '../rules/member_state.mjs';

describe('backoffMs', () => {
  test('从 500ms 起，逐次翻倍', () => {
    assert.equal(backoffMs(0), 500);
    assert.equal(backoffMs(1), 1000);
    assert.equal(backoffMs(2), 2000);
    assert.equal(backoffMs(3), 4000);
  });

  test('30 秒封顶，且一直封住', () => {
    // 不封顶的话，沙箱休眠一晚再打开，退避会涨到几小时。
    for (const n of [6, 7, 8, 20, 1000]) {
      assert.equal(backoffMs(n), 30_000, `attempt=${n} 应该封顶`);
    }
  });

  test('封顶后不会变成 Infinity 或 NaN', () => {
    // 2**1000 是 Infinity，base*Infinity 也是 Infinity，
    // Math.min(Infinity, 30000) 能收住 —— 但那是靠巧合。
    assert.ok(Number.isFinite(backoffMs(1000)));
    assert.ok(Number.isFinite(backoffMs(Number.MAX_SAFE_INTEGER)));
  });

  test('非法输入退回基数，不抛异常', () => {
    // 这条路径在"上一次 backoff 状态没初始化好"时真的会走到。
    assert.equal(backoffMs(-1), 500);
    assert.equal(backoffMs(NaN), 500);
    assert.equal(backoffMs(undefined), 500);
    assert.equal(backoffMs(null), 500);
  });

  test('小数按整数次处理', () => {
    assert.equal(backoffMs(1.9), 1000);
  });
});

describe('shouldRetry', () => {
  test('网络层失败（没拿到响应）要重试', () => {
    assert.equal(shouldRetry(null), true);
    assert.equal(shouldRetry(undefined), true);
  });

  test('5xx / 429 要重试', () => {
    for (const s of [500, 502, 503, 504, 429]) {
      assert.equal(shouldRetry(s), true, `${s} 应该重试`);
    }
  });

  test('401 绝不重试（链接作废，重试一万次也一样）', () => {
    assert.equal(shouldRetry(401), false);
  });

  test('403 / 409 / 400 不重试（重试也一样错）', () => {
    for (const s of [400, 403, 409, 404, 413, 422]) {
      assert.equal(shouldRetry(s), false, `${s} 不该重试`);
    }
  });

  test('和 describeError 的 retry 结论一致', () => {
    // 两个函数分开写是为了各自可读，但结论必须统一 ——
    // 否则会出现"UI 上显示不重试、后台还在偷偷重试"这种鬼故事。
    for (const s of [null, 401, 403, 409, 429, 500, 503]) {
      const d = describeError(s, 'x');
      assert.equal(
        shouldRetry(s),
        d.retry,
        `status=${s}: shouldRetry 与 describeError.retry 不一致`,
      );
    }
  });
});

describe('describeError', () => {
  test('401：让家里人重发链接，而不是让用户"重试"', () => {
    const d = describeError(401, 'no_identity');
    assert.equal(d.kind, 'expired');
    assert.equal(d.retry, false);
    assert.match(d.detail, /重新发/);
  });

  test('文案里不出现 HTTP 状态码和英文错误码', () => {
    // 用户看到 "401 no_identity" 只会更慌。
    for (const s of [401, 403, 409, 429, 500, 400]) {
      const d = describeError(s, 'some_code');
      const text = `${d.title}${d.detail}`;
      assert.ok(!/\d{3}/.test(text), `status=${s} 文案里出现了数字错误码: ${text}`);
      assert.ok(!/[a-z_]{4,}/.test(text), `status=${s} 文案里出现了英文码: ${text}`);
    }
  });

  test('403 按 code 分情况说', () => {
    assert.match(describeError(403, 'future_date').detail, /还没到/);
    assert.match(describeError(403, 'edit_window_expired').detail, /只能看/);
    assert.match(describeError(403, 'forbidden').detail, /不是你的/);
  });

  test('403 未知 code 也有兜底文案', () => {
    const d = describeError(403, 'brand_new_code');
    assert.equal(d.kind, 'forbidden');
    assert.ok(d.detail.length > 0);
  });

  test('离线时不说"服务忙"，直接提 Wi-Fi', () => {
    // 老人对"打不开网页"的默认解读是"手机坏了"。
    const d = describeError(null, null, { online: false });
    assert.match(d.title + d.detail, /联网|Wi-Fi/);
    assert.equal(d.kind, 'server');
  });

  test('在线时是"服务连不上"，不提 Wi-Fi 误导人', () => {
    const d = describeError(null, null, { online: true });
    assert.ok(!/Wi-Fi/.test(d.title + d.detail));
  });

  test('null status 默认为在线（online 默认 true）', () => {
    assert.equal(describeError(null, null).kind, 'server');
  });

  test('429 提示等几秒，可重试', () => {
    const d = describeError(429, 'too_many');
    assert.equal(d.retry, true);
    assert.match(d.detail, /几秒/);
  });

  test('每个分支都带 title 和 detail，且都不为空', () => {
    for (const s of [null, 400, 401, 403, 409, 429, 500, 418]) {
      const d = describeError(s, 'c');
      assert.ok(typeof d.title === 'string' && d.title.length > 0, `status=${s} 缺 title`);
      assert.ok(typeof d.detail === 'string' && d.detail.length > 0, `status=${s} 缺 detail`);
      assert.ok(typeof d.kind === 'string' && d.kind.length > 0, `status=${s} 缺 kind`);
    }
  });
});

describe('applyCheckin', () => {
  const data = {
    member: { name: '妈' },
    items: [
      { taskId: 'a', date: '2026-10-24', slotIndex: 0, checkin: null },
      { taskId: 'b', date: '2026-10-24', slotIndex: 0, checkin: null },
    ],
  };

  test('只改命中的那一条', () => {
    const next = applyCheckin(data, 'a|2026-10-24|0', { state: 'done', doneAtMs: 1, note: null });
    assert.equal(next.items[0].checkin.state, 'done');
    assert.equal(next.items[1].checkin, null);
  });

  test('不改原对象（渲染层可能还拿着旧引用）', () => {
    const before = JSON.stringify(data);
    applyCheckin(data, 'a|2026-10-24|0', { state: 'done' });
    assert.equal(JSON.stringify(data), before);
  });

  test('命中一条时，没被改的那条连引用都不变', () => {
    // 引用不变，后面按引用做 diff 才有意义。
    const next = applyCheckin(data, 'a|2026-10-24|0', { state: 'done' });
    assert.equal(next.items[1], data.items[1]);
  });

  test('key 不存在时返回等价的新对象，不抛错', () => {
    const next = applyCheckin(data, 'zzz|2026-10-24|0', { state: 'done' });
    assert.deepEqual(next.items, data.items);
  });

  test('取消打卡（checkin=null）也走同一条路', () => {
    const done = applyCheckin(data, 'a|2026-10-24|0', { state: 'done' });
    const undone = applyCheckin(done, 'a|2026-10-24|0', null);
    assert.equal(undone.items[0].checkin, null);
  });

  test('槽位 0 和槽位 1 不会串（key 拼接）', () => {
    const two = {
      items: [
        { taskId: 'a', date: '2026-10-24', slotIndex: 0, checkin: null },
        { taskId: 'a', date: '2026-10-24', slotIndex: 1, checkin: null },
      ],
    };
    const next = applyCheckin(two, 'a|2026-10-24|1', { state: 'done' });
    assert.equal(next.items[0].checkin, null);
    assert.equal(next.items[1].checkin.state, 'done');
  });

  test('data 缺 items 也不炸', () => {
    assert.deepEqual(applyCheckin({}, 'k', { state: 'done' }).items, []);
    assert.deepEqual(applyCheckin(null, 'k', { state: 'done' }).items, []);
  });
});

describe('nextToggleState', () => {
  test('没打过 → done', () => {
    assert.equal(nextToggleState(null), 'done');
    assert.equal(nextToggleState(undefined), 'done');
  });

  test('done / makeup → null（取消）', () => {
    assert.equal(nextToggleState({ state: 'done' }), null);
    assert.equal(nextToggleState({ state: 'makeup' }), null);
  });

  test('skipped → done（点勾就是做完了）', () => {
    // 三态循环对老人是灾难：想取消却点成"没做"，界面上还看不出区别。
    // 所以"没做"只能从备注菜单进，勾只负责"做了/不做"。
    assert.equal(nextToggleState({ state: 'skipped' }), 'done');
  });

  test('永远不会返回 skipped', () => {
    for (const s of [null, 'done', 'makeup', 'skipped', 'unknown']) {
      assert.notEqual(nextToggleState({ state: s }), 'skipped');
    }
  });
});

describe('crossedMidnight', () => {
  test('同一天 → false', () => {
    assert.equal(crossedMidnight('2026-10-24', new Date(2026, 9, 24, 23, 59)), false);
  });

  test('过了一天 → true', () => {
    assert.equal(crossedMidnight('2026-10-24', new Date(2026, 9, 25, 0, 1)), true);
  });

  test('跨月、跨年也对（字符串比较，不靠日期减天数）', () => {
    assert.equal(crossedMidnight('2026-10-31', new Date(2026, 10, 1, 0, 0)), true);
    assert.equal(crossedMidnight('2026-12-31', new Date(2027, 0, 1, 0, 0)), true);
  });

  test('没有页面日期 → false（别乱提示）', () => {
    assert.equal(crossedMidnight(null), false);
    assert.equal(crossedMidnight(''), false);
  });

  test('不会出现"今天是 10 月 5 日、页面是 10 月 24 日却判定跨天"', () => {
    // 用字符串比较时这条天然成立；如果用 Date 减法就会出错。
    assert.equal(crossedMidnight('2026-10-24', new Date(2026, 9, 5, 12, 0)), false);
  });
});
