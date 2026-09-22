// 冒烟测试:「Tab/⇧Tab 换环」两个方向都要通(2026-09-22)。
//
//   swift Tools/SmokeRingCross.swift
//
// 为什么要有它:2026-09-22 用户报「关了设置之后,不能互相切换,只能切回来」——
//   真因是 `moveApp` 里**只有主环 → 未启动那一侧挂了门禁** ✗(另一边从来没有),
//   修完我**自己用这个脚本注入事件验过**(日志里那两行 `段切换(⇧Tab)/(Tab)` 就是判据)。
//   ⚠️ 脚本里踩过一次坑,写在这里省得再踩:唤起后的**落点是"上一个 App",不是第一格** ⇒
//     ⇧Tab 要按**两下**(第一下走到 0 格,第二下才跨段)。
// 自带两条安全设计:实例数不为 1 直接退出;收尾用 **Esc**(不聚焦任何窗,不会切走你的前台)。
//   序列:⌘ 按住 → Tab(唤起) → 等一下 → ⇧Tab(反向跨段) → 等一下 → Tab(正向回到环尾) → Esc(放弃) → ⌘ 松开
// 事件注在 HID 层,与我们自己的 tap 看来与真键盘同构。
import AppKit
import CoreGraphics

let cmd: CGKeyCode = 0x37, shift: CGKeyCode = 0x38, tab: CGKeyCode = 0x30, esc: CGKeyCode = 0x35
let src = CGEventSource(stateID: .hidSystemState)

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}
func tap(_ key: CGKeyCode, flags: CGEventFlags) {
    post(key, down: true, flags: flags); usleep(30_000); post(key, down: false, flags: flags)
}
func wait(_ ms: UInt32) { usleep(ms * 1000) }

// 0) 数一遍实例(不止一个会抢同一组 ⌘Tab,是最常见的假象来源)
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cheney12138.macswitcher")
print("  Glance 实例数:\(running.count)"); if running.count != 1 { print("  ⚠️ 实例不唯一,先收拾干净"); exit(2) }

print("  ⌘ 按住 → Tab(唤起)")
post(cmd, down: true, flags: [.maskCommand]); wait(60)
tap(tab, flags: [.maskCommand]); wait(350)          // 唤起 + 落点第一格

print("  ⇧Tab ×2(反向:第一下走到 0 格,第二下跨到未启动环最后一格)")
post(shift, down: true, flags: [.maskCommand, .maskShift]); wait(20)
tap(tab, flags: [.maskCommand, .maskShift]); wait(260)
tap(tab, flags: [.maskCommand, .maskShift]); wait(20)
post(shift, down: false, flags: [.maskCommand]); wait(360)

print("  Tab(正向:应当从未启动环跨回主环第一格)")
tap(tab, flags: [.maskCommand]); wait(350)

print("  Esc 放弃 + 松开 ⌘")
tap(esc, flags: [.maskCommand]); wait(80)
post(cmd, down: false, flags: [])
print("  完成")
