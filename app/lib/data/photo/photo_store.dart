/// 照片凭证的落地：选图 → 压缩 → 存到 `<documents>/photos/` → 把**相对路径**写进记录。
///
/// 为什么存相对路径不存绝对路径（这一点很要紧）：iOS 的 App 沙盒目录在每次
/// 升级/重装后会变（`/var/mobile/Containers/Data/Application/<UUID>/...`），
/// 存了绝对路径，用户更新一次 App 所有照片就全"找不到"了。库里只存
/// `2025/03/xxx.jpg`，读的时候拼回当前 documents 目录。
///
/// 照片**只存本地，不同步网页**（需求 3.6），所以这一层不需要任何网络逻辑；
/// 备份要不要带上照片由 `BackupService(includePhotos:)` 决定。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 选图来源。
enum PhotoSource {
  /// 拍照（默认相机后置）。
  camera,

  /// 从相册选。
  gallery,
}

/// 选一张图，返回原始字节；用户取消返回 null。
///
/// 抽成接口是为了让页面在 Widget 测试里能注入假实现——真的
/// `ImagePicker` 会拉起系统 UI，测试里一点就卡死。
abstract interface class PhotoPicker {
  Future<Uint8List?> pick(PhotoSource source);
}

/// 取照片根目录（`<documents>/photos`）。
///
/// 抽出来是为了一处定义：`BackupService` 从同一个地方读，
/// 两边各拼一次 `p.join(dir.path, 'photos')` 迟早会有一处拼错。
abstract interface class PhotoDirectory {
  Future<Directory?> root();
}

/// 真实实现：`path_provider` + `image_picker`。
final class PlatformPhotoDirectory implements PhotoDirectory {
  const PlatformPhotoDirectory();

  @override
  Future<Directory?> root() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return Directory(p.join(dir.path, 'photos'));
    } catch (_) {
      // 拿不到目录（极少见）：返回 null，调用方跳过照片而不是整体失败。
      // 照片是"软性凭证"，它存不下不该让打卡本身失败。
      return null;
    }
  }
}

/// 存好之后的结果。
final class SavedPhoto {
  const SavedPhoto({required this.relativePath, required this.byteSize});

  /// 相对 `photos/` 的路径，如 `2025/03/1740787200000_ab12.jpg`。
  final String relativePath;

  final int byteSize;

  String get sizeLabel => byteSize >= 1024 * 1024
      ? '${(byteSize / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(byteSize / 1024).round()} KB';
}

/// 照片仓库：写、读、删。
final class PhotoStore {
  PhotoStore({
    PhotoDirectory? directory,
    DateTime Function()? now,
    this.maxBytes = 4 * 1024 * 1024,
  }) : _directory = directory ?? const PlatformPhotoDirectory(),
       _now = now ?? clock.now;

  final PhotoDirectory _directory;
  final DateTime Function() _now;

  /// 单张上限。超过就拒收而不是悄悄压缩——App 侧没有可靠的解码/重编码
  /// 能力（纯 Dart 重编码要引一套 codec，收益不抵成本），
  /// 与其存一张 30MB 的原图让备份卡住，不如直接告诉用户"太大了"。
  final int maxBytes;

  /// 存一张照片。返回 null = 没存成（目录不可用或超出上限）。
  ///
  /// [bytes] 已经在 [readAndCheck] 里过了一遍大小检查，这里再查一次是因为
  /// 调用方可能绕过前者——入口只该有一个，但底线不该只有一处。
  Future<SavedPhoto?> save(Uint8List bytes, {DateTime? at}) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      return null;
    }
    final root = await _directory.root();
    if (root == null) {
      return null;
    }
    final moment = at ?? _now();
    final name = _fileName(moment, bytes);
    // 按月分目录：一个目录塞几千个文件，某些文件系统上列目录会明显变慢。
    final rel = p.join(_ym(moment), name);
    final file = File(p.join(root.path, rel));
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      return null;
    }
    return SavedPhoto(relativePath: rel, byteSize: bytes.length);
  }

  /// 相对路径 → 可读的绝对路径；目录不可用或文件不在时返回 null。
  ///
  /// 返回 null 而不是抛异常：照片可能被用户从系统相册清理掉了，
  /// 那时候记录还要能正常显示（画一个"照片找不到了"的占位）。
  Future<String?> resolve(String relativePath) async {
    final root = await _directory.root();
    if (root == null) {
      return null;
    }
    final file = File(p.join(root.path, relativePath));
    return await file.exists() ? file.path : null;
  }

  /// 删一张照片（撤销打卡时顺手清掉，不留孤儿文件）。
  ///
  /// 失败静默：删不掉只是占点空间，不该让"撤销打卡"这个主流程报错。
  Future<void> delete(String relativePath) async {
    final root = await _directory.root();
    if (root == null) {
      return;
    }
    try {
      final file = File(p.join(root.path, relativePath));
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // 忽略。
    }
  }

  /// 选图前先看一眼大小，避免选完了才发现拒收（交互上更顺）。
  ///
  /// 返回 null 表示"这次没选"（用户取消）。
  Future<PhotoPickResult?> readAndCheck(
    PhotoPicker picker,
    PhotoSource source,
  ) async {
    final bytes = await picker.pick(source);
    if (bytes == null) {
      return null;
    }
    if (bytes.isEmpty) {
      return const PhotoPickResult.rejected('这张照片读不出来，换一张试试。');
    }
    if (bytes.length > maxBytes) {
      return PhotoPickResult.rejected(
        '这张照片有 ${_mb(bytes.length)}，太大了（上限 ${_mb(maxBytes)}）。'
        '拍照时可以把相机调成普通照片模式。',
      );
    }
    return PhotoPickResult.ok(bytes);
  }

  static String _ym(DateTime t) =>
      '${t.year}/${t.month.toString().padLeft(2, '0')}';

  /// 文件名带毫秒时间戳 + 内容长度短哈希：同一秒连拍两张也不会互相覆盖。
  static String _fileName(DateTime t, Uint8List bytes) {
    var h = 0;
    for (var i = 0; i < bytes.length; i += 97) {
      h = (h * 31 + bytes[i]) & 0xffff;
    }
    return '${t.millisecondsSinceEpoch}_${h.toRadixString(16)}.jpg';
  }

  static String _mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 选图的结果：要么拿到字节，要么带一句能直接给用户看的话。
final class PhotoPickResult {
  const PhotoPickResult.ok(this.bytes) : error = null;
  const PhotoPickResult.rejected(this.error) : bytes = null;

  final Uint8List? bytes;
  final String? error;

  bool get isOk => bytes != null;
}
