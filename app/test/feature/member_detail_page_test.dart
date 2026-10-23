import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/feature/members/member_detail_page.dart';
import 'package:famdaily/feature/members/member_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  late AppDatabase db;
  late MemberService service;

  setUp(() async {
    db = AppDatabase.forTesting(openTestConnection());
    service = MemberService(db: db);
    for (final (i, name) in ['我', '妈妈'].indexed) {
      await db.into(db.members).insert(
        Mappers.memberToCompanion(
          domain.Member(
            id: 'm$i',
            name: name,
            sortOrder: i,
            createdAtMs: _ts,
            updatedAtMs: _ts,
          ),
        ),
      );
    }
  });

  tearDown(() async => db.close());

  testWidgets('画出名字、项目数与一行摘要', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('他的打卡项'), findsOneWidget);
    // 一个项目都没排时的摘要（本月无记录时走"还没安排打卡项"分支）。
    expect(find.text('还没安排打卡项'), findsWidgets);
  });

  testWidgets('打卡链接这一项置灰（下一版才做）', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '生成打卡链接'),
    );
    expect(tile.enabled, isFalse);
    expect(find.textContaining('下一版'), findsOneWidget);
  });

  testWidgets('没给 onOpenTasks 时「他的打卡项」也是灰的', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '他的打卡项'),
    );
    expect(tile.enabled, isFalse);
  });

  testWidgets('删除要走二次确认；点「再想想」什么都不发生', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除这个成员'));
    await tester.pumpAndSettle();

    expect(find.text('删除 妈妈？'), findsOneWidget);
    expect(find.textContaining('打卡记录会留在日历里'), findsOneWidget);

    await tester.tap(find.text('再想想'));
    await tester.pumpAndSettle();

    expect(await service.find('m1'), isNotNull);
    expect((await service.find('m1'))!.isDeleted, isFalse);
  });

  testWidgets('确认删除后软删除并退出', (tester) async {
    await tester.pumpWidget(
      _wrap(MemberDetailPage(service: service, memberId: 'm1')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除这个成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    final m = await service.find('m1');
    expect(m, isNotNull, reason: '软删除：行还在');
    expect(m!.isDeleted, isTrue);
    // 列表里已经看不到了。
    expect((await service.list()).map((r) => r.member.id), ['m0']);
  });

  testWidgets('成员已经被删掉了，进来直接退出而不是画空壳', (tester) async {
    await service.remove('m1', nowMs: _ts);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      MemberDetailPage(service: service, memberId: 'm1'),
                ),
              ),
              child: const Text('进来'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进来'));
    await tester.pumpAndSettle();

    expect(find.text('删除这个成员'), findsNothing);
    expect(find.text('进来'), findsOneWidget, reason: '已经退回上一页');
  });
}
