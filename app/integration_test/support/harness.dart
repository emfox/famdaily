/// 集成测试的装配：真 App、真数据库、假通知。
///
/// 为什么要单独一份而不是复用 Widget 测试的写法：
/// Widget 测试里页面是"摆在 test harness 里"的——谁构造它、传了什么参数，
/// 都由测试决定。用户报的「历史里人名变成已删除」那个 bug，恰恰是
/// **真实入口的构造参数漏了**，而 Widget 测试自己把参数补上了，所以永远测不出来。
///
/// 集成测试必须从这个方向走：`HomeShell(services:)` 起手 → 点底部导航 →
/// 点月历 → 断言屏幕上的字。中间不许直接构造页面。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:famdaily/app/app_boot.dart';
import 'package:famdaily/app/home_shell.dart';
import 'package:famdaily/app/test_clock.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/notifier/notification_service.dart';
import 'package:famdaily/data/photo/photo_store.dart';
import 'package:famdaily/data/repo_impl/reminder_scheduler.dart';
import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_config.dart';
import 'package:famdaily/data/sync/sync_service.dart';
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/notification/notification_planner.dart';
import 'package:famdaily/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;

/// 只记账、不碰系统通知的网关。
///
/// 真机上这里会是 `NotificationService`，但集成测试跑在没有通知权限的
/// 桌面/CI 环境里，真去排通知只会抛异常，反而把要测的主流程盖住。
/// 提醒的排程逻辑本身有专门的单测，这里只关心"打卡之后有没有让它静音"。
final class RecordingGateway implements NotificationGateway {
  List<PlannedNotification> plan = const [];
  final List<int> cancelledSlotIds = [];
  int cancelAllCount = 0;
  int applyCount = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => hasPermission();

  @override
  Future<bool> canScheduleExact() async => true;

  @override
  Future<bool> requestExactAlarms() async => true;

  @override
  Future<List<int>> pendingIds() async => [for (final n in plan) n.id];

  @override
  Future<int> applyPlan(
    List<PlannedNotification> incoming, {
    bool allowInexact = false,
  }) async {
    plan = incoming;
    applyCount++;
    return incoming.length;
  }

  @override
  Future<void> cancelSlot({
    required String taskId,
    required domain.LocalDate date,
    required int slotIndex,
  }) async {
    final hit = [
      for (final n in plan)
        if (n.taskId == taskId && n.date == date && n.slotIndex == slotIndex)
          n.id,
    ];
    cancelledSlotIds.addAll(hit);
    plan = [
      for (final n in plan)
        if (!(n.taskId == taskId && n.date == date && n.slotIndex == slotIndex))
          n,
    ];
  }

  @override
  Future<void> cancelAll() async {
    plan = const [];
    cancelAllCount++;
  }
}

/// 假的选图：直接给一张 1×1 PNG 的字节，不拉起任何系统 UI。
final class StubPhotoPicker implements PhotoPicker {
  StubPhotoPicker({this.bytes});

  /// null = 模拟"用户取消"。
  Uint8List? bytes;
  int pickCount = 0;

  static final Uint8List pngBytes = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    pickCount++;
    return bytes ?? pngBytes;
  }
}

/// 临时目录里的照片仓库：不碰用户的 documents 目录。
final class TempPhotoDirectory implements PhotoDirectory {
  TempPhotoDirectory(this.dir);

  final Directory dir;

  @override
  Future<Directory?> root() async => dir;
}

/// 一整套跑在临时目录上的假依肢。
final class Harness {
  Harness._({
    required this.db,
    required this.gateway,
    required this.picker,
    required this.scheduler,
    required this.photoStore,
    required this.tempRoot,
    required this.dbFile,
  });

  final AppDatabase db;
  final RecordingGateway gateway;
  final StubPhotoPicker picker;
  final ReminderScheduler scheduler;
  final PhotoStore photoStore;
  final Directory tempRoot;
  final File dbFile;

  /// 起一套新的。数据库落**真实文件**而不是内存：
  /// 内存库测不出"重启之后数据还在不在"，而这是用户真正会遇到的场景。
  static Future<Harness> create() async {
    final tempRoot = await Directory.systemTemp.createTemp('famdaily_it_');
    final dbFile = File(p.join(tempRoot.path, 'famdaily.sqlite'));

    final db = AppDatabase.forTesting(openFileConnection(dbFile.path));
    // 桌面运行时 flutter 会先设好 foreign_keys；这里手动开一次，
    // 保证和真机上的约束行为一致（软删除靠的正是这套约束不被破坏）。
    await db.customStatement('PRAGMA foreign_keys = ON');

    final gateway = RecordingGateway();
    final scheduler = ReminderScheduler(db: db, notifications: gateway);
    final photos = Directory(p.join(tempRoot.path, 'photos'))
      ..createSync(recursive: true);

    // 真机首次启动会建一个「我」（AppBoot.ensureSelfMember）。这里必须照做：
    // 跳过了首屏就是个空壳，点「新建打卡项」只会弹"先加一个成员"——
    // 那是测试脚手架自己的问题，不是 App 的 bug，但它会把所有用例都带偏。
    // 用生产那份逻辑而不是手工 insert，免得两边对"首次启动"的定义慢慢走散。
    await AppBoot().ensureSelfMember(db);

    return Harness._(
      db: db,
      gateway: gateway,
      picker: StubPhotoPicker(),
      scheduler: scheduler,
      photoStore: PhotoStore(directory: TempPhotoDirectory(photos)),
      tempRoot: tempRoot,
      dbFile: dbFile,
    );
  }

  /// 装配 AppServices。
  ///
  /// `notifications` 那个字段界面层根本没读过（真正发通知的是 scheduler
  /// 里的网关），所以这里给一个**永远不会被调用**的真实现——只要不调
  /// 它的方法，它就不需要插件。这样既不用为测试去改生产类型，
  /// 也不会因为用了假类型而绕开将来界面对它的使用。
  ///
  /// 同步给一个**没配对过**的实例：`syncNow` 会立刻返回 notConfigured，
  /// 一个请求都不发。集成测试跑在没网/有网都可能的环境里，绝不能让它
  /// 真的去连一个不存在的服务端。
  ///
  /// `sync` **必须是同一个实例**：它内部有定时器（防抖、退避），
  /// 每访问一次 getter 就新建一个的话，旧的那些定时器再没人管，
  /// 会在 `db.close()` 之后触发，报一句 "Can't re-open a database
  /// after closing it" 把测试判红。
  late final SyncService _sync = SyncService(
    db: db,
    config: SyncConfigStore(db),
    apiFactory: (baseUrl, transport) =>
        SyncApi(transport: transport, baseUrl: baseUrl),
  );

  AppServices get services => AppServices(
    db: db,
    notifications: NotificationService(),
    scheduler: scheduler,
    photoPicker: picker,
    photoStore: photoStore,
    sync: _sync,
  );

  /// 直接给 App 一套 services（跳过 bootstrap 的插件初始化）。
  ///
  /// bootstrap 在真实启动时会去初始化通知插件与文件目录，桌面/CI 上这些
  /// 要么弹权限、要么依赖 user home。集成测试要验证的是**界面与数据**，
  /// 所以从"依赖已装配好"这一步起手——但装配出来的东西与真机同构：
  /// 同一个 `HomeShell`、同一个 `ReminderScheduler`、同一个真实 sqlite 文件。
  ///
  /// [initialIndex] 交给 `HomeShell`，让指定 tab 成为首屏。这**不是**为了
  /// 少点一次导航——`IndexedStack` 会预创建全部子页面，而"预创建"发生在
  /// 首帧，也就是此刻的 `clock`。历史页的月份光标在 `initState` 里对齐
  /// 今天，若首屏是「今日」，历史页的 initState 仍然在同一个首帧里跑，
  /// 时钟一样是假的。这里显式暴露出来是为了让用例能**断言首屏就是历史页**
  /// 这一事实，免得靠 `find.text('历史').last` 这种脆弱的索引去猜。
  Widget app({int initialIndex = 0}) {
    return MaterialApp(
      title: 'Famdaily',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      theme: famdailyTheme(Brightness.light),
      darkTheme: famdailyTheme(Brightness.dark),
      themeMode: ThemeMode.light,
      home: HomeShell(services: services, initialIndex: initialIndex),
    );
  }

  Future<void> dispose() async {
    // 先停同步的定时器再关库：反过来定时器会在关库之后醒过来。
    _sync.dispose();
    await db.close();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  }
}

/// 把已经存在的库文件重新打开一次——模拟"杀掉 App 再启动"。
///
/// 直接 `AppDatabase.forTesting(openFileConnection(path))` 而不是另起一套
/// Harness：这里只想验证**文件里的数据还在**，不需要再来一份临时目录。
Future<AppDatabase> reopenDatabase(File file) async {
  final db = AppDatabase.forTesting(openFileConnection(file.path));
  await db.customStatement('PRAGMA foreign_keys = ON');
  return db;
}

/// 把时钟钉在"今天某个时刻"。
///
/// 所有页面都会读 `appNow()` 判断"能不能改"，不钉住的话测试跑在
/// 凌晨和跑在中午会得到不同结论——这种不确定性在集成测试里最难查。
///
/// **注意它不走 `withClock`**。`withClock` 是 zone-scoped 的，而
/// `IntegrationTestWidgetsFlutterBinding`（live binding，真渲染真跑帧）
/// 里页面的 `initState`/`build` 跑在**另一个 zone**（引擎那侧），
/// 读不到我们塞进 zone 的值——症状是测试体里 `clock.now()` 是 3 月，
/// 日历却画成 10 月。这里用 [TestClock] 直接钉全局变量，任何 zone 都认。
///
/// **可以嵌套**。钉住是全局状态，`atTime` 里再调一次 `atTime`
/// （`bootApp` 内部就有一层）不该把外层的钉住清掉——这曾经让整组用例
/// 在 `bootApp` 之后悄悄退回真实时钟，症状和没钉一样。这里用计数守住：
/// 只有最外层退出时才真正释放。
int _timeDepth = 0;

Future<T> atTime<T>(DateTime moment, Future<T> Function() body) async {
  final depth = _timeDepth++;
  final previous = TestClock.now;
  final wasEnabled = TestClock.enabled;
  TestClock.pin(moment);
  try {
    return await body();
  } finally {
    _timeDepth = depth;
    if (depth == 0) {
      TestClock.reset();
    } else {
      TestClock.now = previous;
      TestClock.enabled = wasEnabled;
    }
  }
}

/// 让时钟回到真实时间（不钉住）。
Future<T> atRealTime<T>(Future<T> Function() body) async {
  final depth = _timeDepth++;
  TestClock.reset();
  try {
    return await body();
  } finally {
    _timeDepth = depth;
  }
}
