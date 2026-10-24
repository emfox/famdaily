/**
 * 日志脱敏。
 *
 * 成员链接的 token 在 URL 里（`/m/<token>` 或 `?t=<token>`），而现有的
 * 访问日志打的是 `req.method + pathname` —— **pathname 就带着那个 token**。
 * 一份日志文件等于一本成员链接册子，谁看到日志谁能进成员页。
 *
 * 这不是理论风险：`createHttpServer` 的 finally 块无条件打路径，
 * 网页端一上线就开始往日志里写明文 token。
 *
 * 做法：把路径里像凭据的那一段换掉，**保留长度和前缀**。
 * 保留长度是为了排障时能区分"这是 43 字符的 token 还是 8 字符的段"，
 * 但长度本身不构成泄露（token 的熵在内容里）。
 *
 * @module redact
 */

/** token 的形态：base64url，21..128 字符。太短的不当凭据（避免误伤 `today`）。 */
const TOKEN_RE = /^[A-Za-z0-9_-]{21,128}$/;

/** 查询参数里哪些键的值必须打码。 */
const SENSITIVE_QUERY_KEYS = new Set(['t', 'token', 'code', 'sharecode']);

/**
 * 把一个 token 打码成 `***` + 长度信息。
 *
 * 例：`AbCd…（43 字符）` → `***43`
 */
export function maskToken(token) {
  if (typeof token !== 'string') return '***';
  return `***${token.length}`;
}

/**
 * 给一条路径打码。
 *
 * 只处理"整段就是一个 token"的形状，不做通用正则猜测 —— 通用猜测会把
 * `/pair/FAM-7K2M-9XQ4-3TBH` 这种正常的码也打掉，而那个码本来就该在日志里
 * （排查"配对失败"全靠它）。分段判断比全局替换可预测。
 *
 * @param {string} pathname
 * @returns {string}
 */
export function redactPath(pathname) {
  if (typeof pathname !== 'string' || pathname === '') return pathname ?? '';
  const segs = pathname.split('/');
  let touched = false;
  const out = segs.map((seg) => {
    if (seg === '') return seg;
    // `/m/<token>` 的第二段是成员 token。`/m/` 后面还可能有 `api/xxx`，
    // 那些不是 token（`api` 只有 3 个字符，过不了长度门槛）。
    if (TOKEN_RE.test(seg)) {
      touched = true;
      return maskToken(seg);
    }
    return seg;
  });
  return touched ? out.join('/') : pathname;
}

/**
 * 打码 URL 里的敏感查询参数。
 *
 * `?t=<token>` 这种形状在"已经换过票、要把 token 从地址栏洗掉"的跳转里会出现。
 */
export function redactQuery(query) {
  if (typeof query !== 'string' || query === '') return '';
  const params = new URLSearchParams(query);
  let touched = false;
  for (const key of [...params.keys()]) {
    if (SENSITIVE_QUERY_KEYS.has(key)) {
      params.set(key, maskToken(params.get(key) ?? ''));
      touched = true;
    }
  }
  return touched ? params.toString() : query;
}

/**
 * 打码一条完整的请求行信息，给访问日志用。
 *
 * @param {string} method
 * @param {string} pathname
 * @param {string} [search] 含前导 `?`
 */
export function redactRequest(method, pathname, search = '') {
  const p = redactPath(pathname);
  const q = redactQuery(search.startsWith('?') ? search.slice(1) : search);
  return q === '' ? `${method} ${p}` : `${method} ${p}?${q}`;
}
