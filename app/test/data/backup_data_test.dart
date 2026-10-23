import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:famdaily/data/backup/backup_data.dart';
import 'package:famdaily/data/backup/backup_io.dart';
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

domain.Member _member() => const domain.Member(
  id: 'm1',
  name: '爷爷',
  avatarId: 'grandpa',
  sortOrder: 2,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _fixedTask() => domain.Task(
  id: 't1',
  memberId: 'm1',
  name: '降压药',
  note: '白色药片 2 粒',
  iconId: 'pill',
  repeat: const domain.RepeatRule(weekdays: {1, 3, 5}),
  time: domain.FixedTimesRule([domain.LocalTime(8, 0), domain.LocalTime(20, 0)]),
  course: domain.Course.days(domain.LocalDate(2025, 3, 1), 7),
  status: domain.TaskStatus.active,
  reminderEnabled: false,
  sortOrder: 3,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _mealTask() => domain.Task(
  id: 't2',
  memberId: 'm1',
  name: '饭后散步',
  repeat: domain.RepeatRule(
    parity: domain.ParityFilter.oddWeeks,
    anchor: domain.LocalDate(2025, 3, 3),
  ),
  time: domain.MealTimesRule(
    anchors: [domain.MealAnchor.breakfast, domain.MealAnchor.dinner],
    offsetMinutes: 30,
    anchorOverrides: {domain.MealAnchor.breakfast: domain.LocalTime(7, 0)},
  ),
  course: domain.Course.none,
  status: domain.TaskStatus.paused,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.Task _intervalTask() => domain.Task(
  id: 't3',
  memberId: 'm1',
  name: '喝水',
  repeat: const domain.RepeatRule(monthDays: [1, 15]),
  time: domain.CombinedTimeRule([
    domain.IntervalRule(
      everyMinutes: 120,
      from: domain.LocalTime(9, 0),
      to: domain.LocalTime(21, 0),
    ),
    domain.FixedTimesRule([domain.LocalTime(7, 30)]),
  ]),
  course: domain.Course.none,
  status: domain.TaskStatus.archived,
  createdAtMs: _ts,
  updatedAtMs: _ts,
);

domain.CheckinRecord _checkin() => domain.CheckinRecord(
  id: 'c1',
  taskId: 't1',
  date: domain.LocalDate(2025, 3, 3),
  slotIndex: 1,
  state: domain.CheckinState.makeup,
  doneAtMs: _ts,
  dueAtMinuteOfDay: 1200,
  note: '晚了半小时',
  photoPath: 'photos/2025-03-03/c1.jpg',
);

BackupData _sample() => BackupData(
  createdAtMs: _ts,
  appVersion: '0.1.0',
  schemaVersion: 1,
  members: [_member()],
  tasks: [_fixedTask(), _mealTask(), _intervalTask()],
  checkins: [_checkin()],
  settings: {'reminders.enabled': 'true', 'reminders.quietStart': '22:30'},
);

void main() {
  group('顶层结构', () {
    test('带上格式版本号与照片标记', () {
      final json = _sample().toJson();

      expect(json['format_version'], BackupData.formatVersion);
      expect(json['includes_photos'], isFalse);
      expect(json['app_version'], '0.1.0');
    });

    test('摘要是给人看的一句话，不是 JSON 片段', () {
      expect(_sample().summary, '1 位成员 · 3 个项目 · 1 条记录');
    });

    test('文件名带日期，符合需求里的命名', () {
      // _ts = 2025-03-03（UTC）
      expect(
        _sample().suggestedFileName,
        matches(RegExp(r'^famdaily-backup-\d{4}-\d{2}-\d{2}\.zip$')),
      );
    });

    test('格式化后的 JSON 是多行可读的', () {
      final text = _sample().encode();
      expect(text, contains('\n'));
      expect(text, contains('"members"'));
    });
  });

  group('往返一致', () {
    test('成员、项目、记录、设置全字段往返不丢', () {
      final round = BackupData.fromJson(_sample().toJson());

      expect(round.members.single.name, '爷爷');
      expect(round.members.single.avatarId, 'grandpa');
      expect(round.members.single.sortOrder, 2);
      expect(round.settings, {
        'reminders.enabled': 'true',
        'reminders.quietStart': '22:30',
      });

      final t1 = round.tasks[0];
      expect(t1.name, '降压药');
      expect(t1.note, '白色药片 2 粒');
      expect(t1.iconId, 'pill');
      expect(t1.reminderEnabled, isFalse);
      expect(t1.sortOrder, 3);
      expect(t1.repeat.weekdays, {1, 3, 5});
      expect((t1.time as domain.FixedTimesRule).times, [
        domain.LocalTime(8, 0),
        domain.LocalTime(20, 0),
      ]);
      expect(t1.course.start, domain.LocalDate(2025, 3, 1));
      expect(t1.course.end, domain.LocalDate(2025, 3, 7));

      final c = round.checkins.single;
      expect(c.state, domain.CheckinState.makeup);
      expect(c.slotIndex, 1);
      expect(c.dueAtMinuteOfDay, 1200);
      expect(c.note, '晚了半小时');
      expect(c.photoPath, 'photos/2025-03-03/c1.jpg');
    });

    test('四种时刻规则都能往返（含嵌套的 combined）', () {
      final round = BackupData.fromJson(_sample().toJson());

      final meal = round.tasks[1].time as domain.MealTimesRule;
      expect(meal.anchors, [
        domain.MealAnchor.breakfast,
        domain.MealAnchor.dinner,
      ]);
      expect(meal.offsetMinutes, 30);
      expect(meal.anchorOverrides[domain.MealAnchor.breakfast],
          domain.LocalTime(7, 0));

      final combined = round.tasks[2].time as domain.CombinedTimeRule;
      expect(combined.rules, hasLength(2));
      final interval = combined.rules[0] as domain.IntervalRule;
      expect(interval.everyMinutes, 120);
      expect(interval.from, domain.LocalTime(9, 0));
      expect(interval.to, domain.LocalTime(21, 0));
    });

    test('重复规则的所有维度都能往返', () {
      final round = BackupData.fromJson(_sample().toJson());

      final parity = round.tasks[1].repeat;
      expect(parity.parity, domain.ParityFilter.oddWeeks);
      expect(parity.anchor, domain.LocalDate(2025, 3, 3));

      final monthDays = round.tasks[2].repeat;
      expect(monthDays.monthDays, [1, 15]);
    });

    test('任务状态三种都保住（archived 不能悄悄变成 active）', () {
      final round = BackupData.fromJson(_sample().toJson());
      expect(round.tasks.map((t) => t.status), [
        domain.TaskStatus.active,
        domain.TaskStatus.paused,
        domain.TaskStatus.archived,
      ]);
    });
  });

  group('读坏文件时报错而不是猜', () {
    test('缺 format_version 直接拒收', () {
      expect(
        () => BackupData.fromJson({'members': <Object>[]}),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('format_version'),
          ),
        ),
      );
    });

    test('格式版本比当前新，提示升级而不是硬读', () {
      expect(
        () => BackupData.fromJson({
          'format_version': BackupData.formatVersion + 1,
          'created_at_ms': _ts,
        }),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('更新的版本'),
          ),
        ),
      );
    });

    test('未知的打卡状态不能当成「完成」', () {
      final json = _sample().toJson();
      final first = (json['checkins'] as List<dynamic>).first
          as Map<String, dynamic>;
      first['state'] = 'done_somehow';

      expect(
        () => BackupData.fromJson(json),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('打卡状态无法识别'),
          ),
        ),
      );
    });

    test('成员缺 id 时报错，而不是造一个空 id 的成员', () {
      final json = _sample().toJson();
      ((json['members'] as List).first as Map<String, dynamic>).remove('id');

      expect(() => BackupData.fromJson(json), throwsA(isA<BackupFormatException>()));
    });

    test('settings 的值不是字符串时转成字符串，不崩', () {
      final json = _sample().toJson();
      json['settings'] = {'a': 1, 'b': true};

      expect(BackupData.fromJson(json).settings, {'a': '1', 'b': 'true'});
    });

    test('缺可选字段用默认值（向后兼容）', () {
      final minimal = {
        'format_version': 1,
        'created_at_ms': _ts,
        'members': [
          {'id': 'm', 'name': '我'},
        ],
      };
      final data = BackupData.fromJson(minimal);
      expect(data.members.single.sortOrder, 0);
      expect(data.tasks, isEmpty);
      expect(data.includesPhotos, isFalse);
      expect(data.appVersion, '未知');
    });
  });

  group('zip 打包', () {
    test('打包再拆包能拿回同样的数据', () {
      final bytes = buildBackupArchive(data: _sample());
      final contents = readBackupArchive(bytes);

      expect(contents.data.members.single.name, '爷爷');
      expect(contents.data.tasks, hasLength(3));
      expect(contents.hasPhotos, isFalse);
    });

    test('照片放进去也能按相对路径拿回来', () {
      final bytes = buildBackupArchive(
        data: _sample(),
        photos: {
          '2025-03-03/c1.jpg': [1, 2, 3, 4],
        },
      );

      final seen = <String, List<int>>{};
      final contents = readBackupArchive(
        bytes,
        onPhoto: (rel, data) => seen[rel] = data,
      );

      expect(contents.hasPhotos, isTrue);
      expect(contents.photoPaths, ['2025-03-03/c1.jpg']);
      expect(seen['2025-03-03/c1.jpg'], [1, 2, 3, 4]);
    });

    test('zip 里没有 backup.json 时给出人话错误', () {
      final empty = Uint8List.fromList(ZipEncoder().encode(Archive()));

      expect(
        () => readBackupArchive(empty),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('backup.json'),
          ),
        ),
      );
    });

    test('backup.json 不是 JSON 对象时报错', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            manifestEntryName,
            Uint8List.fromList(utf8.encode('[1,2,3]')),
          ),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      expect(() => readBackupArchive(bytes), throwsA(isA<BackupFormatException>()));
    });
  });
}
