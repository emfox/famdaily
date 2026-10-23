#!/usr/bin/env bash
# 跑全部测试。**钉死"用哪个 flutter"，也钉死并发度。**
#
# 为什么要有这个脚本，而不是直接敲 `flutter test`：
#
# 1. 机器上有多套 Flutter。`which flutter` 指向 /opt/flutter，那是
#    Flutter 3.0.0 / Dart 2.17（2022 年的）。本项目要 3.44.9 / Dart 3.12。
#    用错的那套跑，症状是**看起来卡死**：
#
#      Error detected in pubspec.yaml:
#      The specified language version is too high. The highest supported
#      language version is 2.17.
#
#    3.12 的代码喂给 2.17 的编译器，一条都编不过；flutter_tools 不退出，
#    反复重试、反复往日志里刷同一段报错——实测两分多钟刷出 227 万行。
#    看起来是"测试死循环"，其实是**工具链选错了**。
#
# 2. 就算用对的 flutter，默认并发也是坑。默认按 CPU 核数开（这台 nproc=32），
#    每个并发背后是一个真的 flutter_tester 进程各带一份引擎，32 个一起起来
#    会把机器压死，编排器等不到子进程的结束信号，进度条停在原地。
#    实测 523 个用例：-j 32 卡死；-j 4 用 18s 全绿；-j 1 用 45s 全绿。
#
# 用法：
#   ./tool/test.sh                                          # 全部
#   ./tool/test.sh test/feature                             # 某个目录
#   ./tool/test.sh test/feature/day_detail_page_test.dart    # 某个文件
#   FLUTTER=/path/to/flutter ./tool/test.sh                 # 指定 SDK
set -euo pipefail

cd "$(dirname "$0")/.."

# --- 选 flutter ---------------------------------------------------------
# 优先用调用方指定的；否则依次试几个已知位置，挑**Dart >= 3.12** 的那个。
# 不直接用 `which flutter`：它可能是老的那套。
pick_flutter() {
  if [[ -n "${FLUTTER:-}" ]]; then
    echo "$FLUTTER"
    return
  fi
  local candidates=(
    /opt/flutter-3.44.9/bin/flutter
    /opt/flutter/bin/flutter
  )
  # 也把 PATH 里的算进来（可能装在自己目录里、版本是对的）
  command -v flutter >/dev/null 2>&1 && candidates+=("$(command -v flutter)")

  for f in "${candidates[@]}"; do
    [[ -x "$f" ]] || continue
    local root dartver major minor
    root="$(cd "$(dirname "$f")/.." && pwd)"
    [[ -f "$root/bin/cache/dart-sdk/version" ]] || continue
    dartver="$(cat "$root/bin/cache/dart-sdk/version")"
    major="${dartver%%.*}"
    minor="${dartver#*.}"; minor="${minor%%.*}"
    # 项目要求 Dart ^3.12（见 pubspec.yaml 的 environment.sdk）
    if (( major > 3 || (major == 3 && minor >= 12) )); then
      echo "$f"
      return
    fi
  done

  echo "✗ 找不到 Dart >= 3.12 的 Flutter SDK。" >&2
  echo "  试过：/opt/flutter-3.44.9/bin/flutter、PATH 里的 flutter。" >&2
  echo "  用 FLUTTER=/path/to/flutter ./tool/test.sh 指定一个。" >&2
  exit 1
}

FLUTTER_BIN="$(pick_flutter)"
JOBS="${JOBS:-4}"

echo "flutter: $FLUTTER_BIN"
"$FLUTTER_BIN" --version 2>/dev/null | head -1
echo "并发: -j $JOBS"
echo

# --no-pub：依赖已经装好了就别每次重解析，一次省几秒。
exec "$FLUTTER_BIN" test --no-pub -j "$JOBS" "$@"
