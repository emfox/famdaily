import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Web 上的数据库连接：sqlite3 编译成 WebAssembly，数据存在浏览器的
/// IndexedDB / OPFS 里。
///
/// 注意这条路径当前**只是让 Web 编译能过**，还没接进产品流程：
/// 本项目的既定方案是「原生 App 为主，网页端作为同步节点」（见
/// docs/requirements.zh_CN.md），网页端自己带库这件事等到 P3 做同步协议时
/// 再定——很可能改成「网页端直接读同步快照」而不是各自维护一份 SQLite。
///
/// 真要启用，需要把两个产物放进 web/ 目录：
///   sqlite3.wasm      —— `dart run drift_dev make-wasm` 产出
///   drift_worker.js   —— 同上
/// 缺了它们，运行时会报 404，构建阶段不会报错。
QueryExecutor openPlatformConnection() {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: 'famdaily',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    return result.resolvedExecutor;
  });
}

/// Web 上没有"内存测试库"这种跨平台一致的做法，测试也不会跑在浏览器里，
/// 这里留一个明确抛错的实现，防止误用时报难懂的 ffi 错误。
QueryExecutor openTestConnection() {
  throw UnsupportedError('网页端不支持内存测试库，请在 VM 上跑 flutter test。');
}

/// 网页端没有本地文件系统概念，指向文件的连接没有意义。
QueryExecutor openFileConnection(String path) {
  throw UnsupportedError('网页端没有本地文件路径，无法打开 $path。');
}
