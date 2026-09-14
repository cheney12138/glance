// 连按触发键的注入器(调试输入管线用)。
//
//   swift Tools/InjectChord.swift [轮数=10] [间隔ms=300] [--key tab] [--mod cmd]
//
// 为什么能"远程操控":事件注在 **HID 层**(.cghidEventTap),比所有事件 tap 都靠下,
// 对我们自己的 tap 来说与真键盘完全同构 —— 这正是本工具能复现"用户连按"的原因。
//
// 两条安全设计:
// 1. 每一轮用 **Esc 收尾**(而不是松修饰键):Esc = 放弃,不聚焦任何窗,测完不会偷偷切走你的前台窗口;
// 2. 开跑前先数一遍 Glance 实例:**不止一个实例时会抢同一组 ⌘Tab**(先装 tap 的那个吞掉),
//    这是排查这类问题最常见的假象来源,所以直接红灯提示。
//
// 前置:发起进程要有辅助功能权限(终端/pi 通常已有)。没权限时 `post` 静默失效,什么都不发生。

import AppKit
import CoreGraphics

// MARK: - 参数

private let keyCodes: [String: CGKeyCode] = [
    "tab": 0x30, "space": 0x31, "return": 0x24, "grave": 0x32,
    "q": 0x0C, "w": 0x0D, "e": 0x0E, "a": 0x00, "s": 0x01, "d": 0x02,
]

private struct Modifier {
    let name: String
    let keyCode: CGKeyCode
    let flag: CGEventFlags
}

private let modifiers: [String: Modifier] = [
    "cmd": Modifier(name: "⌘", keyCode: 0x37, flag: .maskCommand),
    "opt": Modifier(name: "⌥", keyCode: 0x3A, flag: .maskAlternate),
    "ctrl": Modifier(name: "⌃", keyCode: 0x3B, flag: .maskControl),
]

private var rounds = 10
private var gapMs = 300
private var triggerKey: CGKeyCode = 0x30
private var triggerName = "tab"
private var modifier = modifiers["cmd"]!

private func parseArgs() {
    var positional: [String] = []
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--key", "-k":
            guard let value = rest.first else { fail("--key 缺参数") }
            rest.removeFirst()
            if let code = keyCodes[value.lowercased()] {
                triggerKey = code
                triggerName = value.lowercased()
            } else if let code = UInt16(value) {
                triggerKey = CGKeyCode(code)
                triggerName = "键\(code)"
            } else {
                fail("不认识的键:\(value)(可用:\(keyCodes.keys.sorted().joined(separator: "/")) 或数字 keyCode)")
            }
        case "--mod", "-m":
            guard let value = rest.first, let mod = modifiers[value.lowercased()] else {
                fail("--mod 只认 cmd/opt/ctrl")
            }
            rest.removeFirst()
            modifier = mod
        default:
            positional.append(arg)
        }
    }
    if positional.count > 0 { rounds = Int(positional[0]) ?? rounds }
    if positional.count > 1 { gapMs = Int(positional[1]) ?? gapMs }
    // `1...0` 在 Swift 里是直接崩的区间(实测:传 0 轮时静默死掉)—— 入口就把值收住
    if rounds < 1 { fail("轮数要 ≥ 1(收到 \(rounds))") }
    if gapMs < 0 { fail("间隔不能是负数") }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("错误:\(message)\n").data(using: .utf8)!)
    exit(2)
}

// MARK: - 实例体检(多实例抢 ⌘Tab 是这类排查的头号假象)

private func glanceInstances() -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-fl", "mac-switcher.app/Contents/MacOS/mac-switcher"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

private func reportInstances() {
    let running = glanceInstances()
    print("Glance 实例:\(running.count) 个")
    for line in running {
        let launchedByXcode = line.contains("NSDocumentRevisionsDebugMode") ? "  ← Xcode(调试器下 SIGTERM 杀不掉,要 -9)"
            : "  ← 终端/直接启动"
        print("  \(line)\(launchedByXcode)")
    }
    if running.count != 1 {
        print("⚠️  实例数不是 1:多个实例会抢同一组 \(modifier.name)\(triggerName.uppercased()),先只留一个再测(症状:时好时坏、像掉回系统切换器)")
    }
    if running.isEmpty {
        print("⚠️  Glance 没在跑:这一组和弦会直接落到系统手里(macOS 原生切换器会登场)")
    }
}

// MARK: - 注入

private let source = CGEventSource(stateID: .hidSystemState)

private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, asFlagsChanged: Bool = false) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
        fail("CGEvent 建不出来(多半是缺辅助功能权限)")
    }
    // 纯修饰键没有 keyDown/keyUp,只有 flagsChanged:建个事件再把 type 改过去,这是标准做法
    if asFlagsChanged { event.type = .flagsChanged }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private func ms(_ value: Int) { usleep(UInt32(max(value, 0)) * 1000) }

// MARK: - 主流程

parseArgs()
print("连按 \(rounds) 轮:\(modifier.name)\(triggerName) — 间隔 \(gapMs)ms,每轮用 Esc 收尾(不聚焦任何窗)")
reportInstances()
print("1.5 秒后开始,期间别碰键盘…")
ms(1500)

for round in 1...rounds {
    post(modifier.keyCode, down: true, flags: modifier.flag, asFlagsChanged: true) // 修饰键按下(待命)
    ms(20)
    post(triggerKey, down: true, flags: modifier.flag)                            // 主键:首次 = 面板出现
    ms(10)
    post(triggerKey, down: false, flags: modifier.flag)
    ms(10)
    post(0x35, down: true, flags: modifier.flag)                                  // Esc = 放弃
    post(0x35, down: false, flags: modifier.flag)
    ms(5)
    post(modifier.keyCode, down: false, flags: [], asFlagsChanged: true)          // 修饰键抬起(已 idle,不会确认)
    if rounds <= 10 || round % 5 == 0 { print("  …第 \(round)/\(rounds) 轮") }
    ms(gapMs)
}
print("完成。若想核对每颗事件的处置:用 GLANCE_TRACE=1 从终端起 Glance,再看它的事件流水账(见 docs/debugging.md)")
