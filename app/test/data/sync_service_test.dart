import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/data/sync/sync_api.dart';
import 'package:famdaily/data/sync/sync_config.dart';
import 'package:famdaily/data/sync/sync_service.dart';
import 'package:famdaily/domain/model/checkin.dart' as domain;
import 'package:famdaily/domain/model/checkin_state.dart';
import 'package:famdaily/domain/model/local_date.dart';
import 'package:famdaily/domain/model/local_time.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart';
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart';
import 'package:famdaily/domain/model/time_rule.dart';
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:flutter_test/flutter_test.dart';

/// 假传输：不发网络，只记账并按脚本回答。
///
/// 这里**不**测 HTTP 细节（那是 `sync_api_test.dart` 的活），
/// 只测 `SyncService` 的时序判断：什么时候推、失败后怎么分类、
/// 水位什么时候推进、并发调用会不会打两次。
final class _FakeTransport implements SyncTransport {
  _FakeTransport(this.respond);

  /// 每次请求的回答。
  FutureOr<HttpResponseData> Function(Uri url, Map<String, Object?>? body)
  respond;

  final List<Uri> calls = [];
  final List<Map<String, Object?>?> bodies = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<HttpResponseData> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    calls.add(url);
    this.headers.add(headers);
    bodies.add(jsonDecode(body) as Map<String, Object?>);
    return respond(url, bodies.last);
  }

  @override
  Future<HttpResponseData> get(Uri url, {Map<String, String> headers = const {}}) async {
    calls.add(url);
    this.headers.add(headers);
    bodies.add(null);
    return respond(url, null);
  }

  @override
  void close() {}
}

/// 一个"空响应"的 JSON 骨架。
Map<String, Object?> _emptyResponse({
  int cursor = 100,
  Map<String, Object?> pulled = const {
    'members': [],
    'tasks': [],
    'checkins': [],
    'settings': [],
  },
  List<Object?> rejected = const [],
  bool sinceReset = false,
}) => {
  'ok': true,
  'cursor': cursor,
  'writeHighWater': 0,
  'sinceReset': sinceReset,
  'pulled': pulled,
  'rejected': rejected,
  'tombstoned': 0,
};

HttpResponseData _ok(Map<String, Object?> json) =>
    HttpResponseData(statusCode: 200, json: json);

/// 把"客户端推出去的 body"翻译成"服务端会返回的行"。
///
/// 两边字段名**刻意不一样**：推出去是 camelCase（`createdAtMs`），
/// 回来的行是数据库列名（`created_at_ms`），因为服务端直接把查询结果
/// 吐回来、中间不做一层改名。这个翻译存在就是为了让那次设计选择在
/// 测试里看得见——不翻译就会"缺必填字段"。
Map<String, Object?> _asRow(Map<String, Object?> dto) {
  const camelToSnake = {
    'createdAtMs': 'created_at_ms',
    'updatedAtMs': 'updated_at_ms',
    'deletedAtMs': 'deleted_at_ms',
    'avatarId': 'avatar_id',
    'sortOrder': 'sort_order',
    'memberId': 'member_id',
    'iconId': 'icon_id',
    'repeatJson': 'repeat_json',
    'timeJson': 'time_json',
    'courseStart': 'course_start',
    'courseEnd': 'course_end',
    'courseTotalDays': 'course_total_days',
    'rulesEffectiveFrom': 'rules_effective_from',
    'reminderEnabled': 'reminder_enabled',
    'taskId': 'task_id',
    'slotIndex': 'slot_index',
    'doneAtMs': 'done_at_ms',
    'dueAtMinuteOfDay': 'due_at_minute_of_day',
  };
  return {
    for (final e in dto.entries) camelToSnake[e.key] ?? e.key: e.value,
  };
}

List<Object?> _asRows(Object? list) => [
  for (final row in (list! as List)) _asRow(row as Map<String, Object?>),
];

void main() {
  // 最后一个用例刻意同时开两个库互推，警告是误报（各有各的 executor）。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late _FakeTransport transport;
  late SyncConfigStore config;
  late SyncService service;
  late int now;
  late int dataChangedCalls;
  late int idSeq;

  /// 装配。默认已配对。
  void build({
    FutureOr<HttpResponseData> Function(Uri, Map<String, Object?>?)?
    respond,
  }) {
    transport = _FakeTransport(
      respond ?? (_, _) => _ok(_emptyResponse()),
    );
    service = SyncService(
      db: db,
      config: config,
      apiFactory: (base, t) => SyncApi(transport: t, baseUrl: base),
      transportFactory: () => transport,
      nowMs: () => now,
      newId: () => 'gen-${idSeq++}',
      onDataChanged: () async => dataChangedCalls++,
    );
  }

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    config = SyncConfigStore(db);
    now = 1735689600000;
    dataChangedCalls = 0;
    idSeq = 0;
    build();
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  Future<void> pair() => config.save(
    const SyncConfig(
      baseUrl: 'http://sync.test',
      token: 'tk',
      deviceId: 'dev1',
      familyId: 'fam1',
    ),
    nowMs: now,
  );

  group('没配对', () {
    test('不配对的 syncNow 什么都不发，状态是 notConfigured', () async {
      final s = await service.syncNow();
      expect(s.outcome, SyncOutcome.notConfigured);
      expect(transport.calls, isEmpty);
    });

    test('notConfigured 时设置页那一行不显示（label 为空）', () async {
      final s = await service.syncNow();
      expect(s.shortLabel, isEmpty);
    });
  });

  group('成功路径', () {
    setUp(pair);

    test('推全量：members 含已删成员，checkins 显式给空数组', () async {
      await db.into(db.members).insert(Mappers.memberToCompanion(
        domain.Member(
          id: 'm1',
          name: '我',
          sortOrder: 0,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      ));
      await db.into(db.members).insert(Mappers.memberToCompanion(
        domain.Member(
          id: 'm2',
          name: '已删',
          sortOrder: 1,
          createdAtMs: now,
          updatedAtMs: now,
          deletedAtMs: now,
        ),
      ));

      await service.syncNow();

      final body = transport.bodies.single!;
      final members = body['members']! as List;
      expect(members, hasLength(2), reason: '删掉的成员也必须推，否则对端一直拿它当活着');
      expect(body.containsKey('checkins'), isTrue, reason: '必须显式给，服务端靠它在不在判墓碑');
      expect(body['checkins'], isEmpty);
    });

    test('远端带来新成员：写进库、水位推进、叫醒界面', () async {
      transport.respond = (_, _) => _ok(
        _emptyResponse(
          cursor: 500,
          pulled: {
            'members': [
              {
                'id': 'm9',
                'name': '爷爷',
                'sort_order': 0,
                'created_at_ms': 100,
                'updated_at_ms': 100,
              },
            ],
            'tasks': [],
            'checkins': [],
            'settings': [],
          },
        ),
      );

      final s = await service.syncNow();

      expect(s.outcome, SyncOutcome.ok);
      expect(s.writtenRows, 1);
      expect(dataChangedCalls, 1, reason: '有写入就必须重排提醒并叫醒首页');
      expect((await db.findMember('m9'))!.name, '爷爷');
      expect(await config.loadSince(), 500);
      expect(await config.lastSuccessAtMs(), now);
    });

    test('远端没有新东西：也推进水位，但不叫醒界面', () async {
      final s = await service.syncNow();

      expect(s.outcome, SyncOutcome.ok);
      expect(s.writtenRows, 0);
      expect(dataChangedCalls, 0, reason: '零写入还刷界面=白闪一次');
      expect(await config.loadSince(), 100);
    });

    test('sinceReset 为真：下次 since 回到 0，全量重来', () async {
      transport.respond = (_, _) => _ok(_emptyResponse(sinceReset: true));
      final s = await service.syncNow();

      expect(s.sinceReset, isTrue);
      expect(await config.loadSince(), 0);
    });

    test('被拒若干条：算部分成功，条目留在状态里给人看', () async {
      transport.respond = (_, _) => _ok(
        _emptyResponse(
          rejected: [
            {'kind': 'checkin', 'id': 't1/2025-01-01/0', 'reason': 'FOREIGN KEY'},
          ],
        ),
      );

      final s = await service.syncNow();

      expect(s.outcome, SyncOutcome.partial);
      expect(s.rejects, hasLength(1));
      expect(s.rejects.single.reason, contains('FOREIGN'));
      // 部分成功仍然推进水位：否则一个永远被拒的条目会让水位永远不动，
      // 后面所有数据都拉不下来。
      expect(await config.loadSince(), 100);
    });

    test('远端设置里带白名单之外的键：不写进本机', () async {
      transport.respond = (_, _) => _ok(
        _emptyResponse(
          pulled: {
            'members': [],
            'tasks': [],
            'checkins': [],
            'settings': [
              // 恶意/错误的服务端试图改本机的 token
              {'key': 'sync.token', 'value': 'hijacked', 'updated_at_ms': now},
              {'key': 'reminders.enabled', 'value': 'false', 'updated_at_ms': now},
            ],
          },
        ),
      );

      await service.syncNow();

      expect(await db.getSetting('sync.token'), 'tk');
      expect(await db.getSetting('reminders.enabled'), 'false');
    });

    test('打卡引用了本地没有的项目：跳过，不因为外键整批失败', () async {
      transport.respond = (_, _) => _ok(
        _emptyResponse(
          pulled: {
            'members': [],
            'tasks': [],
            'checkins': [
              {
                'task_id': 'ghost',
                'date': '2025-01-01',
                'slot_index': 0,
                'state': 'done',
                'updated_at_ms': 1,
              },
            ],
            'settings': [],
          },
        ),
      );

      final s = await service.syncNow();

      expect(s.outcome, SyncOutcome.ok);
      expect(s.writtenRows, 0);
    });
  });

  group('失败分类与重试', () {
    setUp(pair);

    test('401 不重试：状态是 auth，错误记在库', () async {
      transport.respond = (_, _) => const HttpResponseData(
        statusCode: 401,
        json: {'error': 'token 无效'},
      );

      final s = await service.syncNow();

      expect(s.outcome, SyncOutcome.failed);
      expect(s.errorKind, SyncErrorKind.auth);
      expect(s.shortLabel, '同步码已失效');
      expect(await config.lastError(), startsWith('auth:'));
      // 水位不动
      expect(await config.loadSince(), 0);
    });

    test('连不上：分类是 network，且真的排了重试', () async {
      var attempts = 0;
      transport.respond = (_, _) {
        attempts++;
        throw TransportException('连不上');
      };

      final s = await service.syncNow();
      expect(s.errorKind, SyncErrorKind.network);
      expect(attempts, 1);

      // 退避第一步是 30 秒，这里不能真等 —— 换成检查"状态里说明可重试"
      expect(SyncErrorKind.network.shouldRetry, isTrue);
      expect(SyncErrorKind.auth.shouldRetry, isFalse);
      expect(SyncErrorKind.protocol.shouldRetry, isFalse);
    });

    test('失败了水位不推进（否则这批数据永久丢失）', () async {
      transport.respond = (_, _) => const HttpResponseData(
        statusCode: 500,
        json: {'error': 'boom'},
      );

      await service.syncNow();

      expect(await config.loadSince(), 0);
      expect(await config.lastSuccessAtMs(), isNull);
    });

    test('resetError 把红字清掉，但成功时间还在', () async {
      transport.respond = (_, _) => _ok(_emptyResponse());
      await service.syncNow();
      final okAt = (await service.syncNow()).lastSuccessAtMs;

      transport.respond = (_, _) => const HttpResponseData(
        statusCode: 401,
        json: {'error': 'x'},
      );
      await service.syncNow();
      expect(service.status.errorKind, SyncErrorKind.auth);

      service.resetError();

      expect(service.status.errorKind, isNull);
      expect(service.status.lastSuccessAtMs, okAt);
    });
  });

  group('触发时机', () {
    setUp(pair);

    test('并发调用只发一次请求', () async {
      // 冷启动和回前台可能几乎同时触发
      await Future.wait([
        service.syncNow(reason: 'a'),
        service.syncNow(reason: 'b'),
        service.syncNow(reason: 'c'),
      ]);

      expect(transport.calls, hasLength(1));
    });

    test('回前台：距上次成功不到 30 秒不发', () async {
      await service.syncNow();
      expect(transport.calls, hasLength(1));

      now += 10 * 1000;
      await service.onForeground();

      expect(transport.calls, hasLength(1), reason: '切来切去不该每次都发请求');
    });

    test('回前台：超过 30 秒才发', () async {
      await service.syncNow();
      now += 31 * 1000;

      await service.onForeground();

      expect(transport.calls, hasLength(2));
    });

    test('本地变更：防抖，连续 5 次只推一次', () async {
      for (var i = 0; i < 5; i++) {
        service.notifyLocalChange();
      }
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(transport.calls, hasLength(1));
    });

    test('dispose 之后 notifyLocalChange 不会再发请求', () async {
      service.dispose();
      service.notifyLocalChange();
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(transport.calls, isEmpty);
      // tearDown 会再 dispose 一次，必须幂等
      build();
    });
  });

  group('两个真库经过 SyncService 互推', () {
    test('A 的数据经过 service 落到 B，B 再看就是 A 的样子', () async {
      final other = AppDatabase.forTesting(openTestConnection());
      addTearDown(other.close);

      // A：一个成员 + 一个项目 + 一条打卡
      await db.into(db.members).insert(Mappers.memberToCompanion(
        domain.Member(
          id: 'm1',
          name: '我',
          sortOrder: 0,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      ));
      await db.into(db.tasks).insert(Mappers.taskToCompanion(
        domain.Task(
          id: 't1',
          memberId: 'm1',
          name: '吃药',
          repeat: const RepeatRule(),
          time: FixedTimesRule([LocalTime(8, 0)]),
          course: domain.Course.none,
          status: TaskStatus.active,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      ));
      await db.upsertCheckin(
        domain.CheckinRecord(
          id: 'c1',
          taskId: 't1',
          date: LocalDate(2025, 1, 1),
          slotIndex: 0,
          state: CheckinState.done,
          doneAtMs: now,
        ),
        nowMs: now,
      );

      // 假服务端：把 A 推上来的原样"拉"给 B。
      // 用真实的 DTO 编解码走一遍，比手搓 JSON 更接近生产路径。
      final fake = SyncService(
        db: other,
        config: SyncConfigStore(other),
        apiFactory: (base, t) => SyncApi(transport: t, baseUrl: base),
        transportFactory: () => transport,
        nowMs: () => now,
        newId: () => 'g-${idSeq++}',
      );
      addTearDown(fake.dispose);
      await SyncConfigStore(other).save(
        const SyncConfig(
          baseUrl: 'http://sync.test',
          token: 'tk',
          deviceId: 'dev2',
          familyId: 'fam1',
        ),
        nowMs: now,
      );

      transport.respond = (url, body) {
        if (url.path == '/sync' && body != null) {
          // 把 A 的推送当成本次响应里的 pulled
          return _ok(
            _emptyResponse(
              cursor: 777,
              pulled: {
                'members': _asRows(body['members']),
                'tasks': _asRows(body['tasks']),
                'checkins': _asRows(body['checkins']),
                'settings': _asRows(body['settings']),
              },
            ),
          );
        }
        return _ok(_emptyResponse());
      };

      // A 也要配对过，否则 syncNow 直接返回 notConfigured，一个请求都不发
      await SyncConfigStore(db).save(
        const SyncConfig(
          baseUrl: 'http://sync.test',
          token: 'tk',
          deviceId: 'dev1',
          familyId: 'fam1',
        ),
        nowMs: now,
      );
      await service.syncNow(); // A 推一次（响应也是它自己，幂等）
      final sent = transport.bodies.last!;

      // 让 B 收到这批
      transport.respond = (_, _) => _ok(
        _emptyResponse(
          cursor: 778,
          pulled: {
            'members': _asRows(sent['members']),
            'tasks': _asRows(sent['tasks']),
            'checkins': _asRows(sent['checkins']),
            'settings': _asRows(sent['settings']),
          },
        ),
      );
      final s = await fake.syncNow();

      expect(s.outcome, SyncOutcome.ok);
      expect(s.writtenRows, 3);
      expect((await other.listMembers()).map((m) => m.name), ['我']);
      expect((await other.listAllTasks()).map((t) => t.name), ['吃药']);
      final onB = await other.checkinsOn(LocalDate(2025, 1, 1));
      expect(onB, hasLength(1));
      expect(onB.single.state, CheckinState.done);
    });
  });
}
