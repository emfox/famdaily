// 集成测试的 App 入口壳。
//
// `flutter test integration_test/xxx.dart -d linux` 需要一个能 runApp 的
// main：测试框架会先把它拉起来，再把 tester 绑上去。这里刻意只放
// `app.main()`，不塞任何测试专用的假实现——真机上跑的时候，
// 它和你双击图标启动的是同一个 App。
import 'package:famdaily/main.dart' as app;

void main() {
  app.main();
}
