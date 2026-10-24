# famdaily-sync

Famdaily 的同步中转服务。

> **它的定位要说清楚：这是一个"你和我都在场时"可用的服务，不是能承诺永远在线的生产服务器。**
> 它跑在 WorkBuddy 沙箱里，沙箱休眠时它不在；沙箱数据**没有备份承诺**。
> 所以 App 本地数据库才是唯一真相源，这里只是中转站 + 一个总在睡觉的公共记事本。

## 为什么零依赖

只有 7 条路由。40 行分发比引一个框架更少出错，也不会因为某个包停更而卡住。
SQLite 用 Node 22 内置的 `node:sqlite`（实测 3.47.2），少一个原生模块就少一处
"换个 Node 版本装不上"。

## 跑起来

```bash
cd server
FAMDAILY_PAIR_SECRET='自己定一个长口令' PORT=8787 node index.mjs
# [famdaily-sync] listening on :8787, db=/abs/path/server/data/famdaily.db, families=0
```

| 环境变量 | 作用 | 不给会怎样 |
|---|---|---|
| `FAMDAILY_PAIR_SECRET` | `POST /pair/new` 的口令 | 拒绝新建家庭；**已配对设备照常同步**（不能因为配错变量把全家断了） |
| `FAMDAILY_DB` | 数据库文件路径，**绝对路径** | 默认 `server/data/famdaily.db`（按本文件位置推算，不看 cwd） |
| `PORT` | 监听端口 | 8787 |

数据库路径必须写死到绝对路径，原因见 [src/db.mjs](src/db.mjs) 的注释：
沙箱重发可能换工作目录，相对路径会把库丢到临时目录，"发布之后数据全空"
有一半是这么来的。

## 接口

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| GET | `/health` | 无 | 存活探针。返回 `families`/`cursor`/`pairEnabled` |
| POST | `/pair/new` | `X-Pair-Secret` | 建家庭，发一次性同步码（10 分钟有效） |
| GET | `/pair/:code` | 码即凭据 | 配对前预览成员名 |
| POST | `/pair/claim` | 同步码 | 码换长期 token，码即刻作废 |
| POST | `/pair/rotate` | Bearer | 轮换 token，**其他设备全部失效**（手机丢了用这个） |
| POST | `/sync` | Bearer | 推全量 + 拉增量，一个往返 |

完整协议见 [`docs/sync-protocol.zh_CN.md`](../docs/sync-protocol.zh_CN.md)。

## 测试

```bash
cd server
node --test "test/*.test.mjs"
```

测试**打真的 HTTP**：`startServer()` 在 127.0.0.1 的随机端口起真服务，
走真 TCP、真 JSON，不 mock `node:http`、不 mock 数据库。
每个用例慢几毫秒，换来"测试全绿、真机不行"这类问题不会从这一层漏过去。
