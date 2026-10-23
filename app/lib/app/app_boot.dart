/// 冷启动时的依赖装配与初始化。
///
/// 顺序是有讲究的：
/// 1. 打开数据库（后面所有事都依赖它）
/// 2. 初始化通知插件 + 时区（**必须**在排程之前，否则时区还没设好，
///    排出来的时刻会整体偏移）
/// 3. 首次启动建"我"这个成员（需求 2：默认自带一个）
/// 4. 冷启动重排提醒
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db/app_database.dart';
import '../data/notifier/notification_service.dart';
import '../data/photo/image_picker_photo_picker.dart';
import '../data/photo/photo_store.dart';
import '../data/repo_impl/reminder_scheduler.dart';
import '../domain/model/member.dart' as domain;
import '../domain/notification/window_policy.dart';
import '../domain/model/local_date.dart';
import 'uuid.dart';

/// 装配完成后的全局依赖。
class AppServices {
  const AppServices({
    required this.db,
    required this.notifications,
    required this.scheduler,
    required this.photoPicker,
    required this.photoStore,
  });

  final AppDatabase db;
  final NotificationService notifications;
  final ReminderScheduler scheduler;

  /// 拍照 / 选图。抽成接口是为了 Widget 测试能注入假实现——
  /// 真的 image_picker 会拉起系统 UI，测试里一点就卡住。
  final PhotoPicker photoPicker;

  /// 照片落盘与读取（写相对路径，见 `photo_store.dart` 的说明）。
  final PhotoStore photoStore;
}

/// 启动引导。可重入（`init` 只会真正跑一次）。
class AppBoot {
  AppBoot();

  AppServices? _services;
  Future<AppServices>? _inflight;

  /// 已经装配好的依赖；未完成时为 null。
  AppServices? get services => _services;

  /// 是否首次启动（没有"我"这个成员）。
  bool isFirstLaunch = false;

  /// 冷启动重排的结果，给启动页展示"提醒已就绪"。
  RescheduleResult? firstReschedule;

  Future<AppServices> init() {
    return _inflight ??= _bootstrap();
  }

  Future<AppServices> _bootstrap() async {
    final db = AppDatabase();
    final notifications = NotificationService();

    // 时区/插件初始化失败不阻塞启动：提醒是附加值，进不了主界面才是灾难。
    try {
      await notifications.init();
    } catch (e) {
      debugPrint('[boot] 通知初始化失败：$e');
    }

    await ensureSelfMember(db);

    final scheduler = ReminderScheduler(db: db, notifications: notifications);
    final photoStore = PhotoStore();

    try {
      firstReschedule = await scheduler.reschedule(
        trigger: RescheduleTrigger.appLaunch,
      );
    } catch (e) {
      debugPrint('[boot] 首次重排失败：$e');
    }

    final services = AppServices(
      db: db,
      notifications: notifications,
      scheduler: scheduler,
      photoPicker: ImagePickerPhotoPicker(),
      photoStore: photoStore,
    );
    _services = services;
    return services;
  }

  /// 首次启动时建一个"我"。不做引导页——一个空列表比三步引导更快让人上手。
  ///
  /// 公开出来是给集成测试用的：测试从 `HomeShell(services:)` 起手时可以
  /// 跳过 `_bootstrap` 里的插件初始化，但**不能**跳过这一步——跳过了
  /// 首屏就是一个空壳，点「新建打卡项」只会弹"先加一个成员"。
  /// 让测试和真机共用同一份"首次启动"逻辑，比在测试里自己 insert 一个
  /// 名字更接近真实。
  Future<void> ensureSelfMember(AppDatabase db) async {
    final members = await db.listMembers();
    if (members.isNotEmpty) {
      return;
    }
    isFirstLaunch = true;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertMember(
      domain.Member(
        id: newId(),
        name: domain.Member.defaultSelfName,
        sortOrder: 0,
        createdAtMs: now,
        updatedAtMs: now,
      ),
      nowMs: now,
    );
    debugPrint('[boot] 首次启动，已创建成员「${domain.Member.defaultSelfName}」');
  }

  /// 供设置页/调试页使用：今天。
  LocalDate get today => LocalDate.fromDateTime(DateTime.now());

  void dispose() {
    // 数据库连接要显式关掉：不关的话热重载会留下旧连接，
    // 开发期会出现"改了 schema 但没生效"的假象。
    unawaited(_services?.db.close());
  }
}
