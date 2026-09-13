import CoreGraphics
import AppKit

/// 触发键配置(T9 设置面板录制式改键;默认 ⌥Tab)。修饰键只允许 ⌥/⌘/⌃——
/// ⇧ 被永久征用为"反向"语义,不许当触发修饰键
struct TriggerConfig: Equatable {
    var keyCode: Int64
    var modifierMask: CGEventFlags
    var modifierKeyCodes: Set<Int64>
    var modifierSymbol: String // ⌥ ⌘ ⌃
    var keyName: String

    var display: String { modifierSymbol + keyName }

    static let `default` = TriggerConfig(
        keyCode: 0x30, modifierMask: .maskAlternate,
        modifierKeyCodes: [0x3A, 0x3D], modifierSymbol: "⌥", keyName: "Tab"
    )

    static func load() -> TriggerConfig {
        let d = UserDefaults.standard
        guard d.object(forKey: "trigger.keyCode") != nil,
              let mod = d.string(forKey: "trigger.modifier") else { return .default }
        let keyCode = Int64(d.integer(forKey: "trigger.keyCode"))
        switch mod {
        case "command":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskCommand,
                                 modifierKeyCodes: [0x37, 0x36], modifierSymbol: "⌘", keyName: keyName(of: keyCode))
        case "control":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskControl,
                                 modifierKeyCodes: [0x3B, 0x3E], modifierSymbol: "⌃", keyName: keyName(of: keyCode))
        case "option":
            return TriggerConfig(keyCode: keyCode, modifierMask: .maskAlternate,
                                 modifierKeyCodes: [0x3A, 0x3D], modifierSymbol: "⌥", keyName: keyName(of: keyCode))
        default:
            return .default
        }
    }

    /// 展示用的键名(够用即可,不追求全键盘表)
    static func keyName(of keyCode: Int64) -> String {
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


/// ⌥Tab 触发层(ADR 无关,纯输入管线)。
/// 状态机:idle ─⌥按下→ armed ─首次 Tab→ navigating ─⌥释放→(确认)idle
///                                              └─Esc→(放弃)idle
/// 裸按 ⌥ 只待命不弹面板(brand-spec 修正);navigating 期间吞 Tab/←→/Esc 的 down+up,
/// 防止"半个键"漏给前台 App。
/// T3 范围:只打事件日志,不接面板;suspend()/resume() 预留给设置面板改键与二期补焦。
@MainActor
final class HotkeyTapCenter {
    enum State { case idle, armed, navigating }

    /// 导航期间的一次动作。T6 面板、T7 聚焦以后订阅这个出口,不直接碰事件层。
    enum Action {
        case begin            // 首次 ⌥+Tab:进入导航态(面板应出现)
        case next             // Tab:图标层后移
        case prev             // ⇧Tab:图标层前移
        case windowLeft       // ←:展开层左移
        case windowRight      // →:展开层右移
        case confirm          // ⌥ 释放:确认(聚焦选中窗)
        case cancel           // Esc:放弃
        case quitApp          // Q:退出选中 App(T12)
        case closeWindow      // W:关闭选中窗(T12)
        case minimizeWindow   // M:最小化选中窗(T12)
    }

    private(set) var state: State = .idle
    /// T6 起由面板控制器赋值;T3 阶段默认为打印。
    var onAction: ((Action) -> Void)?
    /// T7.5:⌘+左键点击(Quartz 全局坐标)。导航态里挂起(Q9-④)
    var onCmdClick: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var runloopSource: CFRunLoopSource?

    private static let keyLeft: Int64 = 0x7B
    private static let keyRight: Int64 = 0x7C
    private static let keyEsc: Int64 = 0x35
    private static let keyReturn: Int64 = 0x24
    private static let keyQ: Int64 = 0x0C
    private static let keyW: Int64 = 0x0D
    private static let keyM: Int64 = 0x2E
    /// 导航期被吞的固定键:方向/Esc/Enter + Q/W/M 破坏性键盘操作(CONTEXT.md)
    private static let navKeys: Set<Int64> = [keyLeft, keyRight, keyEsc, keyReturn, keyQ, keyW, keyM]

    /// 钉住开关:松 ⌥ 不关面板,状态机保持导航态,Enter 接手确认权(用户实评"还挺实用")
    private var pinPanel: Bool { UserDefaults.standard.bool(forKey: "debug.pinPanelOnRelease") }

    /// 键盘路径之外的会话终结(鼠标点卡片确认/面板外点击放弃等):面板控制器每次
    /// dismiss 必须调这个,否则钉住模式下状态机永远卡在 navigating,⌥Tab 再也唤不醒
    /// ——实机现形:鼠标确认后 switcher 永久失能
    func endSession() { state = .idle }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) // T7.5:⌘+click 补焦的耳朵
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,          // HID 层,alt-tab 同款;能拦在系统快捷键之前
            place: .headInsertEventTap,
            options: .defaultTap,         // 默认 tap 才有吞键权
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[mac-switcher] ⌥Tab tap 创建失败——辅助功能权限未就绪,触发层不工作")
            return
        }
        self.tap = tap
        runloopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runloopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[mac-switcher] ⌥Tab 触发层上线")
    }

    func suspend() { if let tap { CGEvent.tapEnable(tap: tap, enable: false) } }
    func resume() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// 事件处理入口。返回值 = 是否吞掉该事件。
    /// 注意:tap 的 runloop source 挂在主 runloop,回调就在主线程,可以安全动 @MainActor 状态。
    fileprivate func handle(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = TriggerConfig.load() // 每次事件现读:改键即时生效,不用重启

        // ⌘+左键:补焦耳朵。导航态里挂起;事件本身永远放行,补不补焦由回调决定
        if event.type == .leftMouseDown {
            if event.flags.contains(.maskCommand), state != .navigating {
                onCmdClick?(event.location)
            }
            return false
        }

        // 触发修饰键的按下/释放只看 flagsChanged:纯修饰键没有 keyDown
        if event.type == .flagsChanged, config.modifierKeyCodes.contains(keyCode) {
            let modifierDown = event.flags.contains(config.modifierMask)
            switch (state, modifierDown) {
            case (.idle, true):
                state = .armed // 裸按触发修饰键只待命,什么都不发生
            case (.armed, false):
                state = .idle  // 待命期放手:恢复原状
            case (.navigating, false):
                // 钉住:松手不确认、不退出导航态——面板与它的"脑子"一起钉住,
                // 否则面板还在台上、状态机已经下班,Tabs/Esc 全漏给前台 App(实机现形)
                if pinPanel { break }
                state = .idle
                emit(.confirm)
            default:
                break
            }
            return false
        }

        // 非导航期:触发主键开导航(armed→navigating),其他键一概放行
        if state == .armed, event.type == .keyDown, keyCode == config.keyCode {
            state = .navigating
            emit(.begin)                                     // 面板出现
            emit(event.flags.contains(.maskShift) ? .prev : .next) // 原生语义:首个和弦即落在"上一个"位
            return true
        }

        guard state == .navigating else { return false }

        // 导航期:导航键与触发主键的 down+up 全吞(keyUp 不吞会把半个键漏给前台 App)
        guard Self.navKeys.contains(keyCode) || keyCode == config.keyCode else { return false }
        guard event.type == .keyDown else { return true }

        if keyCode == config.keyCode {
            emit(event.flags.contains(.maskShift) ? .prev : .next)
        } else if keyCode == Self.keyLeft {
            emit(.windowLeft)
        } else if keyCode == Self.keyRight {
            emit(.windowRight)
        } else if keyCode == Self.keyReturn {
            state = .idle
            emit(.confirm) // 钉住模式的确认键(松手已让位给"保持打开")
        } else if keyCode == Self.keyEsc {
            state = .idle
            emit(.cancel)
        } else if keyCode == Self.keyQ {
            emit(.quitApp)
        } else if keyCode == Self.keyW {
            emit(.closeWindow)
        } else if keyCode == Self.keyM {
            emit(.minimizeWindow)
        }
        return true
    }

    private func emit(_ action: Action) {
        if let onAction { onAction(action) } else { print("[T3] \(Self.describe(action))") }
    }

    private static func describe(_ action: Action) -> String {
        switch action {
        case .begin: return "首次 ⌥+Tab → 导航开始(面板应出现)"
        case .next: return "Tab → 后移"
        case .prev: return "⇧Tab → 前移"
        case .windowLeft: return "← → 窗口左移"
        case .windowRight: return "→ → 窗口右移"
        case .confirm: return "⌥ 释放 → 确认(T7 聚焦此处)"
        case .cancel: return "Esc → 放弃(面板关闭,不聚焦)"
        case .quitApp: return "Q → 退出选中 App(T12)"
        case .closeWindow: return "W → 关闭选中窗(T12)"
        case .minimizeWindow: return "M → 最小化选中窗(T12)"
        }
    }
}

/// C 回调桥。系统停 tap(超时/输入风暴)时原地复活,alt-tab 同款自救。
private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        let center = Unmanaged<HotkeyTapCenter>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            center.revive()
            return Unmanaged.passUnretained(event)
        }
        if center.handle(event) { return nil }
        return Unmanaged.passUnretained(event)
    }
}

extension HotkeyTapCenter {
    /// tap 被系统停用时的原地复活
    fileprivate func revive() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
