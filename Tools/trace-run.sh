#!/bin/bash
# 带诊断日志启动 Glance,日志固定写到 ~/Library/Logs/Glance/trace.log。
#
#   bash Tools/trace-run.sh
#
# 为什么要有这个脚本:诊断期最费时间的不是查问题,是"日志在哪个终端窗口里" ——
# 从终端直接起进程时 stdout 绑在那个 tty 上,别人读不到,只能靠人肉复制粘贴(还经常太长)。
# 固定到一个文件之后:"我测完了" → 助手直接读文件,不用你搬。
set -euo pipefail
APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Glance-*/Build/Products/Debug/Glance.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "找不到构建产物 —— 先在 Xcode 里 ⌘R 跑一次"; exit 1; }
LOG_DIR="$HOME/Library/Logs/Glance"; mkdir -p "$LOG_DIR"; LOG="$LOG_DIR/trace.log"

# 旧实例:先走 TERM(它会先还原系统 ⌘Tab);不吃 TERM 的(通常在调试器里)再 KILL + 手动还原
if pkill -TERM -x Glance 2>/dev/null; then sleep 1; fi
if pgrep -x Glance >/dev/null; then
  kill -9 "$(pgrep -x Glance | head -1)" 2>/dev/null || true
  sleep 1
  swift "$(dirname "$0")/NativeHotkeys.swift" restore >/dev/null 2>&1 || true
fi

# 不在这里重定向:进程自己会写(~Library/Logs/Glance/trace.log),所以 Xcode 起、终端起都落同一个文件
GLANCE_TRACE=1 "$APP/Contents/MacOS/Glance" >/dev/null 2>&1 &
disown || true
echo "已启动(后台)✓  日志:$LOG"
echo "测完跟我说一声就行 —— 我会自己读这个文件。"
