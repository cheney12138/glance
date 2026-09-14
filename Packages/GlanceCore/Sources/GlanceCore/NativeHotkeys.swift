import CoreGraphics
import Carbon.HIToolbox

/// 原生切换器热键(system symbolic hotkey)的**知识 + 总开关** —— 本项目的"屏蔽 ⌘Tab"就在这里。
///
/// 为什么是私有 API 而不是拿事件 tap 吞键:见 `docs/adr/0005`(AltTab 走了多年的同一条路)。
/// **无 AppKit**:本文件只依赖 CoreGraphics/Carbon,所以能进 `GlanceCore` 被单测。
/// 恢复守卫(退出/信号/异常/启动自愈)需要 AppKit,留在 App 侧 `NativeHotkeyGuards`。
public enum NativeHotkeys {
    public enum Key: Int32, CaseIterable {
        case commandTab = 1
        /// 反向切换器。**关 ⌘⇥ 必须连它一起关**,否则原生反向那一发照旧会弹
        case commandShiftTab = 2
        /// ⌘`:系统"下一个窗口"。键位随输入法变(keyAboveTab),单列出来防误伤
        case commandKeyAboveTab = 6
    }

    // MARK: - 纯计算(确定性,不依赖任何全局状态)

    /// 触发键是否与某条系统热键重叠(要不要动系统,先看这个)
    public static func overlapsNativeHotkey(_ trigger: TriggerConfig) -> Bool {
        guard trigger.modifierMask.contains(.maskCommand) else { return false }
        return trigger.keyCode == Int64(kVK_Tab) || trigger.keyCode == Int64(kVK_ANSI_Grave)
    }

    /// 按触发键配置算出该关/该开的原生热键。
    ///
    /// **两个条件同时满足才动系统**:① 用户在设置里显式开了"接管系统切换器";② 触发键确实与系统热键重叠。
    /// 默认触发键是 ⌥Tab,两条都不满足 → 一行都不改系统。
    ///
    /// 参考实现里这个 kernel 是被一个真实 bug 逼出来的(#5653):他们原来用 `.first { }` 遍历字典挑匹配,
    /// 而 **Swift 字典迭代顺序跨进程不稳定**,一个和弦同时匹配两个谓词时会随机丢一个 → 整个会话
    /// 原生 ⌘⇥ 没被关掉。这里的口径是"收集,不要挑":每条重叠都收进来,enable 取补集。
    public static func plan(for trigger: TriggerConfig, takeover: Bool) -> (disable: [Key], enable: [Key]) {
        var disable: Set<Key> = []
        if takeover, overlapsNativeHotkey(trigger) {
            let isCommand = trigger.modifierMask.contains(.maskCommand)
            if isCommand, trigger.keyCode == Int64(kVK_Tab) {
                disable.insert(.commandTab)
                disable.insert(.commandShiftTab) // 配对规则
            }
            if isCommand, trigger.keyCode == Int64(kVK_ANSI_Grave) {
                disable.insert(.commandKeyAboveTab)
            }
        }
        let enable = Set(Key.allCases).subtracting(disable)
        return (disable.sorted { $0.rawValue < $1.rawValue }, enable.sorted { $0.rawValue < $1.rawValue })
    }

    // MARK: - 落地

    /// 应用配置:与触发键重叠的原生热键关掉,其余恢复开着(用户把触发键改回 ⌥Tab 时,⌘Tab 就该还给他)
    public static func apply(trigger: TriggerConfig, takeover: Bool) {
        let (disable, enable) = plan(for: trigger, takeover: takeover)
        for key in disable { _ = cgsSet(key, false) }
        for key in enable { _ = cgsSet(key, true) }
        print("[T13] 原生热键:关 \(disable.map(\.rawValue)) / 开 \(enable.map(\.rawValue))"
              + (disable.isEmpty ? "(未接管或触发键不重叠 —— 系统热键全部归还)" : ""))
    }

    /// 全恢复。启动自愈、退出、崩溃兜底都走它
    public static func restoreAll() {
        for key in Key.allCases { _ = cgsSet(key, true) }
    }
}

/// 私有 SkyLight 符号。取值口径见 AltTab `src/macos/api-wrappers/SkyLight.framework.swift`;
/// 定位方式(他们的注释):用 `CGSGetSymbolicHotKeyValue` 把前几百个号遍历一遍就能看到全部。
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
@discardableResult
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

private func cgsSet(_ key: NativeHotkeys.Key, _ enabled: Bool) -> CGError {
    CGSSetSymbolicHotKeyEnabled(key.rawValue, enabled)
}
