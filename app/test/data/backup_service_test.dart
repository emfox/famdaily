import 'dart:convert';
import 'dart:typed_data';

import 'package:famdaily/data/backup/backup_data.dart';
import 'package:famdaily/data/backup/backup_io.dart';
import 'package:famdaily/data/backup/backup_service.dart';
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart' as domain;
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

/// 内存网关：不落盘、不弹系统面板，但把"写了什么"记下来。
final class FakeGateway implements BackupFileGateway {
  final Map<String, Uint8List> files = {};
  final List<String> shared = [];
  Uint8List? pickResult;

  @override
  Future<String> writeTempFile(String fileName, Uint8List bytes) async {
    files[fileName] = bytes;
    return '/tmp/$fileName';
  }

  @override
  Future<void> share(String path, {required String subject}) async {
    shared.add('$path|$subject');
  }

  @override
  Future<Uint8List?> pickBackupFile() async => pickResult;
}

void main() {
  late AppDatabase db;
  late FakeGateway gateway;
  late BackupService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    gateway = FakeGateway();
    service = BackupService(db: db, gateway: gateway);
  });

  tearDown(() async => db.close());

  Future<void> seed() async {
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
    await db.into(db.tasks).insert(
      Mappers.taskToCompanion(
        domain.Task(
          id: 't1',
          memberId: 'm1',
          name: '降压药',
          repeat: const domain.RepeatRule(),
          time: domain.FixedTimesRule([domain.LocalTime(8, 0)]),
          course: domain.Course.none,
          status: domain.TaskStatus.active,
          createdAtMs: _ts,
          updatedAtMs: _ts,
        ),
      ),
    );
    await db.upsertCheckin(
      domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: domain.LocalDate(2025, 3, 3),
        slotIndex: 0,
        state: domain.CheckinState.done,
        doneAtMs: _ts,
      ),
      nowMs: _ts,
    );
  }

  group('导出', () {
    test('写出一个 zip，内容跟库里一致', () async {
      await seed();

      final result = await service.export(at: DateTime(2025, 3, 5, 10));

      expect(gateway.files, contains(result.fileName));
      expect(result.fileName, 'famdaily-backup-2025-03-05.zip');
      expect(result.byteSize, greaterThan(0));
      expect(result.data.members.single.name, '爷爷');
      expect(result.data.checkins.single.state, domain.CheckinState.done);
    });

    test('大小给人话，不是裸数字', () async {
      await seed();
      final result = await service.export();

      expect(result.sizeLabel, matches(RegExp(r'^\d+(\.\d)? (B|KB|MB)$')));
    });

    test('导出后记下时间，并能在设置页给出提示文案', () async {
      await seed();
      await service.export(at: DateTime(2025, 3, 5, 10));

      expect(
        await service.daysSinceLastExport(at: DateTime(2025, 3, 8, 10)),
        3,
      );
      expect(
        await service.reminderLine(at: DateTime(2025, 3, 8, 10)),
        isNull,
        reason: '刚备份过就别啰嗦',
      );
    });

    test('从没备份过时提示一句（不打扰，只是说明）', () async {
      expect(
        await service.reminderLine(at: DateTime(2025, 3, 5)),
        contains('还没备份过'),
      );
      expect(await service.daysSinceLastExport(), isNull);
    });

    test('超过 30 天没备份才提示', () async {
      await seed();
      await service.export(at: DateTime(2025, 3, 5));
      final line = await service.reminderLine(at: DateTime(2025, 4, 10));

      expect(line, '已经 36 天没备份了。');
    });

    test('exportAndShare 会调分享并带上日期', () async {
      await seed();
      final result = await service.exportAndShare(at: DateTime(2025, 3, 5));

      expect(gateway.shared.single, contains(result.fileName));
      expect(gateway.shared.single, contains('2025-03-05'));
    });

    test('空库也能导出（不是错误）', () async {
      final result = await service.export();
      expect(result.data.members, isEmpty);
      expect(result.byteSize, greaterThan(0));
    });

    test('软删除的成员一起带上，否则恢复后历史会断链', () async {
      await seed();
      await db.deleteMember('m1', nowMs: _ts);

      final result = await service.export();

      expect(result.data.members, hasLength(1));
      expect(result.data.members.single.isDeleted, isTrue);
    });

    test('本机排程进度不跟着备份走', () async {
      await db.setSetting('reminders.lastScheduledFor', '2025-03-05', nowMs: _ts);
      await db.setSetting('reminders.enabled', 'true', nowMs: _ts);

      final result = await service.export();

      expect(result.data.settings, contains('reminders.enabled'));
      expect(
        result.data.settings,
        isNot(contains('reminders.lastScheduledFor')),
        reason: '新机带着这条会以为今天已经排过，从而不排通知',
      );
    });
  });

  group('恢复预览', () {
    test('说清「拿什么换什么」', () async {
      await seed();
      final exported = await service.export(at: DateTime(2025, 3, 5));

      final preview = await service.preview(gateway.files[exported.fileName]!);

      expect(preview.incoming.members, hasLength(1));
      expect(preview.current.label, '1 位成员 · 1 个项目 · 1 条记录');
      expect(preview.dateLabel, '2025-03-05');
      expect(preview.warning, contains('将被替换'));
      expect(preview.warning, contains('不能撤销'));
    });

    test('很旧的备份会被标成 stale', () async {
      await seed();
      final exported = await service.export(at: DateTime(2024, 1, 1));
      final preview = await service.preview(gateway.files[exported.fileName]!);

      expect(preview.isStale(at: DateTime(2025, 6, 1)), isTrue);
      expect(preview.isStale(at: DateTime(2024, 2, 1)), isFalse);
    });

    test('预览不动数据库', () async {
      await seed();
      final exported = await service.export();
      await db.wipeAll(nowMs: _ts);

      await service.preview(gateway.files[exported.fileName]!);

      expect(await db.listMembers(), isEmpty, reason: '预览就该只是看一眼');
    });

    test('坏文件抛的错能直接给用户看', () async {
      expect(
        () => service.preview(Uint8List.fromList(utf8.encode('不是 zip'))),
        throwsA(anything),
      );
    });
  });

  group('恢复', () {
    test('覆盖：先清空再写入，成员/项目/记录全回来', () async {
      await seed();
      final exported = await service.export(at: DateTime(2025, 3, 5));
      final bytes = gateway.files[exported.fileName]!;

      // 模拟"换了台手机 / 数据被搞乱了"。
      await db.wipeAll(nowMs: _ts);
      expect(await db.listMembers(), isEmpty);

      final preview = await service.preview(bytes);
      await service.restore(preview.incoming, at: DateTime(2025, 3, 6));

      expect((await db.listMembers()).single.name, '爷爷');
      expect((await db.listAllTasks()).single.name, '降压药');
      final records = await db.checkinsBetween(
        domain.LocalDate(2025, 3, 3),
        domain.LocalDate(2025, 3, 3),
      );
      expect(records.single.state, domain.CheckinState.done);
    });

    test('覆盖而不是合并：多余的旧数据会被清掉', () async {
      await seed();
      final exported = await service.export();
      final bytes = gateway.files[exported.fileName]!;

      // 备份之后又加了一个人。
      await db.into(db.members).insert(
        Mappers.memberToCompanion(
          const domain.Member(
            id: 'm2',
            name: '后来加的',
            sortOrder: 1,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
      expect(await db.listMembers(), hasLength(2));

      await service.restore((await service.preview(bytes)).incoming);

      expect(
        (await db.listMembers()).map((m) => m.name),
        ['爷爷'],
        reason: '覆盖导入：备份里没有的就不该留下',
      );
    });

    test('设置项也一起恢复', () async {
      await seed();
      await db.setSetting('reminders.enabled', 'false', nowMs: _ts);
      final exported = await service.export();
      final bytes = gateway.files[exported.fileName]!;

      await db.wipeAll(nowMs: _ts);
      await service.restore((await service.preview(bytes)).incoming);

      expect(await db.getSetting('reminders.enabled'), 'false');
    });

    test('坏数据整体回滚：老数据不会陪葬', () async {
      await seed();
      // 一个指向不存在成员的 project —— 外键必然失败。
      final bad = BackupData(
        createdAtMs: _ts,
        appVersion: '0.1.0',
        schemaVersion: 1,
        members: const [],
        tasks: [
          domain.Task(
            id: 'orphan',
            memberId: '不存在的成员',
            name: '孤儿项目',
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
      );

      await expectLater(
        service.restore(bad, at: DateTime(2025, 3, 6)),
        throwsA(anything),
      );

      // 关键断言：清空那一步也回滚了，老成员还在。
      expect((await db.listMembers()).single.name, '爷爷');
    });

    test('恢复后把上次备份时间对齐到备份里的时间', () async {
      await seed();
      final exported = await service.export(at: DateTime(2025, 3, 5));
      final bytes = gateway.files[exported.fileName]!;

      await db.wipeAll(nowMs: _ts);
      await service.restore(
        (await service.preview(bytes)).incoming,
        at: DateTime(2025, 4, 1),
      );

      expect(
        await service.daysSinceLastExport(at: DateTime(2025, 4, 1)),
        27,
      );
    });
  });
}
