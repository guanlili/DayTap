#!/bin/bash
# 构建冒烟:pbxproj 校验 + 双 target 免签构建。
# 需要完整 Xcode(CommandLineTools 不含 watchOS SDK)。
#   ./scripts/build-smoke.sh          # 全部
#   ./scripts/build-smoke.sh watch    # 只下手表
#   ./scripts/build-smoke.sh phone    # 只下手机
set -euo pipefail

cd "$(dirname "$0")/.."
PROJ="apps/DayTap/DayTap.xcodeproj"
TARGET="${1:-all}"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "错误:xcodebuild 不可用。当前开发者目录是 $(xcode-select -p)" >&2
  echo "需要安装完整 Xcode 并执行:sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

echo "== Xcode =="
xcodebuild -version

echo "== pbxproj lint =="
plutil -lint "$PROJ/project.pbxproj"

build_one() {
  local scheme="$1" dest="$2" name="$3"
  echo "== build $name ($scheme) =="
  xcodebuild -project "$PROJ" \
    -scheme "$scheme" \
    -destination "$dest" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -30
}

if [ "$TARGET" = "all" ] || [ "$TARGET" = "watch" ]; then
  build_one "DayTap Watch App" "generic/platform=watchOS" "watch"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "phone" ]; then
  build_one "DayTap" "generic/platform=iOS" "phone"
fi

echo "== 通过 =="
