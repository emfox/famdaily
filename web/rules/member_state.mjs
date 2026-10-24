/**
 * 成员打卡页的**状态与重试逻辑**：全是纯函数，不碰 DOM、不碰 fetch。
 *
 * 把这一层单独拆出来，是因为"什么时候该重试、退避多久、哪些错误不该重试"
 * 这类判断最容易写错，而放在 `app.js` 里就只能靠手点验证。
 * 这里全是纯函数，`node --test` 直接断言。
 *
 * @module rules/member_state
 */

/**
 * 指数退避：500ms 起，每次翻倍，**30 秒封顶**。
 *
 * 为什么封顶：沙箱休眠时服务可能整晚不在，不封顶的话退避会涨到几小时，
 * 用户早上打开页面还得等半小时才重试。封顶之后最多等 30 秒，
 * 而且用户随时可以点"重试"立刻试一次。
 *
 * @param {number} attempt 已经失败了几次（0 表示第一次失败后要等多久）
 */
export function backoffMs(attempt) {
  const base = 500;
  const cap = 30_000;
  if (!Number.isFinite(attempt) || attempt < 0) return base;
  // 2**attempt 在 attempt 很大时会溢出成 Infinity，Math.min 能收住，
  // 但为了不依赖这个隐式行为，先掐一下指数上限（2**10 = 1024 已经远超 cap）。
  const raw = base * 2 ** Math.min(Math.trunc(attempt), 10);
  return Math.min(raw, cap);
}

/**
 * 这个错误值不值得重试。
 *
 * 定得保守一点：**只有"可能自己好"的才重试**。
 *
 * | 情况 | 重试? | 为什么 |
 * |---|---|---|
 * | 网络断了 / 超时 | ✅ | 网络回来就好 |
 * | 5xx | ✅ | 服务端临时故障 |
 * | 429 | ✅ | 限流，等一会儿就好 |
 * | 401 no_identity | ❌ | 链接作废了，重试一万次也一样 |
 * | 403 各种 | ❌ | 权限/窗口问题，不是暂时的 |
 * | 409 slot_not_found | ❌ | 数据本身就是错的 |
 * | 400 | ❌ | 请求发错了，重试也一样 |
 *
 * 401 单独说一句：**重试会让用户看到"一直在转圈"**，而这个页面上唯一的
 * 出路是"让家里人重新发链接"。所以要立刻停，把这句话说到脸上。
 */
export function shouldRetry(status) {
  if (status == null) return true; // 没拿到响应 = 网络层失败
  if (status === 429) return true;
  if (status >= 500) return true;
  return false;
}

/**
 * 把失败归一成"该给用户看什么"。
 *
 * 分成四类，因为这四类的下一步动作完全不同：
 * - `offline` → 等网络 / 重试
 * - `expired` → 找家里人重新要链接（**重试没用**）
 * - `forbidden` → 说明情况（超出期限 / 不是你的）
 * - `server` → 等一会儿 / 重试
 *
 * `offlineHint` 单独给一句，是因为"打不开网页"在老人那里最常见的解读是
 * "手机坏了"，而这九成九是网络或服务没在跑。
 */
export function describeError(status, code, { online = true } = {}) {
  if (status === 401) {
    return {
      kind: 'expired',
      retry: false,
      title: '这个链接不能用了',
      detail: '让家里人在手机上重新发一个给你。',
    };
  }
  if (status === 403) {
    const map = {
      future_date: '还没到那一天，不能提前打卡。',
      edit_window_expired: '太久以前了，只能看，不能改。',
      forbidden: '这不是你的打卡项。',
    };
    return {
      kind: 'forbidden',
      retry: false,
      title: '这一步不能改',
      detail: map[code] ?? '没有权限改这一项。',
    };
  }
  if (status === 409) {
    return {
      kind: 'conflict',
      retry: false,
      title: '这一项今天不需要打卡',
      detail: '可能已经被暂停了，刷新一下看看。',
    };
  }
  if (status === 429) {
    return {
      kind: 'ratelimit',
      retry: true,
      title: '点太快了',
      detail: '等几秒再试。',
    };
  }
  if (status == null || status >= 500) {
    return {
      kind: 'server',
      retry: true,
      title: online ? '服务暂时连不上' : '手机好像没联网',
      detail: online
        ? '可能是服务在休息。会自动重试，你也可以点下面的按钮。'
        : '看看 Wi-Fi 或流量开了没有。',
    };
  }
  return {
    kind: 'unknown',
    retry: true,
    title: '出了点问题',
    detail: '稍后再试一次。',
  };
}

/**
 * 乐观更新的合并：把一条打卡结果并进当前列表。
 *
 * **只改一条**，而且只改它的 `checkin` 字段 —— 不从服务端整页重拉。
 * 理由：整页重拉会让整屏闪一下（用户刚点完就看到所有东西重排），
 * 而且如果服务端算出来的槽位和我们手上的不一样，屏幕上会凭空多一条。
 * 服务端返回的合并结果就是真相，我们只是把它照抄回本地那条。
 *
 * @param {object} data `/m/api/today` 的形状
 * @param {string} key `taskId|date|slotIndex`
 * @param {{state: string, doneAtMs: number|null, note: string|null}} checkin
 * @returns {object} 新的 data（不改原对象）
 */
export function applyCheckin(data, key, checkin) {
  const items = Array.isArray(data?.items) ? data.items : [];
  return {
    ...data,
    items: items.map((it) =>
      `${it.taskId}|${it.date}|${it.slotIndex}` === key ? { ...it, checkin } : it,
    ),
  };
}

/**
 * 打卡按钮点下去之后，状态该变成什么。
 *
 * 规则（和服务端的 `mergeCheckinState` 语义对齐，但这里只管 UI）：
 * - 没打过 / 已"没做" → `done`
 * - 已 `done` / `makeup` → 取消（回 `null`）
 *
 * **"没做"只能从"加备注"旁边的菜单进，不能靠再点一次勾**。
 * 一个按钮转三态（待办 → 完成 → 没做 → 待办）对老人是灾难：
 * 想取消却点成了"没做"，而且界面上看不出区别。
 */
export function nextToggleState(checkin) {
  const state = checkin?.state ?? null;
  if (state === 'done' || state === 'makeup') return null;
  return 'done';
}

/** 现在是不是已经跨过午夜（页面该提示"新的一天了"）。 */
export function crossedMidnight(pageDate, now = new Date()) {
  if (!pageDate) return false;
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(
    now.getDate(),
  ).padStart(2, '0')}`;
  return today > String(pageDate);
}
