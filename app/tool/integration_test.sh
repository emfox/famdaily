#!/usr/bin/env bash
# 跑集成测试（端到端）。
#
# 跟 `tool/test.sh`（单元 + 组件测试）分开，是因为两者对环境的要求完全不同：
# 单元测试纯 Dart、无窗口；集成测试要**真的渲染、真的点**，需要一块屏幕
# 和一个能跑 GTK 的运行时。
#
# 本机没有 KVM，Android 模拟器起不来，所以目标是 **Linux 桌面**：
# 同一份 Flutter 代码，同一套 widget 树，只是换了个 shell 外壳。
# 再套 `xvfb-run` 开一块虚拟屏，CI 上也能跑。
#
# 用法：
#   ./tool/integration_test.sh                      # 全部
#   ./tool/integration_test.sh app_flow_test.dart   # 单个文件
#   加 --keep 可以保留窗口（有真实显示器时调试用）
set -euo pipefail

cd "$(dirname "$0")/.."

# 机器上有两套 Flutter：/opt/flutter 是 3.0.0（Dart 2.17，空安全前），
# 直接用 PATH 里的那个会报一堆看不懂的语法错。这里钉死 3.44.9。
FLUTTER=/opt/flutter-3.44.9/bin/flutter
if [[ ! -x "$FLUTTER" ]]; then
  echo "找不到 $FLUTTER" >&2
  exit 1
fi

TARGET="integration_test/"
if [[ $# -gt 0 && "$1" != -* ]]; then
  TARGET="integration_test/$1"
  shift
fi

DISPLAY_CMD=(xvfb-run -a -s "-screen 0 1280x900x24")
if [[ "${1:-}" == "--keep" ]]; then
  DISPLAY_CMD=()
  shift
fi

echo "==> $FLUTTER test $TARGET -d linux"
# 一次只跑一个文件：集成测试会开真窗口、占真数据库文件，并行没好处。
exec "${DISPLAY_CMD[@]}" "$FLUTTER" test "$TARGET" -d linux "$@"
