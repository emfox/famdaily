import 'dart:convert';

import 'package:famdaily/data/sync/sync_protocol.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/task_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('成员编解码', () {
    final wire = <String, Object?>{
      // 服务端回来的是**数据库列名**，还带 family_id / server_at_ms 这类
      // 客户端用不到的列。多出来的列忽略即可，缺了必填列要报错。
      'family_id': 'fam-1',
      'id': 'm1',
      'name': '爸爸',
      'avatar_id': 'dad',
      'sort_order': 2,
      'created_at_ms': 1000,
      'updated_at_ms': 2000,
      'deleted_at_ms': null,
      'server_at_ms': 3000,
    };

    test('从服务端列名解析，忽略多余列', () {
      final dto = MemberDto.fromWire(wire);
      expect(dto.id, 'm1');
      expect(dto.name, '爸爸');
      expect(dto.avatarId, 'dad');
      expect(dto.sortOrder, 2);
      expect(dto.deletedAtMs, isNull);
    });

    test('推给服务端的字段名是 camelCase，且不含服务端自有列', () {
      // 这条不是风格洁癖：`fromWire` 收的是服务端回来的**数据库列名**，
      // `toWire` 发的是 camelCase。两边格式不同是刻意的（服务端表结构
      // 与协议字段解耦），所以"推出去再读回来"必须经过 domain 模型。
      final out = MemberDto.fromWire(wire).toWire();
      expect(out.keys, containsAll(['createdAtMs', 'updatedAtMs', 'sortOrder']));
      expect(out.keys, isNot(contains('created_at_ms')));
      expect(out.keys, isNot(contains('server_at_ms')));
      expect(out.keys, isNot(contains('family_id')));
    });

    test('domain 往返', () {
      final dto = MemberDto.fromWire(wire);
      final m = dto.toDomain();
      expect(MemberDto.fromDomain(m).toWire(), dto.toWire());
    });

    test('缺 id / 缺名字 抛错，且错误里写清哪一行', () {
      expect(
        () => MemberDto.fromWire({...wire}..remove('id')),
        throwsA(
          isA<SyncFormatException>().having((e) => e.where, 'where', 'member.id'),
        ),
      );
      expect(
        () => MemberDto.fromWire({...wire, 'name': ''}),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test('名字超长抛错（服务端也会拒，这里提前拦）', () {
      expect(
        () => MemberDto.fromWire({...wire, 'name': 'x' * 41}),
        throwsA(isA<SyncFormatException>()),
      );
    });
  });

  group('项目编解码', () {
    Map<String, Object?> taskWire({
      String status = 'active',
      Object? reminder = 1,
      String timeType = 'fixed',
    }) => {
      'id': 't1',
      'member_id': 'm1',
      'name': '吃药',
      'note': null,
      'icon_id': null,
      'repeat_json': jsonEncode({'v': 1, 'weekdays': [1, 2]}),
      'time_json': jsonEncode({
        'v': 1,
        'type': timeType,
        'times': ['08:00'],
      }),
      'course_start': null,
      'course_end': null,
      'course_total_days': null,
      'status': status,
      'reminder_enabled': reminder,
      'sort_order': 0,
      'rules_effective_from': '2025-03-01',
      'created_at_ms': 1000,
      'updated_at_ms': 2000,
      'deleted_at_ms': null,
    };

    test('四种 status 都认', () {
      for (final s in TaskStatus.values) {
        expect(TaskDto.fromWire(taskWire(status: s.name)).status, s);
      }
    });

    test('不认识的 status 抛错，不猜成 active', () {
      // 猜成 active 会让一个已归档的项目在另一台手机上继续提醒；
      // 猜成 deleted 会让项目凭空消失。两种都不该发生。
      expect(
        () => TaskDto.fromWire(taskWire(status: 'snoozed')),
        throwsA(
          isA<SyncFormatException>().having(
            (e) => e.where,
            'where',
            'task.status',
          ),
        ),
      );
    });

    test('reminder_enabled 三种形态都认（1/0、true/false、缺省）', () {
      expect(TaskDto.fromWire(taskWire(reminder: 1)).reminderEnabled, isTrue);
      expect(TaskDto.fromWire(taskWire(reminder: 0)).reminderEnabled, isFalse);
      expect(TaskDto.fromWire(taskWire(reminder: true)).reminderEnabled, isTrue);
      expect(
        TaskDto.fromWire({...taskWire()}..remove('reminder_enabled'))
            .reminderEnabled,
        isTrue,
      );
    });

    test('rules_effective_from 保留（同步会把它放大成"编辑一次就丢"）', () {
      expect(TaskDto.fromWire(taskWire()).rulesEffectiveFrom, '2025-03-01');
    });

    test('规则 JSON 原样搬运，不解释内容', () {
      final t = TaskDto.fromWire(taskWire());
      final parsed = jsonDecode(t.timeJson);
      expect(parsed, isA<Map<String, Object?>>());
      expect((parsed as Map<String, Object?>)['type'], 'fixed');
      expect(t.toWire()['timeJson'], t.timeJson);
    });
  });

  group('打卡编解码', () {
    Map<String, Object?> checkinWire({String state = 'done', Object? deleted}) => {
      'task_id': 't1',
      'date': '2025-03-01',
      'slot_index': 2,
      'state': state,
      'done_at_ms': 1234,
      'due_at_minute_of_day': 480,
      'note': null,
      'deleted': deleted,
      'updated_at_ms': 2000,
      'server_at_ms': 3000,
    };

    test('三种状态都认', () {
      for (final s in ['done', 'makeup', 'skipped']) {
        expect(
          CheckinDto.fromWire(checkinWire(state: s)).state.dbValue,
          s,
        );
      }
    });

    test('不认识的状态抛错，绝不猜成 done', () {
      // 猜成 done = 凭空造出"已完成"。统计数字从此不可信，
      // 而"可信"就是这个产品的全部价值。
      expect(
        () => CheckinDto.fromWire(checkinWire(state: 'DONE')),
        throwsA(
          isA<SyncFormatException>().having(
            (e) => e.where,
            'where',
            'checkin.state',
          ),
        ),
      );
    });

    test('id 不在协议里：推上去也不带', () {
      final dto = CheckinDto.fromWire(checkinWire());
      expect(dto.toWire().containsKey('id'), isFalse);
      expect(dto.toWire().containsKey('taskId'), isTrue);
    });

    test('墓碑标记解析：int 1 和 bool true 都认', () {
      expect(CheckinDto.fromWire(checkinWire(deleted: 1)).deleted, isTrue);
      expect(CheckinDto.fromWire(checkinWire(deleted: true)).deleted, isTrue);
      expect(CheckinDto.fromWire(checkinWire()).deleted, isFalse);
    });

    test('三元组 key 用 NUL 分隔，不会和日期里的连字符混淆', () {
      final a = CheckinDto.fromWire(checkinWire());
      expect(a.key, 't1\u00002025-03-01\u00002');
    });

    test('日期字面量能还原成 LocalDate', () {
      expect(CheckinDto.fromWire(checkinWire()).dateValue(), LocalDate(2025, 3, 1));
    });

    test('照片路径不搬', () {
      final rec = domain.CheckinRecord(
        id: 'c1',
        taskId: 't1',
        date: LocalDate(2025, 3, 1),
        slotIndex: 0,
        state: CheckinState.done,
        doneAtMs: 1234,
        photoPath: 'photos/abc.jpg',
      );
      expect(CheckinDto.fromDomain(rec).toWire().containsKey('photoPath'), isFalse);
      expect(CheckinDto.fromDomain(rec).toWire().containsKey('photo_path'), isFalse);
    });
  });

  group('同步请求', () {
    const member = MemberDto(
      id: 'm1',
      name: '爸爸',
      sortOrder: 0,
      createdAtMs: 1,
      updatedAtMs: 1,
    );

    test('checkins 为 null 时整个字段都不出现', () {
      // 这是"只来拉数据"的表示方式。服务端靠"字段在不在"区分
      // "我本地没有"和"我这次不推"——搞混了所有打卡会被打墓碑。
      final json = jsonDecode(
        const SyncRequest(since: 5, members: [member]).encode(),
      ) as Map<String, Object?>;
      expect(json.containsKey('checkins'), isFalse);
      expect(json['members'], hasLength(1));
    });

    test('checkins 为空数组时字段出现且是空列表', () {
      final json = jsonDecode(
        const SyncRequest(since: 5, checkins: []).encode(),
      ) as Map<String, Object?>;
      expect(json.containsKey('checkins'), isTrue);
      expect(json['checkins'], isEmpty);
    });

    test('since 一定写出去，哪怕是 0', () {
      final json = jsonDecode(const SyncRequest(since: 0).encode())
          as Map<String, Object?>;
      expect(json['since'], 0);
    });
  });

  group('同步响应', () {
    Map<String, Object?> ok({
      int cursor = 100,
      int highWater = 0,
      bool sinceReset = false,
      List<Map<String, Object?>> rejected = const [],
      Map<String, List<Object?>> pulled = const {},
    }) => {
      'ok': true,
      'cursor': cursor,
      'writeHighWater': highWater,
      'sinceReset': sinceReset,
      'pulled': {
        'members': pulled['members'] ?? [],
        'tasks': pulled['tasks'] ?? [],
        'checkins': pulled['checkins'] ?? [],
        'settings': pulled['settings'] ?? [],
      },
      'rejected': rejected,
      'tombstoned': 0,
    };

    test('空拉取解析成功，hasWrites 为 false', () {
      final r = SyncResponse.fromJson(ok());
      expect(r.cursor, 100);
      expect(r.hasWrites, isFalse);
      expect(r.rejected, isEmpty);
    });

    test('ok 不为 true 抛错', () {
      expect(
        () => SyncResponse.fromJson({...ok(), 'ok': false}),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test('缺 pulled 抛错', () {
      expect(
        () => SyncResponse.fromJson({...ok()}..remove('pulled')),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test('rejected 解析出 kind/id/reason', () {
      final r = SyncResponse.fromJson(
        ok(
          rejected: [
            {
              'kind': 'checkin',
              'id': 't1/2025-03-01/0',
              'reason': 'FOREIGN KEY constraint failed',
            },
          ],
        ),
      );
      expect(r.rejected, hasLength(1));
      expect(r.rejected.first.kind, 'checkin');
      expect(r.rejected.first.reason, contains('FOREIGN KEY'));
    });

    test('sinceReset 只在 true 时为真', () {
      expect(SyncResponse.fromJson(ok(sinceReset: true)).sinceReset, isTrue);
      expect(
        SyncResponse.fromJson({...ok(), 'sinceReset': 1}).sinceReset,
        isFalse,
      );
    });

    test('缺 cursor 时按 0 处理，不崩', () {
      final j = ok()..remove('cursor');
      expect(SyncResponse.fromJson(j).cursor, 0);
    });
  });

  group('同步码规范化', () {
    test('标准格式原样通过', () {
      expect(
        normalizePairCode('FAM-7K2M-9XQ4-3TBH'),
        'FAM-7K2M-9XQ4-3TBH',
      );
    });

    test('大小写、空格、少连字符、多换行都认', () {
      for (final v in [
        'fam-7k2m-9xq4-3tbh',
        'FAM 7K2M 9XQ4 3TBH',
        'FAM7K2M9XQ43TBH',
        '  FAM-7K2M-9XQ4-3TBH\n',
        '7K2M-9XQ4-3TBH',
      ]) {
        expect(
          normalizePairCode(v),
          'FAM-7K2M-9XQ4-3TBH',
          reason: '认不出：${jsonEncode(v)}',
        );
      }
    });

    test('不做智能纠错：0/O 不在字母表里', () {
      // 把 0 当作 O 会把两个不同的码纠成同一个，等于把可猜空间缩小一个数量级。
      expect(normalizePairCode('FAM-0K2M-9XQ4-3TBH'), isNull);
      expect(normalizePairCode('FAM-OK2M-9XQ4-3TBH'), isNull);
      expect(normalizePairCode('FAM-1K2M-9XQ4-3TBH'), isNull);
      expect(normalizePairCode('FAM-IK2M-9XQ4-3TBH'), isNull);
      expect(normalizePairCode('FAM-LK2M-9XQ4-3TBH'), isNull);
    });

    test('长度不对返回 null', () {
      expect(normalizePairCode('FAM-7K2M-9XQ4'), isNull);
      expect(normalizePairCode('FAM-7K2M-9XQ4-3TBHX'), isNull);
      expect(normalizePairCode(''), isNull);
      expect(normalizePairCode(null), isNull);
    });
  });
}
