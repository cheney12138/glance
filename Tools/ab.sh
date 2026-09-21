#!/usr/bin/env bash
# 一趟 A/B 的开关+重启（给"人来做对照"用的，省得手打两条命令还容易打错）。
#
#   bash Tools/ab.sh off      # 关掉消元开关 → 重启（日志打「重型开关:无」）
#   bash Tools/ab.sh on       # 打开消元开关 → 重启（日志打 ⚠️ 重型开关 …已打开）
#   bash Tools/ab.sh clear    # 删掉该开关（收尾）
#
# 为什么必须**重启**：汇总行是在"关面板那一刻"打的，运行中改开关的话，
#   日志里两趟会混在一起、切不开（2026-09-21 已经这么白跑过一次）。
#   重启后 `DebugFlags` 的开机自报会把开关状态**大声打进日志** ⇒ 两趟天然可分 ✓。
set -uo pipefail
cd "$(dirname "$0")/.."
DOMAIN=com.cheney12138.macswitcher
KEY=debug.noStripShadow

case "${1:-}" in
  off)   defaults write "$DOMAIN" "$KEY" -bool false; echo "  开关 ${KEY} = **关**" ;;
  on)    defaults write "$DOMAIN" "$KEY" -bool true;  echo "  开关 ${KEY} = **开**" ;;
  clear) defaults delete "$DOMAIN" "$KEY" 2>/dev/null; echo "  开关 ${KEY} 已删除（收尾 ✓）"; exit 0 ;;
  *)     echo "用法：bash Tools/ab.sh off | on | clear"; exit 1 ;;
esac

bash Tools/run.sh
echo
echo "  现在请：唤起面板 → 用 Tab 切几个 App（含大象，来回切两三下）"
echo "          → **按 Esc 关掉面板**（关掉那一刻才会打帧汇总 ✓）"
echo "          → 做完再跑一次 bash Tools/ab.sh 的另一档 ✓"
