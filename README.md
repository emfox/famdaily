# Famdaily

**A family check-in app.** Someone has to remember — meds, jump rope, bedtime.

一个以家庭为单位的打卡工具：一个账号下维护几位家人，给每个人设定每天要做的事，按时提醒、一键代打卡、看谁做到了。

不是"习惯养成"，是**替家人记着**。

---

## 为什么做这个

吃药、跳绳、量血压这类事，本身都不难。难的是**有人得记着**，而且想知道**到底做了没有**。

市面上的习惯类 App 都在激励你变成更自律的人。这个不是——它只记录家里发生了什么，不评判。
一瓶水没喝，它可以老实记成"没做"，而不是逼你补一个勾。

## 核心设计

| 决策 | 说明 |
|---|---|
| 一个账号，成员只是标签 | 家人不需要注册、没有密码，只是名字 + 头像 |
| 打卡结果三态 | 完成 / 补卡 / **没做**。补卡≠把没做标成做了 |
| 提醒必须锁屏准时 | 所以是原生 App，不是网页 |
| 数据本地为主 | 离线完全可用，网页端只做同步节点 |
| 不做连续打卡天数 | 连续天数会逼人为了保数字而补卡，数据就脏了 |

## 文档

| 文档 | 内容 |
|---|---|
| [docs/requirements.zh_CN.md](docs/requirements.zh_CN.md) | 需求文档：功能、规则、场景、待定项 |
| [docs/ui-spec.zh_CN.md](docs/ui-spec.zh_CN.md) | 界面描述：页面流程 + 框架图 + 状态规则 |
| [docs/architecture.zh_CN.md](docs/architecture.zh_CN.md) | 架构说明：App/网页分工、数据流、同步策略 |
| [docs/tech-stack.zh_CN.md](docs/tech-stack.zh_CN.md) | 技术选型：框架、版本矩阵、分层、提醒实现 |

## 计划

| 阶段 | 交付 |
|---|---|
| P1 | 原生 App 单机版：成员、模板、项目、提醒、打卡、统计 |
| P2 | 历史日历、补卡、数据导出/导入 |
| P3 | 网页端 + 同步（成员打卡链接、PC/平板看板） |

## 技术栈

| 层 | 选型 |
|---|---|
| App | **Flutter ≥ 3.44 / Dart 3.12**（一套代码出 iOS + Android） |
| 状态 / 路由 | Riverpod 3 · go_router 18 |
| 本地存储 | **Drift**（SQLite，App 本地为主副本） |
| 提醒 | flutter_local_notifications 22 + timezone（iOS 64 条滚动窗口） |
| 网页端与同步节点 | Node + SQLite（P3） |

完整版本矩阵、代码分层与关键取舍见[技术选型](docs/tech-stack.zh_CN.md)。

## 当前进度

| 模块 | 状态 |
|---|---|
| 需求 / 界面 / 架构 / 选型 文档 | ✅ 定稿 |
| `lib/domain/model`（日期、时刻、重复规则、疗程、打卡三态） | ✅ |
| `lib/domain/scheduling`（排程展开器，跨午夜 / 饭前偏移） | ✅ |
| `lib/domain/stats`（完成率 / 准时率口径） | ✅ |
| `lib/domain/notification`（通知 ID、窗口策略、免打扰、规划器） | ✅ |
| `lib/data/db`（Drift 六表 + DAO + schema 快照） | ✅ |
| `lib/data/notifier` + `reminder_scheduler`（平台通知 + 总调度） | ✅ |
| 首页今日清单（时间轴 / 成员双视图、五态、打卡、补卡/没做弹层） | ✅ |
| 新建打卡项（三步式：模板 → 基本信息 → 什么时候做） | ✅ |
| 历史日历 + 某日明细 + 30 天内补卡 | ✅ |
| 统计（完成率 / 准时率，按成员拆分） | ✅ |
| 成员管理（预置头像、排序、软删除） | ✅ |
| 打卡凭证（文字备注 + 照片，照片只存本地） | ✅ |
| 导出备份 / 覆盖恢复（入口藏在设置里） | ✅ |
| 提醒设置（总开关、15 分钟二次催办、免打扰） | ✅ |
| 打卡项详情（规则复述 + 三个数字 + 最近记录 + 暂停/归档/删除） | ✅ |
| **P1 / P2 全部完成** | ✅ |
| P3：网页端 + 同步 | ⬜ 下一步 |

**486 个测试全绿（含大量 Widget 测试，界面是真的画出来了才通过），`flutter analyze` 零问题。**

```bash
cd app
flutter pub get
flutter test          # 486 个测试，十几秒跑完
flutter analyze
```

### 构建产物（已验证可出包）

三个目标都真机级别地构建过了，不是"应该能过"：

| 目标 | 命令 | 结果 |
|---|---|---|
| Android APK | `flutter build apk --debug` | ✅ `app-debug.apk`（90MB，arm64 单 ABI） |
| Web | `flutter build web --release` | ✅ `build/web`，wasm 试运行也通过 |
| Linux 桌面 | `flutter build linux --debug` | ✅ `build/linux/x64/debug/bundle` |

> **还没做的**：把 APK 装进真手机点一遍。沙箱里没有设备，所以系统弹窗、
> 相机、通知横幅这些只有上手才知道的环节仍是空白。构建通过 ≠ 真机可用。

打完包务必跑一下自检：

```bash
./tool/check_apk.sh        # 确认 libsqlite3.so 真的在 APK 里
```

**这个自检不是形式主义**。第一版 APK 装到手机上直接弹"启动失败"：

```
Invalid argument(s): Couldn't resolve native function 'sqlite3_temp_directory'
  in 'package:sqlite3/src/ffi/libsqlite3.g.dart'
Failed to load dynamic library 'libsqlite3.so'
```

原因是 `pubspec.yaml` 里有一段 `hooks: user_defines: sqlite3: source: system`
——那是沙箱里绕开 github 下载的临时办法，让 Dart 去加载操作系统自带的
libsqlite3。桌面和 `flutter test` 都能用，但 **Android 不提供公开的
libsqlite3.so**，于是构建全程零警告，装上就崩。该段已删除，
`sqlite3_flutter_libs` 恢复打 native 库的正常路径（APK 因此从 90MB 涨到 104MB）。

**三个构建期才暴露的坑**（都是"编译能过、装上就废"或"直接编不过"的类型，已修）：

1. **`flutter_local_notifications` 要求 core library desugaring**。
   它内部用 `java.time`，而 `java.time` 在 Android 上要 API 26；本项目
   `minSdk = 24`（刻意不抬，家里旧机器要能用）。缺少时构建硬失败在
   `:app:checkDebugAarMetadata`。已在 `app/build.gradle.kts` 开
   `isCoreLibraryDesugaringEnabled` 并加 `desugar_jdk_libs` 依赖。
2. **Android 11+ 的包可见性**。`image_picker` 走系统相机 / 相册的 Intent，
   `<queries>` 里不声明 `IMAGE_CAPTURE` 和 `GET_CONTENT`，表现是**点了没反应**，
   不报错、不闪退，最难查。已补，并说明为什么故意不申请 `CAMERA` 权限。
3. **iOS 缺 `NSCameraUsageDescription` 是闪退，不是弹窗被拒**。
   三个 UsageDescription 已补齐。

另外把 `dart:io` / `drift/native.dart` 换成了条件导入（`db_connection.dart`
选 io 还是 web 实现）。不这么做 Web 编译直接失败：
`Dart library 'dart:ffi' is not available on this platform`。

### 提醒怎么排的（一层一句话）

```
项目规则 ──展开器──▶ 具象槽位 ──规划器──▶ 待排通知 ──平台──▶ 系统通知
          (哪天几点)          (剔除已办/免打扰/过去的)   (zonedSchedule)
```

三个地方最容易出错，都已经单测钉死：

1. **跨午夜**：21:00 饭后 4 小时 = 次日 01:00。Dart 的 `~/` 和 `%` 对负数向零截断，
   必须用 `(a / b).floor()`，否则"饭前 30 分钟"会落到错误的日期。
2. **打了卡还催**：通知 ID 由 `(项目, 日期, 第几次, 种类)` 哈希推出，
   打卡后按同样输入算一遍就能精确取消，不靠"记住刚才排了哪条"。
3. **iOS 64 条上限**：超限时系统挤掉的是**最老的**——正好是今天最早那条。
   所以按日均条数自适应窗口天数，上限只排 56 条，留 8 条余量。

调试入口：App 底部"提醒调试"，能看到窗口覆盖到哪天、展开多少槽位、
为什么被跳过、以及每条槽位的通知 ID。

> `lib/domain/**` 是纯 Dart，禁止 `import 'package:flutter/...'`；CI 里有 grep 卡口。
> 这条是为了让排程规则能脱离模拟器单测，也是 P3 网页端复刻规则时的参考实现。

---

<sub>文档中的 🟡 表示"按此默认值执行，可推翻"。</sub>
