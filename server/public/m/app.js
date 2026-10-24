/**
 * 成员打卡页的运行时代码：拉数据、渲染、打卡、重试。
 *
 * 这里只做"接线"，所有判断逻辑都在 `web/rules/member_view.mjs`（渲染）
 * 和 `web/rules/member_state.mjs`（状态/重试）里 —— 那两个是纯函数，能测。
 *
 * ## 几条定死的规矩
 *
 * - **不用 `innerHTML` 拼用户内容**。所有动态 HTML 都来自 `renderList()`，
 *   那里每个插值都过了 `esc()`。这里只负责把字符串塞进容器。
 * - **点击是乐观的**：先改屏幕，再发请求，失败回滚。老人不会等三秒才看到
 *   勾亮起来 —— 看不到反应就会再点一次，然后变成取消。
 * - **不自动放弃**：网络错误会退避重试，最多退到 30 秒；401 立刻停，
 *   因为那种情况重试一万次也一样。
 */

import {
  dateLabel,
  esc,
  hiddenNotice,
  itemKey,
  lockedNotice,
  renderList,
  summaryLine,
} from '/rules/member_view.mjs';
import {
  applyCheckin,
  backoffMs,
  crossedMidnight,
  describeError,
  nextToggleState,
} from '/rules/member_state.mjs';

/** 请求超时：8 秒。沙箱休眠后第一次请求可能要等它醒，但等太久不如让用户选。 */
const REQUEST_TIMEOUT_MS = 8000;

const app = document.getElementById('app');
const noteDialog = document.getElementById('noteDialog');
const noteInput = document.getElementById('noteInput');

/** 当前这一天的数据（服务端 `/m/api/today` 的响应）。 */
let data = null;
/** 正在提交的那一条的 key，用于禁用按钮 + 顶部细条。 */
let busyKey = null;
/** 重试计数（成功后清零）。 */
let attempt = 0;
/** 重试定时器。 */
let retryTimer = null;
/** 页面打开时的日期，用来判断有没有跨过午夜。 */
let pageDate = null;

// ---------------------------------------------------------------------------
// 请求
// ---------------------------------------------------------------------------

/**
 * 带超时的 fetch。
 *
 * `AbortSignal.timeout` 比手搓 `setTimeout + abort` 少一类错误（忘了清定时器）。
 * 它抛的是 `TimeoutError`，和"真的断网"在 `describeError` 里都归到 `null` 状态。
 */
async function request(path, init = {}) {
  const res = await fetch(path, {
    ...init,
    // 同源，Cookie 默认带；显式写出来是为了以后真跨域时不用回来找
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json', ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text === '' ? null : JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: res.status, json };
}

/** 本地日期 `yyyy-mm-dd`（不能用 `toISOString()`：那是 UTC，东八区早上 8 点前会差一天）。 */
function localToday(now = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

async function load() {
  clearRetry();
  pageDate = localToday();
  try {
    const { status, json } = await request(`/m/api/today?date=${pageDate}`, {
      method: 'GET',
    });
    if (status !== 200 || !json?.ok) {
      return fail(status, json?.error?.code, /* duringLoad */ true);
    }
    data = json;
    attempt = 0;
    render();
  } catch {
    // 抛出来的是网络错误或超时：没有 status
    return fail(null, null, true);
  }
}

/** 提交一条打卡。 */
async function submit(key, payload) {
  const [taskId, date, slotIndexStr] = key.split('|');
  busyKey = key;
  render();

  try {
    const { status, json } = await request('/m/api/checkin', {
      method: 'POST',
      body: JSON.stringify({
        taskId,
        date,
        slotIndex: Number(slotIndexStr),
        ...payload,
      }),
    });

    busyKey = null;

    if (status !== 200 || !json?.ok) {
      // 回滚由 render() 负责：屏幕上显示的永远是 data 里的内容，
      // 而 data 从头到尾没被改过 —— 乐观更新改的是 key 而不是 data。
      render();
      return fail(status, json?.error?.code, false);
    }

    // 服务端返回的就是合并后的真相，照抄回本地那一条。
    data = applyCheckin(data, key, {
      state: json.state,
      doneAtMs: json.doneAtMs,
      note: json.note,
    });
    attempt = 0;
    render();
    return true;
  } catch {
    busyKey = null;
    render();
    fail(null, null, false);
    return false;
  }
}

// ---------------------------------------------------------------------------
// 错误与重试
// ---------------------------------------------------------------------------

function clearRetry() {
  if (retryTimer) {
    clearTimeout(retryTimer);
    retryTimer = null;
  }
}

/**
 * 出错时的统一出口。
 *
 * @param {number|null} status
 * @param {string|undefined} code
 * @param {boolean} duringLoad 是不是"拉数据"这一步失败的（决定要不要盖住整页）
 */
function fail(status, code, duringLoad) {
  const info = describeError(status, code, { online: navigator.onLine });

  if (info.retry) {
    scheduleRetry();
  }

  // 拉数据失败：整页换成错误提示（下面没有内容可留）
  // 提交失败：在列表上方插一条提示，**不动列表** ——
  // 用户刚点的东西还在原处，改了没改成一眼能看出来。
  const banner = `
    <div class="notice notice--error" role="alert">
      <span class="notice__title">${esc(info.title)}</span>
      ${esc(info.detail)}
    </div>`;

  if (duringLoad || !data) {
    app.innerHTML = `
      <div class="head">
        <p class="head__who">打不开今天的清单</p>
      </div>
      ${banner}
      <div class="actions">
        <button class="btn btn--primary" type="button" data-act="reload">再试一次</button>
      </div>`;
    return;
  }

  render({ banner });
}

/** 指数退避重试；401/403 这类不重试的，`scheduleRetry` 根本不会被调到。 */
function scheduleRetry() {
  if (retryTimer) return; // 已经在等了，别叠加
  const wait = backoffMs(attempt);
  attempt += 1;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    // 页面在后台时不重试：回来时 `visibilitychange` 会自己拉一次。
    // 否则一晚上能攒出几百次请求，把限流额度用光。
    if (document.hidden) return;
    if (!data) load();
    else load(); // 有数据也整页重拉一次：可能好几条都变了
  }, wait);
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

function render({ banner = '' } = {}) {
  if (!data) return;
  const memberName = data.member?.name ?? '';

  // `app.innerHTML = ...` 会把上一次 `flash()` 插进去的提示一起清掉。
  // 而"点勾 → flash → 某次重绘"这个顺序是常态（切回前台就会重绘），
  // 不接住的话那句话会闪一下就没了，用户根本没读完。
  const pendingFlash = document.querySelector('.flash')?.textContent ?? '';

  app.innerHTML = `
    <header class="head">
      <p class="head__who">${esc(memberName)}</p>
      <p class="head__day">${esc(dateLabel(data.date))}</p>
      <p class="head__sum">${esc(summaryLine(data))}</p>
    </header>
    ${banner}
    ${hiddenNotice(data)}
    ${lockedNotice(data)}
    ${renderList(data, { busyKey })}
    ${
      crossedMidnight(data.date)
        ? `<div class="actions"><button class="btn btn--primary" type="button" data-act="reload">已经是新的一天了，刷新看看</button></div>`
        : ''
    }`;

  if (pendingFlash) flash(pendingFlash);

  // "正在提交"的细条：只在提交时出现。用 fixed 的元素而不是给 body 加类，
  // 避免整页重排。
  const old = document.querySelector('.bar');
  if (busyKey && !old) {
    const bar = document.createElement('div');
    bar.className = 'bar';
    document.body.appendChild(bar);
  } else if (!busyKey && old) {
    old.remove();
  }
}

// ---------------------------------------------------------------------------
// 交互
// ---------------------------------------------------------------------------

/** 找到 key 对应的那一条。 */
function itemByKey(key) {
  return (data?.items ?? []).find((it) => itemKey(it) === key) ?? null;
}

app.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('[data-act]');
  if (!btn) return;
  const act = btn.dataset.act;

  if (act === 'reload') {
    attempt = 0;
    await load();
    return;
  }

  const key = btn.dataset.key;
  const item = itemByKey(key);
  if (!item) return;

  if (act === 'toggle') {
    const next = nextToggleState(item.checkin);
    if (next === null) {
      // 点了一个**已经打过**的勾。
      //
      // ⚠️ 这里以前 `openNote()` —— 注释写着"网页端不提供取消"，代码却弹了
      // 备注框。老人点了一个"✓"（多半是想撤回），冒出来一个文字输入框，
      // 除了困惑没有别的效果。
      //
      // 服务端确实没有"取消"这个状态：`VALID_STATES` 只有 done/makeup/skipped，
      // 而 `mergeCheckinState` 在 incoming 为 null 时会保留 existing ——
      // 也就是说，就算前端发了个 null 过去，"取消"也不会发生，屏幕上却会
      // 乐观地清掉那个勾，看起来"取消了"，刷新一下又回来了。
      //
      // 所以现在**如实告诉用户这件事**，并指一条真的能走通的路：
      // 打错了就改成"没做"（那也是明确的意思），要写情况就点"改备注"。
      flash('已经记上了。点右边的"改备注"可以补充说明，或者让家里人在手机上改。');
      return;
    }
    await submit(key, { state: next, note: item.checkin?.note ?? null });
    return;
  }

  if (act === 'note') {
    openNote(key, item);
  }
});

/**
 * 页面上飘一句话，几秒后自己消失。
 *
 * 用 `role="status"` 而不是 `alert`：这是解释性的一句话，不是紧急中断，
 * 读屏软件不该把用户正在读的内容打断。
 *
 * 同时只留一条 —— 连点五下叠出五条提示，等于什么都没说。
 */
function flash(text) {
  document.querySelector('.flash')?.remove();
  const el = document.createElement('p');
  el.className = 'flash';
  el.setAttribute('role', 'status');
  el.textContent = text; // 纯文本，不用 innerHTML：这里没有需要渲染的标记
  app.appendChild(el);
  setTimeout(() => el.remove(), 6000);
}

/** 打开备注弹层。 */
function openNote(key, item) {
  noteInput.value = item?.checkin?.note ?? '';
  noteDialog.dataset.key = key;
  // `showModal()` 在极老的浏览器上没有；不支持时退化成直接提交空备注没意义，
  // 所以干脆什么都不做 —— 但那时"加备注"按钮本来就不该出现。
  if (typeof noteDialog.showModal === 'function') {
    noteDialog.showModal();
    noteInput.focus();
  }
}

noteDialog.addEventListener('close', async () => {
  if (noteDialog.returnValue !== 'save') return;
  const key = noteDialog.dataset.key;
  const item = itemByKey(key);
  if (!item) return;

  const note = noteInput.value.trim().slice(0, 200);
  // 只改备注：状态保持原样；没打过卡的，写备注等于"做过"，这是用户的意图
  const state = item.checkin?.state ?? 'done';
  await submit(key, { state, note: note === '' ? null : note });
});

// 回到前台时拉一次：手机上切出去接个电话再回来，看到的应该是新的
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  clearRetry();
  attempt = 0;
  load();
});

// 网络回来时立刻试一次，别让用户等退避
window.addEventListener('online', () => {
  clearRetry();
  attempt = 0;
  load();
});

// 每 30 秒检查一次有没有跨午夜（页面挂着过夜是很常见的）
setInterval(() => {
  if (data && crossedMidnight(data.date) && !document.querySelector('[data-act="reload"]')) {
    render();
  }
}, 30_000);

load();
