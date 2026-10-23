> **版本**：v2（决策已定稿）　|　**最后更新**：2026-10-23
> 配套：[requirements.zh_CN.md](./requirements.zh_CN.md) · [ui-spec.zh_CN.md](./ui-spec.zh_CN.md) · [architecture.zh_CN.md](./architecture.zh_CN.md)
>
> 本文回答三个问题：**用什么写、版本怎么钉、代码怎么分层。**
> 所有版本号均为 2026-10-23 当天从 pub.dev / Flutter 官方 release 源实测查得，不是记忆值。

# Famdaily 技术选型

## 0. 一页结论

| 项 | 选型 | 一句话理由 |
|---|---|---|
| 客户端框架 | **Flutter**（Dart 3） | 一套代码双端；本地库/通知插件成熟；将来做桌面端顺 |
| 最低 Flutter 版本 | **3.44.0 / Dart 3.12**（建议团队统一到 3.47.7） | 由 `go_router 18` 与 `flutter_local_notifications 22` 双向夹出 |
| 状态管理 | **Riverpod 3**（`flutter_riverpod`） | 编译期安全、无需 BuildContext、测试友好 |
| 路由 | **go_router** | 声明式，深链（`famdaily://checkin/{taskId}` 供通知点击）原生支持 |
| 本地数据库 | **Drift**（SQLite） | ✅ **Isar 已淘汰**，见 §2.2 |
| 提醒 | **flutter_local_notifications 22** + **timezone** | 锁屏准时响，这是整个架构的地基 |
| 补排程 | **不加 workmanager**（P1），仅"启动/回前台滚排" | 见 §4.3，这条能砍掉一整类后台失败 |
| 不可变模型 | **freezed** + json_serializable | 数据类带 `copyWith`/相等性，同步比对靠它 |
| 照片 | **image_picker** + 自行压缩落盘 | 图片放文件系统，库里只存相对路径 |

**已定稿**：最低 Flutter **3.44.0 / Dart 3.12**；浮动间隔 P1 砍掉；回看不限 / 补卡与"没做" 30 天；`domain/` 零 Flutter 依赖。见 §8。

---

## 1. 硬约束先摆出来

选型不是"哪个库好"，是"哪个库不违反约束"。这个项目的硬约束只有四条：

| # | 约束 | 来源 | 对选型的直接影响 |
|---|---|---|---|
| C1 | **提醒必须锁屏准时响**，误差可接受 ≤1 分钟 | 需求 3.5 | 必须原生本地通知精确调度；排除纯 Web/PWA |
| C2 | **离线完全可用**，数据本地为主副本 | 需求 3.8 | 必须本地关系型数据库，不能依赖网络 |
| C3 | **一天最多催 2 次，且第二条要能撤销** | 需求 3.5（15 分钟二次催办，完成则取消） | 通知 ID 必须**可推导**，能单条取消 |
| C4 | **规则组合极多**（每日/每周几/每 N 小时/浮动间隔/疗程） | 需求 3.2.1 三层规则 | 需要一个能展开成"未来 N 天具体时刻列表"的纯函数层 |

C3 和 C4 合起来决定了本方案的核心设计：**"排程展开器"**（§5.2）。它把任意规则组合折成一条扁平的 `notification_id ↔ (task_id, date, slot)` 映射，写入数据库。提醒、取消、补排程三件事全部读这张表，不需要任何运行时魔法。

---

## 2. 框架：Flutter vs React Native

### 2.1 对比

| 维度 | Flutter | React Native | 本项目权重 |
|---|---|---|---|
| 本地数据库 | Drift（类型安全 SQL，迁移成熟） | 多为 WatermelonDB / op-sqlite，ORM 生态弱一档 | 🔴 高（数据是主副本） |
| 本地通知精确调度 | `flutter_local_notifications` 一线成熟 | `notifee` 同样成熟 | 🟡 平 |
| 自绘一致性 | 双端像素级一致，老人机大字排版可控 | 依赖原生控件，双端差异要单独调 | 🔴 高（大字页） |
| 团队上手 | Dart，语法接近 TS/Kotlin | JS/TS，人更好找 | 🟡 取决于你 |
| 桌面端（未来 PC 客户端） | 一套代码出 Win/macOS | 需 react-native-windows/macos，坑多 | 🟢 低（近期只要网页） |
| 包体积 | 空壳约 +8~12MB | 更小 | 🟢 低 |

**结论：Flutter。** 权重最高的一条是 **Drift**——这个项目的数据模型（成员 / 项目 / 重复规则 / 打卡记录 / 排程实例 / 变更日志，六张表带外键和迁移）用 SQL 表达是最省心的，RN 侧没有同等成熟的选择。

> 如果团队只有 TS 背景、且不想学 Dart，那 RN 也完全能做，代价是数据库层会痛。这是人的问题不是技术的问题，你比我清楚。

### 2.2 ⚠️ 排除 Isar（实测，不是传闻）

我查了 pub.dev 上 `isar` 的最新版本：

```
isar  3.1.0+1   environment: sdk >=2.17.0 <3.0.0
```

**它卡在 Dart 2.x。** 这意味着在 Dart 3 项目里连依赖都解析不了（null safety 上一代）。社区分支 `isar_community` 虽可用，但已是"志愿者维护的兼容层"，不适合做新项目的地基。

**所以数据库只有一个答案：Drift。** 顺带一提，Drift 生态近期有个变化必须知道：

| 变化 | 说明 | 我们要做什么 |
|---|---|---|
| `sqlite3_flutter_libs` 已标 EOL | 包名带 `+eol`，README 明说"升级到 `package:sqlite3` 3.x 后应移除本依赖" | **不要手动加这个包**；用 `drift_flutter` 统一装配，它对内锁 `sqlite3 ^3.0.0` + 兼容壳，我们不直接碰 |
| `sqlite3` 升到 3.7.1 | 改用 Dart 的 `hooks`/`code_assets` 机制编译原生库 | 首次构建会需要 native 工具链；Android 需较新 NDK（Flutter 3.44 自带的够用） |

**动作**：依赖只写 `drift` + `drift_flutter`，不写 `sqlite3_flutter_libs`，也不写 `sqlite3`。让 `drift_flutter` 决定底层。

---

## 3. 版本矩阵（实测，2026-10-23）

### 3.1 生产依赖

| 包 | 选定版本 | pub.dev 最新 | 该版本的 SDK 门槛 |
|---|---|---|---|
| `flutter` | **≥ 3.44.0** | 3.47.7 | — |
| `dart` | **≥ 3.12.0** | 3.13.5（随 3.47） | — |
| `flutter_riverpod` | **^3.4.3** | 3.4.3 | sdk ^3.12.0 |
| `go_router` | **^18.1.1** | 18.1.1 | sdk ^3.12.0, flutter **≥3.44.0** |
| `drift` | **^2.35.2** | 2.35.2 | sdk ≥3.10.0 |
| `drift_flutter` | **^0.3.1** | 0.3.1 | sdk ≥3.10.0 |
| `flutter_local_notifications` | **^22.3.2** | 22.3.2 | sdk ^3.10.0, flutter ≥3.38.1 |
| `timezone` | **^0.11.2** | 0.11.2 | sdk ^3.10.0 |
| `flutter_timezone` | **^5.1.1** | 5.1.1 | sdk ≥3.4.0, flutter ≥3.22.0 |
| `freezed` | **^4.0.3** | 4.0.3 | sdk ≥3.13.0 ⚠️ 见 §3.3 |
| `json_serializable` | **^6.15.2** | 6.15.2 | sdk ^3.12.0 |
| `path_provider` | **^2.1.6** | 2.1.6 | flutter ≥3.38.0 |
| `image_picker` | **^1.2.4** | 1.2.4 | sdk ^3.11.0, flutter ≥3.41.0 |
| `shared_preferences` | **^2.5.6** | 2.5.6 | sdk ^3.11.0, flutter ≥3.41.0 |
| `table_calendar` | **^3.3.0** | 3.3.0 | sdk ≥3.0.0（宽松，安全） |
| `flutter_slidable` | **^4.0.3** | 4.0.3 | flutter ≥3.27.0 |
| `uuid` | **^4.6.0** | 4.6.0 | sdk ≥3.0.0 |
| `intl` | **^0.20.3** | 0.20.3 | sdk ^3.9.0 |
| `archive` | **^4.5.2** | 4.5.2 | 导出备份 zip |
| `file_picker` / `share_plus` | ^13.1.0 / ^13.3.1 | 同 | 导入导出 |
| `clock` | **^1.1.3** | 1.1.3 | 测试里伪造"现在" |

**dev 依赖**：`build_runner ^2.17.1`、`drift_dev`（随 drift 2.35.x）、`freezed_annotation`、`riverpod_generator ^4.0.9`（可选，也可以手写 Provider）。

### 3.2 ⚠️ 两个包把最低版本顶上去了

这是全文唯一需要你决策的技术点，我把账算清楚：

```
go_router        18.1.1  →  flutter >=3.44.0
                 17.5.0  →  flutter >=3.38.0   （降 1 个大版本可省半年）
flutter_local_notifications 22.3.2 → flutter >=3.38.1
shared_preferences 2.5.6 → flutter >=3.41.0   （可钉 2.5.5 → 3.35）
image_picker     1.2.4   → flutter >=3.41.0   （可钉 1.2.3 → 3.38）
google_fonts     9.0.0   → flutter >=3.47.0   ← 别用最新，或干脆不用
```

Flutter 稳定版时间线（官方 release 源）：

| 版本 | 发布 | Dart |
|---|---|---|
| 3.38.0 | 2025-11-12 | 3.10.0 |
| 3.41.0 | 2026-02-11 | 3.11.0 |
| **3.44.0** | **2026-05-18** | **3.12.0** |
| 3.47.7 | 2026-10-08 | 3.13.5 |

**推荐：最低 Flutter 3.44.0，团队实际用 3.47.7。** 理由：

- 单人/小团队起步，没有"老设备要兼容"的历史包袱，定低版本纯属给自己加锁
- 3.44 到今天约 5 个月，稳定期足够
- 反过来看，钉 3.38 会让 4 个包的版本停在半年前，将来升级是一次性的痛

**但如果你或队友的机器上装的是 3.38/3.41**，那就改钉这一套，功能零损失：

```yaml
go_router: ^17.5.0
shared_preferences: ^2.5.5
image_picker: ^1.2.3
flutter_riverpod: ^3.3.2   # 3.4.x 要 sdk ^3.12
# environment: sdk: ">=3.10.0 <4.0.0", flutter: ">=3.38.1"
```

### 3.3 ⚠️ 别装 Flutter 3.47 就顺手升 freezed 4 / google_fonts 9

- `freezed 4.0.3` 要求 `sdk >=3.13.0`，只有 Flutter **3.47** 满足。用 3.44 的话 `freezed` 只能到 3.x 系列，写依赖时**不要写 `^4.0.3`**，让 pub 自己解析或显式钉 3.x。
- `google_fonts 9.0.0` 要求 `flutter >=3.47.0`，且它会在**运行时下载字体**——一个"提醒家人吃药"的 App 首屏不该依赖外网字体。**建议直接不用**，见 §6 字体。

---

## 4. 提醒：本项目最脆的一环

### 4.1 平台硬限制（官方 README 原文要点）

| 平台 | 限制 | 我们的对策 |
|---|---|---|
| **iOS** | 系统**只保留最后排的 64 条**待处理通知（iOS 9+） | 必须主动**滚动窗口**：永远只排未来 64 条以内，见 §4.2 |
| **Android** | 精确闹钟需 `SCHEDULE_EXACT_ALARM`（用户可授权、可撤销）或 `USE_EXACT_ALARM`（需商店审核，适合闹钟/日历类） | P1 用 `SCHEDULE_EXACT_ALARM` + 引导授权；权限被撤销时降级为不精确并**在设置页提示** |
| **Android** | 13+ 需 `POST_NOTIFICATIONS` 运行时权限 | 首启在"建第一个项目"时请求，不在冷启动弹 |
| **Android** | 部分厂商（如三星）对 AlarmManager 有 **500 条**上限 | 我们的窗口（§4.2）远低于此 |
| **通用** | 权限被撤销后，插件会记错误日志，**循环通知也不再调度** | 所有排程走**一次性通知逐条排**，不用 `periodicallyShow` |

> ⚠️ 最后一条很关键：`periodicallyShow`（循环通知）在权限变化后可能静默失效，而且它的周期最小单位是"每 N 分钟/小时"这种固定节奏，表达不了我们"工作日早 7:30 + 周一三五晚 8 点"的混合规则。**全部用 `zonedSchedule` 一次性排**，用展开器（§5.2）生成。

### 4.2 滚动窗口（解决 64 条上限）

```
每次"排程时机"触发时：
  1. 计算未来窗口 W 天（按当前排程密度自适应：最少 3 天，最多 7 天，且总条数 ≤ 60）
  2. 清掉窗口内已排但不再需要的（规则改了/已打卡/项目暂停）
  3. 重新排窗口内所有待做的
```

排程时机只有 4 个，全部是**前台事件**：

| 时机 | 为什么够 |
|---|---|
| App 冷启动 | 每天都有人开 |
| 从后台回前台 | 同上，且是最常见的"排程补齐"点 |
| 本地数据有变更后（防抖 5s） | 改规则/打卡后立即重算 |
| 每日首次进入时（跨天检测） | 跨过午夜，把新一天排进去 |

> **为什么不靠后台任务补排？** 见 §4.3。

### 4.3 为什么不引入 `workmanager`（P1 决定：不加）

| 事实 | 后果 |
|---|---|
| iOS `workmanager` 基于 `BGTaskScheduler` | 系统**不保证**何时执行，可能几天不跑；仅"有机会"时调用 |
| Android `WorkManager` 周期任务最小间隔 15 分钟 | 且受 Doze 白名单影响，不是准点 |
| 它解决的是"App 长时间不打开也要继续响" | 我们的场景是**天天有人开**的家庭 App |

**所以 P1 不加。** 反而要接受一个诚实的边界：

> **如果用户连续 60 天以上完全不打开 App，iOS 侧排程会耗尽，提醒会停。**
> 缓解：① 窗口尽量排满（≤60 条，按每天 3 条算约 20 天）；② 设置页显示"提醒已排至 X 月 X 日"；③ 通知权限/排程异常时在设置页给一行黄字，不做弹窗。

P3 上网页端时再考虑 `workmanager` 或服务端推送——那时"服务器能主动发"才真正解决问题。

### 4.4 二次催办怎么实现（C3）

不用"排两条通知然后想办法撤第二条"，用**确定性 ID + 可取消**：

```
notification_id = hash(task_id, date, slot_index, kind) & 0x7FFFFFFF
  kind: 0 = 到点提醒, 1 = 15分钟催办
```

- 到点时**同时排两条**（T 和 T+15min），ID 不同
- 用户在 15 分钟内完成 → 用 `slot_index` 反查并 `cancel(id(...,1))`
- 只催 1 次：天然成立，因为只排了 1 条催办
- 🟡 免打扰时段：**到点提醒照发**（"用户明确设的时间"），但若 T+15 落在免打扰内，**催办那条直接不排**——正好是需求 3.5 的语义

### 4.5 时区与夏令时

- `timezone` 内置 IANA 库，`flutter_timezone` 取设备当前时区名
- 所有 `zonedSchedule` 用 `matchDateTimeComponents: null`（一次性），**不要**用 `DateTimeComponents.time` 让系统做每日重复——那样绕过了我们的展开器，改规则会失控
- 用户换时区：监听 `AppLifecycleState.resumed` 时比对时区名，变了就清窗重排
- ⚠️ 中国无夏令时，但**不能写死 UTC+8**：万一有人在外地/出差，会全错

---

## 5. 代码分层

### 5.1 依赖方向（单向，永不反向）

```
        ┌──────────────────────────────┐
        │  feature/  （UI + 页面状态）  │  ← Flutter, Riverpod
        └──────────────┬───────────────┘
                       ↓ 只能往下
        ┌──────────────────────────────┐
        │  domain/  （纯 Dart，零 Flutter）│  ← 模型 + 规则 + 排程展开
        └──────────────┬───────────────┘
                       ↓
        ┌──────────────────────────────┐
        │  data/    （Drift + 仓储实现） │
        └──────────────────────────────┘
```

**`domain/` 里不许出现 `import 'package:flutter/...'`**，用 `analysis_options.yaml` 的 `custom_lint` 或一条 CI grep 卡死。这样：

- 排程展开器可以**纯 Dart 单测**（不需要模拟器）
- 将来网页端（TS）要复刻同一套规则时，Dart 代码是**可直接对照的参考实现**
- "以后加云端适配器"只需在 `data/` 加一个实现

### 5.2 核心模块：排程展开器（`domain/scheduling/`）

这是全项目**唯一有真正算法复杂度**的地方，也是最该先写、先测的地方。

```
输入：项目 + 重复规则 + 时刻规则 + 疗程 + 窗口 [from, to]
输出：List<Slot>   其中 Slot = (项目ID, 本地日期, 序号, 应完成时刻, 宽限截止)

实现分两步（关键）：
  ① 展开"哪些天"  ← 重复规则 × 疗程，返回 Set<LocalDate>
  ② 对每天展开"哪些时刻" ← 时刻规则，返回 List<LocalTime>
  最后 ③ 笛卡尔积，排序，裁剪到窗口
```

两步分离的好处：**"工作日每天 8 点"和"周一三五 8 点/20 点"用同一套代码，只是两份输入的笛卡尔积**。三层规则表（需求 3.2.1）只是 UI 分组，**底层数据结构只有一套**：

```dart
// 重复规则：三个可选条件的交集，全空 = 每天
class RepeatRule {
  final Set<int>? weekdays;      // 1..7；null = 不限
  final int? everyNDays;         // 隔 N 天；null = 不限
  final ParityFilter? parity;    // 单周/双周/仅工作日/仅周末
  final List<int>? monthDays;    // 每月几号，如 [1, 15]；null = 不限
}

// 时刻规则：四种基本型 + 组合
sealed class TimeRule {
  TimeRule fixed(TimeOfDay t);                       // 固定时刻
  TimeRule timesPerDay(List<TimeOfDay>);             // 一天 N 次（含不等间隔）
  TimeRule byMeal(MealAnchor a, Duration offset);    // 跟随三餐 ± 偏移
  TimeRule interval(Duration every, TimeOfDay from, TimeOfDay to); // 每 N 小时，限时段
  // 多个 TimeRule 相加 = 多个时间段
}

// 疗程：影响"展开到哪天为止"和"某天是否在疗程内"
class Course { LocalDate? start; LocalDate? end; int? days; }
```

**必须有单测的边界**（都是会真出 bug 的地方）：

| 用例 | 期望 |
|---|---|
| 每 2 小时 / 9:00–21:00 | 9,11,13,15,17,19,21 共 7 条（含端点）还是 6 条？**定：含起含止 → 7 条**，写进测试 |
| 每 2 小时 / 9:00–21:00 但跨午夜 | 禁止跨午夜，UI 直接不允许 |
| 隔周 + 周一三五 | 交集语义：单周的周一/三/五 |
| 疗程 7 天 + 每日 3 次 | 21 个槽位，最后一天 23:00 之后不再生成 |
| 疗程最后一天 + 浮动间隔 | 浮动间隔不排到疗程结束后 |
| 补卡窗口 30 天 vs 日历回看**不限** | 两个数字分开，别混；判定函数 `canEdit(date)` 单点实现（决策 3） |

### 5.3 目录结构

```
famdaily/
├─ lib/
│  ├─ main.dart
│  ├─ app.dart                     # MaterialApp.router、主题、locale
│  ├─ router.dart                  # go_router 路由表 + 深链
│  ├─ domain/                      # ★ 纯 Dart，零 Flutter
│  │  ├─ model/                    # member / task / checkin / repeat_rule / slot
│  │  ├─ scheduling/               # ★ 排程展开器 + 单测
│  │  ├─ stats/                    # 完成率·准时率·放弃率（需求 3.7）
│  │  └─ repo/                     # 仓储接口（抽象类）
│  ├─ data/
│  │  ├─ db/                       # drift 表定义、DAO、迁移
│  │  ├─ repo_impl/                # 仓储实现
│  │  ├─ notifier/                 # 通知调度器（封装 flutter_local_notifications）
│  │  └─ backup/                   # 导出/导入 zip（需求 3.8.1）
│  ├─ feature/
│  │  ├─ home/                     # 今日清单（时间轴/成员双视图）
│  │  ├─ history/                  # 日历 + 某日明细 + 补卡
│  │  ├─ task_edit/                # 新建/编辑项目（三层规则折叠表单）
│  │  ├─ members/                  # 成员列表/编辑
│  │  └─ settings/                 # 含「数据管理 → 导出备份」（藏起来）
│  └─ ui/                          # 设计系统：色板、间距、五态样式、大字组件
├─ test/
│  ├─ domain/scheduling/           # ★ 覆盖率目标 ≥ 90%
│  └─ domain/stats/
└─ integration_test/
```

### 5.4 五态样式实现：一处定义，全局复用

`ui/` 里做一个 `CheckinStateStyle` 查表，把 [ui-spec](./ui-spec.zh_CN.md) 里那张五态表**翻译成代码常量**，禁止任何页面自己写颜色：

```dart
// 状态 → 视觉（唯一来源）
enum CheckinVisual { pending, overdue, doneOnTime, doneMakeup, skipped }

extension on CheckinVisual {
  Color get rowBackground => ...;   // 白 / 淡红 / 白+淡绿边 / 白+淡绿边 / 米白
  IconData get leading    => ...;   // 空心圆 / 空心圆 / 实心绿勾 / 空心绿勾 / 灰小叉
  bool get strikeThrough  => ...;   // false / false / true / true / true
}
```

这样"没做不许标红"这条产品原则就变成了**代码约束**，而不是一句文档里的话。

---

## 6. 数据模型与迁移

### 6.1 六张表

| 表 | 关键列 | 备注 |
|---|---|---|
| `members` | id, name, avatar, sort, deleted_at | 软删除，历史记录保留 |
| `tasks` | id, member_id, name, note, icon, status(paused/archived/deleted), course_*, repeat_json, time_json | 规则存 JSON，语义版本号带上 |
| `checkins` | id, task_id, date, slot_index, state(done/makeup/skipped), done_at, note, photo_path | **唯一索引 (task_id, date, slot_index)** |
| `slots` | task_id, date, slot_index, due_at, remind_id, followup_id | 排程展开结果的落地表，提醒靠它反查 |
| `settings` | key, value | shared_preferences 存不了结构化，用表 |
| `change_log` | id, entity, entity_id, op, changed_at, synced | P3 同步用，P1 就开始记（不然 P3 无从下手） |

> 💡 `change_log` 从 P1 就开始写，只写不读。这个决定几乎零成本，但省掉 P3 时"历史数据怎么补同步"的灾难。

### 6.2 迁移策略

- Drift `schemaVersion` 从 1 开始
- **每次改表结构必须同时提交 migration 和 `drift_dev schema dump` 生成的快照**，CI 跑 `drift_dev schema steps` 校验
- 需求里"改规则不影响历史"（3.2.1）意味着：**`checkins` 里要冗余当时算出的 `due_at`**，不能靠 join 当前规则重算。这是数据层最容易做错的一点。

### 6.3 ID 与同步

- 所有主键用 **UUIDv4（字符串）**，不用自增 int——P3 多端同步时自增 ID 会撞
- 所有可变实体带 `updated_at`（毫秒时间戳）+ `deleted_at`（软删）
- 打卡记录幂等：`(task_id, date, slot_index)` 唯一，冲突时**"已完成"优先**（架构文档 §3）

---

## 7. 其他决定

| 项 | 决定 | 理由 |
|---|---|---|
| 字体 | **系统字体**（iOS 苹方 / Android 思源黑体），不引 `google_fonts` | 老人大字页要的是字重和行高，不是花字；且不依赖运行时下载 |
| 图标 | 预置 SVG 图标集 + 名字首字色块兜底 | 需求 2「不选头像则自动生成色块+首字」 |
| 深色模式 | P1 不做，但色板用 `ColorScheme` 语义命名 | 现在不用，将来不用重写 |
| 本地化 | P1 只中文，但字符串全走 `l10n` | 双语建议留后路，成本极低 |
| 崩溃收集 | P1 不做 | 本地 App + 家庭用户，装了也是给自己看；P2 再说 |
| CI | GitHub Actions：`analyze` + `test` + `build_apk --debug` | 免费额度够 |
| 代码生成 | `build_runner`（drift + freezed + json） | 每次改模型跑一次，写进 README |

---

## 8. 已定决策（2026-10-23 拍板）

原第 8 节列了 3 个待决项，**已全部按推荐值确认**，连同"`domain/` 层零 Flutter 依赖"一起冻结。

### 决策 1 ✅：最低 Flutter 3.44.0 / Dart 3.12

采用 §3.1 全套最新依赖，**不降级**。开发机统一 Flutter **3.44.9**（该系列最后一个稳定补丁，Dart 3.12.2）或更高，建议团队直接上 3.47.7。

### 决策 2 ✅：浮动间隔 P1 砍掉

| 规则 | 决定 | 落地位置 |
|---|---|---|
| **浮动间隔**（"上次完成后 N 小时再提醒"） | ❌ **P1 不做，P2 再做** | 排程器（§5.2）**不引入**"上次完成时间"输入 |
| 单双周 / 隔周 | ✅ 保留 | `RepeatRule.parity` |
| 每月固定日 | ✅ 保留 | `RepeatRule.monthDays`（新增字段） |
| 多时间段 | ✅ 保留 | 多个 `TimeRule` 相加 |
| 深色模式 | ❌ 不做 | 色板用语义命名留后路 |

> ⚠️ 砍它的技术理由再记一次：**它和"提前排好通知"天然冲突**——完成时间未知，下次时间就未知，排不出通知。真要做得靠前台重算，本质是"打开 App 才算得对"。P2 做的时候也建议做成"打开时提示已到期"，而不是指望精确通知。

### 决策 3 ✅：时间窗口三个数字

| 动作 | 窗口 | 说明 |
|---|---|---|
| 历史日历回看 | **不限** | 数据都在本地，往前往后随便翻 |
| 补卡（makeup） | **30 天内** | 超过只展示当时结果，不可修改 |
| "没做"标记（skipped） | **30 天内** | 同上 |
| 今日打卡（done） | 当天 | 今天直接点勾不叫补卡（需求 3.6.4） |

> 组合含义：**翻到三个月前能看到那天没做，但改不了了。** 这个"能看不能改"的边界要在 UI 上明确表达——超过 30 天的行，操作按钮置灰并给一行小字"超出可修改期限"。

### 决策 4 ✅：`domain/` 层零 Flutter 依赖

`lib/domain/**` 内禁止 `import 'package:flutter/...'`。用两条锁死：

1. `analysis_options.yaml` 里的 `custom_lint`（或 `dart_code_metrics`）规则
2. CI 里一条 grep，命中即 fail：

```bash
! grep -rn "package:flutter/" lib/domain/ || (echo "domain 层被 Flutter 污染"; exit 1)
```

目的只有一个：**排程展开器能纯 Dart 单测**，且 P3 网页端复刻规则时有份可直接对照的参考实现。

---

## 9. 落地顺序

1. `flutter create` 起骨架，把 §3.1 依赖写进 `pubspec.yaml`，跑通空壳
2. **先写 `domain/scheduling/` 和它的单测**（不碰 UI），这是地基
3. Drift 建表 + 迁移快照 + 一个能跑通的 DAO
4. 通知调度器：iOS 64 条窗口 + 二次催办取消，单独做一个可手测的调试页
5. 才开始做 UI（首页三态 → 建项目表单 → 历史页）

> 顺序理由：2 和 4 是这个项目里**唯一可能推翻重来的部分**（规则算错、通知排不上）。先把它们做成可信的黑盒，UI 就是纯体力活。

---

<sub>🟡 表示"按此执行即可，可推翻"。本文所有版本号与 SDK 约束为 2026-10-23 实测，随生态演进会变，升级前请重查 pub.dev。</sub>
