import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// 真机 / 桌面上的数据库连接。文件落在应用文档目录（由 drift_flutter 解析）。
QueryExecutor openPlatformConnection() {
  return driftDatabase(
    name: 'famdaily',
    native: const DriftNativeOptions(shareAcrossIsolates: true),
  );
}

/// 纯 Dart 测试用的内存库（`flutter test` 里不需要模拟器）。
QueryExecutor openTestConnection() {
  return NativeDatabase.memory();
}

/// 桌面调试时指向真实文件的连接（给 PC 端 / 调试工具用）。
QueryExecutor openFileConnection(String path) {
  return NativeDatabase(File(path));
}
