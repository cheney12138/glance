#!/bin/bash
# 出正式 DMG(Release 构建 + 标准布局:Glance.app + /Applications 软链)。
#
#   bash Tools/make-dmg.sh              # 产物到 ~/Desktop/Glance-<版本>.dmg
#   bash Tools/make-dmg.sh /tmp/out     # 指定输出目录
#
# 为什么用脚本而不是手敲:DMG 里那份 app 必须与**已授权的那份**同源 —— 每次都要重新
# Release 构建、从 xcodebuild 的输出目录取产物(路径带 DerivedData 哈希,不能写死),
# 手敲一次就会漏一步,得到"看起来一样但签名/版本不同"的包。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-$HOME/Desktop}"
PROJECT="Glance.xcodeproj"
SCHEME="Glance"
CONFIG="Release"

echo "== 1/4 Release 构建"
# -destination generic/platform=macOS:不加的话 xcodebuild 会挑"第一个匹配的目标"(= 本机架构),
# 出包只有 arm64 —— 正式包要 universal(Apple silicon + Intel)
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' build | tail -3

SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' -showBuildSettings 2>/dev/null)
BUILT_DIR=$(echo "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
PRODUCT=$(echo "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $2; exit}')
APP="$BUILT_DIR/$PRODUCT"
[ -d "$APP" ] || { echo "找不到产物:$APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT_DIR/Glance-$VERSION.dmg"
echo "== 2/4 产物 ${APP}（版本 ${VERSION}）"

echo "== 3/4 组装布局"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$PRODUCT"          # ditto 保签名:cp -R 会打散扩展属性
ln -s /Applications "$STAGE/Applications"

echo "== 4/4 打包"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "Glance" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo
echo "✅ ${DMG}（$(du -h "${DMG}" | cut -f1)）"
echo
echo "装法:打开 DMG,把 Glance.app 拖进 Applications。"
echo "注意:① 先退掉 Xcode 里那份(单实例守卫会让第二份直接退出);"
echo "      ② 换了签名/路径,macOS 可能重新要一次辅助功能与屏幕录制授权;"
echo "      ③ 如果开过「接管系统 ⌘Tab」,退出时请让它正常退出(别强杀)。"
