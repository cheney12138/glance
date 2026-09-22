// 冒烟:**hover 扫过环 + 托盘**,量"悬停那几拍"掉不掉。
//
//   swift Tools/SmokeHover.swift [扫几遍=3] [每步ms=16] [哪条屏=auto]
//
// 为什么需要它 —— 用户 2026-09-22 报「我感觉 hover 还有点掉帧, 60hz 的显示器是不是没办法避免 0 损失」。
// 手上原有的脚本测的是"Tab 换选中"与"换环两个方向",**没有测 hover 的** ✗。
//
// 手法要点(踩过的坑):
//   · 托盘卡的 hover 走 SwiftUI `.onHover`(NSTrackingArea)⇒ **必须发真的 mouseMoved 事件** ✗
//     `CGWarpMouseCursorPosition` 只挪指针、不产生事件 ⇒ 托盘永远不 hover(白测一轮)✗
//     ⇒ 这里用 `CGEvent(mouseType: .mouseMoved).post(tap: .cghidEventTap)` ✓
//     (环的 hover 是轮询,两种都行;托盘的必须真事件 ⇒ 统一用真事件 ✓)
//   · 面板从"按住触发键"起就一直在 ⇒ 用 **⌘ 一直按着 + tap Tab** 开门,不放开 ⌘ ⇒ 不释放 ✓
//   · 收尾:放开 ⌘ ⇒ 面板退场 ⇒ `FrameProbe.stop()` 当场打一行汇总 ✓
//   · 指针最后**挪回原位**(用户可能马上回来用机器 ✓)
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let passes = args.count > 1 ? (Int(args[1]) ?? 3) : 3
let stepMs = args.count > 2 ? (Int(args[2]) ?? 16) : 16
let stepPx = args.count > 3 ? (Double(args[3]) ?? 18) : 18
/// 第 4 个参数:把指针先挪到哪块屏再触发(`0` = 主屏 / `1` = 第二块 / `-1` = 不动)。
/// 用它可以做"同一段 hover 换屏量"的对照(60Hz 外接 vs 120Hz 内建 ✓)
let screenIdx = args.count > 4 ? (Int(args[4]) ?? -1) : -1
/// 第 5 个参数:扫哪些线(`all` / `icons` = 只扫图标那一行 / `tray` = 只扫卡片那两行)。
/// 用来分开两条 hover 路径:环图标走**轮询**(pollRingHover)· 托盘卡走 **NSTrackingArea**(.onHover)✓
let lines = args.count > 5 ? args[5] : "all"
/// `passes = 0` ⇒ **只把面板开着、指针全程不动**(基线:面板在场但无输入)✓
let holdMs = 14_000

let bundleID = "com.cheney12138.macswitcher"
let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
guard running.count == 1, let app = running.first else {
    print("  ⚠️ Glance 实例数 = \(running.count)(要求恰好 1 个,先收拾干净)"); exit(2)
}
let pid = app.processIdentifier
let src = CGEventSource(stateID: .hidSystemState)

func postKey(_ k: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
    CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down).map { $0.flags = f; $0.post(tap: .cghidEventTap) }
}
func movePointer(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}
func wait(_ ms: Int) { usleep(UInt32(ms) * 1000) }

/// Glance 当前在屏上的窗口(全局坐标,**左上原点** —— 与 CGEvent 的坐标系一致 ✓)
func glanceWindows() -> [CGRect] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
              width > 20, height > 20 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

let origin = NSEvent.mouseLocation                                     // 收尾还回去
let startGlobal = CGPoint(x: origin.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - origin.y)

print("  pid=\(pid)  扫 \(passes) 遍 · 每步 \(stepMs)ms / \(Int(stepPx))px")

// ⓪ 先把指针挪到指定屏(照屏幕坐标落在它的中心偏下一半,别挨着边缘)
if screenIdx >= 0, screenIdx < NSScreen.screens.count {
    let f = NSScreen.screens[screenIdx].frame      // AppKit 坐标(左下原点)⇒ 转成左上原点
    let mainH = NSScreen.screens.map(\.frame.maxY).max() ?? f.maxY
    let p = CGPoint(x: f.midX, y: mainH - (f.midY + f.height * 0.25))
    movePointer(p); wait(260)
    print("  指针已挪到屏 #\(screenIdx)(\(NSScreen.screens[screenIdx].localizedName))@\(Int(p.x)),\(Int(p.y))")
}

// ① 开门:⌘ 按住 + tap Tab(⌘ 不放开 ⇒ 面板保持在场)
postKey(0x37, true, [.maskCommand]); wait(80)
postKey(0x30, true, [.maskCommand]); wait(35)
postKey(0x30, false, [.maskCommand]); wait(520)

let wins = glanceWindows()
var union: CGRect?
for w in wins { union = union.map { $0.union(w) } ?? w }
guard let union else {
    print("  ⚠️ 没找到 Glance 的窗口(面板没起来?)⇒ 放弃"); postKey(0x37, false, []); exit(3)
}
print("  窗口 \(wins.count) 块:" + wins.map { String(format: "%.0fx%.0f@%.0f,%.0f", $0.width, $0.height, $0.minX, $0.minY) }.joined(separator: " "))
print(String(format: "  扫描范围:%.0f,%.0f %.0fx%.0f(全局坐标,左上原点)", union.minX, union.minY, union.width, union.height))

// ② 扫三条水平线:图标行 / 卡片行 / 更靠下一行(把环与托盘都扫到 ✓)
// ★ 2026-09-22 修:第一版的线是**猜的**(union.minY+42 之类)⇒ 66% 的扫描落在面板的空白区,
//   用户当场指出来:「我看着你指针根本没扫到, 没hover到app」✗ —— 他完全说对了 ✓
//   现在按**实测几何**取线:面板两张窗口各量过一遍(见 Tools/README 或提交信息),
//   图标行在环面板窗口高度的 0.45–0.72、卡片行在托盘窗口高度的 0.45–0.72,
//   横向各内缩 15%(避开玻璃边与阴影)⇒ 每条线都真的压在图标/卡片上 ✓
func linesIn(_ r: CGRect) -> [CGFloat] { [0.45, 0.60, 0.72].map { r.minY + r.height * $0 } }
let ringPanel = wins.max { $0.height < $1.height } ?? union        // 高的那块 = 图标面板
let tray = wins.min { $0.height < $1.height } ?? union            // 矮的那块 = 托盘
let ys: [CGFloat]
let xInset: CGFloat = 0.15
let x0: CGFloat, x1: CGFloat
switch lines {
case "touch":
    // **人那样的 hover**:少数几步**挪进去、停住** —— 用来把"连续跨边界churn"与"真 hover"分开 ✓
    // (第一轮用 12px 步长连扫 ⇒ 每秒几十次 hover-in/out ⇒ 量到的是边界抖动,不是人感受到的 hover ✗)
    ys = linesIn(tray); x0 = tray.minX; x1 = tray.maxX
case "icons": ys = linesIn(ringPanel);            x0 = ringPanel.minX; x1 = ringPanel.maxX
case "tray":  ys = linesIn(tray);                 x0 = tray.minX;      x1 = tray.maxX
default:      ys = linesIn(ringPanel) + linesIn(tray)
              x0 = min(ringPanel.minX, tray.minX); x1 = max(ringPanel.maxX, tray.maxX)
}
var sent = 0
if lines == "touch" {
    let y = ys[0]
    let mid = (x0 + x1) / 2
    for k in 0...5 { movePointer(CGPoint(x: mid - 60 + CGFloat(k) * 24, y: y)); wait(40) }   // 挪进去(≈人手的 6 个事件)
    print("  人那样 hover:6 步挪到卡片上,然后**停住** 12s"); wait(12_000)
    postKey(0x37, false, []); wait(900); movePointer(startGlobal)
    print("  注入完成"); exit(0)
}
for pass in 0..<passes {
    for y in ys {
        let forward = pass % 2 == 0
        let lo = x0 + (x1 - x0) * xInset, hi = x1 - (x1 - x0) * xInset
        let xs = stride(from: lo, through: hi, by: stepPx).map { $0 }
        for x in (forward ? xs : xs.reversed()) {
            movePointer(CGPoint(x: x, y: y)); sent += 1; wait(stepMs)
        }
        wait(180)                                  // 线之间停一下(让 hover 换格/起流都发生)
    }
}
print(passes == 0 ? "  基线模式:面板开着,指针**全程不动** \(holdMs / 1000)s" : "  已发 \(sent) 个 mouseMoved")
if passes == 0 { wait(holdMs) }

// ③ 收尾:放开 ⌘(面板退场 ⇒ 帧汇总打印)
postKey(0x37, false, []); wait(900)
movePointer(startGlobal)
print("  注入完成(指针已挪回原位)")
