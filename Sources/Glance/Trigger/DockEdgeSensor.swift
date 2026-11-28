import AppKit
import CoreGraphics
import Foundation
import GlanceCore

/// Dock 替代功能的屏幕外边缘指针传感器（见 ADR-0018）。
///
/// 设计要点：
/// - 严禁建立阻塞边缘点击的透明窗口；全程使用只读 `mouseMoved` 全局/本地监听（本地监听原样返回事件），
///   配合 `GlanceCore.DockEdgeGeometry.sensorStrips` 缓存做 `CGRect.contains` 判定，零点击阻塞且兼容全屏 Space；
/// - 边缘驻留（dwell）与离区宽限（leave grace）状态迁移全权交给 `GlanceCore.DockTriggerMachine`；
/// - 处于打开态时启用轻量 50ms 轮询 `Timer`，结合 `isPointerInsideDockSurface` 驱动自动收起；
/// - 通过闭包与上层 UI 解耦，不引用任何面板或窗口实现类型。
@MainActor
final class DockEdgeSensor {
    var onEdgePrewarm: ((CGDirectDisplayID) -> Void)?
    var onOpenDock: ((CGDirectDisplayID) -> Void)?
    var onCloseDock: (() -> Void)?
    var isSuppressed: (() -> Bool)?
    var isPointerInsideDockSurface: ((CGPoint) -> Bool)?

    /// 常驻程序坞**已经占住**的那块屏:这块屏不再响应边缘贴边唤起(避免重复触发),
    /// 但**其他屏照常监听** —— 鼠标在别的屏贴边驻留 ⇒ `onOpenDock` 把常驻条带平滑换到那块屏 ✓
    ///
    /// 由上层按「常驻条带当前在哪块屏」实时同步;条带因**全屏 Space 避让**而隐藏时,
    /// 上层把它置 `nil` ⇒ 这块屏立刻恢复贴边唤起能力(见 ADR-0018 常驻模式)。
    /// 语义是**豁免**而不是 suppress:离区/收起/轮询一律不受影响,只有"贴边开始 dwell"这一条被跳过 ✓
    ///
    /// ⚠️ 它还决定**跨屏停边时长**(见 `effectiveDwellDuration`):值一变,在途 dwell 的计时口径
    /// 就跟着变 ⇒ 必须在 `didSet` 里重新上钟,否则会沿用旧的 0.1s 计时器把条带**误触发换屏** ✗
    var ignoredDisplayID: CGDirectDisplayID? {
        didSet {
            guard oldValue != ignoredDisplayID else { return }
            resyncDwellTimerForRegimeChange()
        }
    }

    private static let openPollInterval: TimeInterval = 0.05

    /// 贴边**那一刻**就预热目标屏的上限时长:短 dwell(自动隐藏档 50–280ms)才立刻预热;
    /// 跨屏停边(3.0s)超过它 ⇒ 延后到「到点前 0.5s」再预热(路过零开销,真停满时已热)✓
    private static let prewarmDwellCeiling: Double = 0.5
    /// 长 dwell 提前预热窗口（3.0s 跨屏停边在 2.5s 时开始预热）
    private static let longDwellPrewarmLeadTime: Double = 0.5

    /// 本屏贴边唤起时真正该等的时长(见 `GlanceCore.DockAlwaysOnPolicy.effectiveEdgeDwellDuration`)。
    ///
    /// · 常驻条带**占着别的屏**(`ignoredDisplayID != nil`)⇒ 跨屏切过去要连续停边 **3.0s**:
    ///   多屏用户把指针划过另一块屏的下缘是家常便饭,短 dwell 会让条带乱弹 ✗
    /// · 其余情形(自动隐藏 / 常驻条带因全屏避让而隐藏)⇒ 用户配置的 `Keys.dockDwellSeconds`(50–280ms)✓
    private var effectiveDwellDuration: Double {
        DockAlwaysOnPolicy.effectiveEdgeDwellDuration(
            isAlwaysOnHostedOnAnotherDisplay: ignoredDisplayID != nil,
            autoHideDwellSeconds: Keys.dockDwellSeconds
        )
    }

    private var position: DockPosition = Keys.currentDockPosition
    private var machine = DockTriggerMachine(dwellDuration: Keys.dockDwellSeconds)
    private var cachedStrips: [DockSensorStrip] = []

    private var isRunning = false
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var dwellTimer: Timer?
    private var prewarmTimer: Timer?
    private var openPollTimer: Timer?

    // MARK: - 生命周期与外部同步

    func start() {
        guard !isRunning else { return }
        isRunning = true

        position = Keys.currentDockPosition
        machine = DockTriggerMachine(dwellDuration: effectiveDwellDuration)
        rebuildStrips()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { name in
            wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreenParametersChanged()
                }
            }
        }

        // 两个 `mouseMoved` 监听都是 **120Hz** 的量级:每帧一个 `Task {}` 会在主队列上排队,
        // 攒到几十个再一起跑,贴边判定的时机会飘。这两处回调实测**由主 run loop 派发**(与
        // `HotkeyTap` 的 Carbon tap 不同,它们本来就在主线程)⇒ 主线程直调 `assumeIsolated`,
        // 省掉 Task 排队;万一将来被挪到别的线程,退回 Task 而不是崩(不用 assumeIsolated 硬断言)。
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.handleMouseMoved() }
            } else {
                Task { @MainActor [weak self] in self?.handleMouseMoved() }
            }
        }

        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            if let self {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self.handleMouseMoved() }
                } else {
                    Task { @MainActor [weak self] in self?.handleMouseMoved() }
                }
            }
            return event
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let globalMoveMonitor {
            NSEvent.removeMonitor(globalMoveMonitor)
            self.globalMoveMonitor = nil
        }
        if let localMoveMonitor {
            NSEvent.removeMonitor(localMoveMonitor)
            self.localMoveMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if !wakeObservers.isEmpty {
            let wsCenter = NSWorkspace.shared.notificationCenter
            for token in wakeObservers {
                wsCenter.removeObserver(token)
            }
            wakeObservers.removeAll()
        }

        stopDwellTimer()
        stopOpenPollTimer()
        _ = machine.forceClose()
    }

    func reloadConfiguration() {
        position = Keys.currentDockPosition
        resyncDwellTimerForRegimeChange()
        rebuildStrips()
        if isRunning {
            evaluatePointer(at: NSEvent.mouseLocation, now: CFAbsoluteTimeGetCurrent())
        }
    }

    /// `ignoredDisplayID` 或配置变更导致 dwell 档位切换时，同步重算在途计时器：
    /// - 正在 dwell 的屏刚好被豁免 ⇒ 立刻作废；
    /// - 时长拉长（0.1s → 3.0s）⇒ 按新时长重算剩余并重排预热；
    /// - 时长缩短（3.0s → 0.1s）且已超新时长（`remaining <= 0`）⇒ **不立刻开火**（避免主屏进全屏时把副屏边上原本 2s 的指针误弹开），而是按新时长重新起表 ✓
    private func resyncDwellTimerForRegimeChange() {
        let newDuration = effectiveDwellDuration
        machine.dwellDuration = newDuration

        guard case .dwelling(let dwellingID, let enteredAt) = machine.state else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if dwellingID == ignoredDisplayID {
            stopDwellTimer()
            let effect = machine.edgeExited(displayID: dwellingID, now: now)
            apply(effect)
            return
        }

        stopDwellTimer()
        let remaining = newDuration - (now - enteredAt)
        if remaining <= 0 {
            _ = machine.edgeExited(displayID: dwellingID, now: now)
            let effect = machine.edgeEntered(
                displayID: dwellingID,
                mouseButtonsPressed: NSEvent.pressedMouseButtons != 0,
                suppressed: isSuppressed?() ?? false,
                now: now
            )
            apply(effect)
        } else {
            scheduleDwellTimer(after: remaining)
            if newDuration > Self.prewarmDwellCeiling {
                let prewarmRemaining = remaining - Self.longDwellPrewarmLeadTime
                if prewarmRemaining > 0.05 {
                    scheduleDelayedPrewarm(for: dwellingID, after: prewarmRemaining)
                }
            }
        }
    }

    func notifyDockOpened(displayID: CGDirectDisplayID) {
        stopDwellTimer()
        if machine.state != .open(displayID: displayID) {
            let savedDwell = machine.dwellDuration
            _ = machine.forceClose()
            machine.dwellDuration = 0
            _ = machine.edgeEntered(
                displayID: displayID,
                mouseButtonsPressed: false,
                suppressed: false,
                now: CFAbsoluteTimeGetCurrent()
            )
            machine.dwellDuration = savedDwell
        }
        if isRunning {
            ensureOpenPollTimer()
        }
    }

    func notifyDockClosedExternally() {
        stopDwellTimer()
        stopOpenPollTimer()
        _ = machine.forceClose()
    }

    // MARK: - 几何与状态驱动

    private func rebuildStrips() {
        let displays: [DockDisplayRect] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DockDisplayRect(
                id: number.uint32Value,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        cachedStrips = DockEdgeGeometry.sensorStrips(displays: displays, position: position, thickness: 3)
    }

    private func handleScreenParametersChanged() {
        guard isRunning else { return }
        rebuildStrips()
        evaluatePointer(at: NSEvent.mouseLocation, now: CFAbsoluteTimeGetCurrent())
    }

    private func handleMouseMoved() {
        guard isRunning else { return }
        evaluatePointer(at: NSEvent.mouseLocation, now: CFAbsoluteTimeGetCurrent())
    }

    private func evaluatePointer(at point: CGPoint, now: Double) {
        let buttonsPressed = NSEvent.pressedMouseButtons != 0
        let suppressed = isSuppressed?() ?? false

        // 常驻条带换屏/条带隐藏后,原先那块屏的在途 dwell 立刻作废:
        // 否则计时器一响就会对着"已被豁免的屏"唤起一次(重复触发)。
        if case .dwelling(let dwellingID, _) = machine.state, dwellingID == ignoredDisplayID {
            let effect = machine.edgeExited(displayID: dwellingID, now: now)
            stopDwellTimer()
            apply(effect)
        }

        // 豁免屏的贴边**不发起** dwell;其余屏照常 ⇒ 在其他屏贴边仍能把常驻条带换过去 ✓
        // 使用 `DockEdgeGeometry.contains` 闭区间判据（避免 `.right` 边 `x == maxX` 被 `CGRect.contains` 半开区间漏检）
        let hitDisplayID = cachedStrips
            .first(where: {
                $0.displayID != ignoredDisplayID
                    && DockEdgeGeometry.contains(strip: $0, point: point, position: position)
            })?.displayID

        switch machine.state {
        case .idle:
            if let displayID = hitDisplayID {
                enterEdge(
                    displayID: displayID,
                    mouseButtonsPressed: buttonsPressed,
                    suppressed: suppressed,
                    now: now
                )
            }

        case .dwelling(let currentDisplayID, _):
            if let displayID = hitDisplayID {
                enterEdge(
                    displayID: displayID,
                    mouseButtonsPressed: buttonsPressed,
                    suppressed: suppressed,
                    now: now
                )
            } else {
                let effect = machine.edgeExited(displayID: currentDisplayID, now: now)
                stopDwellTimer()
                apply(effect)
            }

        case .open(let displayID), .leaving(let displayID, _):
            evaluateOpenOrLeaving(
                displayID: displayID,
                point: point,
                now: now,
                buttonsPressed: buttonsPressed,
                suppressed: suppressed
            )
        }
    }

    private func enterEdge(
        displayID: CGDirectDisplayID,
        mouseButtonsPressed: Bool,
        suppressed: Bool,
        now: Double
    ) {
        let previousDwellingID: CGDirectDisplayID? = if case .dwelling(let id, _) = machine.state { id } else { nil }
        let effect = machine.edgeEntered(
            displayID: displayID,
            mouseButtonsPressed: mouseButtonsPressed,
            suppressed: suppressed,
            now: now
        )
        if machine.state == .idle {
            stopDwellTimer()
        }
        if case .dwelling(let dwellingID, _) = machine.state, previousDwellingID != dwellingID {
            // · 短 dwell（50–280ms）：贴边立刻预热；
            // · 长 dwell（3.0s 跨屏停边）：延后到「到点前 0.5s」（2.5s 时）再预热 ——
            //   路过副屏底边零开销，真停满 3.0s 切过去时图标热启动不空白 ✓
            if machine.dwellDuration <= Self.prewarmDwellCeiling {
                stopPrewarmTimer()
                onEdgePrewarm?(dwellingID)
            } else {
                let leadDelay = max(0.2, machine.dwellDuration - Self.longDwellPrewarmLeadTime)
                scheduleDelayedPrewarm(for: dwellingID, after: leadDelay)
            }
        }
        apply(effect)
    }

    private func evaluateOpenOrLeaving(
        displayID: CGDirectDisplayID,
        point: CGPoint,
        now: Double,
        buttonsPressed: Bool,
        suppressed: Bool
    ) {
        if suppressed {
            let effect = machine.tick(now: now, mouseButtonsPressed: buttonsPressed, suppressed: true)
            apply(effect)
            return
        }

        let inSurface = isPointerInsideDockSurface?(point) ?? false
        let onStrip = cachedStrips.contains(where: {
            $0.displayID == displayID
                && DockEdgeGeometry.contains(strip: $0, point: point, position: position)
        })

        if inSurface || onStrip {
            if case .leaving = machine.state {
                let effect = if inSurface {
                    machine.pointerEnteredSurface(displayID: displayID, now: now)
                } else {
                    machine.edgeEntered(
                        displayID: displayID,
                        mouseButtonsPressed: buttonsPressed,
                        suppressed: false,
                        now: now
                    )
                }
                apply(effect)
            }
            return
        }

        switch machine.state {
        case .open:
            let effect = machine.pointerLeftSurface(displayID: displayID, now: now)
            apply(effect)
        case .leaving:
            let effect = machine.tick(now: now, mouseButtonsPressed: buttonsPressed, suppressed: false)
            apply(effect)
        case .idle, .dwelling:
            break
        }
    }

    private func apply(_ effect: DockTriggerEffect) {
        switch effect {
        case .none:
            break
        case .scheduleDwellCheck(let delay):
            scheduleDwellTimer(after: delay)
        case .openDock(let displayID):
            stopDwellTimer()
            if isRunning {
                ensureOpenPollTimer()
            }
            if isTraceEnabled {
                glog("[Dock触发] 贴边唤起 display=\(displayID) pos=\(position.rawValue)")
            }
            onOpenDock?(displayID)
        case .scheduleLeaveCheck:
            if isRunning {
                ensureOpenPollTimer()
            }
        case .closeDock:
            stopDwellTimer()
            stopOpenPollTimer()
            if isTraceEnabled {
                glog("[Dock触发] 离开联合交互区或被抑制，自动收起")
            }
            onCloseDock?()
        }
    }

    // MARK: - 定时器管理

    private func scheduleDwellTimer(after delay: Double) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        let interval = max(0.005, delay)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDwellTimerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func stopDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopPrewarmTimer()
    }

    private func scheduleDelayedPrewarm(for displayID: CGDirectDisplayID, after delay: Double) {
        stopPrewarmTimer()
        let timer = Timer(timeInterval: max(0.05, delay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.prewarmTimer != nil else { return }
                self.prewarmTimer = nil
                guard case .dwelling(let currentID, _) = self.machine.state,
                      currentID == displayID,
                      currentID != self.ignoredDisplayID else { return }
                self.onEdgePrewarm?(displayID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        prewarmTimer = timer
    }

    private func stopPrewarmTimer() {
        prewarmTimer?.invalidate()
        prewarmTimer = nil
    }

    private func handleDwellTimerFired() {
        guard isRunning, dwellTimer != nil else { return }
        dwellTimer = nil

        guard case .dwelling(let displayID, _) = machine.state else { return }
        let point = NSEvent.mouseLocation
        let now = CFAbsoluteTimeGetCurrent()

        // 豁免屏(常驻条带已占住)**不因计时器到点而唤起**:这里与 `evaluatePointer` 同一条豁免。
        // 只有这条计时器路径不受指针事件驱动 —— 若不在此处拦一下,`ignoredDisplayID` 刚置上、
        // 而指针恰好静着不动时,计时器仍会多唤起一次(重复触发)。
        guard displayID != ignoredDisplayID else {
            _ = machine.edgeExited(displayID: displayID, now: now)
            return
        }

        guard cachedStrips.contains(where: {
            $0.displayID == displayID
                && DockEdgeGeometry.contains(strip: $0, point: point, position: position)
        }) else {
            _ = machine.edgeExited(displayID: displayID, now: now)
            return
        }

        let buttonsPressed = NSEvent.pressedMouseButtons != 0
        let suppressed = isSuppressed?() ?? false
        let effect = machine.tick(now: now, mouseButtonsPressed: buttonsPressed, suppressed: suppressed)
        apply(effect)
    }

    private func ensureOpenPollTimer() {
        guard openPollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.openPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOpenPollTimerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        openPollTimer = timer
    }

    private func stopOpenPollTimer() {
        openPollTimer?.invalidate()
        openPollTimer = nil
    }

    private func handleOpenPollTimerFired() {
        guard isRunning else {
            stopOpenPollTimer()
            return
        }

        let point = NSEvent.mouseLocation
        let now = CFAbsoluteTimeGetCurrent()
        let buttonsPressed = NSEvent.pressedMouseButtons != 0
        let suppressed = isSuppressed?() ?? false

        switch machine.state {
        case .open(let displayID), .leaving(let displayID, _):
            evaluateOpenOrLeaving(
                displayID: displayID,
                point: point,
                now: now,
                buttonsPressed: buttonsPressed,
                suppressed: suppressed
            )
        case .idle, .dwelling:
            stopOpenPollTimer()
        }
    }
}
