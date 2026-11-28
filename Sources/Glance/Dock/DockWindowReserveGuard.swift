import AppKit
import ApplicationServices
import GlanceCore

// ─────────────────────────────────────────────────────────────────────────────
// `_AXUIElementGetWindow`(未公开符号):AX 元素 → CGWindowID。
// 与 `Inventory/AXWindowList.swift` 同一份声明(同在 `Focus/WindowFocuser.swift` 之外)。
// 这里只用来给「防打架冷却表」做窗口身份键 —— 拿不到时 `CFHash` 兜底,功能不受影响 ✓
// ─────────────────────────────────────────────────────────────────────────────
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AXObserver 回调(C 函数指针)。AXObserver 的 source 只挂在**主 run loop** 上,
/// 所以回调必定在主线程 —— self 通过 `Unmanaged` 的 refcon 取回(observer 的生命周期完全
/// 由本类的 `update`/`disable`/`deinit` 控制,`takeUnretainedValue` 不会悬垂)✓
private func dockWindowReserveAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon, Thread.isMainThread else { return }
    let guardObject = Unmanaged<DockWindowReserveGuard>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        guardObject.handleAXEvent()
    }
}

/// 单屏常驻模式下的**事件驱动窗口边界避让**(ADR-0018 方案 A / 方案 1A)。
///
/// 要解决的问题:常驻条带停在屏边,用户把窗口「铺满 / Zoom / 双击标题栏 / 左右分屏」时,
/// 窗口会伸进条带那一条带子底下 —— 底边一截被啃掉 ✗。
///
/// 处方(三条纪律):
///   1. **只对当前常驻的那一块屏**动手(`target.displayID`),别的屏一概不碰 ✓
///   2. **零轮询**:同一时刻最多只挂 1 个 AXObserver(当前前台、非自身 App),
///      监听 4 个窗口通知 + 1 个 App 激活通知 ⇒ 空闲 0 唤醒 ✓
///   3. **误伤比漏判贵**:全屏免疫三重、非标准窗跳过、拖拽期间绝不抢窗、
///      同一扇窗反复抗拒 resize 时进冷却不再拉扯 ✓
///
/// 几何判定全部落在 `GlanceCore.DockAlwaysOnPolicy`(纯函数、可单测),
/// 这里只负责 AX 读写与事件接线 ✓
@MainActor
final class DockWindowReserveGuard {

    /// 常驻条带在屏上的**占位描述**(值语义:相等即无需重装 observer)✓
    struct Target: Equatable {
        let displayID: CGDirectDisplayID
        /// 整块屏的 Quartz frame(原点在主屏左上,Y 向下)
        let screenFrameQuartz: CGRect
        /// 可见区(避开菜单栏与原生 Dock)的 Quartz frame
        let visibleFrameQuartz: CGRect
        let position: DockPosition
        /// 条带占住的厚度(含 4pt 余量)
        let reservedThickness: CGFloat
    }

    /// 万一发现某屏其实处于全屏(而我们没来得及收条带)⇒ 通知 DockController 立即重评。
    var onFullscreenDetected: (() -> Void)?

    /// 每个窗口「最近一次我们尝试修正」的记录 —— 防打架的核心。
    private struct CooldownRecord {
        let sourceFrame: CGRect
        let targetFrame: CGRect
        let appliedAt: CFAbsoluteTime
        /// 同一目标的连续尝试次数（App 不认时用来自行降频，见 `enforceFrontmostWindowIfNeeded`）
        var attempts: Int
    }

    // MARK: 常量

    /// 事件合并窗口:80ms 内的连续 AX 通知只跑一次判定(拖动/缩放时通知是连发的)✓
    private static let debounceInterval: Double = 0.08
    /// 同一扇窗在这么近的时间内又「弹回原样」⇒ 它抗拒 resize,放弃 ✗
    private static let refusedRepeatWindow: CFAbsoluteTime = 0.8
    /// 同一扇窗在这么近的时间内已经到了目标位置 ⇒ 我们自己写出来，不用再看 ✓
    private static let settledWindow: CFAbsoluteTime = 0.4
    /// 同一个目标在这么近的时间内重复不成立 ⇒ 这扇窗不认，别再拉扯
    private static let repeatAttemptWindow: CFAbsoluteTime = 1.5
    /// 冷却记录保留时长(超过就该被清掉,表不会无限长)
    private static let cooldownLifetime: CFAbsoluteTime = 5
    /// 几何比较容差(AX 取整带来的 1pt 级差异不算变化)
    private static let frameTolerance: CGFloat = 2
    /// 写属性的 AX 消息超时 —— 抓一个卡死的 App 不能把主线程拖住 ✗（0.12s 足够正常 App 响应，且把最坏串行读耗时压在一半以内）
    private static let axMessagingTimeout: Float = 0.12
    /// AXObserver 要监听的 4 个窗口通知 ✓
    private static let notifications: [CFString] = [
        kAXWindowResizedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString,
    ]

    // MARK: 状态

    private var target: Target?
    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var debounceWork: DispatchWorkItem?
    private var mouseUpMonitor: Any?
    /// 窗口身份键 → 冷却记录(键 = `w<CGWindowID>`,兜底 `h<pid>-<CFHash>`)
    private var cooldowns: [String: CooldownRecord] = [:]

    // MARK: - 生命周期(由 DockController 驱动)

    /// 装/拆:传 `nil` 立即全拆(零副作用、不留空边);同一 target 重复传直接返回 ✓
    func update(target newTarget: Target?) {
        guard let newTarget else {
            disable()
            return
        }
        if target == newTarget { return }
        target = newTarget
        installWorkspaceObserverIfNeeded()
        attachObserverForFrontmostApp()
        // 开局先看一眼当前前台那一扇窗(此刻可能就已经铺满了)✓
        scheduleEnforce(delay: Self.debounceInterval)
    }

    /// 完整卸载:AXObserver / workspace observer / 一次性 mouseUp 监听 / 防抖任务 / 冷却表 ✓
    func disable() {
        debounceWork?.cancel()
        debounceWork = nil
        detachAXObserver()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        removeMouseUpMonitor()
        cooldowns.removeAll()
        target = nil
    }

    deinit {
        // 显式清理:主 run loop 持有 source 本身,不摘就一直躺在 RunLoop 上 ✗
        if let debounceWork { debounceWork.cancel() }
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }

    // MARK: - 事件接线

    /// 前台 App 变了:换那个 App 的 AXObserver(同一时刻系统里最多只挂 1 个)✓
    private func installWorkspaceObserverIfNeeded() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self.handleFrontmostAppChanged()
            }
        }
    }

    private func handleFrontmostAppChanged() {
        guard target != nil else { return }
        attachObserverForFrontmostApp()
        scheduleEnforce(delay: Self.debounceInterval)
    }

    /// AX 通知进门(主线程):合并到一次 80ms 防抖 ✓
    fileprivate func handleAXEvent() {
        scheduleEnforce(delay: Self.debounceInterval)
    }

    private func scheduleEnforce(delay: Double) {
        guard target != nil else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceWork = nil
            self.enforceFrontmostWindowIfNeeded()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - AXObserver 装配

    @discardableResult
    private func attachObserverForFrontmostApp() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            detachAXObserver()
            return nil
        }
        attachAXObserver(for: front.processIdentifier)
        return front.processIdentifier
    }

    private func attachAXObserver(for pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            detachAXObserver()
            return
        }
        if observedPID == pid, axObserver != nil { return }
        detachAXObserver()

        var observer: AXObserver?
        guard AXObserverCreate(pid, dockWindowReserveAXCallback, &observer) == .success,
              let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axMessagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, app, name, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        observedPID = pid
    }

    private func detachAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        observedPID = nil
    }

    // MARK: - 拖拽保护

    /// 用户正按着鼠标(拖动/缩放窗口)⇒ 绝不中途抢窗,等他松手 ✓
    private func installMouseUpMonitorIfNeeded() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                // 延迟一拍摘除自身监听，避免在监视器回调栈内直接 removeMonitor
                DispatchQueue.main.async { [weak self] in
                    self?.removeMouseUpMonitor()
                }
                self.scheduleEnforce(delay: Self.debounceInterval)
            }
        }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    // MARK: - 判定与写入

    private func enforceFrontmostWindowIfNeeded() {
        guard let target else { return }
        guard AXIsProcessTrusted() else { return }

        if NSEvent.pressedMouseButtons != 0 {
            installMouseUpMonitorIfNeeded()
            return
        }

        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard let screen = Self.screen(for: target.displayID) else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axMessagingTimeout)
        guard let window = focusedWindow(ofApp: app) else { return }

        // 只处理标准窗:弹窗 / sheet / 面板 / 无标准标题栏的浮层一律跳过 ✓
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String,
              subrole == kAXStandardWindowSubrole else { return }

        // 全屏免疫 ①:这扇窗自己声明是全屏窗
        if boolAttribute(window, "AXFullScreen") == true {
            onFullscreenDetected?()
            return
        }
        // 全屏免疫 ②:这块屏当前被某个全屏窗占着(Space 级)⇒ 该整条让位
        if DockFullscreenProbe.isScreenInFullscreen(screen) {
            onFullscreenDetected?()
            return
        }

        guard let windowFrame = readFrame(window) else { return }

        // 全屏免疫 ③ + 铺满判定:纯函数在核里,返回 nil = 不动,0 AX 写 ✓
        guard let desiredFrame = DockAlwaysOnPolicy.clampedFrameIfNeeded(
            windowFrame: windowFrame,
            screenFrame: target.screenFrameQuartz,
            visibleFrame: target.visibleFrameQuartz,
            position: target.position,
            reservedThickness: target.reservedThickness
        ) else { return }

        // 防打架:同一扇窗反复弹回原样 ⇒ 它抗拒 resize(或有硬最小尺寸)⇒ 放弃 ✗
        let key = windowKey(window, pid: pid)
        let now = CFAbsoluteTimeGetCurrent()
        pruneCooldowns(now: now)
        var attempts = 1
        if let record = cooldowns[key] {
            let elapsed = now - record.appliedAt
            if elapsed <= Self.refusedRepeatWindow,
               nearlyEqual(windowFrame, record.sourceFrame) {
                if isTraceEnabled {
                    glog("[Dock避让] 跳过:\(front.localizedName ?? "?") 抗拒 resize,不反复拉扯")
                }
                return
            }
            if elapsed <= Self.settledWindow,
               nearlyEqual(windowFrame, record.targetFrame) {
                return
            }
            // 同一个目标已经连续 2 次不认（Electron 网格重排 / 硬约束）：
            // 无条件停手并把 appliedAt 刷新为 now（让 5s 生命期从最后一次拒绝起算 ⇒
            // 一直在弹就一直不碰；静下来 5s 后自然过期恢复）✓
            let sameTarget = nearlyEqual(desiredFrame, record.targetFrame)
            if sameTarget, record.attempts >= 2 {
                cooldowns[key] = CooldownRecord(
                    sourceFrame: record.sourceFrame,
                    targetFrame: record.targetFrame,
                    appliedAt: now,
                    attempts: record.attempts
                )
                if isTraceEnabled {
                    glog("[Dock避让] 跳过:\(front.localizedName ?? "?") 连续两次不认目标位置,冷却续期")
                }
                return
            }
            attempts = (sameTarget && elapsed <= Self.repeatAttemptWindow) ? record.attempts + 1 : 1
        }

        cooldowns[key] = CooldownRecord(
            sourceFrame: windowFrame,
            targetFrame: desiredFrame,
            appliedAt: now,
            attempts: attempts
        )
        apply(
            window: window,
            from: windowFrame,
            to: desiredFrame,
            ownerName: front.localizedName ?? "?"
        )
    }

    /// 干净单次写入:**位置 → 尺寸 → 再钉一次位置**(尺寸变化会把窗口拉回,尤其 `.left` 那侧)✓
    private func apply(window: AXUIElement, from current: CGRect, to desired: CGRect, ownerName: String) {
        AXUIElementSetMessagingTimeout(window, Self.axMessagingTimeout)
        let originChanged = abs(current.minX - desired.minX) > 1 || abs(current.minY - desired.minY) > 1
        let sizeChanged = abs(current.width - desired.width) > 1 || abs(current.height - desired.height) > 1

        var wrote: [String] = []
        if originChanged, setPosition(window, desired.origin) {
            wrote.append("位置")
        }
        if sizeChanged, setSize(window, desired.size) {
            wrote.append("尺寸")
        }
        if originChanged {
            // 补写一次位置:resize 之后系统/App 会按自己的锚点重排位置,不补就白改 ✓
            _ = setPosition(window, desired.origin)
        }

        if isTraceEnabled {
            glog("[Dock避让] \(ownerName) 窗口 "
                 + "(\(Int(current.minX)),\(Int(current.minY)) \(Int(current.width))x\(Int(current.height)))"
                 + " ⇒ (\(Int(desired.minX)),\(Int(desired.minY)) \(Int(desired.width))x\(Int(desired.height)))"
                 + " 写入=\(wrote.isEmpty ? "无" : wrote.joined(separator: "+"))")
        }
    }

    // MARK: - AX 读写小工具

    private func focusedWindow(ofApp app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func readFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private func setPosition(_ element: AXUIElement, _ origin: CGPoint) -> Bool {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: - 小型几何/身份工具

    /// 窗口身份键:优先 CGWindowID(最便宜),取不到再退到 `CFHash` ✓
    private func windowKey(_ window: AXUIElement, pid: pid_t) -> String {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
            return "w\(wid)"
        }
        return "h\(pid)-\(CFHash(window))"
    }

    /// 四边差都在容差内 = 两个 frame 实际上是同一个 ✓
    private func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= Self.frameTolerance
            && abs(a.minY - b.minY) <= Self.frameTolerance
            && abs(a.width - b.width) <= Self.frameTolerance
            && abs(a.height - b.height) <= Self.frameTolerance
    }

    private func pruneCooldowns(now: CFAbsoluteTime) {
        guard !cooldowns.isEmpty else { return }
        cooldowns = cooldowns.filter { now - $0.value.appliedAt <= Self.cooldownLifetime }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
