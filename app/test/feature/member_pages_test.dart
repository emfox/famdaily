import 'package:famdaily/data/db/app_database.dart';
import 'package:famdaily/data/db/mappers.dart';
import 'package:famdaily/domain/model/member.dart' as domain;
import 'package:famdaily/feature/members/member_avatar.dart';
import 'package:famdaily/feature/members/member_edit_page.dart';
import 'package:famdaily/feature/members/member_list_page.dart';
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
    for (final (i, name) in ['我', '妈妈', '爷爷'].indexed) {
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

  group('成员列表', () {
    testWidgets('列出全部成员，写明「不用登录」', (tester) async {
      await tester.pumpWidget(_wrap(MemberListPage(service: service)));
      await tester.pumpAndSettle();

      // 用 ListTile 定位而不是 find.text：名字叫「我」时，头像里的首字
      // 也是「我」，而 ListTile 的子树里也含头像，所以按 tile 取标题。
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(titles, ['我', '妈妈', '爷爷']);
      expect(find.textContaining('成员不用登录'), findsOneWidget);
    });

    testWidgets('第一行不能上移，最后一行不能下移', (tester) async {
      await tester.pumpWidget(_wrap(MemberListPage(service: service)));
      await tester.pumpAndSettle();

      final ups = tester
          .widgetList<IconButton>(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up))
          .toList();
      final downs = tester
          .widgetList<IconButton>(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down))
          .toList();

      // 三行三对按钮，顺序与行一致。
      expect(ups, hasLength(3));
      expect(downs, hasLength(3));
      expect(ups.first.onPressed, isNull, reason: '第一行没有上移');
      expect(downs.last.onPressed, isNull, reason: '最后一行没有下移');
    });

    testWidgets('点下移真的换位，并落库', (tester) async {
      await tester.pumpWidget(_wrap(MemberListPage(service: service)));
      await tester.pumpAndSettle();

      // 点第一行的「下移」。
      await tester.tap(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down).first,
      );
      await tester.pumpAndSettle();

      final rows = await service.list();
      expect(rows.map((r) => r.member.name), ['妈妈', '我', '爷爷']);
      // 界面上也跟着换了。
      final tile = tester.widgetList<ListTile>(find.byType(ListTile)).first;
      expect(((tile.title! as Text)).data, '妈妈');
    });

    testWidgets('空列表给一句引导而不是空白', (tester) async {
      await db.customStatement('DELETE FROM members');
      await tester.pumpWidget(_wrap(MemberListPage(service: service)));
      await tester.pumpAndSettle();

      expect(find.textContaining('先加一个「我」'), findsOneWidget);
    });
  });

  group('新增成员', () {
    testWidgets('名字空着保存按钮不可点', (tester) async {
      await tester.pumpWidget(_wrap(MemberEditPage(service: service)));
      await tester.pumpAndSettle();

      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '保存'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('填了名字点了头像，保存后落库', (tester) async {
      await tester.pumpWidget(_wrap(MemberEditPage(service: service)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '奶奶');
      await tester.pumpAndSettle();
      expect(find.byType(MemberAvatar), findsOneWidget, reason: '实时预览');

      await tester.tap(find.bySemanticsLabel('奶奶'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      final rows = await service.list();
      expect(rows.map((r) => r.member.name), contains('奶奶'));
      final added = rows.firstWhere((r) => r.member.name == '奶奶');
      expect(added.member.avatarId, 'grandma');
      expect(added.member.sortOrder, 3, reason: '新成员排到末尾');
    });

    testWidgets('不选头像也能存，avatarId 保持 null（走首字兜底）', (tester) async {
      await tester.pumpWidget(_wrap(MemberEditPage(service: service)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '小黑');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      final rows = await service.list();
      final added = rows.firstWhere((r) => r.member.name == '小黑');
      expect(added.member.avatarId, isNull);
      expect(added.member.initial, '小');
    });

    testWidgets('取消不动数据', (tester) async {
      await tester.pumpWidget(_wrap(MemberEditPage(service: service)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '临时');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect((await service.list()).map((r) => r.member.name),
          ['我', '妈妈', '爷爷']);
    });
  });

  group('编辑成员', () {
    testWidgets('带 initial 进来时预填名字，标题写「改成员」', (tester) async {
      final m = await service.find('m1');
      await tester.pumpWidget(
        _wrap(MemberEditPage(service: service, initial: m)),
      );
      await tester.pumpAndSettle();

      expect(find.text('改成员'), findsOneWidget);
      expect(find.widgetWithText(TextField, '妈妈'), findsOneWidget);
    });

    testWidgets('改名字保存，id 不变、其他字段不丢', (tester) async {
      final m = await service.find('m1');
      await service.update(m!.copyWith(avatarId: 'mom'), nowMs: _ts);

      final fresh = await service.find('m1');
      await tester.pumpWidget(
        _wrap(MemberEditPage(service: service, initial: fresh)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '母亲');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      final after = await service.find('m1');
      expect(after!.name, '母亲');
      expect(after.id, 'm1');
      expect(after.avatarId, 'mom', reason: '换名字不该顺手把头像丢了');
      expect(after.sortOrder, 1);
    });
  });

  group('成员头像', () {
    testWidgets('预置头像画图标，不画首字', (tester) async {
      const m = domain.Member(
        id: 'a',
        name: '爷爷',
        avatarId: 'grandpa',
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0,
      );
      await tester.pumpWidget(_wrap(const Center(child: MemberAvatar(member: m))));

      expect(find.byIcon(Icons.elderly), findsOneWidget);
      expect(find.text('爷'), findsNothing);
    });

    testWidgets('没设头像时画名字首字', (tester) async {
      const m = domain.Member(
        id: 'a',
        name: '爷爷',
        sortOrder: 0,
        createdAtMs: 0,
        updatedAtMs: 0,
      );
      await tester.pumpWidget(_wrap(const Center(child: MemberAvatar(member: m))));

      expect(find.text('爷'), findsOneWidget);
    });
  });
}
