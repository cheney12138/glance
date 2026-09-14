// 原生 symbolic hotkey(⌘Tab / ⌘⇧Tab / ⌘`)的开关与手动复原。
//
//   swift Tools/NativeHotkeys.swift restore     # 全部打开(= 把 ⌘Tab 还给系统,治"⌘Tab 死了")
//   swift Tools/NativeHotkeys.swift disable     # 关掉 ⌘Tab 那一对(手动复现"接管后"的状态)
//
// 为什么需要这个工具:App 关掉的是**系统级**热键,效果**跨进程退出持久化**。App 被 SIGKILL
// (或任何没能走到兜底恢复的路径)带走的场合,⌘Tab 会一直死着 —— 这条命令是最后的手动保险。
// 状态没有 getter(私有 API 只给了 setter),所以"现在开没开"只能实测:
//   按住 ⌘Tab 若干秒,看有没有「程序坞 / layer=20 / 全屏」的窗口冒出来 ——
//   有 = 原生切换器在(热键是开的);没有 = 被关着。Tools/CaptureWindow.swift list 就能看到。

import Foundation
import CoreGraphics

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
@discardableResult
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

/// 编号口径与 App 内 `NativeSwitcherHotkeys.Key` 一致(AltTab 同款)
private let commandTab: Int32 = 1
private let commandShiftTab: Int32 = 2
private let commandKeyAboveTab: Int32 = 6

private let all: [(String, Int32)] = [
    ("⌘Tab", commandTab), ("⌘⇧Tab", commandShiftTab), ("⌘`", commandKeyAboveTab),
]

private func set(_ enabled: Bool, _ keys: [(String, Int32)]) {
    for (name, id) in keys {
        let error = CGSSetSymbolicHotKeyEnabled(id, enabled)
        print("\(enabled ? "开" : "关") \(name)(id=\(id)) → \(error == .success ? "ok" : "错误 \(error.rawValue)")")
    }
}

switch CommandLine.arguments.dropFirst().first {
case "restore", "on":
    set(true, all)
    print("已全部归还原生热键。实测:按住 ⌘Tab,应能看到「程序坞」的全屏窗口")
case "disable", "off":
    // 只关我们接管的那一对(配对规则:关 ⌘Tab 必须连 ⌘⇧Tab 一起)
    set(false, [("⌘Tab", commandTab), ("⌘⇧Tab", commandShiftTab)])
    print("已关掉 ⌘Tab 那一对。实测:按住 ⌘Tab,应什么都不发生")
default:
    print("""
    用法:swift Tools/NativeHotkeys.swift <restore|disable>
      restore  全部打开(把 ⌘Tab 还给系统)—— App 被强杀后 ⌘Tab 死掉时的手动保险
      disable  关掉 ⌘Tab + ⌘⇧Tab(手动复现"接管后"的状态,用于 A/B 验证)
    """)
}
