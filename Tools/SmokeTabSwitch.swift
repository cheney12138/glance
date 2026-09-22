// 冒烟:唤起 + 连续 Tab 换选中(给 Instruments/xctrace 录一段"有动作"的窗口用)。
//
//   swift Tools/SmokeTabSwitch.swift [次数=8] [间隔ms=420]
//
// 与 SmokeRingCross 的分工:那个测**换环两个方向**,这个测**同环内连按 Tab 的掉帧/卡顿** ——
// 用户 2026-09-22 报「60Hz 屏上 tab 切换还是掉帧」时,就是拿它配 `Animation Hitches` 模板录的。
// 收尾用 Esc(放弃,不聚焦任何窗);实例不唯一直接退出。
import AppKit
import CoreGraphics

let rounds = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 8) : 8
let gapMs  = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 420) : 420
let cmd: CGKeyCode = 0x37, tab: CGKeyCode = 0x30, esc: CGKeyCode = 0x35
let src = CGEventSource(stateID: .hidSystemState)
func post(_ k: CGKeyCode, _ d: Bool, _ f: CGEventFlags) {
    CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: d).map { $0.flags = f; $0.post(tap: .cghidEventTap) }
}
func tap(_ k: CGKeyCode, _ f: CGEventFlags) { post(k, true, f); usleep(35_000); post(k, false, f) }
func wait(_ ms: Int) { usleep(UInt32(ms) * 1000) }

let n = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cheney12138.macswitcher").count
print("  Glance 实例数:\(n)"); if n != 1 { print("  ⚠️ 实例不唯一,先收拾干净"); exit(2) }

post(cmd, true, [.maskCommand]); wait(80)
tap(tab, [.maskCommand]); wait(500)                 // 唤起(落点 = 上一个 App)
for i in 0..<rounds { tap(tab, [.maskCommand]); wait(gapMs); _ = i }
tap(esc, [.maskCommand]); wait(100); post(cmd, false, [])
print("  注入完成:唤起 + \(rounds) 次 Tab + Esc(间隔 \(gapMs)ms)")
