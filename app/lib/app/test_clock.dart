/// 一个**跨 zone 生效**的假时钟，只给集成测试用。
///
/// 为什么不直接用 `package:clock` 的 `withClock`：
/// `withClock` 是把 Clock 塞进 `Zone.current` 的 zoneValue 里。在
/// `flutter test` 的 AutomatedTestWidgetsFlutterBinding 下这够用，因为
/// 一切都在同一个 zone 里跑。但在 `IntegrationTestWidgetsFlutterBinding`
/// （Live binding，真渲染真跑帧）下**不成立**——实测：
///
/// ```
/// BODY  zone=18070123 clock=2026-03-02 20:00   ← 测试体在假时钟 zone
/// BUILD zone=159873591 clock=2026-10-24 00:39  ← 页面在另一个 zone，真时钟
/// ```
///
/// 页面的 `initState`/`build` 走的是引擎那侧的 zone，`Zone.current` 里
/// 没有我们塞的值，于是所有页面都退回真实时钟。症状很迷惑：测试体里
/// `clock.now()` 明明是 3 月，日历画出来却是 10 月。
///
/// 这里的做法是绕开 zone——把"现在几点"放进一个全局可写的变量，
/// 哪个 zone 读到都是同一个值。只在 `TestClock.enabled` 为 true 时生效，
/// 生产构建里没有任何地方会把它打开。
///
/// 代价是它**不是** zone 隔离的：并行跑测试会互相踩。集成测试是串行、
/// 一次一个 App 实例，所以没影响；Widget 测试继续用 `withClock` 就好。
library;

import 'package:clock/clock.dart';

/// 集成测试的时钟开关。
abstract final class TestClock {
  /// 打开后，`AppClock.now()` 优先返回 [now]。
  ///
  /// 默认 false：生产代码里这条分支永远不进，`AppClock.now()` 就是
  /// 普通的 `clock.now()`。
  static bool enabled = false;

  /// 钉住的时刻。`TestClock.enabled` 为 false 时被忽略。
  static DateTime? now;

  /// 钉住时刻并打开开关。测试结束时调用 [reset]。
  static void pin(DateTime moment) {
    now = moment;
    enabled = true;
  }

  /// 清掉钉住的时刻并关掉开关。
  static void reset() {
    now = null;
    enabled = false;
  }
}

/// 页面和 service 统一从这里读"现在几点"。
///
/// 平时它就是 `clock.now()`（仍然尊重 `withClock`，Widget 测试照旧）。
/// 集成测试里 `TestClock` 打开后，它在**任何 zone** 里都返回同一个假时刻。
DateTime appNow() {
  if (TestClock.enabled && TestClock.now != null) {
    return TestClock.now!;
  }
  return clock.now();
}
