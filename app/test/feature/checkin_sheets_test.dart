import 'dart:typed_data';

import 'package:famdaily/data/photo/photo_store.dart';
import 'package:famdaily/domain/model/course.dart' as domain;
import 'package:famdaily/domain/model/local_date.dart' as domain;
import 'package:famdaily/domain/model/local_time.dart' as domain;
import 'package:famdaily/domain/model/repeat_rule.dart' as domain;
import 'package:famdaily/domain/model/task.dart' as domain;
import 'package:famdaily/domain/model/task_status.dart' as domain;
import 'package:famdaily/domain/model/time_rule.dart' as domain;
import 'package:famdaily/domain/model/checkin_row.dart';
import 'package:famdaily/domain/scheduling/scheduler.dart';
import 'package:famdaily/feature/home/checkin_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ts = 1740787200000;

final domain.LocalDate _today = domain.LocalDate(2025, 3, 15);

CheckinRow _row() {
  final task = domain.Task(
    id: 't1',
    memberId: 'm1',
    name: '降压药',
    repeat: const domain.RepeatRule(),
    time: domain.FixedTimesRule([domain.LocalTime(20, 0)]),
    course: domain.Course.none,
    status: domain.TaskStatus.active,
    createdAtMs: _ts,
    updatedAtMs: _ts,
  );
  return CheckinRow(
    task: task,
    date: _today,
    slotIndex: 0,
    dueAt: LocalDateTimeRef(_today, domain.LocalTime(20, 0)),
    dueMinuteOfDay: 1200,
  );
}

/// 假的选图器。真的 image_picker 会拉起系统 UI，测试里一点就卡死。
final class _FakePicker implements PhotoPicker {
  _FakePicker({this.bytes, this.error});

  Uint8List? bytes;
  Object? error;
  int calls = 0;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return bytes;
  }
}

void main() {
  Future<CheckinExtras?> open(
    WidgetTester tester, {
    PhotoPicker? picker,
  }) async {
    CheckinExtras? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showNoteSheet(context, _row(), picker: picker);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('没注入 picker 时不显示拍照按钮（测试/只读场景）', (tester) async {
    await open(tester);

    expect(find.text('降压药 · 记一句'), findsOneWidget);
    expect(find.text('拍一张'), findsNothing);
    expect(find.text('从相册选'), findsNothing);
  });

  testWidgets('注入 picker 后两个入口都在', (tester) async {
    await open(tester, picker: _FakePicker());

    expect(find.text('拍一张'), findsOneWidget);
    expect(find.text('从相册选'), findsOneWidget);
  });

  testWidgets('点「拍一张」拿到图后显示预览，保存时带上照片', (tester) async {
    final picker = _FakePicker(bytes: Uint8List.fromList(_png1x1));
    CheckinExtras? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showNoteSheet(context, _row(), picker: picker);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('拍一张'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    // 预览出现后，"拍一张"按钮就收起来了
    expect(find.text('拍一张'), findsNothing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result?.photo, isNotNull);
    expect(result?.photo?.bytes, _png1x1);
  });

  testWidgets('拍照失败（没权限）时说能改用相册，不说技术错误', (tester) async {
    final picker = _FakePicker(error: Exception('camera_access_denied'));

    await open(tester, picker: picker);
    await tester.tap(find.text('拍一张'));
    await tester.pumpAndSettle();

    expect(find.textContaining('可以先把照片存到相册里再选'), findsOneWidget);
    // 仍然能继续用相册入口
    expect(find.text('从相册选'), findsOneWidget);
  });

  testWidgets('只填备注、不拍照，也能保存', (tester) async {
    CheckinExtras? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showNoteSheet(
                    context,
                    _row(),
                    picker: _FakePicker(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '吃了两粒');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result?.note, '吃了两粒');
    expect(result?.photo, isNull);
  });

  testWidgets('什么都不填直接「不用了」返回 null（正常路径，不是取消）', (tester) async {
    CheckinExtras? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showNoteSheet(context, _row());
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不用了'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('只有空格备注 + 没照片 = isEmpty（不写库）', (tester) async {
    CheckinExtras? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showNoteSheet(context, _row());
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result?.isEmpty, isTrue);
  });
}

/// 最小合法 PNG（1×1），用来让 `Image.memory` 真的能解码。
const _png1x1 = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
