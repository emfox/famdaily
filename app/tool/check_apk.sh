#!/usr/bin/env bash
# 打完 APK 后的自检：确认 sqlite3 原生库真的在包里。
#
# 为什么要这个脚本：
#   曾经因为 pubspec.yaml 里加了 `hooks: user_defines: sqlite3: source: system`
#   （沙箱里绕过 github 下载的临时办法），APK 里就没有 libsqlite3.so，
#   装到手机上第一次启动直接抛
#     Couldn't resolve native function 'sqlite3_temp_directory'
#     Failed to load dynamic library 'libsqlite3.so'
#   界面弹"启动失败"。构建全程没有任何警告——这类问题只能靠事后查包发现。
#
# 用法：./tool/check_apk.sh [apk 路径]
set -euo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-debug.apk}"

if [[ ! -f "$APK" ]]; then
  echo "✗ 找不到 $APK" >&2
  exit 1
fi

# 先把清单落到变量里再判断。
#
# 原来是 `unzip -l "$APK" | grep -qE ...` 直接接在 if 里。`grep -q` 一旦命中
# 就立刻退出，unzip 还在写管道时会拿到 SIGPIPE 并以非零码收场；上面又开了
# `set -o pipefail`，于是"找到了"被判成"没找到"——包明明是对的，脚本却报错。
# 在 65MB 的 release 包上必现，在小的 debug 包里偶尔不复现，所以之前没暴露。
LISTING="$(unzip -l "$APK")"

if ! grep -qE 'lib/[^/]+/libsqlite3\.so' <<< "$LISTING"; then
  echo "✗ $APK 里没有 libsqlite3.so —— 装到手机上会启动失败。" >&2
  echo "  查一下 pubspec.yaml 里有没有 hooks.user_defines.sqlite3.source=system，" >&2
  echo "  那个配置会让构建改用系统库，而 Android 并不提供公开的 libsqlite3.so。" >&2
  exit 1
fi

echo "✓ $(basename "$APK") 内含 libsqlite3.so："
grep -E 'lib/[^/]+/libsqlite3\.so' <<< "$LISTING" | awk '{printf "    %s  %s\n", $1, $4}'
