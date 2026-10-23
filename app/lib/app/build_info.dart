/// 构建信息：让"装的是哪一版"这件事看得见。
///
/// 为什么需要它：给用户发 APK 时，反复出现"我装了新包，怎么还是老样子"。
/// 光靠版本号 0.1.0 区分不出来——前后几个包都是 0.1.0。构建时间不一样，
/// 但它只要**一眼能看出来**。
///
/// 用 `--dart-define=BUILD_TIME=...` 在打包时塞进去，缺省就显示"未知"。
/// 不用 package_info_plus：为了一个字符串再加一个插件，代价比收益大。
library;

abstract final class BuildInfo {
  /// 构建时刻，由打包命令塞入（见 `tool/build_apk.sh`）。
  ///
  /// 格式是 `yyyy-MM-dd HH:mm`，直接显示，不做时区换算——它是给人看的标签，
  /// 不是用来做计算的。
  static const String builtAt = String.fromEnvironment(
    'BUILD_TIME',
    defaultValue: '',
  );

  /// 一条短的可追溯标记：构建时间 + 提交号前缀（也叫"三秒判断装没装新版"）。
  static String get label {
    if (builtAt.isEmpty) {
      return '开发版';
    }
    return builtAt;
  }
}
