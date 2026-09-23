#!/bin/bash
# 自动回归门 —— 每次"改完一处"就跑一遍(三道门 + 一份真机验收清单)
#
# 为什么需要它(2026-09-22 用户原话):
#   「最近做新功能老是出现影响存量实现的问题。搞的我自己当时测试完都不敢发版, 要用个一天半天的」
# ⇒ 让"能自动判的"全部自动判掉,把用户的时间只花在**只有他能判**的那几件事上 ✓
#
# 纪律:任何一门不过 ⇒ 脚本**非零退出**(挡住继续往下做 ✓);绝不允许"看见红了还往下走" ✓
set -u
cd "$(dirname "$0")/.."
FAIL=0

step() { printf '\n\033[1m══ %s\033[0m\n' "$1"; }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=1; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; }

step "① 领域层单测(规则的可执行版本)"
# ⚠️ 判据用 **swift test 的退出码**,不要拿尾部几行去 grep 摘要 ——
#    第一版我按摘要匹配,`tail -3` 常常只是构建/规划行 ⇒ 明明全绿却报红 ✗(脚本自己也会假阳 ✓)
TEST_LOG=$(mktemp)
if (cd Packages/GlanceCore && swift test >"$TEST_LOG" 2>&1); then
    grep -E 'Executed [0-9]+ tests, with [0-9]+ failures' "$TEST_LOG" | tail -1 | sed 's/^/    /'
    ok "单测全绿"
else
    grep -E 'error:|XCTAssert|failed|Executed [0-9]+ tests' "$TEST_LOG" | tail -8 | sed 's/^/    /'
    bad "单测有红 ⇒ 不许提交"
fi
rm -f "$TEST_LOG"

step "② 架构规矩(界面能改的键必须有运行时读取点 等)"
if swift Tools/check-architecture.swift 2>&1 | tail -20 | grep -q '无违例'; then
    ok "无违例"
else
    swift Tools/check-architecture.swift 2>&1 | tail -12 | sed 's/^/    /'
    bad "架构有违例"
fi

step "③ 构建(含 warning 计数)"
BUILD_LOG=$(mktemp)
if xcodebuild -project Glance.xcodeproj -scheme Glance -configuration Debug build >"$BUILD_LOG" 2>&1; then
    WARN=$(grep -E 'Sources/.*warning:' "$BUILD_LOG" | sort -u | wc -l | tr -d ' ')
    ok "构建通过 · 本次输出里的 warning: $WARN 条(旧取图 API 的那条弃用是有意保留的 ✓ 增量构建可能不重复打印)"
    [ "$WARN" -gt 2 ] && printf '    ⚠️ warning 变多了,看一眼:\n' && grep -E 'Sources/.*warning:' "$BUILD_LOG" | sort -u | head -5 | sed 's/^/    /'
else
    grep -E 'error:' "$BUILD_LOG" | sort -u | head -10 | sed 's/^/    /'
    bad "构建失败"
fi
rm -f "$BUILD_LOG"

cat <<'TXT'

── 以下是**只有人**能判的(照 docs/存量面清单.md 的第三节走) ──
   [ ] 这次碰了哪几条冻结面?依据是什么?
   [ ] 新增的状态活多久、谁清它?
   [ ] 动作失败时会看得见地退回去吗?
   [ ] 有没有读"还没落定"的列表(复核期)?
   [ ] 改动涉及视觉吗?对照图里有"真实现场"吗?
   [ ] 真机验收:让用户试哪 3 步?(越具体越好)
TXT

if [ "$FAIL" -ne 0 ]; then
    printf '\n\033[31m✗ 有门没过 —— 先修它,别提交\033[0m\n'
    exit 1
fi
printf '\n\033[32m✅ 三道自动门都过\033[0m\n'
