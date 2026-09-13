import CoreGraphics
import AppKit

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
    }

    private(set) var state: State = .idle
    /// T6 起由面板控制器赋值;T3 阶段默认为打印。
    var onAction: ((Action) -> Void)?
    /// T7.5:⌘+左键点击(Quartz 全局坐标)。导航态里挂起(Q9-④)
    var onCmdClick: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var runloopSource: CFRunLoopSource?

    private static let keyTab: Int64 = 0x30
    private static let keyLeft: Int64 = 0x7B
    private static let keyRight: Int64 = 0x7C
    private static let keyEsc: Int64 = 0x35
    private static let optionKeys: Set<Int64> = [0x3A, 0x3D] // 左右 ⌥
    private static let navKeys: Set<Int64> = [keyTab, keyLeft, keyRight, keyEsc]

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

        // ⌘+左键:补焦耳朵。导航态里挂起;事件本身永远放行,补不补焦由回调决定
        if event.type == .leftMouseDown {
            if event.flags.contains(.maskCommand), state != .navigating {
                onCmdClick?(event.location)
            }
            return false
        }

        // ⌥ 的按下/释放只看 flagsChanged:纯修饰键没有 keyDown
        if event.type == .flagsChanged, Self.optionKeys.contains(keyCode) {
            let optionDown = event.flags.contains(.maskAlternate)
            switch (state, optionDown) {
            case (.idle, true):
                state = .armed // 裸按 ⌥ 只待命,什么都不发生
            case (.armed, false):
                state = .idle  // 待命期放手:恢复原状
            case (.navigating, false):
                state = .idle
                emit(.confirm)
            default:
                break
            }
            return false
        }

        // 非导航期:Tab 可以开导航(armed→navigating),其他键一概放行
        if state == .armed, event.type == .keyDown, keyCode == Self.keyTab {
            state = .navigating
            emit(.begin)                                     // 面板出现
            emit(event.flags.contains(.maskShift) ? .prev : .next) // 原生语义:首个和弦即落在"上一个"位
            return true
        }

        guard state == .navigating else { return false }

        // 导航期:四个导航键的 down+up 全吞(keyUp 不吞会把半个键漏给前台 App)
        guard Self.navKeys.contains(keyCode) else { return false }
        guard event.type == .keyDown else { return true }

        switch keyCode {
        case Self.keyTab:
            emit(event.flags.contains(.maskShift) ? .prev : .next)
        case Self.keyLeft: emit(.windowLeft)
        case Self.keyRight: emit(.windowRight)
        case Self.keyEsc:
            state = .idle
            emit(.cancel)
        default: break
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
