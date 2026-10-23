import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'photo_store.dart';

/// `image_picker` 的真实实现。
///
/// 三点要点（都是踩过的坑）：
/// 1. `maxWidth` / `imageQuality` 让插件在**原生侧**就降采样，
///    不这样做一张 4000×3000 的原图会先整个读进内存；
/// 2. 传入的 `ImagePicker` 必须复用（不要在每次 pick 时 new 一个），
///    否则 Android 上偶发拿不到结果；
/// 3. 不加 `camera` 权限的运行时请求——`image_picker` 自己会处理，
///    我们多请求一次反而会在 iOS 上出现两次弹窗。
final class ImagePickerPhotoPicker implements PhotoPicker {
  ImagePickerPhotoPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    final file = await _picker.pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // 凭证照片不需要大图：够看清药盒上的字、作业本上的对错就够了。
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 82,
    );
    if (file == null) {
      return null;
    }
    return file.readAsBytes();
  }
}
