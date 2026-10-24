/**
 * 成员打卡页的渲染函数测试。
 *
 * 这一层能测，正是「把渲染抽成纯字符串函数」的全部理由。
 * 下面每一条断言都对应一个"上线后会被用户看见"的具体后果，
 * 不是为覆盖率凑数。
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  esc,
  itemTone,
  itemKey,
  timeLabel,
  dateLabel,
  renderItem,
  renderList,
  summaryLine,
  hiddenNotice,
  lockedNotice,
} from '../rules/member_view.mjs';

/** 造一条待办。默认是"待打卡"的普通药。 */
function item(over = {}) {
  return {
    taskId: 't1',
    name: '降压药',
    taskNote: null,
    date: '2026-10-24',
    slotIndex: 0,
    dueTime: '08:00:00',
    crossesMidnight: false,
    editable: true,
    checkin: null,
    ...over,
  };
}

describe('esc', () => {
  test('五个字符全转义', () => {
    assert.equal(esc(`&<>"'`), '&amp;&lt;&gt;&quot;&#39;');
  });

  test('null / undefined 给空串，不给 "null"', () => {
    // 直接 String(null) 会在页面上印出 "null" 四个字母。
    assert.equal(esc(null), '');
    assert.equal(esc(undefined), '');
  });

  test('数字和 0 都要照原样', () => {
    assert.equal(esc(0), '0');
    assert.equal(esc(18), '18');
  });

  test('先转 & 再转别的，否则会双重转义', () => {
    // 顺序错了 `&lt;` 会变成 `&amp;lt;`，用户看到的是字面的 "&lt;"。
    assert.equal(esc('a<b'), 'a&lt;b');
    assert.equal(esc('&lt;'), '&amp;lt;');
  });
});

describe('itemTone', () => {
  test('没打卡且可改 → 待打卡', () => {
    assert.deepEqual(itemTone(item()), { tone: 'todo', label: '待打卡' });
  });

  test('done 和 makeup 都算完成（补卡不该显示成"没做"）', () => {
    assert.equal(itemTone(item({ checkin: { state: 'done' } })).tone, 'done');
    assert.equal(itemTone(item({ checkin: { state: 'makeup' } })).label, '已完成');
  });

  test('skipped → 没做', () => {
    assert.equal(itemTone(item({ checkin: { state: 'skipped' } })).tone, 'skipped');
  });

  test('超出期限且未打卡 → locked', () => {
    assert.equal(itemTone(item({ editable: false })).tone, 'locked');
  });

  test('超出期限但已打卡 → 仍算完成，不显示"已过期"', () => {
    // 这一条是刻意的：昨天打了卡，今天回看时该觉得"我做了"，
    // 而不是被一个"已过期"糊一脸。
    assert.equal(
      itemTone(item({ editable: false, checkin: { state: 'done' } })).tone,
      'done',
    );
  });

  test('未知状态当作待打卡，不炸', () => {
    assert.equal(itemTone(item({ checkin: { state: 'wat' } })).tone, 'todo');
    assert.equal(itemTone(null).tone, 'todo');
  });
});

describe('itemKey', () => {
  test('和库里的主键同构：taskId|日期|槽位', () => {
    assert.equal(itemKey(item()), 't1|2026-10-24|0');
  });

  test('槽位 0 不能丢（falsy 陷阱）', () => {
    // 用 `slotIndex || ''` 拼的话槽位 0 会变成空串，
    // 于是"第 0 次"和"没有槽位"撞成同一个 key。
    assert.match(itemKey(item({ slotIndex: 0 })), /\|0$/);
  });
});

describe('timeLabel', () => {
  test('普通时刻只取 时:分', () => {
    assert.equal(timeLabel(item({ dueTime: '08:30:00' })), '08:30');
  });

  test('跨午夜要写"次日"', () => {
    // 老人看 "01:00" 会以为是今天凌晨；这个药其实是今晚睡前吃。
    assert.equal(timeLabel(item({ dueTime: '01:00:00', crossesMidnight: true })), '次日 01:00');
  });

  test('没时间给空串，不给 "undefined"', () => {
    assert.equal(timeLabel(item({ dueTime: undefined })), '');
    assert.equal(timeLabel(null), '');
  });
});

describe('dateLabel', () => {
  test('中文短格式', () => {
    assert.equal(dateLabel('2026-10-24'), '10月24日 周六');
  });

  test('月和日不补零', () => {
    assert.equal(dateLabel('2026-01-05'), '1月5日 周一');
  });

  test('格式不对给空串', () => {
    assert.equal(dateLabel('2026/10/24'), '');
    assert.equal(dateLabel(''), '');
    assert.equal(dateLabel(null), '');
  });

  test('跨年也对（用 UTC 算星期，不受本机时区影响）', () => {
    assert.equal(dateLabel('2027-01-01'), '1月1日 周五');
  });
});

describe('renderItem', () => {
  test('任务名里的 HTML 被转义（XSS 第一道）', () => {
    const html = renderItem(item({ name: '<img src=x onerror=alert(1)>' }));
    assert.ok(!html.includes('<img'), '不能出现未转义的 <img');
    assert.ok(html.includes('&lt;img'));
  });

  test('备注里的引号不会截断 data-* 属性', () => {
    // 第一版把整条 JSON 塞进 data-item，备注里一个双引号就把属性截断了。
    const html = renderItem(item({ name: 'a"b', checkin: { state: 'done', note: '他说"好"' } }));
    // 属性值里不该出现裸双引号：数一下引号是否成对。
    for (const m of html.matchAll(/data-[\w-]+="([^"]*)"/g)) {
      assert.ok(!m[1].includes('"'), `属性 ${m[0]} 被截断`);
    }
  });

  test('待打卡：按钮可点、aria-pressed=false', () => {
    const html = renderItem(item());
    assert.ok(html.includes('aria-pressed="false"'));
    assert.ok(!html.includes('disabled'));
    assert.ok(html.includes('item--todo'));
  });

  test('已完成：显示勾、按钮仍可点（用来取消）', () => {
    const html = renderItem(item({ checkin: { state: 'done' } }));
    assert.ok(html.includes('aria-pressed="true"'));
    assert.ok(html.includes('✓'));
    assert.ok(!html.includes('disabled'));
  });

  test('locked（过期未打卡）：按钮 disabled，且不显示"改备注"', () => {
    const html = renderItem(item({ editable: false, checkin: null }));
    assert.ok(html.includes('disabled'));
    assert.ok(!html.includes('data-act="note"'));
    assert.ok(html.includes('已过期'));
  });

  test('locked 但已完成：不是 locked，按钮仍可点', () => {
    // 过期 ≠ 冻结。昨天打的卡今天发现点错了，系统应该还是允许取消的
    // —— 真正的时间窗由服务端 `edit_window` 管，前端别抢着把门焊死。
    // 前端只负责：过期且**没打过**的那一项，别给点出一个 403。
    const html = renderItem(item({ editable: false, checkin: { state: 'done' } }));
    assert.ok(!html.includes('disabled'));
    assert.ok(html.includes('item--done'));
  });

  test('busy=saving 时按钮 disabled（防连点）', () => {
    const html = renderItem(item(), 'saving');
    assert.ok(html.includes('disabled'));
  });

  test('无备注时备注占位是 hidden 的', () => {
    const html = renderItem(item());
    assert.match(html, /data-note-for="[^"]*" hidden/);
  });

  test('有备注时显示原文', () => {
    const html = renderItem(item({ checkin: { state: 'done', note: '饭后吃' } }));
    assert.ok(html.includes('饭后吃'));
    assert.ok(!/data-note-for="[^"]*" hidden/.test(html));
  });

  test('有任务说明时渲染出提示', () => {
    assert.ok(renderItem(item({ taskNote: '半片' })).includes('半片'));
    assert.ok(!renderItem(item({ taskNote: null })).includes('item__hint'));
  });

  test('aria-label 里带上状态，读屏能听出来', () => {
    const html = renderItem(item({ checkin: { state: 'done' } }));
    assert.match(html, /aria-label="降压药 已完成"/);
  });
});

describe('renderList', () => {
  test('空列表给一句人话，带上成员名', () => {
    const html = renderList({ member: { name: '妈' }, items: [] });
    assert.ok(html.includes('妈，今天没有要打卡的事'));
    assert.ok(!html.includes('<ul'));
  });

  test('没有成员名时不出现开头的"某某，"', () => {
    const html = renderList({ member: null, items: [] });
    assert.ok(html.includes('今天没有要打卡的事'));
    assert.ok(!html.includes('，今天'));
  });

  test('成员名也要转义', () => {
    const html = renderList({ member: { name: '<b>妈</b>' }, items: [] });
    assert.ok(!html.includes('<b>'));
  });

  test('多条按顺序渲染，key 各不相同', () => {
    const data = {
      member: { name: '妈' },
      items: [item({ slotIndex: 0 }), item({ slotIndex: 1, dueTime: '20:00:00' })],
    };
    const html = renderList(data);
    assert.equal(html.match(/<li /g)?.length, 2);
    assert.ok(html.indexOf('08:00') < html.indexOf('20:00'));
    assert.ok(html.includes('t1|2026-10-24|0'));
    assert.ok(html.includes('t1|2026-10-24|1'));
  });

  test('busyKey 命中的那一条被 disabled', () => {
    const data = { member: { name: '妈' }, items: [item({ slotIndex: 0 }), item({ slotIndex: 1 })] };
    const html = renderList(data, { busyKey: 't1|2026-10-24|1' });
    const lis = html.split('<li ').slice(1);
    assert.ok(!lis[0].includes('disabled'), '第 0 条不该被禁用');
    assert.ok(lis[1].includes('disabled'), '第 1 条该被禁用');
  });

  test('items 不是数组也不炸', () => {
    assert.ok(renderList({}).includes('今天没有要打卡的事'));
    assert.ok(renderList(null).includes('今天没有要打卡的事'));
  });
});

describe('summaryLine', () => {
  const mk = (states) => ({
    items: states.map((s, i) => item({ slotIndex: i, checkin: s ? { state: s } : null })),
  });

  test('没有安排', () => {
    assert.equal(summaryLine({ items: [] }), '今天没有安排');
  });

  test('一件都没做 → 今天有 N 件事', () => {
    assert.equal(summaryLine(mk([null, null, null])), '今天有 3 件事');
  });

  test('全做完 → 今天都做完了（不是"剩 0 件"）', () => {
    // "剩 0 件"读起来像在说别的东西。
    assert.equal(summaryLine(mk(['done', 'skipped'])), '今天都做完了');
  });

  test('做了一半 → 还剩 X 件，共 Y 件', () => {
    assert.equal(summaryLine(mk(['done', null, null])), '还剩 2 件，共 3 件');
  });

  test('locked 不算"还没做"', () => {
    const data = { items: [item({ checkin: { state: 'done' } }), item({ slotIndex: 1, editable: false })] };
    assert.equal(summaryLine(data), '今天都做完了');
  });
});

describe('hiddenNotice', () => {
  test('没有隐藏项时输出空串（不占位置）', () => {
    assert.equal(hiddenNotice({ hidden: [] }), '');
    assert.equal(hiddenNotice({}), '');
  });

  test('有隐藏项必须显眼地说出来', () => {
    const html = hiddenNotice({ hidden: [{ taskId: 'x' }, { taskId: 'y' }] });
    assert.ok(html.includes('2 项'));
    assert.ok(html.includes('notice--warn'));
  });

  test('文案里不出现技术细节', () => {
    // 用户不需要知道 journal_mode 之类的词，只需要知道"找家里人重设"。
    const html = hiddenNotice({ hidden: [{ taskId: 'x' }] });
    for (const word of ['parse', 'rule', 'JSON', 'null', 'undefined']) {
      assert.ok(!html.includes(word), `不该出现 ${word}`);
    }
  });
});

describe('lockedNotice', () => {
  test('可编辑时不出提示', () => {
    assert.equal(lockedNotice({ dayEditable: true }), '');
    assert.equal(lockedNotice({}), '');
  });

  test('不可编辑时出提示', () => {
    assert.ok(lockedNotice({ dayEditable: false }).includes('只能看'));
  });
});
