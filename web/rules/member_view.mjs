/**
 * 成员打卡页的**纯渲染函数**：数据进，HTML 片段出。
 *
 * ## 为什么不直接用 DOM API 拼
 *
 * 三个理由，按重要性排：
 *
 * 1. **能测**。这一层是纯字符串函数，`node --test` 里能直接断言输出，
 *    不需要 jsdom / 无头浏览器。要测"跨午夜怎么显示""长名字怎么截"，
 *    拼 DOM 的写法只能靠肉眼看，或者引一套几百 MB 的浏览器。
 * 2. **错一次就错到底**。转义漏一个地方就是 XSS，而转义只在拼字符串时
 *    有一个入口。用 `innerHTML` 逐块更新时，每个块都要记得转义。
 * 3. **首屏快**。一次 `innerHTML` 比几百次 `createElement` 快，
 *    在老人机上（低端安卓）差别是能摸出来的。
 *
 * ## 安全前提
 *
 * **所有插入都必须过 `esc()`**。任务名、备注、成员名都是用户输入。
 * 这条没有例外 —— 想在某个地方"直接塞 HTML"时，先想清楚那些内容是谁写的。
 *
 * @module rules/member_view
 */

/** HTML 转义。五个字符：`& < > " '`。 */
export function esc(value) {
  if (value == null) return '';
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** 打卡状态 → 中文。未知状态给"未知"，不猜。 */
const STATE_LABEL = {
  done: '已完成',
  makeup: '补卡',
  skipped: '没做',
};

/**
 * 一条待办的显示状态。
 *
 * 返回 `{ tone, label }`：
 * - `todo` 待打卡
 * - `done` 已完成（含补卡）
 * - `skipped` 今天不做
 * - `locked` 超出可修改期限（只展示）
 */
export function itemTone(item) {
  const state = item?.checkin?.state ?? null;
  if (state === 'done' || state === 'makeup') return { tone: 'done', label: '已完成' };
  if (state === 'skipped') return { tone: 'skipped', label: '没做' };
  if (item?.editable === false) return { tone: 'locked', label: '已过期' };
  return { tone: 'todo', label: '待打卡' };
}

/** 一条待办的 key：`taskId|日期|槽位`，和库里的主键同构。 */
export function itemKey(item) {
  return `${item.taskId}|${item.date}|${item.slotIndex}`;
}

/**
 * 时刻显示。
 *
 * 跨午夜的要写成"次日 01:00" —— 老人看"01:00"会以为是今天凌晨，
 * 而这个药是**今天晚上睡前**该吃的，写错一天会真的吃错。
 */
export function timeLabel(item) {
  const base = String(item?.dueTime ?? '').slice(0, 5);
  if (!item?.crossesMidnight) return base;
  // 只有"次日"这一种情况：跨午夜的槽位属于当天，提醒落在次日。
  return `次日 ${base}`;
}

/**
 * 一天的标题：`10月24日 周五`。
 *
 * 手写而不是 `toLocaleDateString`：不同设备/浏览器的中文日期格式不一致
 * （iOS Safari 给"2026年10月24日星期六"，安卓 Chrome 给"2026/10/24 星期六"），
 * 而这一行只在页面顶部出现一次，固定格式更好排版。
 */
export function dateLabel(isoDate) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(isoDate ?? ''));
  if (!m) return '';
  const [, y, mo, d] = m;
  const wd = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][
    new Date(`${y}-${mo}-${d}T00:00:00Z`).getUTCDay()
  ];
  return `${Number(mo)}月${Number(d)}日 ${wd}`;
}

/**
 * 渲染一条待办。
 *
 * @param {object} item `/m/api/today` 的一条
 * @param {'todo'|'saving'} [busy] 正在提交时按钮变灰，防连点
 */
export function renderItem(item, busy = 'todo') {
  const { tone, label } = itemTone(item);
  const note = item?.checkin?.note ?? '';
  const checked = tone === 'done';
  const skipped = tone === 'skipped';
  const locked = tone === 'locked';
  const key = esc(itemKey(item));

  // `data-*` 上只放 key，真正的数据从内存里的 Map 取 ——
  // 把整条 JSON 塞进属性里，一旦里面有引号就会把属性截断。
  const ariaState = checked ? '已完成' : skipped ? '没做' : '未完成';

  return `
    <li class="item item--${tone}" data-key="${key}">
      <button class="item__check" type="button"
              data-act="toggle"
              data-key="${key}"
              ${busy === 'saving' || locked ? 'disabled' : ''}
              aria-pressed="${checked}"
              aria-label="${esc(item?.name)} ${ariaState}">
        <span class="item__mark" aria-hidden="true">${checked ? '✓' : skipped ? '—' : ''}</span>
      </button>

      <div class="item__body">
        <div class="item__head">
          <span class="item__time">${esc(timeLabel(item))}</span>
          <span class="item__name" title="${esc(item?.name)}">${esc(item?.name)}</span>
        </div>
        ${
          item?.taskNote
            ? `<p class="item__hint">${esc(item.taskNote)}</p>`
            : ''
        }
        ${
          note
            ? `<p class="item__note" data-note-for="${key}">${esc(note)}</p>`
            : `<p class="item__note" data-note-for="${key}" hidden></p>`
        }
        <div class="item__foot">
          <span class="item__state">${esc(label)}</span>
          ${
            locked
              ? ''
              : `<button class="item__link" type="button" data-act="note" data-key="${key}"
                         ${busy === 'saving' ? 'disabled' : ''}>${note ? '改备注' : '加备注'}</button>`
          }
        </div>
      </div>
    </li>`;
}

/**
 * 渲染整页。
 *
 * @param {object} data `/m/api/today` 的响应
 * @param {object} [opts]
 * @param {string} [opts.busyKey] 正在提交的那一条的 key
 */
export function renderList(data, { busyKey = null } = {}) {
  const items = Array.isArray(data?.items) ? data.items : [];
  const memberName = esc(data?.member?.name ?? '');

  if (items.length === 0) {
    return `
      <p class="empty">
        ${memberName ? `${memberName}，` : ''}今天没有要打卡的事
      </p>`;
  }
  return `<ul class="items">${items
    .map((it) => renderItem(it, itemKey(it) === busyKey ? 'saving' : 'todo'))
    .join('')}</ul>`;
}

/**
 * 页面顶部的一句话：今天还剩几件。
 *
 * 只数"还没做"的（todo + locked 不算待办）。全做完了要说"都做完了"，
 * 而不是"剩 0 件"—— 后者读起来像是在说别的。
 */
export function summaryLine(data) {
  const items = Array.isArray(data?.items) ? data.items : [];
  const total = items.length;
  const left = items.filter((it) => itemTone(it).tone === 'todo').length;
  if (total === 0) return '今天没有安排';
  if (left === 0) return '今天都做完了';
  if (left === total) return `今天有 ${total} 件事`;
  return `还剩 ${left} 件，共 ${total} 件`;
}

/**
 * 规则解析失败的任务 → 一句人话。
 *
 * **必须显示出来**。静默少一条，用户会以为"我今天真的没事"，
 * 而实际上是他设的规则服务端读不懂 —— 这种"安静地错"比报错难查一百倍。
 */
export function hiddenNotice(data) {
  const hidden = Array.isArray(data?.hidden) ? data.hidden : [];
  if (hidden.length === 0) return '';
  return `
    <p class="notice notice--warn">
      有 ${hidden.length} 项今天的安排读不出来，已经先跳过了。可以让家里人在手机上重新设置一下。
    </p>`;
}

/** 超出可修改期限时的说明。 */
export function lockedNotice(data) {
  if (data?.dayEditable !== false) return '';
  return `<p class="notice">这一天已经超过可修改期限，只能看，不能改。</p>`;
}
