#!/usr/bin/env bash
# 干净重启 Glance（唯一入口）。
#
# 为什么需要它（2026-09-21 两次被咬）：
#   Xcode 启动的实例**外部杀不掉**，而 `osascript quit` + `open` 有时候只是把**旧进程**
#   唤到前面 ⇒ 你在屏幕上操作的是**旧代码**，日志里却看不出异常。
#   病例：用户按了 **55 次 Tab** 复现"tab 切换掉帧"，而日志里 `[工] 键盘换选中` **0 行** ✗
#        —— 说明那个进程根本没有我们刚加的计时器 ⇒ 那一轮排查白做。
#
# 所以这个脚本做三件事：**停干净 → 启新构建 → 自证"进程比二进制新"**。
set -uo pipefail
cd "$(dirname "$0")/.."

APP=~/Library/Developer/Xcode/DerivedData/Glance-gisdvtihuakrcnctlhesuzppbkym/Build/Products/Debug/Glance.app
BIN="$APP/Contents/MacOS/Glance"
PATTERN='DerivedData.*Glance.app/Contents/MacOS/Glance'

if [[ ! -x "$BIN" ]]; then
  echo "✗ 找不到构建产物：$BIN"
  echo "  先构建：xcodebuild -project Glance.xcodeproj -scheme Glance -configuration Debug build"
  exit 1
fi

# ① 停干净：先请它自己退，再确认；不退就 SIGKILL（Xcode 起的实例经常赖着）
osascript -e 'quit app "Glance"' 2>/dev/null
for _ in $(seq 1 20); do pgrep -f "$PATTERN" >/dev/null || break; sleep 0.25; done
if pgrep -f "$PATTERN" >/dev/null; then
  echo "  · 旧实例不理会 quit ⇒ SIGKILL"
  pkill -9 -f "$PATTERN"; sleep 0.5
fi
if pgrep -f "$PATTERN" >/dev/null; then
  echo "✗ 还有实例活着：$(pgrep -f "$PATTERN" | tr '\n' ' ')"; exit 1
fi

# ② 启新构建
open "$APP"
for _ in $(seq 1 32); do pgrep -f "$PATTERN" >/dev/null && break; sleep 0.25; done
PID="$(pgrep -f "$PATTERN" | head -1)"
[[ -z "$PID" ]] && { echo "✗ 没起来"; exit 1; }

# ③ 自证：进程启动时间必须晚于二进制修改时间（否则屏幕上跑的是旧代码）
BIN_TS=$(stat -f %m "$BIN")
PROC_TS=$(ps -o lstart= -p "$PID" | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null || echo 0)
echo "  二进制改动: $(date -r "$BIN_TS" '+%H:%M:%S')   进程启动: $(date -r "${PROC_TS:-0}" '+%H:%M:%S' 2>/dev/null)   pid=$PID"
if [[ "${PROC_TS:-0}" -lt "$BIN_TS" ]]; then
  echo "  ⚠️ 进程比二进制**还早** ⇒ 屏幕上跑的是旧代码！"
  echo "     再跑一次本脚本；或在 Xcode 里 Stop 后再 Run"
  exit 2
fi
echo "  ✓ 新构建已上屏（pid=${PID}）"
