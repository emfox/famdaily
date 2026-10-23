#!/usr/bin/env bash
# 打一个能直接发给人的 release APK，并把**构建时间**印进包里。
#
# 为什么要有这个脚本：
#   反复出现"我装了新包，怎么还是老样子"。一个原因是 APK 装在手机上，
#   版本号永远是 0.1.0，用户没法判断手里这个到底是哪天的。
#   现在「设置 → 关于 → 版本」会显示构建时间，一眼能对上。
#
# 只出 arm64 单 ABI：真机基本都是 arm64，单 ABI 的包小一半，
# 也不用担心"手机上装的是哪一份"。
#
# 用法：
#   ./tool/build_apk.sh                    # 出到 /workspace/famdaily-build/
#   OUT=/tmp ./tool/build_apk.sh           # 换输出目录
set -euo pipefail

cd "$(dirname "$0")/.."

FLUTTER="${FLUTTER:-/opt/flutter-3.44.9/bin/flutter}"
OUT="${OUT:-/workspace/famdaily-build}"
STAMP="$(date '+%Y-%m-%d %H:%M')"
NAME="famdaily-arm64-release.apk"

echo "构建时间：$STAMP"
echo

"$FLUTTER" build apk --release \
  --target-platform=android-arm64 \
  --dart-define=BUILD_TIME="$STAMP" \
  "$@"

APK="build/app/outputs/flutter-apk/app-release.apk"
./tool/check_apk.sh "$APK"

mkdir -p "$OUT"
cp "$APK" "$OUT/$NAME"

echo
echo "✓ $OUT/$NAME"
ls -lh "$OUT/$NAME" | awk '{print "  大小：" $5}'
echo "  md5：$(md5sum "$OUT/$NAME" | cut -d' ' -f1)"
echo
echo "装上去之后，「设置 → 关于 → 版本」里应该显示："
echo "  0.1.0（开发版 · $STAMP）"
