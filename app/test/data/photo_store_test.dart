import 'dart:io';
import 'dart:typed_data';

import 'package:famdaily/data/photo/photo_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 临时目录版 PhotoDirectory，测试不碰 path_provider。
final class _TempDir implements PhotoDirectory {
  _TempDir(this.dir);

  final Directory dir;

  @override
  Future<Directory?> root() async => Directory('${dir.path}/photos');
}

final class _NullDir implements PhotoDirectory {
  @override
  Future<Directory?> root() async => null;
}

final class _FakePicker implements PhotoPicker {
  _FakePicker(this.bytes);

  Uint8List? bytes;
  PhotoSource? lastSource;
  Object? error;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    lastSource = source;
    if (error != null) {
      throw error!;
    }
    return bytes;
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('famdaily_photo_test');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  PhotoStore makeStore({int maxBytes = 4 * 1024 * 1024, DateTime? at}) {
    return PhotoStore(
      directory: _TempDir(tmp),
      maxBytes: maxBytes,
      now: () => at ?? DateTime(2025, 3, 15, 9, 12),
    );
  }

  test('存下来的路径是相对的，不含 documents 目录', () async {
    final store = makeStore();
    final saved = await store.save(Uint8List.fromList([1, 2, 3, 4]));

    expect(saved, isNotNull);
    expect(saved!.relativePath, startsWith('2025/03/'));
    expect(saved.relativePath, endsWith('.jpg'));
    // 关键：不含绝对路径前缀，iOS 升级后目录变了也能找回
    expect(saved.relativePath.contains(tmp.path), isFalse);
    expect(saved.byteSize, 4);
  });

  test('按月分目录（一个目录塞几千个文件会拖慢列目录）', () async {
    final store = PhotoStore(
      directory: _TempDir(tmp),
      now: () => DateTime(2025, 7, 4, 10),
    );
    final saved = await store.save(Uint8List.fromList([9]));
    expect(saved!.relativePath, startsWith('2025/07/'));
  });

  test('resolve 能把相对路径还原成当前目录下的绝对路径', () async {
    final store = makeStore();
    final saved = await store.save(Uint8List.fromList([1, 2, 3]));
    final abs = await store.resolve(saved!.relativePath);

    expect(abs, isNotNull);
    expect(abs, contains('photos'));
    expect(File(abs!).existsSync(), isTrue);
  });

  test('文件被清掉时 resolve 返回 null，不抛异常', () async {
    final store = makeStore();
    final saved = await store.save(Uint8List.fromList([1, 2, 3]));
    await File((await store.resolve(saved!.relativePath))!).delete();

    expect(await store.resolve(saved.relativePath), isNull);
  });

  test('目录拿不到时 save 返回 null（照片存不下不该让打卡失败）', () async {
    final store = PhotoStore(directory: _NullDir());
    expect(await store.save(Uint8List.fromList([1])), isNull);
  });

  test('超过上限直接拒收，不悄悄压缩', () async {
    final store = makeStore(maxBytes: 10);
    expect(await store.save(Uint8List(11)), isNull);
    expect(await store.save(Uint8List(10)), isNotNull);
  });

  test('空字节拒收', () async {
    final store = makeStore();
    expect(await store.save(Uint8List(0)), isNull);
  });

  test('同一毫秒存两张不会互相覆盖（文件名带内容哈希）', () async {
    final store = makeStore();
    final a = await store.save(Uint8List.fromList([1, 1, 1]));
    final b = await store.save(Uint8List.fromList([2, 2, 2]));

    expect(a!.relativePath, isNot(b!.relativePath));
    expect(File((await store.resolve(a.relativePath))!).existsSync(), isTrue);
    expect(File((await store.resolve(b.relativePath))!).existsSync(), isTrue);
  });

  test('删除照片；删不存在的不报错', () async {
    final store = makeStore();
    final saved = await store.save(Uint8List.fromList([7, 7]));
    await store.delete(saved!.relativePath);
    expect(await store.resolve(saved.relativePath), isNull);

    // 再删一次（幂等）
    await store.delete(saved.relativePath);
  });

  group('选图前先查大小', () {
    test('用户取消返回 null', () async {
      final store = makeStore();
      final picker = _FakePicker(null);
      expect(await store.readAndCheck(picker, PhotoSource.camera), isNull);
    });

    test('正常大小放行，并把来源透传下去', () async {
      final store = makeStore();
      final picker = _FakePicker(Uint8List.fromList([1, 2]));
      final result = await store.readAndCheck(picker, PhotoSource.gallery);

      expect(result!.isOk, isTrue);
      expect(result.bytes, [1, 2]);
      expect(picker.lastSource, PhotoSource.gallery);
    });

    test('太大时给一句人话，带上实际大小和上限', () async {
      final store = makeStore(maxBytes: 2 * 1024 * 1024);
      final picker = _FakePicker(Uint8List(5 * 1024 * 1024));
      final result = await store.readAndCheck(picker, PhotoSource.camera);

      expect(result!.isOk, isFalse);
      expect(result.error, contains('5.0 MB'));
      expect(result.error, contains('2.0 MB'));
    });

    test('空文件说"读不出来"，不说"太大"', () async {
      final store = makeStore();
      final picker = _FakePicker(Uint8List(0));
      final result = await store.readAndCheck(picker, PhotoSource.camera);

      expect(result!.isOk, isFalse);
      expect(result.error, contains('读不出来'));
    });
  });

  test('SavedPhoto 的大小标签：KB / MB', () {
    expect(
      const SavedPhoto(relativePath: 'a', byteSize: 2048).sizeLabel,
      '2 KB',
    );
    expect(
      const SavedPhoto(relativePath: 'a', byteSize: 3 * 1024 * 1024).sizeLabel,
      '3.0 MB',
    );
  });
}
