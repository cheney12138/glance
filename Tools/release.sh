#!/bin/bash
# 发版:构建 universal DMG → EdDSA 签名 → 生成 appcast.xml → 打印上传步骤。
#
#   bash Tools/release.sh 0.2.0
#
# 为什么是一条脚本而不是手敲五步:发版最容易错的就是"忘了签名 / 版本号没涨 / appcast 指向旧包"——
# 那三种错都不会当场报错,而是等到用户点「检查更新…」才炸,那时已经没有人记得细节了。
# 所以这里把口径写死:版本号必须显式传(不猜)、构建号自动用时间戳(单调递增,Sparkle 就靠它比大小)、
# 签名与 appcast 都由 Sparkle 官方的 generate_appcast 生成(不手写 XML)。
set -euo pipefail

cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "用法:bash Tools/release.sh <版本号,如 0.2.0>"; exit 1; }
VERSION="$1"
TAG="v$VERSION"
PROJECT="Glance.xcodeproj"

# Sparkle 官方工具(sign_update / generate_appcast)。默认放缓存目录,不在仓库里。
TOOLS="${SPARKLE_TOOLS:-$HOME/Library/Caches/glance-sparkle}"
SPARKLE_VERSION="2.10.0"

echo "== 0/4 准备 Sparkle 工具"
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  mkdir -p "$TOOLS"
  echo "   下载 Sparkle $SPARKLE_VERSION 工具到 $TOOLS"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar xJ -C "$TOOLS"
fi

echo "== 1/4 写版本号 + 构建号(时间戳)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Sources/Glance/Info.plist 2>/dev/null || true
BUILD=$(date +%Y%m%d%H%M)
# 短版本号在 Info.plist(局部),构建号在工程设置里(CURRENT_PROJECT_VERSION → CFBundleVersion)
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PROJECT/project.pbxproj"
echo "   版本 $VERSION / 构建 $BUILD"

echo "== 2/4 构建 DMG"
bash Tools/make-dmg.sh "$HOME/Desktop" | tail -2

echo "== 3/4 EdDSA 签名 + 生成 appcast"
# ⚠️ 这里**不用** Sparkle 的 generate_appcast(2026-09-15 病例):
# 它在归档里那个 App 的 Info.plist 缺 SUPublicEDKey、或它自己判断"不该签"时,
# 会**静默**生成一份没有 sparkle:edSignature 的 appcast(退出码 0、没有警告)——
# 结果就是:更新检查永远"没有新版本",而且沿着 appcast 一路查都看不出问题。
# 改成显式两步:sign_update 出签名 → 自己写 appcast(字段全部由命令量出来,不猜)。
if [ -n "${GLANCE_ED_KEY:-}" ]; then
  SIG_ARGS=(--ed-key-file "$GLANCE_ED_KEY")     # CI/多机:私钥文件
else
  SIG_ARGS=(--account glance)                    # 本机:登录钥匙串(首次会弹一次"始终允许")
fi
SIG=$("$TOOLS/bin/sign_update" "$HOME/Desktop/Glance-$VERSION.dmg" "${SIG_ARGS[@]}")
echo "   签名:$SIG"

DMG_PATH="$HOME/Desktop/Glance-$VERSION.dmg"
# 最低系统版本直接从工程设置读 —— 不要现去 xcodebuild 问一遍:
# 一旦那条命令失败,$() 会退化成空串,拼出来的路径就成了 "/Glance.app/...",
# PlistBuddy 会**真的在根目录创建** /Glance.app 再报"文件不存在"(2026-09-15 踩过两次)。
MIN_SYS=$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$PROJECT/project.pbxproj" | sed 's/.*= \(.*\);/\1/' | tr -d ' ')
[ -n "$MIN_SYS" ] || MIN_SYS="14.0"
python3 - "$VERSION" "$BUILD" "$MIN_SYS" "$TAG" "$DMG_PATH" "$SIG" <<'PYX'
import sys, os, datetime
version, build, min_sys, tag, dmg, sig = sys.argv[1:7]
size = os.path.getsize(dmg)
url = f"https://github.com/cheney12138/Glance/releases/download/{tag}/{os.path.basename(dmg)}"
pub = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
xml = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Glance</title>
    <item>
      <title>{version}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_sys}</sparkle:minimumSystemVersion>
      <enclosure url="{url}" {sig.strip()} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""
open(os.path.expanduser("~/Desktop/appcast.xml"), "w").write(xml)
print(f"   appcast:{url}")
print(f"   签名长度 {len(sig.strip())} 字符(含 edSignature 与 length)")
PYX

echo "== 4/4 上传(gh 没装就照下面两条手点)"
cat <<EOF

  产物:
    $HOME/Desktop/Glance-$VERSION.dmg
    $HOME/Desktop/appcast.xml

  装了 gh 的话两条命令就够:
    gh release create $TAG "$HOME/Desktop/Glance-$VERSION.dmg" "$HOME/Desktop/appcast.xml" \\
      --title "Glance $VERSION" --notes "…"

  没装 gh:到 https://github.com/cheney12138/Glance/releases/new 新建 $TAG,
  把**两个文件都**传上去当资产(appcast.xml 必须在最新那一版上 —— app 里的 SUFeedURL
  指向 releases/latest/download/appcast.xml,少传它更新就会断)。

  发完之后,别忘了把版本号/构建号这两处改动提交(否则下次发版会从旧号继续涨)。
EOF
