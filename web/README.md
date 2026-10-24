# famdaily-web

Famdaily 的成员打卡页（浏览器里打开，给不会用 App 的家人）。

> **现状**：只有规则引擎（`rules/`）+ 测试。页面、鉴权、接口都还没写。
> 这个 README 先记录"规则引擎为什么存在、为什么是第二份实现"。

## 为什么这里有一份规则引擎的复印件

App 里"今天该做哪几件事"由三套正交规则决定：
**哪天做 × 几点做 × 疗程**（`app/lib/domain/model/*.dart` + `domain/scheduling/scheduler.dart`）。

网页端跑在 Node 里，没有 Dart VM，用不上那份代码；而 App 的 `slots` 表是**派生数据**，
**从不参与同步**（同步它等于同步一份随时会过期的缓存）。所以网页端拿到任务规则后，
必须**按规则现算**槽位。

结果是：同一套算法写了两遍。这是本项目唯一一处"逻辑写两遍"，靠下面这套机制守住一致性。

## 一致性怎么保证

| 机制 | 位置 |
|---|---|
| 函数名逐个照抄，可并排对照 | `rules/local_date.mjs` ↔ `local_date.dart` 等 |
| **双端共享夹具**（45 条 case，两端各跑一遍） | `test/fixtures/slots-cases.json` |
| 期望值**手算**，不从实现生成 | 夹具每条 case 的 `备注` 记录了推演过程 |
| 数量守卫 | 两侧各有 `cases.length >= 40` 断言 |

```bash
cd web && npm test          # 76 条
cd app && ./tool/test.sh test/domain/slots_fixture_test.dart   # 47 条，跑同一份夹具
```

改一边必须改另一边，否则那 45 条里会红。**这不是形式主义**：手机显示"今天 3 次"、
网页显示"今天 2 次"，用户会认为软件坏了；更糟的是网页多出一个槽位，用户点它打卡，
落库的 `slot_index` 手机上不存在 —— 那条记录在手机上永远看不到，反过来像"改了没生效"。

## 模块

| 文件 | 对应 Dart | 说明 |
|---|---|---|
| `rules/local_date.mjs` | `model/local_date.dart` | `yyyy-mm-dd`，内部用 epochDay 整数运算 |
| `rules/local_time.mjs` | `model/local_time.dart` | 只有时分；`addMinutes` 返回 `[天数, 时刻]` |
| `rules/repeat_rule.mjs` | `model/repeat_rule.dart` | 周几 / 每 N 天 / 单双周 / 每月几号，取交集 |
| `rules/time_rule.mjs` | `model/time_rule.dart` | fixed / meal / interval / combined |
| `rules/course.mjs` | `model/course.dart` | 疗程：长期 / 起止 / 连续 N 天 |
| `rules/scheduler.mjs` | `scheduling/scheduler.dart` | 展开器，**全项目唯一有算法复杂度的地方** |
| `rules/edit_window.mjs` | `model/checkin.dart` 的 `EditWindow` | 30 天补卡窗口 |
| `rules/task_spec.mjs` | 无（App 里无需这层） | `tasks` 裸行 → `ScheduleSpec` |
| `rules/today.mjs` | 无（App 里是 DB 查询） | 读模型：某成员某天的待办清单 |

## 移植时踩到的三个坑（每个都有对应测试）

| 坑 | 正确写法 | 写错的症状 |
|---|---|---|
| 跨天折算的取整 | `Math.floor` | `Math.trunc(-50/1440)` 是 `-0`，"饭前 60 分钟"落到**当天**而不是前一天 |
| 单双周基准日 | 固定 1970-01-01 那周为第 0 周 | 改成"从今天起算"，用户一改规则单双周整体位移 |
| `slot_index` 分组 | 按 `(taskId, 疗程日)` 分组 | 全局累加 → 手机上不存在的 index，打卡记录丢失 |

> ⚠️ **一个诚实说明**：早期注释里写"负数取模必须 floorMod，否则出错"，
> 实测**不成立** —— `everyNDays` 的判据是 `rem === 0`，`%` 和 floorMod 在这件事上等价
> （穷举 `a∈[-100,100]`、`n∈[1,30]` 差异 0 处）。`mod()` 留着是为了表达意图，
> 不是为了修 bug，所以**没有**为它编一条"改坏也不会红"的测试。

## 已知缺陷

`CombinedTimeRule` 的跨午夜问题（BUG-1）见
[docs/architecture.zh_CN.md §7.2](../docs/architecture.zh_CN.md)。
本目录的实现**故意与 Dart 保持一致**（都错），这样两端结果仍然相同。
