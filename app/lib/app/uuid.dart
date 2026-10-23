import 'dart:math';

/// 极简 UUID v4 生成。
///
/// 不引 `uuid` 包的原因：我们只需要"本地唯一"，不需要跨设备全局唯一
/// （P3 同步时会由服务端再定 ID 规则），`Random.secure()` 加几十行就够，
/// 少一个依赖少一处供应链风险。
String newId() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  // 版本位 4（随机 UUID），变体位 10xx。
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex =
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
