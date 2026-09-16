#!/usr/bin/env bash
# 发版后生成/更新 Homebrew cask 的内容 —— 参数:版本号(如 0.1.3)
# 放在这里而不是塞进 release.sh:release.sh 已经很长,而这一步只在"发到 Homebrew"时才需要;
# 独立脚本零风险,也不会拖慢发版。
set -euo pipefail
V="${1:?用法: bash Tools/make-cask.sh <version>}"
DMG="$HOME/Desktop/Glance-$V.dmg"
[ -f "$DMG" ] || { echo "✗ 找不到 $DMG —— 先跑 bash Tools/release.sh $V"; exit 1; }
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
OUT="${2:-/tmp/glance-cask.rb}"
cat > "$OUT" <<RB
cask "glance" do
  version "$V"
  sha256 "$SHA"

  url "https://github.com/cheney12138/glance/releases/download/v#{version}/Glance-#{version}.dmg"
  name "Glance"
  desc "Per-display, window-level app switcher"
  homepage "https://github.com/cheney12138/glance"

  auto_updates true
  depends_on macos: :sonoma

  app "Glance.app"

  caveats <<~EOS
    Glance is signed but not notarized. Homebrew installs it without the macOS
    quarantine flag, so it should open normally. If macOS still refuses:
      xattr -dr com.apple.quarantine "/Applications/Glance.app"
  EOS
end
RB
echo "  版本 $V"
echo "  sha256 $SHA"
echo "  写入 $OUT"
echo
echo "  发到 tap(在 tap 仓库里执行):"
echo "    cp $OUT Casks/glance.rb && git commit -am 'cask: glance $V' && git push"
