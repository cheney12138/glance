import CoreGraphics
import Foundation

/// 触发键配置(纯类型 + 纯解析,无 AppKit —— 所以它能进 `GlanceCore` 被单测)。
/// 读写口径只有一处:`UserDefaults` 的两个键 + `trigger.takeoverSystemSwitcher` 这个显式接管开关。
///
/// ⇧ 被永久征用为"反向"语义,不许当触发修饰键
public struct TriggerConfig: Equatable {
    public var keyCode: Int64
    public var modifierMask: CGEventFlags
    public var modifierKeyCodes: Set<Int64>
    public var modifierSymbol: String // ⌥ ⌘ ⌃
    public var keyName: String

    public init(keyCode: Int64, modifierMask: CGEventFlags, modifierKeyCodes: Set<Int64>,
                modifierSymbol: String, keyName: String) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
        self.modifierKeyCodes = modifierKeyCodes
        self.modifierSymbol = modifierSymbol
        self.keyName = keyName
    }

    public var display: String { modifierSymbol + keyName }

    public static let `default` = TriggerConfig(
        keyCode: 0x30, modifierMask: .maskAlternate,
        modifierKeyCodes: [0x3A, 0x3D], modifierSymbol: "⌥", keyName: "Tab"
    )

    /// "接管系统切换器(⌘Tab)"是否由用户**在设置里显式开启**。默认 false。
    ///
    /// 这是本文件里唯一有权改动系统 symbolic hotkey 的开关(见 `NativeSwitcherHotkeys.plan`):
    /// 默认触发键是 ⌥Tab,一行系统设置都不碰。旧版本把"接管"记在触发键上(键 = ⌘Tab 就算接管),
    /// 那条口径已废 —— 见 `HotkeyTapCenter.normalizeLegacyTakeoverState`。
    public static var takeoverEnabled: Bool { takeoverEnabled(in: .standard) }
    public static func takeoverEnabled(in d: UserDefaults) -> Bool {
        d.bool(forKey: "trigger.takeoverSystemSwitcher")
    }

    public static func setTakeover(_ on: Bool) { setTakeover(on, in: .standard) }
    public static func setTakeover(_ on: Bool, in d: UserDefaults) {
        d.set(on, forKey: "trigger.takeoverSystemSwitcher")
    }

    /// **No globals**(参考实现 AltTab #5653 的教训:kernel 不许读全局状态,依赖一律显式传入 ——
    /// 否则它就没法被单测,而单测正是这类"读配置拼值"的逻辑唯一能钉住的地方)。
    public static func load() -> TriggerConfig { load(from: .standard) }

    public static func load(from d: UserDefaults) -> TriggerConfig {
        guard d.object(forKey: "trigger.keyCode") != nil,
              let mod = d.string(forKey: "trigger.modifier") else { return .default }
        return make(keyCode: Int64(d.integer(forKey: "trigger.keyCode")), modifier: mod) ?? .default
    }

    /// **跨屏送窗**的快捷键（脱面板的全局动作 ✓，ADR-0016）。
    /// 默认 **⌘⇧M**（用户 2026-09-22 口径:「快捷键用 cmd + shift默认」）——
    /// 出厂默认值就写在这里一处 ✓（`Keys` 只管键名，不抄默认值 ✗）
    public static func loadMoveWindow(from d: UserDefaults = .standard) -> TriggerConfig {
        guard d.object(forKey: "moveWindow.keyCode") != nil,
              let mod = d.string(forKey: "moveWindow.modifier") else { return moveWindowDefault }
        return make(keyCode: Int64(d.integer(forKey: "moveWindow.keyCode")), modifier: mod) ?? moveWindowDefault
    }

    public static let moveWindowDefault = TriggerConfig(
        keyCode: 0x2E, modifierMask: [.maskCommand, .maskShift],       // M = "move" ✓
        modifierKeyCodes: [0x37, 0x36, 0x38, 0x3C], modifierSymbol: "⌘⇧", keyName: "M"
    )

    /// 键 + 修饰键名 ⇒ 配置（**唯一一处**解析修饰键名 ✓；送窗与触发键共用 ✓）
    public static func make(keyCode: Int64, modifier: String) -> TriggerConfig? {
        switch modifier {
        case "command":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskCommand,
                                 modifierKeyCodes: [0x37, 0x36], modifierSymbol: "⌘", keyName: keyName(of: keyCode))
        case "control":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskControl,
                                 modifierKeyCodes: [0x3B, 0x3E], modifierSymbol: "⌃", keyName: keyName(of: keyCode))
        case "option":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskAlternate,
                                 modifierKeyCodes: [0x3A, 0x3D], modifierSymbol: "⌥", keyName: keyName(of: keyCode))
        case "commandShift":
            return TriggerConfig(keyCode: keyCode, modifierMask: [.maskCommand, .maskShift],
                                 modifierKeyCodes: [0x37, 0x36, 0x38, 0x3C],
                                 modifierSymbol: "⌘⇧", keyName: keyName(of: keyCode))
        default:
            return nil
        }
    }

    /// 展示用的键名(够用即可,不追求全键盘表)
    public static func keyName(of keyCode: Int64) -> String {
        switch keyCode {
        case 0x30: return "Tab"
        case 0x31: return "Space"
        case 0x24: return "↩"
        default:
            if let name = [
                0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
                0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
                0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
                0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
                0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
                0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
                0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
                0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
            ][Int(keyCode)] { return name }
            return "键\(keyCode)"
        }
    }
}
