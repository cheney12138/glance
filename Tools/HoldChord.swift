// 按住触发键若干秒(观察用)。
//
//   swift Tools/HoldChord.swift [秒数=3] [--key tab] [--mod cmd]
//
// 和 `InjectChord.swift` 分工:那个是"快速连按"(测响应/丢键),这个是"按住不放" ——
// 有些东西只在按住期间存在,比如:
//   · 系统原生切换器(按住 ⌘Tab 才出现;用 `Tools/CaptureWindow.swift list` 能看到
//     `程序坞 / layer=20 / 全屏` 那个窗口 —— 这就是"⌘Tab 现在归谁"的实测口径,见 docs/debugging.md 第 7 节);
//   · 我们自己的面板与预览托盘(Glance layer=101/100)。
//
// 收尾用 **Esc**(而不是松修饰键):Esc = 放弃,不会聚焦/切走任何窗口。
// 前置:发起进程要有辅助功能权限;没权限时 `post` 静默失效。

import AppKit
import CoreGraphics

private let keyCodes: [String: CGKeyCode] = [
    "tab": 0x30, "space": 0x31, "grave": 0x32, "q": 0x0C, "w": 0x0D,
]
private let modifiers: [String: (CGKeyCode, CGEventFlags, String)] = [
    "cmd": (0x37, .maskCommand, "⌘"),
    "opt": (0x3A, .maskAlternate, "⌥"),
    "ctrl": (0x3B, .maskControl, "⌃"),
]

private var seconds = 3.0
private var keyName = "tab"
private var keyCode: CGKeyCode = 0x30
private var mod = modifiers["cmd"]!

private func parseArgs() {
    var rest = Array(CommandLine.arguments.dropFirst())
    var positional: [String] = []
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--key", "-k":
            guard let value = rest.first?.lowercased() else { exit(2) }
            rest.removeFirst()
            guard let code = keyCodes[value] else {
                print("不认识的键:\(value)(可用:\(keyCodes.keys.sorted().joined(separator: "/")))")
                exit(2)
            }
            keyName = value
            keyCode = code
        case "--mod", "-m":
            guard let value = rest.first?.lowercased(), let found = modifiers[value] else {
                print("--mod 只认 cmd/opt/ctrl")
                exit(2)
            }
            rest.removeFirst()
            mod = found
        default:
            positional.append(arg)
        }
    }
    if let first = positional.first, let value = Double(first) { seconds = value }
    if seconds <= 0 { print("秒数要 > 0"); exit(2) }
}

private let source = CGEventSource(stateID: .hidSystemState)

private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, asFlagsChanged: Bool = false) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
        print("CGEvent 建不出来(多半是缺辅助功能权限)")
        exit(1)
    }
    if asFlagsChanged { event.type = .flagsChanged }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

parseArgs()
print("按住 \(mod.2)\(keyName) \(seconds)s —— 期间用 `Tools/CaptureWindow.swift list` 抓窗口清单")

post(mod.0, down: true, flags: mod.1, asFlagsChanged: true) // 修饰键按下
usleep(120_000)
post(keyCode, down: true, flags: mod.1)                     // 主键按下(保持不松)
print("  ↓ 按住中…")
usleep(UInt32(seconds * 1_000_000))
print("  ↑ 松开(Esc 放弃,不切走窗口)")
post(0x35, down: true, flags: mod.1)                        // Esc = 放弃
post(0x35, down: false, flags: mod.1)
usleep(50_000)
post(keyCode, down: false, flags: mod.1)
post(mod.0, down: false, flags: [], asFlagsChanged: true)
print("完成")
