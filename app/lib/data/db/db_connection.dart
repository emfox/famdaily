// 平台相关的数据库连接。
//
// 为什么单独拆成三个文件：
//   `drift/native.dart` 和 `dart:io` 在浏览器里根本不存在（前者最终 import
//   `dart:ffi`），Web 编译会直接失败：
//       Error: Dart library 'dart:ffi' is not available on this platform.
//   所以不能在一个文件里"先 import 再判断"，只能靠条件导入，让编译器在
//   Web 构建时根本不加载 native 实现。
//
// 用法（app_database.dart 里）：
//   import 'db_connection_io.dart'
//       if (dart.library.js_interop) 'db_connection_web.dart';
//
// 三个文件必须导出同名同签名的函数，否则条件导入会报错。
export 'db_connection_io.dart'
    if (dart.library.js_interop) 'db_connection_web.dart';
