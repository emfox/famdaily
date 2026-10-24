/**
 * 成员链接的 HTTP 入口（App 侧调用，走设备 Bearer）。
 *
 * 三条路由：
 * - `POST /members/:id/link`  生成/重新生成成员链接
 * - `POST /members/:id/unlink` 作废
 * - `GET  /m/link-info`       成员页自己查"我是谁、链接是什么状态"
 *
 * ## 为什么生成链接放在服务端而不是 App 里拼
 *
 * 链接里的 token 必须由服务端生成并**立刻存哈希**。如果 App 自己随机一个字符串
 * 拼进 URL，服务端就得在第一次访问时"顺手把它登记下来" —— 那等于
 * **谁先把某个 token 拿去访问，谁就把它变成有效凭据**。任何人随便填一个
 * 想要的 token，都能提前占坑。所以必须是"服务端发、库里先有哈希、URL 后生成"。
 *
 * @module web_link
 */

import { HttpError } from './http.mjs';
import { issueWebToken, revokeWebToken } from './web_auth.mjs';

/**
 * 成员链接的**基地址**。
 *
 * 三种来源，优先级从高到低：
 * 1. 环境变量 `FAMDAILY_WEB_BASE`（部署时钉死，最可靠）
 * 2. 请求头 `x-forwarded-host` + `x-forwarded-proto`（沙箱端口映射会带）
 * 3. 请求的 `Host` 头
 *
 * 为什么不能自己拼 `http://127.0.0.1:PORT`：那个地址在用户手机上打不开。
 * 沙箱映射后的对外域名只有平台知道，而平台的入口就是这几个头。
 */
export function resolveWebBase(req) {
  const configured = process.env.FAMDAILY_WEB_BASE;
  if (typeof configured === 'string' && configured.trim() !== '') {
    return configured.trim().replace(/\/+$/, '');
  }
  const protoHeader = req.headers['x-forwarded-proto'];
  const proto =
    typeof protoHeader === 'string' && protoHeader.trim() !== ''
      ? protoHeader.split(',')[0].trim()
      : 'http';
  const hostHeader = req.headers['x-forwarded-host'] ?? req.headers['host'];
  const host =
    typeof hostHeader === 'string' && hostHeader.trim() !== ''
      ? hostHeader.split(',')[0].trim()
      : 'localhost';
  return `${proto}://${host}`;
}

/**
 * `POST /members/:id/link`：给成员发一个链接，返回完整 URL。
 *
 * URL 里的 token **只在这里出现一次**，之后服务端再也拿不到明文
 * （库里只有哈希）。所以响应里必须把完整链接给全，App 负责显示/复制/分享。
 *
 * 重新调用会顶掉旧链接（一个成员最多一条有效链接）。
 */
export function handleMemberLink(ctx, deps) {
  const { db, clock } = deps;
  const { device, params, req } = ctx;
  if (!device) {
    throw new HttpError(401, 'unauthorized', '需要先配对');
  }

  const memberId = params?.id;
  if (typeof memberId !== 'string' || memberId === '') {
    throw new HttpError(400, 'bad_request', '缺成员 id');
  }

  const now = Date.now();
  const { token, issuedAtMs } = issueWebToken(db, device.familyId, memberId, now);

  const base = resolveWebBase(req);
  // 路径里带 token（`/m/<token>`）而不是查询参数：
  // 查询参数在有些场合会被当成"页面参数"转发（分享卡片、统计脚本），
  // 路径段不会被转发。而两者都会进日志 —— 那一层由 redact.mjs 兜。
  const url = `${base}/m/${token}`;

  return {
    ok: true,
    memberId,
    url,
    issuedAtMs,
    clock: clock.peek(),
  };
}

/** `POST /members/:id/unlink`：作废成员链接。 */
export function handleMemberUnlink(ctx, deps) {
  const { db, clock } = deps;
  const { device, params } = ctx;
  if (!device) {
    throw new HttpError(401, 'unauthorized', '需要先配对');
  }
  const memberId = params?.id;
  if (typeof memberId !== 'string' || memberId === '') {
    throw new HttpError(400, 'bad_request', '缺成员 id');
  }

  const r = revokeWebToken(db, device.familyId, memberId);
  return { ok: true, memberId, revoked: r.revoked, clock: clock.peek() };
}
