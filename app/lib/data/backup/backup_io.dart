/// 备份的文件层：拼 zip、落临时文件、调系统分享。
///
/// 与 `backup_data.dart` 的分工：那边只管"字节 ⇄ 对象"，这边只管"字节 ⇄ 文件"。
/// 这样那 90% 容易出错的逻辑（字段名、兼容、校验）可以纯单测，
/// 这里只剩不可避免的平台调用。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_data.dart';
import '../../app/test_clock.dart';

/// zip 里那个固定名字的 JSON。
const String manifestEntryName = 'backup.json';

/// 照片目录在 zip 里的前缀。
const String photosDirInZip = 'photos/';

/// 打包成 zip 的字节。**纯函数**，可单测（不用真文件系统）。
Uint8List buildBackupArchive({
  required BackupData data,
  Map<String, List<int>> photos = const {},
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        manifestEntryName,
        Uint8List.fromList(utf8.encode(data.encode())),
      ),
    );

  // 照片按 zip 内的相对路径原样放；record 里存的就是这个相对路径。
  for (final entry in photos.entries) {
    archive.addFile(
      ArchiveFile.bytes(
        '$photosDirInZip${entry.key}',
        Uint8List.fromList(entry.value),
      ),
    );
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 从 zip 字节里读回备份。
///
/// [onPhoto] 用来把 `photos/` 下的文件交给调用方（默认什么也不做，
/// 只在 [BackupArchiveContents.photoPaths] 里记下路径）。
BackupArchiveContents readBackupArchive(
  Uint8List bytes, {
  void Function(String relativePath, List<int> bytes)? onPhoto,
}) {
  final archive = ZipDecoder().decodeBytes(bytes);

  ArchiveFile? manifest;
  final photos = <String>[];
  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    if (file.name == manifestEntryName) {
      manifest = file;
    } else if (file.name.startsWith(photosDirInZip)) {
      final rel = file.name.substring(photosDirInZip.length);
      if (rel.isEmpty) {
        continue;
      }
      photos.add(rel);
      onPhoto?.call(rel, file.content as List<int>);
    }
  }

  if (manifest == null) {
    throw const BackupFormatException(
      '压缩包里没有 $manifestEntryName，可能不是 Famdaily 的备份。',
    );
  }

  final raw = utf8.decode(manifest.content as List<int>);
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const BackupFormatException('$manifestEntryName 不是合法的 JSON 对象');
  }

  return BackupArchiveContents(
    data: BackupData.fromJson(decoded),
    photoPaths: photos,
  );
}

/// 解出来的内容。
final class BackupArchiveContents {
  const BackupArchiveContents({required this.data, required this.photoPaths});

  final BackupData data;

  /// zip 里 `photos/` 下有哪些文件（相对路径）。
  final List<String> photoPaths;

  bool get hasPhotos => photoPaths.isNotEmpty;
}

/// 文件的落地与分享。
///
/// 抽成接口是为了让"导出成功"的整个流程在测试里也能跑：
/// 真机上这是写临时目录 + 弹系统分享面板，测试里换成内存实现。
abstract interface class BackupFileGateway {
  /// 把字节写成一份文件，返回它的绝对路径。
  Future<String> writeTempFile(String fileName, Uint8List bytes);

  /// 调系统分享/存储。
  Future<void> share(String path, {required String subject});

  /// 让用户挑一个备份文件，返回它的字节；取消返回 null。
  Future<Uint8List?> pickBackupFile();
}

/// 生产实现：临时目录 + share_plus。
final class PlatformBackupGateway implements BackupFileGateway {
  const PlatformBackupGateway();

  @override
  Future<String> writeTempFile(String fileName, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    // 每次导出建一个子目录：同名文件被覆盖过一次，分享出去的就可能是旧内容，
    // 而"备份文件是旧的"这种错用户根本发现不了。
    final stamp = appNow().toUtc().toIso8601String().replaceAll(':', '-');
    final sub = Directory(p.join(dir.path, 'backup_$stamp'));
    await sub.create(recursive: true);
    final file = File(p.join(sub.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<void> share(String path, {required String subject}) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], subject: subject),
    );
  }

  @override
  Future<Uint8List?> pickBackupFile() async {
    // 恢复需要系统文件选择器，而 file_picker 还没有引入。
    // 与其写一个假的"恢复"按钮骗用户，不如明确抛出来，
    // 让调用方显示"这一版还不能在 App 里选文件"。
    throw UnsupportedError(
      '这一版还不支持在 App 内选择备份文件；可以先把备份发到自己的邮箱保存。',
    );
  }
}
