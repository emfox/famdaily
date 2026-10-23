/// 备份的业务流程：导出、导出预览、恢复。
///
/// 只做编排，具体活儿都在 `backup_data.dart`（格式）和 `backup_io.dart`（文件）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/model/local_date.dart';
import '../db/app_database.dart' hide Member, Task, Checkin, Slot;
import 'backup_data.dart';
import 'backup_io.dart';
import '../../app/test_clock.dart';

/// 导出的结果：写在哪、多大、装了什么。
final class ExportResult {
  const ExportResult({
    required this.path,
    required this.fileName,
    required this.byteSize,
    required this.data,
  });

  final String path;
  final String fileName;
  final int byteSize;
  final BackupData data;

  /// `1.2 MB` 这样的可读大小。
  String get sizeLabel {
    if (byteSize < 1024) {
      return '$byteSize B';
    }
    if (byteSize < 1024 * 1024) {
      return '${(byteSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(byteSize / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 恢复前的预览：让用户在真正覆盖之前看清"要拿什么换什么"。
final class RestorePreview {
  const RestorePreview({
    required this.incoming,
    required this.current,
    required this.createdAtMs,
    required this.appVersion,
    required this.hasPhotos,
  });

  /// 文件里有什么。
  final BackupData incoming;

  /// 现在库里有什么（用于对比"将被替换"）。
  final BackupCounts current;

  final int createdAtMs;
  final String appVersion;
  final bool hasPhotos;

  /// 备份是哪天做的，`2026-10-23`。
  String get dateLabel =>
      LocalDate.fromDateTime(DateTime.fromMillisecondsSinceEpoch(createdAtMs))
          .toString();

  /// 备份是不是很久以前的（超过 90 天），用来提醒"别拿旧备份盖新数据"。
  bool isStale({DateTime? at}) {
    final now = at ?? appNow();
    final then = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    return now.difference(then).inDays > 90;
  }

  /// 二次确认弹窗的正文。
  String get warning =>
      '当前的 ${current.label} 将被替换成\n'
      '${incoming.summary}（$dateLabel 的备份）。\n\n'
      '这一步不能撤销。';
}

/// 备份服务。
final class BackupService {
  BackupService({
    required this.db,
    required this.gateway,
    this.appVersion = '0.1.0',
    this.schemaVersion = 1,
  });

  final AppDatabase db;
  final BackupFileGateway gateway;
  final String appVersion;
  final int schemaVersion;

  /// 上次成功导出的时间存在这个 setting key 里。
  static const String lastExportKey = 'backup.lastExportAtMs';

  /// 超过多少天没备份就在设置页轻提示。需求定的是 30 天。
  static const int staleAfterDays = 30;

  /// 导出：读库 → 组装 → 打包 → 写文件。**不调分享**，分享由页面决定。
  ///
  /// 拆开是有原因的：测试要能验"字节对不对"，而不是被系统分享面板卡住。
  Future<ExportResult> export({
    bool includePhotos = false,
    DateTime? at,
  }) async {
    final now = at ?? appNow();
    final snapshot = await db.readAllForBackup();

    // 照片只在明确要求时才读盘，而且缺文件不能整包失败——
    // 用户可能是从另一台设备导过来的路径。
    final photos = includePhotos
        ? await _readPhotos(snapshot)
        : <String, List<int>>{};

    final data = BackupData(
      createdAtMs: now.millisecondsSinceEpoch,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      includesPhotos: includePhotos,
      members: snapshot.members,
      tasks: snapshot.tasks,
      checkins: snapshot.checkins,
      settings: snapshot.settings,
    );

    final bytes = buildBackupArchive(data: data, photos: photos);
    final fileName = data.suggestedFileName;
    final path = await gateway.writeTempFile(fileName, bytes);

    await db.setSetting(
      lastExportKey,
      '${now.millisecondsSinceEpoch}',
      nowMs: now.millisecondsSinceEpoch,
    );

    return ExportResult(
      path: path,
      fileName: fileName,
      byteSize: bytes.length,
      data: data,
    );
  }

  /// 导出并立刻弹系统分享。
  Future<ExportResult> exportAndShare({
    bool includePhotos = false,
    DateTime? at,
  }) async {
    final result = await export(includePhotos: includePhotos, at: at);
    await gateway.share(result.path, subject: 'Famdaily 备份 ${result.data.dateLabel}');
    return result;
  }

  /// 解析备份字节，给出预览。**不动数据库**。
  ///
  /// 解析失败抛 [BackupFormatException]（消息可直接展示给用户）。
  Future<RestorePreview> preview(Uint8List bytes) async {
    final contents = readBackupArchive(bytes);
    return RestorePreview(
      incoming: contents.data,
      current: await db.counts(),
      createdAtMs: contents.data.createdAtMs,
      appVersion: contents.data.appVersion,
      hasPhotos: contents.hasPhotos,
    );
  }

  /// 真正执行覆盖恢复。
  ///
  /// 事务在 `AppDatabase.restoreAll` 里：中途失败整体回滚，老数据还在。
  Future<void> restore(BackupData data, {DateTime? at}) async {
    final now = at ?? appNow();
    await db.restoreAll(
      BackupSnapshot(
        members: data.members,
        tasks: data.tasks,
        checkins: data.checkins,
        settings: data.settings,
      ),
      nowMs: now.millisecondsSinceEpoch,
    );
    // 恢复之后必须立刻重排：新数据的时间规则跟老的不一样，
    // 系统队列里那几十条还按老规则响，会响到完全无关的项目上。
    await db.setSetting(
      lastExportKey,
      '${data.createdAtMs}',
      nowMs: now.millisecondsSinceEpoch,
    );
  }

  /// 距上次备份多少天；从没备份过返回 null。
  Future<int?> daysSinceLastExport({DateTime? at}) async {
    final raw = await db.getSetting(lastExportKey);
    final ms = int.tryParse(raw ?? '');
    if (ms == null) {
      return null;
    }
    final now = at ?? appNow();
    final then = DateTime.fromMillisecondsSinceEpoch(ms);
    return now.difference(then).inDays;
  }

  /// 设置页那一行轻提示；不需要提示时返回 null（**不打扰**）。
  Future<String?> reminderLine({DateTime? at}) async {
    final days = await daysSinceLastExport(at: at);
    if (days == null) {
      return '还没备份过。万一手机丢了，记录就找不回来了。';
    }
    if (days >= staleAfterDays) {
      return '已经 $days 天没备份了。';
    }
    return null;
  }

  /// 收集照片字节。缺失的文件**跳过而不是失败**——
  /// 用户可能是从另一台设备导过来的路径，一张坏图不该让整份备份导不出来。
  Future<Map<String, List<int>>> _readPhotos(BackupSnapshot snapshot) async {
    final out = <String, List<int>>{};
    final root = await _photoRoot();
    if (root == null) {
      return out;
    }
    for (final c in snapshot.checkins) {
      final rel = c.photoPath;
      if (rel == null || rel.isEmpty) {
        continue;
      }
      final file = File(p.join(root, rel));
      if (!await file.exists()) {
        continue;
      }
      out[rel] = await file.readAsBytes();
    }
    return out;
  }

  /// 照片根目录；拿不到就返回 null（含照片备份降级成不含）。
  Future<String?> _photoRoot() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return p.join(dir.path, 'photos');
    } on Object {
      return null;
    }
  }
}
