import 'dart:typed_data';

import 'package:famdaily/data/backup/backup_data.dart';
import 'package:famdaily/data/backup/backup_io.dart';
import 'package:famdaily/data/backup/backup_service.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/feature/settings/backup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

final class FakeGateway implements BackupFileGateway {
  final Map<String, Uint8List> files = {};
  final List<String> shared = [];
  Uint8List? pickResult;

  /// 让 pickBackupFile 走"用户取消"。
  bool pickCancelled = false;

  @override
  Future<String> writeTempFile(String fileName, Uint8List bytes) async {
    files[fileName] = bytes;
    return '/tmp/$fileName';
  }

  @override
  Future<void> share(String path, {required String subject}) async {
    shared.add(path);
  }

  @override
  Future<Uint8List?> pickBackupFile() async =>
      pickCancelled ? null : pickResult;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 点「导出到文件」。
///
/// 这一页在测试的 800×600 视口里比屏幕长，按钮可能在折叠线以下。
/// 直接 tap 找不到落点会静默打空（不报错、也不触发），所以先滚过去。
Future<void> _tapExport(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, '导出到文件');
  await tester.scrollUntilVisible(button, 120, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late FakeGateway gateway;
  late BackupService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    gateway = FakeGateway();
    service = BackupService(db: db, gateway: gateway);
    await db.into(db.members).insert(
      Mappers.memberToCompanion(
        const domain.Member(
          id: 'm1',
          name: '爷爷',
          sortOrder: 0,
          createdAtMs: _ts,
          updatedAtMs: _ts,
        ),
      ),
    );
  });

  tearDown(() async => db.close());

  testWidgets('显示"备份里有什么"，且默认不含照片', (tester) async {
    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('备份内容：1 位成员 · 0 个项目 · 0 条记录'), findsOneWidget);
    expect(find.textContaining('不是加密黑盒'), findsOneWidget);

    final seg = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    expect(seg.selected, {false}, reason: '默认只备份记录，不含照片');
    expect(find.textContaining('照片不含'), findsOneWidget);
  });

  testWidgets('点导出真的写出文件并成功提示', (tester) async {
    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    await _tapExport(tester);

    expect(gateway.files, hasLength(1));
    expect(gateway.shared, hasLength(1));
    expect(find.textContaining('已导出'), findsOneWidget);
    expect(find.textContaining('1 位成员'), findsWidgets);
  });

  testWidgets('勾了「连照片一起」后，说明文字跟着变', (tester) async {
    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.textContaining('照片不含'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<bool>),
        matching: find.text('连照片一起'),
      ),
    );
    await tester.pumpAndSettle();

    final seg = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    expect(seg.selected, {true});
    expect(find.textContaining('文件会大很多'), findsOneWidget);
    expect(find.textContaining('照片不含'), findsNothing);
  });

  // 纯 service 调用，不该放进 testWidgets：tester 的 fake async zone 里
  // 跑真的 IO/异步链会卡死（"Cannot add event while adding stream"）。
  test('选「连照片一起」后导出，zip 里标记了 includesPhotos', () async {
    final result = await service.export(includePhotos: true);
    final contents = readBackupArchive(gateway.files[result.fileName]!);

    expect(contents.data.includesPhotos, isTrue);
  });

  testWidgets('导出失败时显示错误，不崩', (tester) async {
    final broken = _ThrowingGateway();
    final brokenService = BackupService(db: db, gateway: broken);
    await tester.pumpWidget(_wrap(BackupPage(service: brokenService)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出到文件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出没成功'), findsOneWidget);
  });

  testWidgets('恢复：用户取消选文件时什么都不发生', (tester) async {
    gateway.pickCancelled = true;
    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选一份备份恢复'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(await db.listMembers(), hasLength(1));
  });

  testWidgets('恢复：先给预览，点「再想想」不动数据', (tester) async {
    // 先导一份，再清空，然后拿它来恢复。
    final exported = await service.export();
    gateway.pickResult = gateway.files[exported.fileName]!;
    await db.wipeAll(nowMs: _ts);
    expect(await db.listMembers(), isEmpty);

    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选一份备份恢复'));
    await tester.pumpAndSettle();

    expect(find.text('用这份备份替换现在所有数据？'), findsOneWidget);
    expect(find.textContaining('将被替换'), findsOneWidget);
    expect(find.textContaining('不能撤销'), findsOneWidget);

    await tester.tap(find.text('再想想'));
    await tester.pumpAndSettle();

    expect(await db.listMembers(), isEmpty, reason: '没确认就一个字都不该写');
  });

  testWidgets('恢复：确认后数据回来，并调用重排', (tester) async {
    final exported = await service.export();
    gateway.pickResult = gateway.files[exported.fileName]!;
    await db.wipeAll(nowMs: _ts);

    var rescheduled = 0;
    await tester.pumpWidget(
      _wrap(
        BackupPage(
          service: service,
          reschedule: () async => rescheduled++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('选一份备份恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();

    expect((await db.listMembers()).single.name, '爷爷');
    expect(rescheduled, 1, reason: '新旧规则不同，必须重排通知');
    expect(find.textContaining('已恢复'), findsOneWidget);
  });

  testWidgets('文件坏了只说文件坏了，不动数据', (tester) async {
    final exported = await service.export();
    final good = gateway.files[exported.fileName]!;
    // 截断的 zip：解不开。
    gateway.pickResult = Uint8List.fromList(good.sublist(0, 20));

    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选一份备份恢复'));
    await tester.pumpAndSettle();

    // 解包失败走的是"读不了这份文件"，不是"恢复失败"——两者措辞要分开，
    // 因为前者根本还没碰数据库。页面照原样转述解包器/格式层给的话。
    expect(find.textContaining('备份'), findsWidgets);
    expect(find.textContaining('按钮'), findsNothing);
    expect(await db.listMembers(), hasLength(1), reason: '老数据必须还在');
  });

  testWidgets('能解析但写不进去时说「原来的数据没动」', (tester) async {
    // 造一份成员指向不存在的项目记录：解析没问题，写库会撞外键。
    final broken = buildBackupArchive(
      data: BackupData(
        createdAtMs: _ts,
        appVersion: '0.1.0',
        schemaVersion: 1,
        members: const [],
        tasks: [
          domain.Task(
            id: 'orphan',
            memberId: '不存在的人',
            name: '孤儿',
            repeat: const domain.RepeatRule(),
            time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
            course: domain.Course.none,
            status: domain.TaskStatus.active,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ],
        checkins: const [],
        settings: const {},
      ),
    );
    gateway.pickResult = broken;

    await tester.pumpWidget(_wrap(BackupPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选一份备份恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();

    expect(find.textContaining('原来的数据没动'), findsOneWidget);
    expect((await db.listMembers()).single.name, '爷爷', reason: '整体回滚');
  });
}

final class _ThrowingGateway implements BackupFileGateway {
  @override
  Future<String> writeTempFile(String fileName, Uint8List bytes) async =>
      throw const DiskFullException('磁盘满了');

  @override
  Future<void> share(String path, {required String subject}) async {}

  @override
  Future<Uint8List?> pickBackupFile() async => null;
}

/// 一个能在测试里抛出的异常。
final class DiskFullException implements Exception {
  const DiskFullException(this.message);

  final String message;

  @override
  String toString() => message;
}
