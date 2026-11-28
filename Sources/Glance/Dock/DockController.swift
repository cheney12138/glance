import AppKit
import GlanceCore
import SwiftUI

/// Dock 独立无边框悬浮窗（永不抢占 key 焦点：避免 AppKit 吞掉第一击设为 key 或在
/// `_SLPSSetFrontProcessWithOptions` 前抢走前台激活，与 `GlancePanel(keyable: false)` 同理）。
final class DockFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 禁止 AppKit 把屏外起跑框或带 108pt 透明阴影呼吸区的条带窗框夹回菜单栏/屏内，
    /// 否则 `setFrame(offEdgeFrame)` 会被静默挪偏 Y/X，造成入场斜着滑出 ✗
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(level: NSWindow.Level) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        isReleasedWhenClosed = false
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // 默认穿透，仅当指针实际落在玻璃内容区内时由 `syncPanelMousePassthrough` 打开接收，
        // 避免 108pt/96pt 阴影透明呼吸区拦截底层 App 点击 ✓
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
}

/// 常驻条带上的**独立渲染槽**（App 加入 / 退出时的丝滑伸缩）。
///
/// 为什么渲染层不再直接遍历 `groups`：增删那一拍我们需要「正在退出的 App 还留在原槽位收拢」，
/// 而 `groups` 是业务名单（索引语义、hover、托盘、稳定槽位全压在它身上），绝不能塞幽灵条目进去 ✗。
/// ⇒ 业务认 `groups`，渲染只认这份槽位表。
struct RunningStripSlot: Identifiable {
    let pid: pid_t
    var group: AppGroup
    var isExiting: Bool
    /// 0 = 收起透明，1 = 完全展开落位（参数驱动，保证系统开启 reduceMotion 时依然可由 MotionPolicy 放行完整弹簧动画）
    var progress: CGFloat
    var id: pid_t { pid }
}

/// Dock 替代条带与窗口预览托盘的控制器（与 `PanelController` 完全隔离）。
@MainActor
final class DockController: ObservableObject {
    @Published private(set) var isVisible: Bool = false
    @Published private(set) var position: DockPosition = Keys.currentDockPosition
    @Published private(set) var groups: [AppGroup] = []
    /// 常驻条带渲染槽（可能含「正在退出」的幽灵槽，`progress` 收到 0 后静默剔除）。
    /// **只供渲染层**：业务一律认 `groups`（见 `RunningStripSlot` 的注释）。
    @Published private(set) var runningSlots: [RunningStripSlot] = []
    /// **图标版本号**(2026-11-25 根因 C):后台真的把图标落进账本时 +1,作为 token 传给
    /// `DockRunningIconCell`。它是纯值参数子视图 —— 父视图重算时参数一比特没变就会跳过 `body`,
    /// 于是真 logo 落了账也画不上屏(要等 hover / 重开程序坞才突然变出来 ✗)
    @Published private(set) var iconRevision: Int = 0
    @Published private(set) var launchables: [DockAppsProvider.LaunchableApp] = []
    @Published private(set) var showingLaunchSegment: Bool = false
    @Published private(set) var hoveredAppIndex: Int?
    @Published var hoveredLaunchIndex: Int?
    @Published private(set) var hoveredTailToggle: Bool = false
    @Published private(set) var selectedWindowIndex: Int = 0
    @Published private(set) var isSideChipStackExpanded: Bool = false
    @Published private(set) var glassEpoch: Int = 0
    @Published private(set) var metrics: DockMetrics = DockMetrics()
    @Published private(set) var stripContentSize: CGSize = .zero
    @Published private(set) var trayContentSize: CGSize = .zero
    @Published private(set) var trayAvailableSize: CGSize = CGSize(width: 600, height: 600)

    /// 打开前回调（供 App 层收起可能开着的 ⌘Tab 面板）。
    var onWillOpen: (() -> Void)?
    /// 收起后回调（通知边缘传感器复位）。
    var onDidDismiss: (() -> Void)?

    // MARK: - 常驻模式状态（ADR-0018 方案 A：悬浮常驻 + 全屏自动避让）

    /// 常驻模式是否开启（与「此刻条带是否真在屏上」无关：全屏避让时仍为 `true`）。
    @Published private(set) var isAlwaysOnActive: Bool = false
    /// 是否因**目标屏被全屏占用**而暂时避让（条带收起，但常驻模式仍然开着）。
    @Published private(set) var isHiddenForFullscreen: Bool = false
    /// 常驻条带所属的屏（全屏避让期间也保留 ⇒ 退出全屏后能回到同一块屏）。
    @Published private(set) var alwaysOnDisplayID: CGDirectDisplayID?
    /// 常驻条带在屏上可见/不可见的**归属变化**回调。
    ///
    /// 参数 = 条带此刻「占住」的那块屏；`nil` 表示条带当前不可见（全屏避让 / 关闭常驻）。
    /// 供 `DockEdgeSensor.ignoredDisplayID` 使用：占住的那块屏不再响应贴边唤起，
    /// 其余屏照常 ⇒ 常驻条带可以靠贴边换屏 ✓
    var onAlwaysOnDisplayStateChanged: ((_ ignoredDisplayID: CGDirectDisplayID?) -> Void)?

    /// **常驻条带此刻是否真的在屏上**（唯一判据）。
    ///
    /// 两种运行态在这里分叉：
    ///   · `true`  ⇒ 常驻条带：dock 层级、`[.canJoinAllSpaces, .transient]`、空闲 0Hz；
    ///   · `false` ⇒ 老行为（自动隐藏，或全屏避让后的贴边临时唤起）：`.popUpMenu`、
    ///     `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`、60Hz hover 轮询。
    var isShowingPersistentStrip: Bool { isAlwaysOnActive && !isHiddenForFullscreen }

    /// 常驻态指针离开「交互区 + 近场」的起始时刻（0.26s 宽限后收托盘退回 0Hz）。
    private var alwaysOnLeaveStartedAt: CFAbsoluteTime?
    /// 交互期间后台刷到的新名单：等 `endAlwaysOnInteraction` 时再正式落地（防鼠标底下重排）。
    private var pendingAlwaysOnGroups: [AppGroup]?
    private var pendingAlwaysOnLaunchables: [DockAppsProvider.LaunchableApp]?
    private var alwaysOnRefreshWork: DispatchWorkItem?
    private var alwaysOnRefreshInFlight: Bool = false
    /// 期间是否有「必须重扫 candidates（Dock plist + LaunchServices）」的请求没被满足。
    /// 在途去重时合并进来，保证这轮最重的活不会因为一次去重就被丢掉 ✓
    private var alwaysOnNeedsCandidatesRefresh: Bool = false
    private var alwaysOnEvaluateWork: DispatchWorkItem?
    private var alwaysOnMoveGlobalMonitor: Any?
    private var alwaysOnMoveLocalMonitor: Any?

    /// 单屏常驻的**窗口边界避让**（方案 1A：事件驱动、零轮询）。
    /// 只对当前常驻的那一块屏生效；条带不在屏上时它是完全卸载状态（`disable()`）✓
    private let windowReserveGuard = DockWindowReserveGuard()
    /// 条带占位之外再留的余量（pt）—— 0pt 直接贴合玻璃环内侧外缘（与 macOS 原生常驻 Dock 的 visibleFrame 贴边一致，避免留出多余黑沟 ✓）
    private static let reservedGap: CGFloat = 0
    /// 常驻图标的**稳定槽位顺序**（按屏记）：新开的 App 追加到末尾，刷新 / 切 App 不跳变。
    /// 只在常驻态使用；自动隐藏模式的 MRU 逻辑一个字都不变 ✓
    private var alwaysOnStableOrderByDisplay: [CGDirectDisplayID: [pid_t]] = [:]

    /// 常驻态指针离开交互区的宽限（与 `GlanceCore.DockTriggerMachine.leaveGraceDuration` 同口径）。
    private static let alwaysOnLeaveGrace: CFAbsoluteTime = 0.26

    private var stripPanel: DockFloatingPanel?
    private var stripHostingView: ClickThroughHostingView<DockStripView>?
    private var trayPanel: DockFloatingPanel?
    private var trayHostingView: ClickThroughHostingView<DockTrayView>?

    private var activeScreen: NSScreen?
    private var activeDisplayID: CGDirectDisplayID?
    private var currentStripContentRect: CGRect?
    private var currentTrayContentRect: CGRect?

    // MARK: - 常驻条带增删动效（App 加入/退出时的弹簧伸缩）

    /// morph 代次：任何一次新 morph / 立即同步都会 +1，在途的 start / finish 任务按它校验作废 ✓
    private var stripMorphGeneration: Int = 0
    private var stripMorphStartWork: DispatchWorkItem?
    private var stripMorphFinishWork: DispatchWorkItem?
    /// morph 的**目标**窗框；非 nil = 正活在「包络窗框」里演弹簧（收尾后清空）。
    /// 它同时是「当前是否处于 morph」的唯一判据（`layoutAndShowStrip` 靠它让路）✓
    private var stripMorphTargetWindowFrame: CGRect?

    private struct CachedGroups {
        var groups: [AppGroup]
        var updatedAt: CFAbsoluteTime
        /// 这份缓存**干净**吗？写入时 `epochAtStart == cacheEpoch` 才置 true；
        /// `scheduleCacheRefreshSoon(markDirty: true)` 打回 false（`updatedAt = 0`）。
        /// `prunePIDFromCache` 剪枝后**不**标脏：剪过的名单依旧是有效名单 ✓
        /// 干净的缓存即使超过 0.4s 也能 0ms 直出（贴边唤起不许为「续鲜」等枚举）✓
        var isFresh: Bool
    }

    /// 按屏预热/续鲜缓存：干净的缓存可 0ms 直出；超时仅作 55ms 极端卡顿兜底，禁止先吐旧名单再现场重排。
    private var freshGroupsByDisplay: [CGDirectDisplayID: CachedGroups] = [:]
    private var lastPrewarmStartedAt: [CGDirectDisplayID: CFAbsoluteTime] = [:]
    private var prewarmInFlightDisplays: Set<CGDirectDisplayID> = []
    /// 在途 prewarm 是从哪个 `cacheEpoch` 起跑的、什么时候起跑的。
    /// 用途：① `open` 撞上同 epoch 的在途预热 ⇒ 复用它，不再并起第二趟抢 AX IPC；
    /// ② 预热结果落地时按起跑时刻剪「起跑后才退出的进程」✓
    private var prewarmEpochByDisplay: [CGDirectDisplayID: Int] = [:]
    private var prewarmStartedAtByDisplay: [CGDirectDisplayID: CFAbsoluteTime] = [:]
    private var cacheEpoch: Int = 0
    private var recentlyPrunedPIDs: [pid_t: CFAbsoluteTime] = [:]
    private var debouncedRefreshWork: DispatchWorkItem?
    private var openFallbackWork: DispatchWorkItem?
    /// 悬停扫过多个 Dock 图标时的 120ms 驻留防抖：未驻留前 0ms 展示已有缓存帧/快照，
    /// 驻留满 120ms 才起重量级 SCStream 实时流与 Snapshotter 补拍，避免扫 4 个图标就轰出 5 条流 + 12 张截屏拖慢切焦 ✓
    private var liveCaptureDebounceWork: DispatchWorkItem?
    private var openGeneration: Int = 0

    private var outsideGlobalClickMonitor: Any?
    private var outsideLocalClickMonitor: Any?
    private var escGlobalMonitor: Any?
    private var escLocalMonitor: Any?
    private var clickGateTimer: Timer?
    private var hoverPollTimer: Timer?

    /// Safe-Triangle 防误串：上一次指针落在「当前 hoveredAppIndex 图标自身」上的位置（三角形顶点）。
    private var lastSafeAnchorPoint: CGPoint?
    /// Safe-Triangle 防误串：斜向移入托盘首次进入宽限的时刻（CFAbsoluteTime）。
    private var diagonalHoldStartedAt: CFAbsoluteTime?
    /// Safe-Triangle 防误串：上一帧指针位置（区分「仍在推进」与「已经停住」）。
    private var lastMousePoint: CGPoint?
    /// 斜向移入托盘的宽限上限：停住超过这个时长，说明用户真的停在隔壁图标上，放行切换。
    private static let diagonalHoldGraceLimit: CFAbsoluteTime = 0.18
    private var stripAnimTimer: Timer?
    private var trayAnimTimer: Timer?
    private var hasRevealedInSession: Bool = false
    private var isEnteringStrip: Bool = false
    private var isExitingStrip: Bool = false
    private var animStartFrame: CGRect = .zero
    private var animTargetFrame: CGRect = .zero
    private var animStartAlpha: CGFloat = 0
    private var animTargetAlpha: CGFloat = 1
    private var animStartedAt: CFAbsoluteTime = 0
    private var animDuration: Double = 0.22
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init() {
        installSystemObservers()
        // 避让守卫万一发现目标屏其实处于全屏（我们自己没判到）⇒ 立刻重评，让条带让位
        windowReserveGuard.onFullscreenDetected = { [weak self] in
            self?.scheduleAlwaysOnFullscreenEvaluation(delay: 0.05)
        }
    }

    deinit {
        // 4 枚定时器都要显式 invalidate：主 run loop 持有 Timer 本身，不 invalidate 就一直躺着跑
        // （常驻态那条 60Hz 的尤其贵）✗
        stripAnimTimer?.invalidate()
        trayAnimTimer?.invalidate()
        clickGateTimer?.invalidate()
        hoverPollTimer?.invalidate()
        // 增删动效的两个在途任务也要显式取消：它们各自持有一份 self 弱引用 + 捕获的代次，
        // 不取消就得在队列里白躺到 0.36s（与上面 4 枚定时器同一条纪律）✓
        stripMorphStartWork?.cancel()
        stripMorphFinishWork?.cancel()
        // 4 枚点击/Esc 监听同理：不移除就永久挂着闭包（P3 deinit 泄漏）✗
        if let monitor = outsideGlobalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = outsideLocalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = escGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = escLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = alwaysOnMoveGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = alwaysOnMoveLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // 常驻避让守卫不需要在这里叫 disable()：`deinit` 是非隔离上下文，而它自己的
        // `deinit` 会完整拆掉 AXObserver source / workspace observer / 一次性 mouseUp 监听 /
        // 防抖任务（见 DockWindowReserveGuard.deinit）⇒ 本对象释放时一并清干净 ✓
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    var activeHoveredGroup: AppGroup? {
        guard !showingLaunchSegment,
              let idx = hoveredAppIndex,
              groups.indices.contains(idx) else {
            return nil
        }
        return groups[idx]
    }

    /// 当前 hover 的那一格对应哪个 App。**身份是 PID**：稳定顺序下同一个下标随时可能换成别的 App
    /// （渲染槽里还可能有正在退出的幽灵槽），按下标点确认会点错 ✗
    var hoveredAppPID: pid_t? {
        guard let idx = hoveredAppIndex, groups.indices.contains(idx) else { return nil }
        return groups[idx].pid
    }

    var showsTailToggleButton: Bool {
        !launchables.isEmpty || showingLaunchSegment
    }

    // MARK: - 公开生命周期接口

    func prewarm(on displayID: CGDirectDisplayID) {
        // 常驻态：**换屏的目标屏**必须允许预热（否则新屏要等一次真实枚举才有名单，P2）；
        // 只要不是「常驻且目标就是当前常驻屏」，其余口径与老行为一致 ✓
        guard !isVisible || (isAlwaysOnActive && displayID != alwaysOnDisplayID) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastPrewarmStartedAt[displayID], now - last < 0.15 {
            return
        }
        guard !prewarmInFlightDisplays.contains(displayID),
              let screen = Self.screen(for: displayID) else {
            return
        }

        lastPrewarmStartedAt[displayID] = now
        prewarmInFlightDisplays.insert(displayID)
        let epochAtStart = cacheEpoch
        prewarmEpochByDisplay[displayID] = epochAtStart
        prewarmStartedAtByDisplay[displayID] = now

        Task.detached(priority: .userInitiated) {
            let raw = WindowEnumerator.rawGroups(on: screen, includeMinimized: true)
            let candidates = DockAppsProvider.computeCandidates()
            let running = DockAppsProvider.computeRunningSet()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.prewarmInFlightDisplays.remove(displayID)
                let startedAt = self.prewarmStartedAtByDisplay.removeValue(forKey: displayID) ?? now
                self.prewarmEpochByDisplay.removeValue(forKey: displayID)
                guard let currentScreen = Self.screen(for: displayID) else {
                    return
                }
                let ordered = WindowEnumerator.orderByMRU(raw, on: currentScreen)
                // ★★ 2026-11-27:无论 epoch 变没变都先**洗掉死进程**再落地 ——
                //   刚退出的 App 的 `didTerminate` 可能还排在队列里，靠它剪是赶不上这一趟的 ✗
                let cleaned = self.filterAliveGroups(ordered, prunedSince: startedAt)
                DockAppsProvider.storeCandidates(candidates)
                DockAppsProvider.storeRunningSet(running)
                if epochAtStart == self.cacheEpoch {
                    self.freshGroupsByDisplay[displayID] = CachedGroups(
                        groups: cleaned,
                        updatedAt: CFAbsoluteTimeGetCurrent(),
                        isFresh: true
                    )
                }
                // ★★ 2026-11-27:贴边唤起的 `open` 正在等名单（兜底还没吐）⇒ 直接把预热结果交接过去，
                //   省掉一趟重复枚举 + 90ms 兜底的卡顿 ✓
                if epochAtStart == self.cacheEpoch,
                   self.isVisible,
                   !self.isShowingPersistentStrip,
                   self.activeDisplayID == displayID {
                    self.handleOpenEnumerationResult(
                        ordered: ordered,
                        running: running,
                        displayID: displayID,
                        generation: self.openGeneration,
                        startedAt: startedAt
                    )
                }
            }
        }
    }

    func open(on displayID: CGDirectDisplayID) {
        // 常驻态分流（ADR-0018 方案 A）：
        //   · 已在别的屏上常驻 ⇒ 这次贴边是「换屏」，走 moveAlwaysOn（原地换屏、不播退场动画）；
        //   · 正在本屏常驻 ⇒ 条带已经在了，open 无事可做；
        //   · 仅「本屏因全屏避让而收起」时才落到下面的临时唤起流程 ✓
        if isAlwaysOnActive {
            if displayID != alwaysOnDisplayID {
                moveAlwaysOn(to: displayID)
                return
            }
            if isShowingPersistentStrip {
                return
            }
        }
        if isVisible && activeDisplayID == displayID {
            return
        }
        guard let screen = Self.screen(for: displayID) else {
            glog("[Dock] 未找到 displayID=\(displayID) 对应的 NSScreen，取消打开")
            return
        }

        onWillOpen?()

        // 若正在播退场动画，立刻中断并准备原地滑回（无缝可打断）
        let resumingFromExit = isExitingStrip && (stripPanel?.isVisible == true)
        stopStripAnimation()
        stopTrayAnimation()
        openFallbackWork?.cancel()
        openFallbackWork = nil

        if isVisible || (trayPanel?.isVisible == true) {
            hideTray()
        }
        syncPanelMousePassthrough()

        activeScreen = screen
        activeDisplayID = displayID
        position = Keys.currentDockPosition
        openGeneration &+= 1
        let gen = openGeneration
        if !resumingFromExit {
            glassEpoch &+= 1
        }
        hasRevealedInSession = false

        showingLaunchSegment = false
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        resetDiagonalGuard()
        isVisible = true
        LivePreviewPool.shared.setAccepting(true)
        PanelScreen.update(screen)

        launchables = DockAppsProvider.launchables(excluding: DockAppsProvider.runningSet())

        installMonitors()
        startHoverPolling()

        let now = CFAbsoluteTimeGetCurrent()
        // ★★ 2026-11-27:缓存**干净**（没被标脏，剪枝过的名单依旧有效）就 0ms 直出，
        //   不再卡「0.4s 有效期」—— 贴边唤起为一次无意义的「续鲜」等枚举是纯浪费 ✗
        if let cached = freshGroupsByDisplay[displayID],
           cached.isFresh || now - cached.updatedAt <= 0.4 {
            let alive = filterAliveGroups(cached.groups)
            // 干净的缓存就算这次全员被洗掉（例如刚全部退出）也直出，别把用户押在枚举上 ✓
            if !alive.isEmpty || cached.isFresh {
                groups = isAlwaysOnActive
                    ? mergeAlwaysOnStableOrder(fresh: alive, displayID: displayID)
                    : alive
                layoutAndShowStrip(on: screen)
                pollHover()
            }
            // 干净但久未续鲜：补一趟**不改顺序**的轻量复核（只剔幽灵 + 同步窗口数）✓
            // 已有同 epoch 在途预热时让它去干，不重复枚举 ✓
            if now - cached.updatedAt > 0.4,
               !prewarmInFlightDisplays.contains(displayID) {
                let startedAt = now
                Task.detached(priority: .utility) {
                    let raw = WindowEnumerator.rawGroups(on: screen, includeMinimized: true)
                    let running = DockAppsProvider.computeRunningSet()

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let targetScreen = Self.screen(for: displayID) ?? screen
                        let ordered = WindowEnumerator.orderByMRU(raw, on: targetScreen)
                        DockAppsProvider.storeRunningSet(running)
                        self.handleOpenEnumerationResult(
                            ordered: ordered,
                            running: running,
                            displayID: displayID,
                            generation: gen,
                            startedAt: startedAt
                        )
                    }
                }
            }
            return
        }

        let hasCachedAlive = !filterAliveGroups(freshGroupsByDisplay[displayID]?.groups ?? []).isEmpty
        let fallbackWork = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isVisible,
                  gen == self.openGeneration,
                  !self.hasRevealedInSession,
                  let currentScreen = Self.screen(for: displayID) ?? self.activeScreen else {
                return
            }
            // ★★ 2026-11-27:兜底也是「上屏」的路径，一样要洗掉已退出的进程（通知还在队列里）✗
            let aliveFallback = self.filterAliveGroups(self.freshGroupsByDisplay[displayID]?.groups ?? [])
            self.groups = self.isAlwaysOnActive
                ? self.mergeAlwaysOnStableOrder(fresh: aliveFallback, displayID: displayID)
                : aliveFallback
            self.layoutAndShowStrip(on: currentScreen)
            self.pollHover()
        }
        openFallbackWork = fallbackWork
        // 有可用旧缓存时 55ms 即可兜底；彻底无缓存（休眠唤醒 / 换屏 / 重启后冷启）时别在 55ms
        // 急着吐出一块 120pt 高的「无本屏窗口」小方块（随后真名单落地猛涨高度会闪跳），给真枚举 0.18s 一次到位 ✓
        let fallbackDelay: TimeInterval = hasCachedAlive ? 0.055 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay, execute: fallbackWork)

        let epochAtStart = cacheEpoch
        let startedAt = now

        // ★★ 2026-11-27:贴边停驻期间 prewarm 已在途且 epoch 未变 ⇒ 复用它（它落地时会直接
        //   把结果交接给本趟 open），再起第二趟只会两条并发枚举互抢 AX IPC，把延迟拉爆 ✗
        if prewarmInFlightDisplays.contains(displayID),
           prewarmEpochByDisplay[displayID] == cacheEpoch {
            return
        }

        Task.detached(priority: .userInitiated) {
            let raw = WindowEnumerator.rawGroups(on: screen, includeMinimized: true)
            let candidates = DockAppsProvider.computeCandidates()
            let running = DockAppsProvider.computeRunningSet()

            await MainActor.run { [weak self] in
                guard let self else { return }
                let targetScreen = Self.screen(for: displayID) ?? self.activeScreen ?? screen
                let ordered = WindowEnumerator.orderByMRU(raw, on: targetScreen)
                // ★★ 2026-11-25:新冒出来的 App(刚启动 / 刚从无窗变有窗)先派后台预热图标 ——
                //   已命中 bundleID 二级缓存的当场 0ms 回填,其余抢在用户看到白纸之前落账 ✓
                IconProvider.prewarmMissing(for: ordered.map { (pid: $0.pid, bundleID: $0.bundleID) })
                DockAppsProvider.storeCandidates(candidates)
                DockAppsProvider.storeRunningSet(running)
                if epochAtStart == self.cacheEpoch {
                    self.freshGroupsByDisplay[displayID] = CachedGroups(
                        groups: self.filterAliveGroups(ordered, prunedSince: startedAt),
                        updatedAt: CFAbsoluteTimeGetCurrent(),
                        isFresh: true
                    )
                }
                self.handleOpenEnumerationResult(
                    ordered: ordered,
                    running: running,
                    displayID: displayID,
                    generation: gen,
                    startedAt: startedAt
                )
            }
        }
    }

    // MARK: - 真实枚举回流（open / prewarm 共用入口）

    /// 三条纪律：
    ///   1. **先剔死进程**（`filterAliveGroups`）：`didTerminate` 通知可能还排在队列里，
    ///      刚退出的微信不能指望它剪，直接按 `runningApplications.isTerminated` 判 ✓
    ///   2. **首屏之后不重排**：`hasRevealedInSession == true` 时冻结已有顺序，
    ///      只按 PID 剔除幽灵 / 原地换新 `AppGroup`（仅窗口数变化时连窗框都不碰）✓
    ///   3. 任何一次回流都作废兜底任务，避免陈旧兜底在真名单之后又把幽灵吐回来 ✓
    private func handleOpenEnumerationResult(
        ordered: [AppGroup],
        running: Set<String>,
        displayID: CGDirectDisplayID,
        generation: Int,
        startedAt: CFAbsoluteTime
    ) {
        guard isVisible,
              generation == openGeneration,
              activeDisplayID == displayID,
              let currentScreen = Self.screen(for: displayID) ?? activeScreen else {
            return
        }

        openFallbackWork?.cancel()
        openFallbackWork = nil

        let cleaned = filterAliveGroups(ordered, prunedSince: startedAt)
        let resolvedGroups = isAlwaysOnActive
            ? mergeAlwaysOnStableOrder(fresh: cleaned, displayID: displayID)
            : cleaned

        // a) 首屏还没上屏 ⇒ 直接按本轮枚举落名单（这是唯一允许「整块换」的时刻）✓
        guard hasRevealedInSession else {
            groups = resolvedGroups
            launchables = DockAppsProvider.launchables(excluding: running)
            layoutAndShowStrip(on: currentScreen)
            pollHover()
            return
        }

        // b) 已上屏但当前是空名单（兜底吐了个空）⇒ 整块补上，同样不许空屏
        guard !groups.isEmpty || resolvedGroups.isEmpty else {
            groups = resolvedGroups
            launchables = DockAppsProvider.launchables(excluding: running)
            layoutAndShowStrip(on: currentScreen)
            pollHover()
            return
        }

        // c) 已上屏：**冻结已有顺序**，只按 PID 剔幽灵 / 原地换新事实（鼠标底下重排 = 跳）✓
        var freshByPID: [pid_t: AppGroup] = [:]
        freshByPID.reserveCapacity(resolvedGroups.count)
        for group in resolvedGroups where freshByPID[group.pid] == nil {
            freshByPID[group.pid] = group
        }
        var updated: [AppGroup] = []
        updated.reserveCapacity(groups.count)
        var removedPIDs: [pid_t] = []
        var windowsChanged = false
        for existing in groups {
            guard let fresh = freshByPID[existing.pid] else {
                removedPIDs.append(existing.pid)
                continue
            }
            if fresh.windows.count != existing.windows.count { windowsChanged = true }
            updated.append(fresh)
        }
        guard !removedPIDs.isEmpty || windowsChanged else { return }

        let hoveredPIDNow: pid_t? = hoveredAppIndex.flatMap { groups.indices.contains($0) ? groups[$0].pid : nil }
        groups = updated
        launchables = DockAppsProvider.launchables(excluding: running)

        if !removedPIDs.isEmpty {
            // 与 `prunePIDFromVisibleAutoHideGroups` 同一口径修 hover / 托盘 / 选中窗
            if let hoveredPIDNow, !removedPIDs.contains(hoveredPIDNow),
               let newIndex = groups.firstIndex(where: { $0.pid == hoveredPIDNow }) {
                hoveredAppIndex = newIndex
                let windowCount = groups[newIndex].windows.count
                selectedWindowIndex = min(selectedWindowIndex, max(0, windowCount - 1))
                if trayPanel?.isVisible == true {
                    updateTray(for: newIndex, on: currentScreen)
                }
            } else if hoveredPIDNow != nil {
                hoveredAppIndex = nil
                selectedWindowIndex = 0
                isSideChipStackExpanded = false
                hideTray()
            }
            layoutAndShowStrip(on: currentScreen)
        } else {
            // PID 集合没变、只有窗口数变了 ⇒ 只换槽里的 group，**不碰窗框**（一个像素都不挪）✓
            refreshRunningSlotGroups()
        }
    }

    func dismiss(reason: String, instantTrayHide: Bool = false) {
        guard isVisible else { return }
        // 常驻条带**不可被 dismiss 收走**（ADR-0018 方案 A 的硬约束）：常驻态下外面那些
        // 「互斥/配置变更」调用一律降级为「只收托盘」，条带原地不动。
        // 真要关掉常驻必须走 `setAlwaysOnMode(false)` ✓
        if isShowingPersistentStrip {
            if isTraceEnabled { glog("[Dock] 常驻态 dismiss 降级为仅收托盘: \(reason)") }
            dismissTrayOnly(reason: reason)
            return
        }
        if isTraceEnabled { glog("[Dock] 收起: \(reason)") }
        isVisible = false
        openGeneration &+= 1
        let dismissGen = openGeneration

        openFallbackWork?.cancel()
        openFallbackWork = nil
        liveCaptureDebounceWork?.cancel()
        liveCaptureDebounceWork = nil
        if !instantTrayHide {
            LivePreviewPool.shared.stopAll(reason: "程序坞关闭")
        }
        stopHoverPolling()
        stopClickGateTimer()
        removeMonitors()
        stopStripAnimation()
        stopTrayAnimation()

        // 退场动画期间立即释放事件穿透，不挡用户后续点击
        stripPanel?.ignoresMouseEvents = true
        trayPanel?.ignoresMouseEvents = true

        let savedPosition = position
        let savedStripSize = stripContentSize
        let hadTrayVisible = !instantTrayHide
            && (trayPanel?.isVisible == true)
            && ((trayPanel?.alphaValue ?? 0) > 0.01)
        let trayStartAlpha = trayPanel?.alphaValue ?? 0
        let hadStripVisible = (stripPanel?.isVisible == true) && ((stripPanel?.alphaValue ?? 0) > 0.01)

        // 退场动画期间冻结视觉 @Published 状态，避免第 0 帧触发全体图标弹簧落位与托盘闪空
        currentStripContentRect = nil
        currentTrayContentRect = nil
        activeScreen = nil
        activeDisplayID = nil

        onDidDismiss?()

        let finalizeHide: () -> Void = { [weak self] in
            guard let self, self.openGeneration == dismissGen else { return }
            self.isExitingStrip = false
            self.trayPanel?.alphaValue = 0
            self.trayPanel?.orderOut(nil)
            self.trayPanel?.ignoresMouseEvents = true
            self.stripPanel?.alphaValue = 0
            self.stripPanel?.orderOut(nil)
            self.stripPanel?.ignoresMouseEvents = true
            self.hoveredAppIndex = nil
            self.hoveredLaunchIndex = nil
            self.hoveredTailToggle = false
            self.selectedWindowIndex = 0
            self.isSideChipStackExpanded = false
            self.showingLaunchSegment = false
            self.resetDiagonalGuard()
            self.trayContentSize = .zero
            self.groups = []
            // 渲染槽一并清空（否则退场后还提着一位幽灵槽的 group）
            self.syncRunningSlotsImmediately()
            self.glassEpoch &+= 1
            self.scheduleCacheRefreshSoon(markDirty: false)
        }

        guard hadStripVisible, let panel = stripPanel else {
            finalizeHide()
            return
        }

        if !hadTrayVisible {
            trayPanel?.alphaValue = 0
            trayPanel?.orderOut(nil)
            trayPanel?.ignoresMouseEvents = true
        }

        let startFrame = panel.frame
        let exitFrame = offEdgeFrame(
            for: startFrame,
            contentSize: savedStripSize,
            position: savedPosition
        )
        animateStrip(
            from: startFrame,
            to: exitFrame,
            fromAlpha: panel.alphaValue,
            toAlpha: 0,
            duration: instantTrayHide ? 0.11 : 0.16,
            entering: false,
            trayFadeOutFromAlpha: hadTrayVisible ? trayStartAlpha : nil,
            trayFadeOutDuration: 0.10,
            generation: dismissGen,
            completion: finalizeHide
        )
    }

    // MARK: - 常驻模式（ADR-0018 方案 A：悬浮常驻 + 全屏自动避让）

    /// 开关常驻模式。
    ///
    /// - Parameters:
    ///   - enabled: `true` = 常驻（条带停在屏边）；`false` = 回到自动隐藏（老行为）。
    ///   - preferredDisplayID: 想停在哪个屏；不传则依次回退「上次常驻屏 → 鼠标所在屏 → `NSScreen.main`」。
    ///
    /// 两种运行态在这里切换，**窗口层级/collectionBehavior/定时器策略**全部跟着 `isShowingPersistentStrip` 走
    /// （详见 `applyPanelChrome()` 与 `installAlwaysOnNearFieldMonitors()`）。
    func setAlwaysOnMode(_ enabled: Bool, preferredDisplayID: CGDirectDisplayID? = nil) {
        if enabled {
            activateAlwaysOn(preferredDisplayID: preferredDisplayID)
        } else {
            deactivateAlwaysOn()
        }
    }

    /// 把常驻条带换到另一块屏（贴边在其他屏驻留时由上层调用）。
    func moveAlwaysOn(to displayID: CGDirectDisplayID) {
        guard isAlwaysOnActive else { return }

        // 特例：本屏正在全屏避让 ⇒ 走既有 `open(on:)` 临时浮出（鼠标贴边唤起），
        // 离开后照常收起并回到「全屏隐藏」态 ✓
        if displayID == alwaysOnDisplayID, isHiddenForFullscreen {
            open(on: displayID)
            return
        }
        if displayID == alwaysOnDisplayID, isShowingPersistentStrip { return }
        guard let screen = Self.screen(for: displayID) else {
            glog("[Dock] 常驻换屏失败：未找到 displayID=\(displayID) 对应的 NSScreen")
            return
        }

        // 先把旧屏的临时交互（托盘 / hover / 未启动段）收干净，再原地换屏
        endAlwaysOnInteraction(exitLaunchSegment: true)
        alwaysOnRefreshWork?.cancel()
        alwaysOnRefreshWork = nil

        alwaysOnDisplayID = displayID
        activeScreen = screen
        activeDisplayID = displayID
        position = Keys.currentDockPosition
        glassEpoch &+= 1
        PanelScreen.update(screen)
        launchables = DockAppsProvider.launchables(excluding: DockAppsProvider.runningSet())

        if DockFullscreenProbe.isScreenInFullscreen(screen) {
            enterAlwaysOnFullscreenAvoidance()
            return
        }

        isHiddenForFullscreen = false
        isVisible = true
        hasRevealedInSession = true
        isExitingStrip = false
        installAlwaysOnNearFieldMonitors()
        installMonitors()
        applyPanelChrome()
        if let cachedGroups = freshGroupsByDisplay[displayID]?.groups, !cachedGroups.isEmpty {
            groups = mergeAlwaysOnStableOrder(fresh: cachedGroups, displayID: displayID)
        } else {
            groups = []
        }
        layoutAndShowStrip(on: screen)
        onAlwaysOnDisplayStateChanged?(displayID)
        // 换屏后新屏的未启动名单/候选可能完全不同 ⇒ 必须重扫 candidates，且不空等 0.25s 防抖（P2）
        startAlwaysOnRefresh(includeCandidates: true)
    }

    /// 位置 / 图标尺寸 / 预览倍率等布局参数变更后调用：**原地**重算常驻条带，绝不把它收走。
    func reloadAlwaysOnLayoutIfNeeded() {
        guard isShowingPersistentStrip else { return }
        position = Keys.currentDockPosition
        endAlwaysOnInteraction(exitLaunchSegment: false)
        guard let screen = activeScreen
            ?? alwaysOnDisplayID.flatMap({ Self.screen(for: $0) })
            ?? NSScreen.main else { return }
        activeScreen = screen
        isVisible = true
        hasRevealedInSession = true
        relayoutAlwaysOnStripInPlace()
        refreshAlwaysOnGroupsSoon()
    }

    /// 只收托盘：退出未启动段、清 hover、停 60Hz 轮询与点击门，**常驻条带原样留在屏上**。
    ///
    /// 用途：⌘Tab / 三指切换器唤起时的互斥 —— 常驻条带不该跟着消失（方案 A 的硬约束）。
    func dismissTrayOnly(reason: String) {
        if isTraceEnabled { glog("[Dock] 仅收起托盘: \(reason)") }
        let persistent = isShowingPersistentStrip

        alwaysOnLeaveStartedAt = nil
        // 自动隐藏模式不走这里；万一上层误调，也**不能**把它的 60Hz hover 轮询停掉
        // （停掉就再也悬停不出来了，属于回归）。只有常驻态才退回 0Hz 空闲 ✓
        if persistent {
            stopHoverPolling()
            stopClickGateTimer()
        }
        hideTray()
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        resetDiagonalGuard()
        if showingLaunchSegment {
            showingLaunchSegment = false
        }

        // 暂存的名单在这一刻落地（交互已结束，可以重排了）
        if let pending = pendingAlwaysOnGroups {
            pendingAlwaysOnGroups = nil
            let pendingLaunchables = pendingAlwaysOnLaunchables
            pendingAlwaysOnLaunchables = nil
            // 真增删 ⇒ 演弹簧伸缩（此时 hover / 未启动段已经收干净，命中判据与新名单一致 ✓）
            transitionAlwaysOnGroups(to: pending, launchables: pendingLaunchables)
        } else if let pendingLaunchables = pendingAlwaysOnLaunchables {
            pendingAlwaysOnLaunchables = nil
            launchables = pendingLaunchables
        }

        if persistent { relayoutAlwaysOnStripInPlace() }
    }

    // MARK: 常驻模式 · 内部实现

    private func activateAlwaysOn(preferredDisplayID: CGDirectDisplayID?) {
        guard let resolved = Self.resolveScreenAndDisplayID(
            preferred: preferredDisplayID ?? alwaysOnDisplayID
        ) else {
            glog("[Dock] 常驻模式开启失败：未找到可用屏幕")
            return
        }
        let screen = resolved.screen
        let displayID = resolved.displayID

        if isAlwaysOnActive {
            // 已经开着：换屏走 moveAlwaysOn，同屏只做「重读配置 + 重评全屏 + 原地重排」
            if displayID != alwaysOnDisplayID {
                moveAlwaysOn(to: displayID)
                return
            }
            position = Keys.currentDockPosition
            evaluateAlwaysOnFullscreen()
            if isShowingPersistentStrip {
                relayoutAlwaysOnStripInPlace()
                refreshAlwaysOnGroupsSoon(includeCandidates: true)
                onAlwaysOnDisplayStateChanged?(displayID)
            } else {
                onAlwaysOnDisplayStateChanged?(nil)
            }
            return
        }

        // 接管前先结束可能正在进行的自动隐藏会话（不播退场动画，直接换层级原地接管）
        stopStripAnimation()
        stopTrayAnimation()
        openFallbackWork?.cancel()
        openFallbackWork = nil
        removeMonitors()
        hideTray()
        stopHoverPolling()
        stopClickGateTimer()
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        showingLaunchSegment = false
        resetDiagonalGuard()
        openGeneration &+= 1

        isAlwaysOnActive = true
        alwaysOnDisplayID = displayID
        activeScreen = screen
        activeDisplayID = displayID
        position = Keys.currentDockPosition
        alwaysOnLeaveStartedAt = nil
        pendingAlwaysOnGroups = nil
        pendingAlwaysOnLaunchables = nil
        alwaysOnNeedsCandidatesRefresh = false
        glassEpoch &+= 1
        PanelScreen.update(screen)

        launchables = DockAppsProvider.launchables(excluding: DockAppsProvider.runningSet())
        // 只用**本屏**的缓存开局（绝不把别的屏的名单先摆上去，也不能拿旧名单充数）；
        // 缓存缺失就先空着，紧接着的后台枚举很快就到 ✓
        // 缓存有料时走稳定槽位合并：换屏回来 / 重开常驻都不应该让图标挪位 ✓
        if let cachedGroups = freshGroupsByDisplay[displayID]?.groups, !cachedGroups.isEmpty {
            groups = mergeAlwaysOnStableOrder(fresh: cachedGroups, displayID: displayID)
        } else {
            groups = []
        }

        if DockFullscreenProbe.isScreenInFullscreen(screen) {
            // 全屏：静默避让（不闪、不播动画），并放开该屏的贴边临时唤起
            enterAlwaysOnFullscreenAvoidance()
            return
        }

        isHiddenForFullscreen = false
        isVisible = true
        hasRevealedInSession = true
        isExitingStrip = false
        installAlwaysOnNearFieldMonitors()
        installMonitors()
        applyPanelChrome()
        layoutAndShowStrip(on: screen)
        onAlwaysOnDisplayStateChanged?(displayID)
        // 开局就要真实名单：直接起后台枚举（不走 0.25s 防抖，避免首屏「无本屏窗口」空一下）
        startAlwaysOnRefresh(includeCandidates: true)
    }

    private func deactivateAlwaysOn() {
        guard isAlwaysOnActive || alwaysOnDisplayID != nil || isHiddenForFullscreen else { return }

        windowReserveGuard.disable()
        // 保留 alwaysOnStableOrderByDisplay：切回自动隐藏再重新打开常驻时图标也不挪位；
        // 已经退出的 PID 会被 mergeStableOrder 按 fresh 集合自然淘汰 ✓
        alwaysOnLeaveStartedAt = nil
        alwaysOnRefreshWork?.cancel()
        alwaysOnRefreshWork = nil
        alwaysOnEvaluateWork?.cancel()
        alwaysOnEvaluateWork = nil
        pendingAlwaysOnGroups = nil
        pendingAlwaysOnLaunchables = nil
        alwaysOnNeedsCandidatesRefresh = false
        removeAlwaysOnNearFieldMonitors()
        stopHoverPolling()
        stopClickGateTimer()
        openFallbackWork?.cancel()
        openFallbackWork = nil
        openGeneration &+= 1

        isAlwaysOnActive = false
        isHiddenForFullscreen = false
        alwaysOnDisplayID = nil
        removeMonitors()
        hideTray()
        hidePanelsImmediately()
        isVisible = false
        activeScreen = nil
        activeDisplayID = nil
        currentStripContentRect = nil
        groups = []
        syncRunningSlotsImmediately()
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        showingLaunchSegment = false
        hasRevealedInSession = false
        isEnteringStrip = false
        isExitingStrip = false
        glassEpoch &+= 1
        applyPanelChrome()
        scheduleCacheRefreshSoon(markDirty: false)
        onAlwaysOnDisplayStateChanged?(nil)
    }

    /// 把「上一轮的槽位顺序」与「这一轮扫到的集合」合并成**不跳变**的常驻顺序。
    ///
    /// 常驻条带每隔几秒就可能刷新一次（激活 App / 换屏 / 启退通知都能触发）——
    /// 每次都按新扫描结果重排，用户会看到图标自己挪位置 ✗。规则：**老的相对顺序尽量留着，
    /// 退出的移除，新开的追加到末尾**（纯函数在核里：`DockAlwaysOnPolicy.mergeStableOrder` ✓）。
    ///
    /// - Parameter fallbackBase: 优先用它当「上一轮」（交互期间 `groups` 可能已局部更新）；
    ///   为空时用按屏记的 `alwaysOnStableOrderByDisplay` ✓
    private func mergeAlwaysOnStableOrder(
        fresh: [AppGroup],
        displayID: CGDirectDisplayID,
        fallbackBase: [AppGroup]? = nil
    ) -> [AppGroup] {
        var existingPIDs: [pid_t] = []
        if let fallbackBase, !fallbackBase.isEmpty {
            existingPIDs = fallbackBase.map(\.pid)
        } else if let stored = alwaysOnStableOrderByDisplay[displayID], !stored.isEmpty {
            existingPIDs = stored
        }

        let orderedPIDs = DockAlwaysOnPolicy.mergeStableOrder(
            existingIDs: existingPIDs,
            freshIDs: fresh.map(\.pid)
        )

        // 按稳定槽位从**这一轮**的 fresh 里取（确保 windows / metadata 都是最新的，只有位置稳定）✓
        var byPID: [pid_t: AppGroup] = [:]
        byPID.reserveCapacity(fresh.count)
        for group in fresh where byPID[group.pid] == nil {
            byPID[group.pid] = group
        }
        let merged = orderedPIDs.compactMap { byPID[$0] }

        // 空名单（枚举暂时没料）不覆盖旧槽位，避免下一次扫描从零开始又跳一遍 ✓
        if !merged.isEmpty {
            alwaysOnStableOrderByDisplay[displayID] = merged.map(\.pid)
        }
        return merged
    }

    /// 后台刷来的新名单落地；交互期间只暂存（防鼠标底下重排），空闲时直接换。
    private func applyAlwaysOnGroups(
        _ ordered: [AppGroup],
        launchables newLaunchables: [DockAppsProvider.LaunchableApp]
    ) {
        guard isShowingPersistentStrip else { return }

        let interacting = isInAlwaysOnInteraction
        if interacting {
            // 交互期间同样走稳定顺序：以「暂存名单（没就当前名单）」为基准合并，
            // 存进 pending 等交互结束才落地（防鼠标底下重排）✓
            let merged: [AppGroup]
            if let displayID = alwaysOnDisplayID {
                merged = mergeAlwaysOnStableOrder(
                    fresh: ordered,
                    displayID: displayID,
                    fallbackBase: pendingAlwaysOnGroups ?? groups
                )
            } else {
                merged = ordered
            }
            pendingAlwaysOnGroups = merged
            pendingAlwaysOnLaunchables = newLaunchables

            // 就地更新已存在 PID 的 windows（计数点实时跟上），**不动顺序**
            var updated = groups
            var byPID: [pid_t: AppGroup] = [:]
            for group in merged { byPID[group.pid] = group }
            var hoveredWindowsChanged = false
            for idx in updated.indices {
                guard let fresh = byPID[updated[idx].pid] else { continue }
                guard updated[idx].windows.count != fresh.windows.count
                    || updated[idx].windows.map(\.wid) != fresh.windows.map(\.wid) else { continue }
                if idx == hoveredAppIndex { hoveredWindowsChanged = true }
                updated[idx].windows = fresh.windows
            }
            if updated.map(\.windows).map({ $0.map(\.wid) }) != groups.map(\.windows).map({ $0.map(\.wid) }) {
                groups = updated
                // 只窗口增减（PID 集合与顺序都没动）⇒ 槽位原地换 group：计数点跟上，
                // 外框与 progress 一个像素都不动（演不得弹簧，这是「同一批 App」的事）✓
                refreshRunningSlotGroups()
            }
            if hoveredWindowsChanged, let idx = hoveredAppIndex, let screen = activeScreen {
                updateTray(for: idx, on: screen)
            }
            return
        }

        pendingAlwaysOnGroups = nil
        pendingAlwaysOnLaunchables = nil

        // 替换名单前先记下 hover 的 **PID**：稳定顺序下同一个下标可能换成别的 App，
        // 只有 PID 能跟着走 ✓（悬停的那格不该因为我们重排而变样 ✗）
        let hoveredPID: pid_t? = hoveredAppIndex.flatMap {
            groups.indices.contains($0) ? groups[$0].pid : nil
        }
        let resolvedGroups: [AppGroup]
        if let displayID = alwaysOnDisplayID {
            resolvedGroups = mergeAlwaysOnStableOrder(fresh: ordered, displayID: displayID, fallbackBase: groups)
        } else {
            resolvedGroups = ordered
        }
        // ★ 唯一落地点：真增删 App 时演弹簧伸缩；其余（纯 windows 变化 / 顺序没动）就地同步，不演 ✓
        transitionAlwaysOnGroups(to: resolvedGroups, launchables: newLaunchables)
        if let hoveredPID {
            if let newIndex = groups.firstIndex(where: { $0.pid == hoveredPID }) {
                hoveredAppIndex = newIndex
                selectedWindowIndex = min(selectedWindowIndex, max(0, groups[newIndex].windows.count - 1))
                if trayPanel?.isVisible == true, let screen = activeScreen {
                    updateTray(for: newIndex, on: screen)
                }
            } else {
                // 悬停的那个 App 已经不在名单里（退出 / 隐藏）⇒ 安全复位
                hoveredAppIndex = nil
                selectedWindowIndex = 0
                isSideChipStackExpanded = false
                hideTray()
            }
        } else if hoveredAppIndex != nil {
            // 原本有 hover 但下标已越界 ⇒ 同样复位
            hoveredAppIndex = nil
            selectedWindowIndex = 0
            isSideChipStackExpanded = false
            hideTray()
        }
        relayoutAlwaysOnStripInPlace()
    }

    /// terminate / hide：立即从常驻名单里剪掉该 PID 并原地重排（hover 失效则安全重置）。
    private func prunePIDFromAlwaysOnGroups(_ pid: pid_t) {
        pendingAlwaysOnGroups?.removeAll { $0.pid == pid }
        guard groups.contains(where: { $0.pid == pid }) else { return }

        let hoveredPID: pid_t? = hoveredAppIndex.flatMap { groups.indices.contains($0) ? groups[$0].pid : nil }
        var remaining = groups
        remaining.removeAll { $0.pid == pid }
        transitionAlwaysOnGroups(to: remaining)
        // 稳定槽位顺序同步剪掉，否则它会在下一次合并里“诈尸”般地占一个空位置 ✓
        if let displayID = alwaysOnDisplayID {
            alwaysOnStableOrderByDisplay[displayID]?.removeAll { $0 == pid }
        }

        if let hoveredPID, hoveredPID != pid, let newIndex = groups.firstIndex(where: { $0.pid == hoveredPID }) {
            hoveredAppIndex = newIndex
            let windowCount = groups[newIndex].windows.count
            selectedWindowIndex = min(selectedWindowIndex, max(0, windowCount - 1))
            if trayPanel?.isVisible == true, let screen = activeScreen {
                updateTray(for: newIndex, on: screen)
            }
        } else if hoveredPID != nil {
            hoveredAppIndex = nil
            selectedWindowIndex = 0
            isSideChipStackExpanded = false
            hideTray()
        }

        if isShowingPersistentStrip { relayoutAlwaysOnStripInPlace() }
    }

    private func relayoutAlwaysOnStripInPlace() {
        guard isShowingPersistentStrip, isVisible, !isExitingStrip, !isEnteringStrip else { return }
        guard let screen = activeScreen
            ?? alwaysOnDisplayID.flatMap({ Self.screen(for: $0) })
            ?? NSScreen.main else { return }
        activeScreen = screen
        if activeDisplayID == nil { activeDisplayID = alwaysOnDisplayID }
        hasRevealedInSession = true
        applyPanelChrome()
        layoutAndShowStrip(on: screen)
    }

    // MARK: 常驻条带 · App 加入/退出的丝滑伸缩

    /// 把渲染槽**立即**同步为 `groups`（全员 progress = 1、无幽灵槽），并取消在途 morph。
    ///
    /// 首屏开局 / 换屏 / 全屏进入退出 / 关常驻 / 未启动段 / dismiss 一律走这条 ——
    /// 动画只留给「常驻条带已经稳稳在屏上」的增删（见 `shouldAnimateAlwaysOnGroupChange`）✓
    private func syncRunningSlotsImmediately() {
        stripMorphStartWork?.cancel()
        stripMorphStartWork = nil
        stripMorphFinishWork?.cancel()
        stripMorphFinishWork = nil
        stripMorphTargetWindowFrame = nil
        stripMorphGeneration &+= 1
        runningSlots = groups.map {
            RunningStripSlot(pid: $0.pid, group: $0, isExiting: false, progress: 1)
        }
    }

    /// 只有 `group.windows` 变了（PID 集合与顺序都没动）⇒ 原地换掉槽里的 group，
    /// **不碰** progress、不碰外框（计数点实时跟上，图标一个像素都不挪）✓
    private func refreshRunningSlotGroups() {
        guard !runningSlots.isEmpty else { return }
        var byPID: [pid_t: AppGroup] = [:]
        for group in groups { byPID[group.pid] = group }
        var slots = runningSlots
        for idx in slots.indices {
            if let group = byPID[slots[idx].pid] { slots[idx].group = group }
        }
        runningSlots = slots
    }

    /// 这一次名单替换该不该演弹簧？
    ///
    /// 只给「常驻条带已经稳稳在屏上」的增删演。首屏开局 / 换屏 / 全屏避让 / 关闭常驻 / 未启动段
    /// 都有自己整块滑入滑出的动画，再叠一层伸缩只会互相打架 ⇒ 一律走 `syncRunningSlotsImmediately` ✓
    private func shouldAnimateAlwaysOnGroupChange(from old: [AppGroup], to new: [AppGroup]) -> Bool {
        guard isShowingPersistentStrip, isVisible, hasRevealedInSession,
              !showingLaunchSegment, !isEnteringStrip, !isExitingStrip else { return false }
        // 空态 ↔ 有项：玻璃壳该整块长 / 缩（老行为，零风险），不拉幽灵槽
        guard !old.isEmpty, !new.isEmpty else { return false }
        return old.map(\.pid) != new.map(\.pid)
    }

    /// 两个窗框是否「同一个」（包络判定用；亚像素差异不算变化）
    private static func frameIsClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    /// **常驻名单替换的唯一入口**（`applyAlwaysOnGroups` / `prunePIDFromAlwaysOnGroups` / 暂存落地 都走这里）。
    ///
    /// 增删 App 时演「玻璃壳与图标列同步弹簧伸缩」：
    ///   · 退出的 App 留在**原槽位**收拢（progress 1 → 0），收完才从槽位表里删；
    ///   · 新加入的 App 在目标槽位上从 0 长到 1；
    ///   · 外框**不逐帧 setFrame**（那会抖、还会把退出图标的投影裁掉）：先撑成「新旧目标的包络窗框」，
    ///     动画期间窗框一行代码不动，收尾那一刻再静默收紧到目标框（`display: false`，0 像素跳动）✓
    ///   · 绝不改 `glassEpoch`（macOS 26 的 `.glassEffect` 会整块重建 ⇒ 闪一下 ✗）
    private func transitionAlwaysOnGroups(
        to newGroups: [AppGroup],
        launchables newLaunchables: [DockAppsProvider.LaunchableApp]? = nil
    ) {
        let oldGroups = groups
        guard shouldAnimateAlwaysOnGroupChange(from: oldGroups, to: newGroups) else {
            groups = newGroups
            if let newLaunchables { launchables = newLaunchables }
            syncRunningSlotsImmediately()
            return
        }

        // a) 起点快照（槽位表空则按老名单补一份全员展开的）
        let oldSlots: [RunningStripSlot] = runningSlots.isEmpty
            ? oldGroups.map { RunningStripSlot(pid: $0.pid, group: $0, isExiting: false, progress: 1) }
            : runningSlots
        let oldPIDs = Set(oldSlots.map(\.pid))
        let oldWindowFrame = stripPanel?.frame

        // b) 业务名单先落地（hover / 命中 / 托盘立刻按新名单算），并作废在途 morph
        groups = newGroups
        if let newLaunchables { launchables = newLaunchables }
        stripMorphGeneration &+= 1
        let morphGen = stripMorphGeneration
        stripMorphStartWork?.cancel()
        stripMorphStartWork = nil
        stripMorphFinishWork?.cancel()
        stripMorphFinishWork = nil
        stripMorphTargetWindowFrame = nil

        guard let screen = activeScreen
            ?? alwaysOnDisplayID.flatMap({ Self.screen(for: $0) })
            ?? NSScreen.main,
            let panel = stripPanel else {
            syncRunningSlotsImmediately()
            return
        }
        activeScreen = screen

        // c) 目标布局（与 `layoutAndShowStrip` 同一口径：改一处必须改两处）
        let targetItemCount = newGroups.count
        let hasToggle = showsTailToggleButton
        let targetMetrics = DockMetrics.fitted(
            visibleSize: screen.visibleFrame.size,
            position: position,
            itemCount: targetItemCount,
            hasToggle: hasToggle,
            trayWindows: activeHoveredGroup?.windows ?? [],
            layout: WindowLayout.current,
            sideStackExpanded: isSideChipStackExpanded
        )
        let targetContentSize = targetMetrics.stripContentSize(
            itemCount: targetItemCount,
            position: position,
            hasToggle: hasToggle
        )
        let targetContentRect = DockLayoutGeometry.stripContentRect(
            contentSize: targetContentSize,
            position: position,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let targetWindowFrame = targetContentRect.insetBy(
            dx: -targetMetrics.shadowPadStrip,
            dy: -targetMetrics.shadowPadStrip
        )

        // d) 包络窗框：把新旧窗框一起包住（退出图标的收拢轨迹与投影都不会被窗框切掉），
        //    外侧那条边**严格钉死**在目标边（bottom⇒下 / left⇒左 / right⇒右），另一轴按目标居中 ✓
        let oldFrame = oldWindowFrame ?? targetWindowFrame
        let envW = max(oldFrame.width, targetWindowFrame.width)
        let envH = max(oldFrame.height, targetWindowFrame.height)
        let envelopeFrame: CGRect
        switch position {
        case .bottom:
            envelopeFrame = CGRect(
                x: targetWindowFrame.midX - envW / 2,
                y: targetWindowFrame.minY,
                width: envW,
                height: envH
            )
        case .left:
            envelopeFrame = CGRect(
                x: targetWindowFrame.minX,
                y: targetWindowFrame.midY - envH / 2,
                width: envW,
                height: envH
            )
        case .right:
            envelopeFrame = CGRect(
                x: targetWindowFrame.maxX - envW,
                y: targetWindowFrame.midY - envH / 2,
                width: envW,
                height: envH
            )
        }
        metrics = targetMetrics
        stripHostingView?.pad = targetMetrics.shadowPadStrip
        stripMorphTargetWindowFrame = targetWindowFrame
        panel.setFrame(envelopeFrame, display: true)   // 透明外圈无感知
        panel.orderFrontRegardless()
        currentStripContentRect = targetContentRect
        syncPanelMousePassthrough()
        syncWindowReserveGuard()

        // e) 第 0 帧：老槽位原样留在老位置；新 App 在目标槽位上 progress = 0；退出的打上 isExiting
        var slotsByPID: [pid_t: RunningStripSlot] = [:]
        for slot in oldSlots { slotsByPID[slot.pid] = slot }
        let newPIDs = Set(newGroups.map(\.pid))
        var initialSlots: [RunningStripSlot] = newGroups.map { group in
            if var kept = slotsByPID[group.pid] {
                // 正在退场的 PID 又重新出现（刚关的窗又开了）⇒ 取消退出标记，接着长回原位 ✓
                kept.group = group
                kept.isExiting = false
                return kept
            }
            return RunningStripSlot(pid: group.pid, group: group, isExiting: false, progress: 0)
        }
        for (oldIndex, slot) in oldSlots.enumerated() where !newPIDs.contains(slot.pid) {
            var ghost = slot
            ghost.isExiting = true   // progress 保留当前值（通常 1）⇒ 从现在的姿态开始收，不跳
            initialSlots.insert(ghost, at: min(oldIndex, initialSlots.count))
        }
        // 此刻 `stripContentSize` **故意保持旧值**：它要和下一拍的槽位一起动（否则玻璃壳先跳一下 ✗）
        runningSlots = initialSlots

        // f) 目标帧：与第 0 帧**同元素顺序**，只把 progress 改到终点（幽灵槽收到 0）
        let animatedSlots = initialSlots.map { slot -> RunningStripSlot in
            var out = slot
            out.progress = slot.isExiting ? 0 : 1
            return out
        }

        // g) 跨过 SwiftUI 的首次提交再起跑（同一拍里连改两次 @Published，SwiftUI 只看最后一帧 ✗）
        let hasNewcomer = newGroups.contains { !oldPIDs.contains($0.pid) }
        let spring: Animation = hasNewcomer
            ? .spring(response: 0.30, dampingFraction: 0.78)   // 有新 App 长出来：稍微带点弹
            : .spring(response: 0.24, dampingFraction: 0.88)   // 纯退出：干脆收拢，别晃
        let startWork = DispatchWorkItem { [weak self] in
            guard let self, morphGen == self.stripMorphGeneration else { return }
            let anim = MotionPolicy.animation(spring, reduced: 0.16)
            withAnimation(anim) {
                self.stripContentSize = targetContentSize
                self.runningSlots = animatedSlots
            }
        }
        stripMorphStartWork = startWork
        DispatchQueue.main.async(execute: startWork)

        // h) 收尾：幽灵槽此刻 progress = 0 / opacity = 0，删掉是 0 视觉变化；窗框静默收紧到目标框
        let finishWork = DispatchWorkItem { [weak self] in
            guard let self, morphGen == self.stripMorphGeneration else { return }
            self.stripMorphFinishWork = nil
            self.runningSlots = self.runningSlots.filter { !$0.isExiting }
            if let finalFrame = self.stripMorphTargetWindowFrame {
                self.stripPanel?.setFrame(finalFrame, display: false)
            }
            self.stripMorphTargetWindowFrame = nil
        }
        stripMorphFinishWork = finishWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: finishWork)
    }

    /// 常驻态「正在交互」（托盘 / 未启动段 / 60Hz 轮询 / **指针正压在条带内容区内**）。
    /// 此时后台名单只暂存不落地。
    ///
    /// 最后一条是 P1 的修复：点完图标后指针恰好停在原来那枚图标的位置，名单一重排，
    /// 屏上的图标就在鼠标底下换位（刚点过的那格突然变成别的 App）✗
    private var isInAlwaysOnInteraction: Bool {
        hoverPollTimer != nil
            || trayPanel?.isVisible == true
            || showingLaunchSegment
            || (currentStripContentRect?.contains(NSEvent.mouseLocation) ?? false)
    }

    // MARK: 常驻模式 · 全屏避让

    /// 某块屏被全屏应用占着吗？—— 常驻条带据此让位（方案 A 的核心约束）。
    private func evaluateAlwaysOnFullscreen() {
        guard isAlwaysOnActive else { return }
        guard let displayID = alwaysOnDisplayID,
              let screen = Self.screen(for: displayID) ?? activeScreen else { return }

        let inFullscreen = DockFullscreenProbe.isScreenInFullscreen(screen)
        if inFullscreen {
            if !isHiddenForFullscreen && isShowingPersistentStrip {
                enterAlwaysOnFullscreenAvoidance()
            }
        } else if isHiddenForFullscreen {
            restoreAlwaysOnStrip(on: screen)
        }
    }

    /// 全屏态变化事件来得密（激活 / 切空间 / 启动），合并到一次探针。
    private func scheduleAlwaysOnFullscreenEvaluation(delay: Double = 0.10) {
        guard isAlwaysOnActive else { return }
        alwaysOnEvaluateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.alwaysOnEvaluateWork = nil
            self.evaluateAlwaysOnFullscreen()
        }
        alwaysOnEvaluateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: 常驻模式 · 窗口边界避让（方案 1A）

    /// 当前常驻条带在 `screen` 上**占住的厚度**（含 4pt 余量，单位 pt）。
    ///
    /// 优先用已算出的内容区（真实布局）；布局还没跑过时用 `stripContentSize` + `edgeMargin` 推一份，
    /// 宁可多留 16pt 也不要把窗口放进条带底下 ✓
    /// 坐标一律 AppKit（`screen.frame` 与 `currentStripContentRect` 同系）✓
    private func currentAlwaysOnReservedThickness(on screen: NSScreen) -> CGFloat {
        let stripRect: CGRect
        if let current = currentStripContentRect {
            stripRect = current
        } else {
            stripRect = DockLayoutGeometry.stripContentRect(
                contentSize: stripContentSize,
                position: position,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }

        switch position {
        case .bottom:
            return max(0, stripRect.maxY - screen.frame.minY) + Self.reservedGap
        case .left:
            return max(0, stripRect.maxX - screen.frame.minX) + Self.reservedGap
        case .right:
            return max(0, screen.frame.maxX - stripRect.minX) + Self.reservedGap
        }
    }

    /// 把当前常驻状态同步给避让守卫：只有「条带真的在屏上」才装，否则立即全拆（不留空边）✓
    private func syncWindowReserveGuard() {
        guard isShowingPersistentStrip,
              isVisible,
              let displayID = alwaysOnDisplayID,
              let screen = Self.screen(for: displayID) else {
            windowReserveGuard.disable()
            return
        }
        let thickness = currentAlwaysOnReservedThickness(on: screen)
        guard thickness > 0 else {
            windowReserveGuard.disable()
            return
        }
        windowReserveGuard.update(target: DockWindowReserveGuard.Target(
            displayID: displayID,
            screenFrameQuartz: WindowEnumerator.quartzFrame(of: screen),
            visibleFrameQuartz: WindowEnumerator.quartzVisibleFrame(of: screen),
            position: position,
            reservedThickness: thickness
        ))
    }

    /// 目标屏扣除常驻程序坞占位后的 **Quartz 可用可见区**；
    /// 仅当常驻条带此刻正显示在该屏上时返回非 nil（其余一律 `nil`：零副作用、不留空边）✓
    ///
    /// 调用方（App 层）用它把「送到某块屏 / 撑满某块屏」的目标矩形让出条带那一条带子。
    func reservedQuartzVisibleFrame(for screen: NSScreen) -> CGRect? {
        guard isShowingPersistentStrip,
              let hostDisplayID = alwaysOnDisplayID,
              Self.displayID(of: screen) == hostDisplayID else { return nil }
        let thickness = currentAlwaysOnReservedThickness(on: screen)
        guard thickness > 0 else { return nil }
        return DockAlwaysOnPolicy.usableFrame(
            visibleFrame: WindowEnumerator.quartzVisibleFrame(of: screen),
            screenFrame: WindowEnumerator.quartzFrame(of: screen),
            position: position,
            reservedThickness: thickness
        )
    }

    /// 进入全屏避让：静默收条带（常驻模式仍然开着，`alwaysOnDisplayID` 不清）。
    private func enterAlwaysOnFullscreenAvoidance() {
        // 全屏了就不再避让任何窗口（用户要的是「只看这一个」）⇒ 立刻整条卸载 ✓
        windowReserveGuard.disable()
        // 先置隐藏态，`endAlwaysOnInteraction` 里的原地重排才不会把条带又摆出来
        isHiddenForFullscreen = true
        endAlwaysOnInteraction(exitLaunchSegment: true)
        openFallbackWork?.cancel()
        openFallbackWork = nil
        openGeneration &+= 1

        isVisible = false
        activeScreen = nil
        activeDisplayID = nil
        currentStripContentRect = nil
        groups = []
        // 全屏避让是静默收起：渲染槽同步清空，绝不能留个幽灵槽让下次回来先长一下 ✗
        syncRunningSlotsImmediately()
        hasRevealedInSession = false
        removeAlwaysOnNearFieldMonitors()
        removeMonitors()
        hidePanelsImmediately()
        applyPanelChrome()
        // 该屏恢复贴边临时唤起能力（条带不在屏上了，不该再豁免）
        onAlwaysOnDisplayStateChanged?(nil)
    }

    /// 退出全屏：回到常驻条带（若此刻正好是贴边临时唤起，原地转成常驻，不闪一下）。
    private func restoreAlwaysOnStrip(on screen: NSScreen) {
        guard isAlwaysOnActive else { return }
        let resolvedDisplayID = alwaysOnDisplayID ?? Self.displayID(of: screen)
        alwaysOnDisplayID = resolvedDisplayID
        isHiddenForFullscreen = false
        activeScreen = screen
        activeDisplayID = resolvedDisplayID
        position = Keys.currentDockPosition
        alwaysOnLeaveStartedAt = nil
        installAlwaysOnNearFieldMonitors()
        installMonitors()
        // 退出全屏必须**先**把窗口层级 / collectionBehavior 切回常驻档：
        // 否则下面 `if isVisible` 那条提前退出会让条带停在「贴边临时唤起」档位上（P3）✗
        applyPanelChrome()

        if isVisible {
            // 全屏临时唤起的条带恰好开着 ⇒ 先收掉临时交互，再原地按常驻重排
            endAlwaysOnInteraction(exitLaunchSegment: true)
            onAlwaysOnDisplayStateChanged?(resolvedDisplayID)
            refreshAlwaysOnGroupsSoon()
            return
        }

        isVisible = true
        hasRevealedInSession = true
        glassEpoch &+= 1
        launchables = DockAppsProvider.launchables(excluding: DockAppsProvider.runningSet())
        if let resolvedDisplayID, let cached = freshGroupsByDisplay[resolvedDisplayID] {
            groups = mergeAlwaysOnStableOrder(fresh: cached.groups, displayID: resolvedDisplayID)
        }
        applyPanelChrome()
        layoutAndShowStrip(on: screen)
        onAlwaysOnDisplayStateChanged?(resolvedDisplayID)
        refreshAlwaysOnGroupsSoon()
    }

    /// 休眠/锁屏回来：重查屏幕与全屏态，把常驻条带接回来（`isAlwaysOnActive` 一直没关）。
    private func resyncAlwaysOnAfterWake() {
        guard isAlwaysOnActive else { return }
        guard let resolved = Self.resolveScreenAndDisplayID(preferred: alwaysOnDisplayID) else { return }
        let targetScreen = resolved.screen
        let targetDisplayID = resolved.displayID

        let displayChanged = targetDisplayID != alwaysOnDisplayID
        alwaysOnDisplayID = targetDisplayID
        activeScreen = targetScreen
        activeDisplayID = targetDisplayID

        if DockFullscreenProbe.isScreenInFullscreen(targetScreen) {
            if !isHiddenForFullscreen {
                enterAlwaysOnFullscreenAvoidance()
            } else if displayChanged {
                onAlwaysOnDisplayStateChanged?(nil)
            }
            return
        }
        if isHiddenForFullscreen {
            restoreAlwaysOnStrip(on: targetScreen)
            return
        }

        isVisible = true
        hasRevealedInSession = true
        installAlwaysOnNearFieldMonitors()
        if outsideLocalClickMonitor == nil { installMonitors() }
        relayoutAlwaysOnStripInPlace()
        refreshAlwaysOnGroupsSoon(includeCandidates: true)
        onAlwaysOnDisplayStateChanged?(targetDisplayID)
    }

    /// 屏参变化：常驻态只「重新解析目标屏 + 重评全屏 + 原地重排」，绝不 dismiss 掉常驻模式。
    private func handleAlwaysOnScreenParametersChanged() {
        guard isAlwaysOnActive else { return }
        // ★★ 2026-11-25 实机病例（拔掉外接屏回到单屏内建屏，窗口避让彻底失效）：
        //   旧写法 `screen = displayID.flatMap(screen(for:)) ?? NSScreen.main` 把 `screen` 兜成了内建屏，
        //   却跳过 `if screen == nil`，导致 `alwaysOnDisplayID` 永久残留已拔掉的外接屏死 ID ⇒
        //   `syncWindowReserveGuard` 查 `Self.screen(for: displayID) == nil` 直接 `disable()` 整条卸载 ✗
        //   ⇒ 统一走 `resolveScreenAndDisplayID` 保证 `screen` 与 `displayID` 永远成对一致 ✓
        guard let resolved = Self.resolveScreenAndDisplayID(preferred: alwaysOnDisplayID) else { return }
        let targetScreen = resolved.screen
        let targetDisplayID = resolved.displayID

        alwaysOnDisplayID = targetDisplayID
        activeScreen = targetScreen
        activeDisplayID = targetDisplayID
        position = Keys.currentDockPosition
        glassEpoch &+= 1
        PanelScreen.update(targetScreen)

        if isHiddenForFullscreen {
            // 全屏态可能已经变了（比如全屏 App 被拔掉的屏带走了）⇒ 重评一次，必要时由它恢复
            evaluateAlwaysOnFullscreen()
            return
        }

        isVisible = true
        hasRevealedInSession = true
        installAlwaysOnNearFieldMonitors()
        if outsideLocalClickMonitor == nil { installMonitors() }
        evaluateAlwaysOnFullscreen()
        // 重评后可能已转成全屏避让（它自己发过 `nil`）⇒ 这里不能再报 displayID，否则
        // `DockEdgeSensor.ignoredDisplayID` 会豁免一块根本没有条带的屏 ✗
        guard isShowingPersistentStrip else { return }
        relayoutAlwaysOnStripInPlace()
        refreshAlwaysOnGroupsSoon(includeCandidates: true)
        onAlwaysOnDisplayStateChanged?(targetDisplayID)
    }

    // MARK: 常驻模式 · 0Hz 空闲续航 + 交互收束

    /// 安装轻量「近场」指针监听（只判到边就唤醒 60Hz 轮询，空闲时 0 定时器）。
    ///
    /// 两个监听都是 **mouseMoved** 级量级：与 `DockEdgeSensor` 同一条纪律 ——
    /// 回调实测由主 run loop 派发，主线程直调 `assumeIsolated`，省掉每帧一个 `Task` 排队 ✓
    private func installAlwaysOnNearFieldMonitors() {
        guard alwaysOnMoveGlobalMonitor == nil, alwaysOnMoveLocalMonitor == nil else { return }

        alwaysOnMoveGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.handleAlwaysOnPointerMoved() }
            } else {
                Task { @MainActor [weak self] in self?.handleAlwaysOnPointerMoved() }
            }
        }

        alwaysOnMoveLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            if let self {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self.handleAlwaysOnPointerMoved() }
                } else {
                    Task { @MainActor [weak self] in self?.handleAlwaysOnPointerMoved() }
                }
            }
            return event
        }
    }

    private func removeAlwaysOnNearFieldMonitors() {
        if let monitor = alwaysOnMoveGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            alwaysOnMoveGlobalMonitor = nil
        }
        if let monitor = alwaysOnMoveLocalMonitor {
            NSEvent.removeMonitor(monitor)
            alwaysOnMoveLocalMonitor = nil
        }
    }

    /// 近场（条带外扩 8pt / 托盘外扩 12pt）：进到这里才唤醒 60Hz hover 轮询。
    ///
    /// 条带只留 8pt（而不是 24pt）：这圈只是「指针快到条带了」的唤醒带 —— 留太宽会让用户
    /// 在条带外面停住也算近场，60Hz 就永远停不下来 ✗（P3 续航）
    private func isPointInAlwaysOnNearField(_ point: CGPoint) -> Bool {
        if let stripRect = currentStripContentRect,
           stripRect.insetBy(dx: -8, dy: -8).contains(point) {
            return true
        }
        if trayPanel?.isVisible == true,
           let trayRect = currentTrayContentRect,
           trayRect.insetBy(dx: -12, dy: -12).contains(point) {
            return true
        }
        return false
    }

    /// 指针动了一下：只有「常驻条带在屏上 + 正空闲 + 进入近场」才起 60Hz 轮询（其余 0 唤醒）。
    private func handleAlwaysOnPointerMoved() {
        guard isShowingPersistentStrip, isVisible, !isExitingStrip else { return }
        let mouse = NSEvent.mouseLocation
        // ★★ 2026-11-25 实机病例（108pt 透明呼吸区拦截环外点击）：
        //   必须在 `hoverPollTimer == nil` 之前以 120Hz 实时同步精确穿透门 ——
        //   指针刚离开玻璃本体 1 像素即立刻置 `ignoresMouseEvents = true`，环外/上方/缝隙 100% 透传给底层 App ✓
        syncPanelMousePassthrough(at: mouse)
        guard hoverPollTimer == nil else { return }

        // 交互期间暂存的名单：指针已彻底离开条带（托盘也没开着盖住指针）⇒ **立刻**落地并原地重排。
        // 这一条保证暂存名单一定会生效 —— 不能指望下一次进近场或某个事件把它捞回来（P1）✓
        if pendingAlwaysOnGroups != nil,
           !(currentStripContentRect?.contains(mouse) ?? false),
           !(trayPanel?.isVisible == true && (currentTrayContentRect?.contains(mouse) ?? false)) {
            if let pending = pendingAlwaysOnGroups {
                pendingAlwaysOnGroups = nil
                let pendingLaunchables = pendingAlwaysOnLaunchables
                pendingAlwaysOnLaunchables = nil
                transitionAlwaysOnGroups(to: pending, launchables: pendingLaunchables)
            } else if let pendingLaunchables = pendingAlwaysOnLaunchables {
                pendingAlwaysOnLaunchables = nil
                launchables = pendingLaunchables
            }
            relayoutAlwaysOnStripInPlace()
        }

        guard isPointInAlwaysOnNearField(mouse) else { return }
        alwaysOnLeaveStartedAt = nil
        startHoverPolling()
        pollHover()
    }

    /// 收束一次常驻交互：收托盘、清 hover、停定时器与直播流，条带**原地不动**。
    ///
    /// - Parameter exitLaunchSegment: `true` = 顺手退出未启动段（确认/启动/换屏/休眠用）。
    private func endAlwaysOnInteraction(exitLaunchSegment: Bool, deferStreamTeardown: TimeInterval = 0) {
        alwaysOnLeaveStartedAt = nil
        stopHoverPolling()
        stopClickGateTimer()
        hideTray(deferStreamTeardown: deferStreamTeardown)
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        resetDiagonalGuard()
        if exitLaunchSegment { showingLaunchSegment = false }

        // 交互期间暂存的名单在这一刻正式落地并重排
        if let pending = pendingAlwaysOnGroups {
            pendingAlwaysOnGroups = nil
            let pendingLaunchables = pendingAlwaysOnLaunchables
            pendingAlwaysOnLaunchables = nil
            transitionAlwaysOnGroups(to: pending, launchables: pendingLaunchables)
        } else if let pendingLaunchables = pendingAlwaysOnLaunchables {
            pendingAlwaysOnLaunchables = nil
            launchables = pendingLaunchables
        }

        if isShowingPersistentStrip { relayoutAlwaysOnStripInPlace() }
    }

    /// 后台防抖（0.25s）刷新常驻条带名单；同屏同时只跑一个真实枚举（`alwaysOnRefreshInFlight` 去重）。
    ///
    /// - Parameter includeCandidates: 是否要重扫「Dock plist + LaunchServices」（这轮最重的两件活）。
    ///   切 App / 切 Space / 取消隐藏**不需要**（只刷窗口名单）；开关常驻、换屏、启/退 App、
    ///   屏参变化、休眠回插才需要 ✓
    ///   期间多次请求会合并：只要有一次要，下一轮就带上（`alwaysOnNeedsCandidatesRefresh`）
    private func refreshAlwaysOnGroupsSoon(includeCandidates: Bool = false) {
        guard isAlwaysOnActive, isShowingPersistentStrip else { return }
        if includeCandidates { alwaysOnNeedsCandidatesRefresh = true }
        alwaysOnRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startAlwaysOnRefresh()
        }
        alwaysOnRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startAlwaysOnRefresh(includeCandidates: Bool = false) {
        alwaysOnRefreshWork = nil
        guard isAlwaysOnActive, isShowingPersistentStrip,
              let displayID = alwaysOnDisplayID else { return }
        // 需求合并：期间攒下的 candidates 需求不能因为这一轮没显式传就丢掉
        let needsCandidates = includeCandidates || alwaysOnNeedsCandidatesRefresh
        alwaysOnNeedsCandidatesRefresh = false
        guard !alwaysOnRefreshInFlight else {
            // 在途期间又来请求 ⇒ 把 candidates 需求寄存到下一轮（防抖后再起）✓
            if needsCandidates { alwaysOnNeedsCandidatesRefresh = true }
            refreshAlwaysOnGroupsSoon(includeCandidates: needsCandidates)
            return
        }
        guard let screen = Self.screen(for: displayID) ?? activeScreen else { return }

        alwaysOnRefreshInFlight = true
        let epochAtStart = cacheEpoch
        let startedAt = CFAbsoluteTimeGetCurrent()

        Task.detached(priority: .userInitiated) {
            let raw = WindowEnumerator.rawGroups(on: screen, includeMinimized: true)
            // 只有真要的时候才碰 Dock plist / LaunchServices（同步 IO + Bundle 解析，很贵）
            let candidates = needsCandidates ? DockAppsProvider.computeCandidates() : nil
            let running = DockAppsProvider.computeRunningSet()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.alwaysOnRefreshInFlight = false
                guard self.isAlwaysOnActive, self.alwaysOnDisplayID == displayID else { return }

                let targetScreen = Self.screen(for: displayID) ?? self.activeScreen ?? screen
                var ordered = WindowEnumerator.orderByMRU(raw, on: targetScreen)
                if epochAtStart != self.cacheEpoch {
                    let pruned = self.activePrunedPIDs(since: startedAt)
                    if !pruned.isEmpty {
                        ordered.removeAll { pruned.contains($0.pid) }
                    }
                }
                // 新冒出来的 App 先派后台预热图标（与 open 路径同一条纪律）
                IconProvider.prewarmMissing(for: ordered.map { (pid: $0.pid, bundleID: $0.bundleID) })
                // 本轮没重扫 candidates ⇒ 缓存原样留用（切 App 不该每次重扫 Dock plist / LaunchServices）
                if let candidates = candidates { DockAppsProvider.storeCandidates(candidates) }
                DockAppsProvider.storeRunningSet(running)
                if epochAtStart == self.cacheEpoch {
                    self.freshGroupsByDisplay[displayID] = CachedGroups(
                        groups: ordered,
                        updatedAt: CFAbsoluteTimeGetCurrent(),
                        isFresh: true
                    )
                }
                self.applyAlwaysOnGroups(
                    ordered,
                    launchables: DockAppsProvider.launchables(excluding: running)
                )
            }
        }
    }

    /// 窗口层级与 Space 归属：常驻 = dock 层级（20 / 托盘 21）+ 不参与全屏 Space；
    /// 老行为 = `.popUpMenu` / `.popUpMenu - 1` + `.fullScreenAuxiliary`（全屏临时唤起仍要浮在全屏上）。
    private func applyPanelChrome() {
        let persistent = isShowingPersistentStrip
        let stripLevel: NSWindow.Level = persistent
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
            : .popUpMenu
        let trayLevel = NSWindow.Level(
            rawValue: persistent
                ? stripLevel.rawValue + 1
                : NSWindow.Level.popUpMenu.rawValue - 1
        )
        let behavior: NSWindow.CollectionBehavior = persistent
            ? [.canJoinAllSpaces, .transient]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        if let stripPanel {
            stripPanel.level = stripLevel
            stripPanel.collectionBehavior = behavior
        }
        if let trayPanel {
            trayPanel.level = trayLevel
            trayPanel.collectionBehavior = behavior
        }
    }

    /// 无动画收起条带与托盘（换屏 / 全屏避让 / 关常驻用；绝不在这里清 `isAlwaysOnActive`）。
    private func hidePanelsImmediately() {
        stopStripAnimation()
        stopTrayAnimation()
        stripPanel?.alphaValue = 0
        stripPanel?.orderOut(nil)
        stripPanel?.ignoresMouseEvents = true
        trayPanel?.alphaValue = 0
        trayPanel?.orderOut(nil)
        trayPanel?.ignoresMouseEvents = true
        currentTrayContentRect = nil
        trayContentSize = .zero
        LivePreviewPool.shared.stopAll(reason: "常驻程序坞收起")
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func cursorScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func cursorDisplayID() -> CGDirectDisplayID? {
        cursorScreen().flatMap(displayID(of:))
    }

    /// 把首选 `displayID` 解析为必然匹配的 `(screen, displayID)` 对：
    /// 若首选屏已拔出，同步回退 `screen` 与 `displayID`，杜绝 `activeScreen` 与 `alwaysOnDisplayID` 分裂。
    private static func resolveScreenAndDisplayID(
        preferred: CGDirectDisplayID?
    ) -> (screen: NSScreen, displayID: CGDirectDisplayID)? {
        if let preferred, let matched = screen(for: preferred) {
            return (matched, preferred)
        }
        let fallbackScreen = cursorScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let fallbackScreen, let fallbackID = displayID(of: fallbackScreen) else {
            return nil
        }
        return (fallbackScreen, fallbackID)
    }

    func isPointInInteractiveRegion(_ point: CGPoint) -> Bool {
        guard isVisible, let stripRect = currentStripContentRect else { return false }
        let trayRect = (trayPanel?.isVisible == true) ? currentTrayContentRect : nil
        return DockLayoutGeometry.isPointInInteractiveRegion(
            point: point,
            stripRect: stripRect,
            trayRect: trayRect,
            position: position
        )
    }

    // MARK: - 交互动作

    func hoverApp(at index: Int?) {
        guard isVisible, !showingLaunchSegment else { return }
        guard let index, groups.indices.contains(index) else {
            hoveredAppIndex = nil
            selectedWindowIndex = 0
            isSideChipStackExpanded = false
            hideTray()
            return
        }

        let changed = hoveredAppIndex != index
        hoveredAppIndex = index
        if changed {
            selectedWindowIndex = 0
            isSideChipStackExpanded = false
        }

        let group = groups[index]
        guard !group.windows.isEmpty else {
            hideTray()
            return
        }

        if changed, let first = group.windows.first, !first.isMinimized {
            // 悬停即后台预热目标窗的 AXUIElement，点击瞬间跳过 50~150ms 的 kAXWindowsAttribute 扫描 ✓
            WindowFocuser.prewarmAXElement(pid: first.pid, wid: first.wid)
        }

        // 0ms 回填已有热帧，保证扫过图标时预览卡立刻出图不闪空；重量级 SCStream 起流与补拍等驻留 120ms 再发，
        // 避免滑过 3~5 个图标就向 WindowServer 轰出多条并发录屏流（实测会拖慢切焦 2× 甚至触发 530ms 停顿 ✓）
        prefillCachedLiveFrames(for: group)
        if let screen = activeScreen {
            updateTray(for: index, on: screen, syncLive: false)
        }
        scheduleLiveCaptureAfterHoverSettle(for: group, appIndex: index)
    }

    func expandSideChipStack() {
        guard isVisible,
              position.isVertical,
              WindowLayout.current == .rail,
              !isSideChipStackExpanded,
              let appIdx = hoveredAppIndex,
              let group = activeHoveredGroup,
              group.windows.count > 1,
              let screen = activeScreen else {
            return
        }
        let anchoredTopY = currentTrayContentRect?.maxY
        isSideChipStackExpanded = true
        updateTray(for: appIdx, on: screen, anchoredTopY: anchoredTopY)
    }

    func hoverWindow(at index: Int) {
        guard let group = activeHoveredGroup, !group.windows.isEmpty else {
            selectedWindowIndex = 0
            return
        }
        let next = min(max(index, 0), group.windows.count - 1)
        if selectedWindowIndex != next {
            selectedWindowIndex = next
            let target = group.windows[next]
            if !target.isMinimized {
                WindowFocuser.prewarmAXElement(pid: target.pid, wid: target.wid)
            }
            // 底部轨道槽宽随当前卡宽变化，需重算托盘宽度；侧边轨道尺寸在组内恒定，无需动窗框（芯片纹丝不动）
            if WindowLayout.current == .rail,
               !position.isVertical,
               let appIdx = hoveredAppIndex,
               let screen = activeScreen {
                updateTray(for: appIdx, on: screen)
            } else {
                syncLivePreview(for: group)
            }
        }
    }

    func toggleLaunchSegment() {
        guard isVisible else { return }
        showingLaunchSegment.toggle()
        hoveredAppIndex = nil
        hoveredLaunchIndex = nil
        hoveredTailToggle = false
        selectedWindowIndex = 0
        isSideChipStackExpanded = false
        hideTray()

        if showingLaunchSegment {
            launchables = DockAppsProvider.launchables(excluding: DockAppsProvider.runningSet())
        }
        if let screen = activeScreen {
            layoutAndShowStrip(on: screen)
            pollHover()
        }
    }

    /// 点击确认前 0ms 瞬收预览托盘与自动隐藏条带 + 延后拆 SCStream：
    /// 2026-11-27 实测（N=361）：Panel（先 orderOut + 0 并发停流）AX raise 中位 31–51ms / 零 500ms 尖峰；
    /// 旧版 Dock 留着 `.popUpMenu` 条带跑 120Hz `setFrameOrigin` 且在 t=0ms 并发 `SCStream.stopCapture()`，
    /// 令同 4 个 App 全部慢 2×（中位 58–97ms）且 Chrome P90 飙到 530ms、连带冻住主线程 510–532ms ✗。
    /// 现在在 `WindowFocuser.focus` 之前即刻：
    ///   ① 取消未落地的悬停起流/补拍，立刻落闸静音直播流并把 `stopCapture()` 推迟 250ms；
    ///   ② 自动隐藏态把托盘与条带双双 `orderOut(nil)`（切焦窗口内零可见 popUpMenu 窗、零主线程 WindowServer 动画 IPC）✓
    private func prepareInstantFocusHandoff() {
        liveCaptureDebounceWork?.cancel()
        liveCaptureDebounceWork = nil
        LivePreviewPool.shared.stopAll(reason: "程序坞确认切换", deferStreamTeardown: 0.25)
        stopTrayAnimation()
        trayPanel?.alphaValue = 0
        trayPanel?.orderOut(nil)
        trayPanel?.ignoresMouseEvents = true
        if !isShowingPersistentStrip {
            stopStripAnimation()
            stripPanel?.alphaValue = 0
            stripPanel?.orderOut(nil)
            stripPanel?.ignoresMouseEvents = true
        }
    }

    func confirmWindow(_ window: WindowRecord) {
        prepareInstantFocusHandoff()
        WindowFocuser.focus(window: window)
        if isShowingPersistentStrip {
            endAlwaysOnInteraction(exitLaunchSegment: true, deferStreamTeardown: 0.25)
        } else {
            dismiss(reason: "点击窗口确认", instantTrayHide: true)
        }
    }

    func confirmApp(at index: Int) {
        guard groups.indices.contains(index) else { return }
        let group = groups[index]
        let screen = activeScreen
        let targetWindow: WindowRecord?
        if !group.windows.isEmpty {
            let winIdx = (hoveredAppIndex == index && group.windows.indices.contains(selectedWindowIndex))
                ? selectedWindowIndex
                : 0
            targetWindow = group.windows[winIdx]
        } else {
            targetWindow = nil
        }

        // 先 0ms 清场（关窗 + 静音流且延后拆 SCStream），再立刻发 WindowServer 抬窗 ✓
        prepareInstantFocusHandoff()
        if let targetWindow {
            WindowFocuser.focus(window: targetWindow)
        } else if let app = NSRunningApplication(processIdentifier: group.pid), app.bundleURL == nil {
            app.activate(options: .activateAllWindows)
        } else {
            WindowFocuser.focusWindowlessApp(pid: group.pid, contextScreen: screen)
        }

        if isShowingPersistentStrip {
            endAlwaysOnInteraction(exitLaunchSegment: true, deferStreamTeardown: 0.25)
        } else {
            dismiss(reason: "点击应用确认", instantTrayHide: true)
        }
    }

    /// 按 PID 确认（**渲染槽专用**：动画期间同一个下标可能对应正在退出的幽灵槽或新 App，
    /// 只有 PID 能保证不点错；也不存在「槽位下标越出 groups」的越界风险）✓
    func confirmApp(pid: pid_t) {
        guard let index = groups.firstIndex(where: { $0.pid == pid }) else { return }
        confirmApp(at: index)
    }

    func launchApp(_ app: DockAppsProvider.LaunchableApp) {
        DockAppsProvider.launch(at: app.path)
        if isShowingPersistentStrip {
            endAlwaysOnInteraction(exitLaunchSegment: true)
        } else {
            dismiss(reason: "启动未运行应用(\(app.name))")
        }
    }

    // MARK: - 布局与窗口装配

    private func buildStripPanelIfNeeded() {
        guard stripPanel == nil else { return }
        let panel = DockFloatingPanel(level: .popUpMenu)
        let hosting = ClickThroughHostingView(rootView: DockStripView(controller: self))
        hosting.pad = metrics.shadowPadStrip
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.contentMinSize = .zero
        stripPanel = panel
        stripHostingView = hosting
    }

    private func buildTrayPanelIfNeeded() {
        guard trayPanel == nil else { return }
        let trayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        let panel = DockFloatingPanel(level: trayLevel)
        let hosting = ClickThroughHostingView(rootView: DockTrayView(controller: self, snapshotter: Snapshotter.shared))
        hosting.pad = metrics.shadowPadPop
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.contentMinSize = .zero
        trayPanel = panel
        trayHostingView = hosting
    }

    private func layoutAndShowStrip(on screen: NSScreen) {
        buildStripPanelIfNeeded()
        // 常驻/老行为的窗口层级与 Space 归属在这里统一切换（两种运行态的唯一分叉点）✓
        applyPanelChrome()
        let itemCount = showingLaunchSegment ? launchables.count : groups.count
        let hasToggle = showsTailToggleButton
        let trayWindows = activeHoveredGroup?.windows ?? []
        let updatedMetrics = DockMetrics.fitted(
            visibleSize: screen.visibleFrame.size,
            position: position,
            itemCount: itemCount,
            hasToggle: hasToggle,
            trayWindows: trayWindows,
            layout: WindowLayout.current,
            sideStackExpanded: isSideChipStackExpanded
        )

        let contentSize = updatedMetrics.stripContentSize(
            itemCount: itemCount,
            position: position,
            hasToggle: hasToggle
        )

        let contentRect = DockLayoutGeometry.stripContentRect(
            contentSize: contentSize,
            position: position,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )

        let windowFrame = contentRect.insetBy(
            dx: -updatedMetrics.shadowPadStrip,
            dy: -updatedMetrics.shadowPadStrip
        )

        // ★ 增删动效在途：几何由 `transitionAlwaysOnGroups` 自己驱动（包络窗框 + 弹簧长缩）。
        //   只要这次算的落点就是它的目标 ⇒ 尺寸 / 窗框一步都不能动，否则整段弹簧被瞬间跳到终点 ✗
        if let morphTarget = stripMorphTargetWindowFrame,
           Self.frameIsClose(morphTarget, windowFrame) {
            metrics = updatedMetrics
            stripHostingView?.pad = updatedMetrics.shadowPadStrip
            syncPanelMousePassthrough()
            return
        }
        // 非 morph 路径（以及中途改了位置 / 尺寸 / 屏参而被放弃的那次 morph）：
        // 渲染槽立即同步成 `groups`（没有幽灵槽），再正常落位 ✓
        syncRunningSlotsImmediately()

        metrics = updatedMetrics
        stripContentSize = contentSize
        currentStripContentRect = contentRect
        // 条带内容区变了 ⇒ 占位厚度跟着变（图标增减 / 位置切换 / 屏参变化都会走到这里）
        if isShowingPersistentStrip { syncWindowReserveGuard() }
        stripHostingView?.pad = updatedMetrics.shadowPadStrip

        guard let panel = stripPanel else { return }
        if !hasRevealedInSession {
            hasRevealedInSession = true
            let startFrame: CGRect
            let startAlpha: CGFloat
            if panel.isVisible, panel.alphaValue > 0.02,
               screen.frame.intersects(panel.frame) {
                // 同一块屏上从退场途中无缝接力滑回：只沿滑入轴继承当前位置，非滑入轴（侧边锁 Y / 底部锁 X）
                // 严格对齐新 `windowFrame`，防止名单增减改了高度后斜向滑入 ✓
                let resumeOrigin = position.isVertical
                    ? CGPoint(x: panel.frame.origin.x, y: windowFrame.origin.y)
                    : CGPoint(x: windowFrame.origin.x, y: panel.frame.origin.y)
                startFrame = CGRect(origin: resumeOrigin, size: windowFrame.size)
                startAlpha = panel.alphaValue
            } else {
                startFrame = offEdgeFrame(
                    for: windowFrame,
                    contentSize: contentSize,
                    position: position
                )
                startAlpha = 0
            }
            panel.setFrame(startFrame, display: true)
            panel.alphaValue = startAlpha
            panel.orderFrontRegardless()
            syncPanelMousePassthrough()
            animateStrip(
                from: startFrame,
                to: windowFrame,
                fromAlpha: startAlpha,
                toAlpha: 1,
                duration: 0.22,
                entering: true,
                generation: openGeneration,
                completion: nil
            )
        } else if isEnteringStrip {
            // ★★ 2026-11-27 实机病例（久置后贴边唤起，侧边 Dock 从斜上方滑出）：
            //   兜底/旧缓存先以较短条带起跑（AppKit 坐标系下短条带居中 `origin.y` 更高），
            //   20~50ms 后真枚举落地变高（`windowFrame.origin.y` 更低）；旧代码只改了
            //   `animTargetFrame` 和 `animStartFrame.size`，把 `animStartFrame.origin.y` 留在高处，
            //   于是 120Hz 插值把整条 Dock 从右上斜着拽到正右 ✗
            //   ⇒ 非滑入轴（侧边锁 Y、底部锁 X）同步钉死到 `windowFrame.origin`，并把当前窗框同步齐平，
            //     保证全程严格纯水平/纯垂直平移入场 ✓
            animTargetFrame = windowFrame
            animStartFrame.size = windowFrame.size
            if position.isVertical {
                animStartFrame.origin.y = windowFrame.origin.y
                let snappedOrigin = CGPoint(x: panel.frame.origin.x, y: windowFrame.origin.y)
                panel.setFrame(CGRect(origin: snappedOrigin, size: windowFrame.size), display: false)
            } else {
                animStartFrame.origin.x = windowFrame.origin.x
                let snappedOrigin = CGPoint(x: windowFrame.origin.x, y: panel.frame.origin.y)
                panel.setFrame(CGRect(origin: snappedOrigin, size: windowFrame.size), display: false)
            }
            syncPanelMousePassthrough()
        } else {
            panel.setFrame(windowFrame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            syncPanelMousePassthrough()
        }
    }

    private func updateTray(
        for appIndex: Int,
        on screen: NSScreen,
        anchoredTopY: CGFloat? = nil,
        syncLive: Bool = true
    ) {
        guard groups.indices.contains(appIndex),
              let stripRect = currentStripContentRect else {
            hideTray()
            return
        }
        let group = groups[appIndex]
        guard !group.windows.isEmpty else {
            hideTray()
            return
        }

        buildTrayPanelIfNeeded()
        applyPanelChrome()
        let layout = WindowLayout.current
        let itemCount = groups.count
        let updatedMetrics = DockMetrics.fitted(
            visibleSize: screen.visibleFrame.size,
            position: position,
            itemCount: itemCount,
            hasToggle: showsTailToggleButton,
            trayWindows: group.windows,
            layout: layout,
            sideStackExpanded: isSideChipStackExpanded
        )
        metrics = updatedMetrics

        let avail = updatedMetrics.trayMaxAvailableSize(
            visibleSize: screen.visibleFrame.size,
            stripSize: stripContentSize,
            position: position
        )
        trayAvailableSize = avail

        let size = updatedMetrics.trayContentSize(
            windows: group.windows,
            layout: layout,
            position: position,
            maxSize: avail,
            selectedIndex: selectedWindowIndex,
            sideStackExpanded: isSideChipStackExpanded
        )
        trayContentSize = size

        // 默认与 Cmd+Tab 一致始终相对程序坞居中；关闭「预览卡片居中」时跟随悬停图标移动
        let anchor: CGFloat = Keys.isDockTrayCentered
            ? (position.isVertical ? stripRect.midY : stripRect.midX)
            : updatedMetrics.iconCenterAlongAxis(
                at: appIndex,
                itemCount: itemCount,
                stripRect: stripRect,
                position: position
            )
        var trayRect = DockLayoutGeometry.trayContentRect(
            traySize: size,
            stripRect: stripRect,
            anchorCenterAlongAxis: anchor,
            position: position,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        if let anchoredTopY {
            // 侧边芯片叠卡展开时尽量锚定原托盘顶边，仅当底边会越出可视区底边安全距时才向上夹紧
            let pad: CGFloat = 12
            let minAllowedY = screen.visibleFrame.minY + pad
            let maxAllowedY = max(minAllowedY, screen.visibleFrame.maxY - pad - size.height)
            let desiredY = anchoredTopY - size.height
            trayRect.origin.y = min(max(desiredY, minAllowedY), maxAllowedY)
        } else if position.isVertical, layout == .rail, group.windows.count > 1 {
            // 侧边多窗叠卡尾巴（peekLayers × peekStep）向下自然垂出，而不是参与整托盘居中：
            // 消除「单窗 ↔ 多窗」切换时预览卡片向上偏移半个叠卡高度的垂直跳动 ✓
            let geom = updatedMetrics.sideRailGeometry(
                windows: group.windows,
                maxHeight: avail.height,
                expanded: isSideChipStackExpanded
            )
            let extraTailH = max(0, geom.listHeight - updatedMetrics.chipH)
            if extraTailH > 0 {
                let pad: CGFloat = 12
                let minAllowedY = screen.visibleFrame.minY + pad
                let maxAllowedY = max(minAllowedY, screen.visibleFrame.maxY - pad - size.height)
                trayRect.origin.y = min(max(trayRect.origin.y - extraTailH / 2, minAllowedY), maxAllowedY)
            }
        }
        currentTrayContentRect = trayRect

        let windowFrame = trayRect.insetBy(
            dx: -updatedMetrics.shadowPadPop,
            dy: -updatedMetrics.shadowPadPop
        )
        trayHostingView?.pad = updatedMetrics.shadowPadPop
        let wasVisible = (trayPanel?.isVisible == true) && ((trayPanel?.alphaValue ?? 0) > 0.5)
        stopTrayAnimation()
        trayPanel?.setFrame(windowFrame, display: true)
        if !wasVisible {
            trayPanel?.alphaValue = 0
            trayPanel?.orderFrontRegardless()
            animateTrayFadeIn(generation: openGeneration)
        } else {
            trayPanel?.alphaValue = 1
            trayPanel?.orderFrontRegardless()
        }

        startClickGateTimerIfNeeded()
        syncPanelMousePassthrough()
        if syncLive {
            syncLivePreview(for: group)
        }
    }

    /// 0ms 回填已有热帧（不触发任何 SCStream / SCScreenshotManager 系统调用）。
    private func prefillCachedLiveFrames(for group: AppGroup) {
        guard LivePreviewPool.enabled else { return }
        for w in group.windows where !w.isMinimized && LivePreviewPool.shared.box(for: w.wid).image == nil {
            if let cached = LivePreviewPool.shared.cachedFrame(for: w.wid) {
                LivePreviewPool.shared.box(for: w.wid).image = cached
            }
        }
    }

    /// 指针在同一个 App 图标驻留满 120ms 后才发起重量级实时流与快照补拍，
    /// 扫过途中的图标只用已有缓存帧/快照，彻底消除「划过即起 4~5 条 SCStream」对切焦的拖累 ✓
    private func scheduleLiveCaptureAfterHoverSettle(for group: AppGroup, appIndex: Int) {
        liveCaptureDebounceWork?.cancel()
        let gen = openGeneration
        let pid = group.pid
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.openGeneration == gen,
                  self.isVisible,
                  !self.showingLaunchSegment,
                  self.hoveredAppIndex == appIndex,
                  self.groups.indices.contains(appIndex),
                  self.groups[appIndex].pid == pid else { return }
            let latestGroup = self.groups[appIndex]
            Snapshotter.shared.precapture(latestGroup.windows, force: false)
            self.syncLivePreview(for: latestGroup)
        }
        liveCaptureDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func syncLivePreview(for group: AppGroup) {
        guard isVisible, !showingLaunchSegment else {
            LivePreviewPool.shared.stopAll(reason: "程序坞托盘隐藏")
            return
        }
        guard LivePreviewPool.enabled else { return }
        let selIdx = group.windows.indices.contains(selectedWindowIndex) ? selectedWindowIndex : 0
        // `.rail` 模式（多窗）场上只展示选中窗一张预览卡，严格只为这一扇非最小化选中窗同步 Live 流
        let targetWindows: [WindowRecord]
        if WindowLayout.current == .rail, group.windows.count > 1 {
            targetWindows = group.windows.indices.contains(selIdx) ? [group.windows[selIdx]] : []
        } else {
            targetWindows = group.windows
        }
        // 回填缓存热帧，减少快照→实时首帧过渡闪烁
        for w in targetWindows where !w.isMinimized && LivePreviewPool.shared.box(for: w.wid).image == nil {
            if let cached = LivePreviewPool.shared.cachedFrame(for: w.wid) {
                LivePreviewPool.shared.box(for: w.wid).image = cached
            }
        }
        let items = targetWindows.filter { !$0.isMinimized }.map { w in
            (wid: w.wid, aspect: w.aspect, box: metrics.thumbSize(real: w.bounds.size, aspect: w.aspect))
        }
        if items.isEmpty {
            LivePreviewPool.shared.stopAll(reason: "程序坞当前组无可见窗")
        } else {
            let selectedWid = group.windows.indices.contains(selIdx)
                ? group.windows[selIdx].wid
                : items.first?.wid
            // ★ 2026-11-25 病例（直播预览在同一局里永久失效）：
            //   本次会话里滑过**无窗 App**（如无窗的微信）/ 最小化窗 / 切到未启动段，都会走上面的
            //   `stopAll(...)`；而 `stopAll` 会把池子的全局闸门 `isAccepting` 落成 `false`
            //   （它假定「面板散场了」，见 `LivePreviewPool.isAccepting` 的病例）。
            //   托盘其实还开着，再悬停到**有窗** App 时 `sync(...)` 全部被闸门**静默丢弃** ⇒
            //   整局的直播预览再也起不来，必须重新唤起托盘才好 ✗
            //   ⇒ 每次重新 sync 之前先把闸门抬起来（`open()` 里那次只覆盖第一次）✓
            LivePreviewPool.shared.setAccepting(true)
            LivePreviewPool.shared.sync(items, selected: selectedWid)
        }
    }

    private func hideTray(deferStreamTeardown: TimeInterval = 0) {
        liveCaptureDebounceWork?.cancel()
        liveCaptureDebounceWork = nil
        stopClickGateTimer()
        stopTrayAnimation()
        LivePreviewPool.shared.stopAll(reason: "程序坞收起托盘", deferStreamTeardown: deferStreamTeardown)
        trayPanel?.alphaValue = 0
        trayPanel?.orderOut(nil)
        trayPanel?.ignoresMouseEvents = true
        currentTrayContentRect = nil
        trayContentSize = .zero
        isSideChipStackExpanded = false
        syncPanelMousePassthrough()
        // 托盘不在了 ⇒ 斜向移入的宽限态一并作废（`toggleLaunchSegment` 也经由此处清理）
        resetDiagonalGuard()
    }

    // MARK: - 120Hz 登/退场动画（无边框 NSPanel 不走 NSAnimationContext.animator）

    private func offEdgeFrame(
        for targetFrame: CGRect,
        contentSize: CGSize,
        position: DockPosition
    ) -> CGRect {
        let travelMargin: CGFloat = 22
        switch position {
        case .bottom:
            return targetFrame.offsetBy(dx: 0, dy: -(contentSize.height + travelMargin))
        case .left:
            return targetFrame.offsetBy(dx: -(contentSize.width + travelMargin), dy: 0)
        case .right:
            return targetFrame.offsetBy(dx: contentSize.width + travelMargin, dy: 0)
        }
    }

    private func animateStrip(
        from startFrame: CGRect,
        to targetFrame: CGRect,
        fromAlpha: CGFloat,
        toAlpha: CGFloat,
        duration: Double,
        entering: Bool,
        trayFadeOutFromAlpha: CGFloat? = nil,
        trayFadeOutDuration: Double = 0.10,
        generation: Int,
        completion: (() -> Void)?
    ) {
        stopStripAnimation()
        isEnteringStrip = entering
        isExitingStrip = !entering
        animStartFrame = startFrame
        animTargetFrame = targetFrame
        animStartAlpha = fromAlpha
        animTargetAlpha = toAlpha
        animDuration = max(duration, 0.01)
        animStartedAt = CFAbsoluteTimeGetCurrent()

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.openGeneration == generation else {
                    self?.stopStripAnimation()
                    return
                }
                guard let panel = self.stripPanel else {
                    self.stopStripAnimation()
                    completion?()
                    return
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - self.animStartedAt
                let rawT = min(max(elapsed / self.animDuration, 0), 1)
                let eased: CGFloat = entering
                    ? CGFloat(1.0 - pow(1.0 - rawT, 3.4)) // ease-out quartic：起手敏捷、落地柔顺
                    : CGFloat(pow(rawT, 1.55))            // 起手即动、收尾干脆

                let s = self.animStartFrame
                let e = self.animTargetFrame
                let origin = CGPoint(
                    x: s.origin.x + (e.origin.x - s.origin.x) * eased,
                    y: s.origin.y + (e.origin.y - s.origin.y) * eased
                )
                let currentSize = panel.frame.size
                if abs(currentSize.width - e.size.width) > 0.5 || abs(currentSize.height - e.size.height) > 0.5 {
                    panel.setFrame(CGRect(origin: origin, size: e.size), display: false)
                } else {
                    panel.setFrameOrigin(origin)
                }

                let alphaT: CGFloat = entering
                    ? CGFloat(min(1.0, rawT * 2.4))
                    : CGFloat(rawT)
                panel.alphaValue = self.animStartAlpha + (self.animTargetAlpha - self.animStartAlpha) * alphaT

                if let trayStartAlpha = trayFadeOutFromAlpha,
                   let tray = self.trayPanel,
                   tray.isVisible {
                    let trayT = min(max(elapsed / max(trayFadeOutDuration, 0.01), 0), 1)
                    if trayT >= 1 {
                        tray.alphaValue = 0
                        tray.orderOut(nil)
                        tray.ignoresMouseEvents = true
                    } else {
                        tray.alphaValue = trayStartAlpha * CGFloat(1.0 - trayT)
                    }
                }

                if rawT >= 1 {
                    self.stopStripAnimation()
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stripAnimTimer = timer
    }

    private func stopStripAnimation() {
        stripAnimTimer?.invalidate()
        stripAnimTimer = nil
        isEnteringStrip = false
        isExitingStrip = false
    }

    private func animateTrayFadeIn(generation: Int) {
        stopTrayAnimation()
        let startedAt = CFAbsoluteTimeGetCurrent()
        let duration: Double = 0.11
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.openGeneration == generation, self.isVisible,
                      let panel = self.trayPanel else {
                    self?.stopTrayAnimation()
                    return
                }
                let t = min(max((CFAbsoluteTimeGetCurrent() - startedAt) / duration, 0), 1)
                panel.alphaValue = CGFloat(1.0 - pow(1.0 - t, 2.2))
                if t >= 1 {
                    panel.alphaValue = 1
                    self.stopTrayAnimation()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trayAnimTimer = timer
    }

    private func stopTrayAnimation() {
        trayAnimTimer?.invalidate()
        trayAnimTimer = nil
    }

    // MARK: - 监听与兜底收起

    private func installMonitors() {
        removeMonitors()

        outsideLocalClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }

            // 常驻态：条带**绝不因点击而消失**。只有「托盘开着 / 处于未启动段」才把临时交互收掉，
            // 且**外部点击一律放行**（return event）—— 不能把用户对别处的点击吃掉 ✓
            if self.isShowingPersistentStrip {
                guard self.isVisible else { return event }
                let loc = NSEvent.mouseLocation
                if event.type == .leftMouseDown,
                   !(self.currentStripContentRect?.contains(loc) ?? false),
                   let idx = self.expandedSideChipHitIndex(at: loc),
                   let group = self.activeHoveredGroup,
                   group.windows.indices.contains(idx) {
                    self.hoverWindow(at: idx)
                    self.confirmWindow(group.windows[idx])
                    return nil
                }
                if event.type == .leftMouseDown,
                   self.handleStripMouseDown(at: loc) {
                    return nil
                }
                // 托盘内的点击交给 SwiftUI（卡片 / 芯片自己处理）
                if let trayRect = self.currentTrayContentRect,
                   self.trayPanel?.isVisible == true,
                   trayRect.contains(loc) {
                    return event
                }
                _ = self.endPersistentInteractionIfNeeded()
                return event
            }

            guard self.isVisible else { return event }
            let loc = NSEvent.mouseLocation
            if self.isClickOutside(loc) {
                self.dismiss(reason: "面板外点击(本地)")
                return nil
            }
            // 条带左键点击直接走几何命中分发（与 60Hz hover 同源），彻底杜绝非激活 NSPanel 内
            // SwiftUI `.onTapGesture` 因托盘弹出/重绘或 key 焦点切换被吞导致“有窗 App 点击没反应”。
            // 展开态侧边芯片同理：先按几何确认命中窗口，事件消费掉（不回给 SwiftUI），
            // 避免 `.onTapGesture` 偶尔也能收到而同一次 `confirmWindow` 被跑两遍。
            if event.type == .leftMouseDown,
               !(self.currentStripContentRect?.contains(loc) ?? false),
               let idx = self.expandedSideChipHitIndex(at: loc),
               let group = self.activeHoveredGroup,
               group.windows.indices.contains(idx) {
                self.hoverWindow(at: idx)
                self.confirmWindow(group.windows[idx])
                return nil
            }
            if event.type == .leftMouseDown,
               self.handleStripMouseDown(at: loc) {
                return nil
            }
            return event
        }

        outsideGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // 零空闲 Task：常驻态且没有可收的临时交互（托盘没开、也不在未启动段）⇒ 连 Task 都不分配 ✓
            // 全局点击监听每次点屏都会回调，空闲时每一下都排一个 Task 很贵（P3 续航）✓
            if Thread.isMainThread, !MainActor.assumeIsolated({ self.needsGlobalInteractionHandling }) {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                let loc = NSEvent.mouseLocation
                if self.isShowingPersistentStrip {
                    guard !self.isPointInInteractiveRegion(loc) else { return }
                    _ = self.endPersistentInteractionIfNeeded()
                    return
                }
                if self.isClickOutside(loc) {
                    self.dismiss(reason: "面板外点击(全局)")
                }
            }
        }

        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            guard let self else { return }
            // 同上：没东西可收时（常驻空闲）连 Task 都不排 ✓
            if Thread.isMainThread, !MainActor.assumeIsolated({ self.needsGlobalInteractionHandling }) {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                if self.isShowingPersistentStrip {
                    _ = self.endPersistentInteractionIfNeeded()
                    return
                }
                self.dismiss(reason: "Esc(全局)")
            }
        }

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            if let self, self.isShowingPersistentStrip {
                // 常驻态 Esc 只收托盘/未启动段；没东西可收就把 Esc 还给前台 App ✓
                var consumed = false
                if Thread.isMainThread {
                    consumed = MainActor.assumeIsolated { self.endPersistentInteractionIfNeeded() }
                } else {
                    Task { @MainActor in _ = self.endPersistentInteractionIfNeeded() }
                }
                return consumed ? nil : event
            }
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                self.dismiss(reason: "Esc(本地)")
            }
            return nil
        }
    }

    /// 常驻态「点击/按键落到交互区外」：只在托盘开着或处于未启动段时收一下，返回是否真做了事。
    /// **绝不动常驻条带**（ADR-0018 方案 A）✓
    private func endPersistentInteractionIfNeeded() -> Bool {
        guard isShowingPersistentStrip, isVisible else { return false }
        let trayOpen = trayPanel?.isVisible == true
        guard trayOpen || showingLaunchSegment else { return false }
        endAlwaysOnInteraction(exitLaunchSegment: true)
        return true
    }

    /// 全局点击 / 全局 Esc 监听的主线程零 Task 预判：这一击/这一键**有没有可能让我们做任何事**。
    ///
    /// 判据与 `endPersistentInteractionIfNeeded` 完全同源：常驻态下只有「托盘开着 / 未启动段」
    /// 才可能被收（条带本身绝不动）；自动隐藏态一律返回 `true`（要跑完整的 dismiss 逻辑）。
    private var needsGlobalInteractionHandling: Bool {
        guard isVisible else { return false }
        guard isShowingPersistentStrip else { return true }
        return trayPanel?.isVisible == true || showingLaunchSegment
    }

    private func removeMonitors() {
        if let m = outsideLocalClickMonitor { NSEvent.removeMonitor(m) }
        outsideLocalClickMonitor = nil
        if let m = outsideGlobalClickMonitor { NSEvent.removeMonitor(m) }
        outsideGlobalClickMonitor = nil
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m) }
        escGlobalMonitor = nil
        if let m = escLocalMonitor { NSEvent.removeMonitor(m) }
        escLocalMonitor = nil
    }

    private func isClickOutside(_ point: CGPoint) -> Bool {
        let trayRect = (trayPanel?.isVisible == true) ? currentTrayContentRect : nil
        return OutsideClickRule.isOutside(
            point: point,
            panelContent: currentStripContentRect,
            trayContent: trayRect
        )
    }

    private func startClickGateTimerIfNeeded() {
        guard clickGateTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStripClickGate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickGateTimer = timer
    }

    private func stopClickGateTimer() {
        clickGateTimer?.invalidate()
        clickGateTimer = nil
    }

    /// 精确点击穿透门（2026-11-25 实机病例：`shadowPadStrip = 108pt` 透明呼吸区拦截环外点击）：
    /// - 仅当面板可见、非退场且**指针真正落在玻璃内容区内**时，才允许对应 NSPanel 接收鼠标事件；
    /// - 指针在内容区外（含 108pt / 96pt 阴影呼吸区、增删动效包络余量、环与窗口间的缝隙）时，
    ///   一律置 `ignoresMouseEvents = true`，让 WindowServer 直接把点击/滚动透传给底层 App，零像素误伤 ✓
    /// - 当鼠标位于托盘内容区内且不在条带内容区内时，条带自然保持 `true`、托盘为 `false`，不互挡 ✓
    private func syncPanelMousePassthrough(at mouse: CGPoint = NSEvent.mouseLocation) {
        guard isVisible, !isExitingStrip else {
            if stripPanel?.ignoresMouseEvents == false { stripPanel?.ignoresMouseEvents = true }
            if trayPanel?.ignoresMouseEvents == false { trayPanel?.ignoresMouseEvents = true }
            return
        }
        let inStrip = (stripPanel?.isVisible == true) && (currentStripContentRect?.contains(mouse) ?? false)
        let inTray = (trayPanel?.isVisible == true) && (currentTrayContentRect?.contains(mouse) ?? false)
        let stripShouldIgnore = !inStrip
        let trayShouldIgnore = !inTray
        if stripPanel?.ignoresMouseEvents != stripShouldIgnore {
            stripPanel?.ignoresMouseEvents = stripShouldIgnore
        }
        if trayPanel?.ignoresMouseEvents != trayShouldIgnore {
            trayPanel?.ignoresMouseEvents = trayShouldIgnore
        }
    }

    private func updateStripClickGate() {
        syncPanelMousePassthrough()
    }

    // MARK: - 60Hz 几何 Hover 轮询（非激活 NSPanel 的 .onHover 在帧移动/淡入后会失灵）

    private func startHoverPolling() {
        guard hoverPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollHover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    private func stopHoverPolling() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    private enum StripHitTarget {
        case none
        case tailToggle
        case runningApp(Int)
        case launchApp(Int)
    }

    /// 与 `pollHover` 与 `handleStripMouseDown` 共用的条带几何命中计算（唯一来源）。
    private func stripHitTarget(at mouse: CGPoint) -> StripHitTarget {
        guard let stripRect = currentStripContentRect,
              stripRect.contains(mouse) else {
            return .none
        }
        let m = metrics
        // position.isVertical 时 AppKit Y 轴向上、第 0 格在 stripRect.maxY - rowPadX 向下排；
        // bottom 时第 0 格在 stripRect.minX + rowPadX 向右排。
        let offset = position.isVertical
            ? (stripRect.maxY - mouse.y)
            : (mouse.x - stripRect.minX)

        let itemCount = showingLaunchSegment ? launchables.count : groups.count
        let itemsSpan: CGFloat = itemCount > 0
            ? CGFloat(itemCount) * m.icon + CGFloat(max(itemCount - 1, 0)) * m.iconGap
            : m.emptyStripBodySpan

        if showsTailToggleButton {
            let toggleStart = m.rowPadX + itemsSpan + m.toggleGap + m.toggleDividerThickness + m.toggleGap
            let toggleEnd = toggleStart + m.toggleButtonSize
            if offset >= toggleStart && offset <= toggleEnd {
                return .tailToggle
            }
        }

        if itemCount > 0 {
            let cellsStart = m.rowPadX - m.iconGap / 2
            let cellsEnd = m.rowPadX + itemsSpan + m.iconGap / 2
            if offset >= cellsStart && offset < cellsEnd {
                let rawIndex = Int(floor((offset - cellsStart) / m.pitch))
                let idx = min(max(rawIndex, 0), itemCount - 1)
                return showingLaunchSegment ? .launchApp(idx) : .runningApp(idx)
            }
        }

        return .none
    }

    /// 侧边芯片叠卡展开后的几何命中（60Hz hover 轮询与点击分发共用的唯一来源）。
    /// 为什么要有它：`DockFloatingPanel` 是非激活 NSPanel（`canBecomeKey = false`），展开时
    /// `trayPanel.setFrame` 刚改过窗口高度，AppKit/SwiftUI 的 `.onHover` tracking area 会滞后甚至丢事件
    /// ⇒ 展开后 hover 芯片压不动、点不动。这里按与 `DockSideChipStack` 完全同源的几何直接算命中。
    private func expandedSideChipHitIndex(at mouse: CGPoint) -> Int? {
        guard isVisible,
              isSideChipStackExpanded,
              position.isVertical,
              WindowLayout.current == .rail,
              let group = activeHoveredGroup,
              group.windows.count > 1,
              let trayRect = currentTrayContentRect,
              trayRect.contains(mouse) else {
            return nil
        }
        let m = metrics
        let count = group.windows.count
        let naturalListH = CGFloat(count) * m.chipH + CGFloat(max(count - 1, 0)) * m.chipRailGap
        // 可滚动情形（芯片总高超出展开高度）交给 SwiftUI 的 `ScrollView` + `.onTapGesture` 自己处理：
        // 滚动偏移不在几何模型里，硬算必然错位，这里直接放弃兜底。
        let geom = m.sideRailGeometry(
            windows: group.windows,
            maxHeight: trayAvailableSize.height,
            expanded: true
        )
        guard naturalListH <= geom.expandedListHeight + 0.5 else { return nil }

        // AppKit 全局坐标 Y 轴向上：芯片列第 0 枚胶囊的上沿 = 托盘内容顶边
        // 往下 `trayPadTop`（内边距）+ `slotHeight`（预览卡槽）+ `sectionGap`（卡与芯片列间距）。
        let chipsTopY = trayRect.maxY - m.trayPadTop - geom.slotHeight - geom.sectionGap
        guard abs(mouse.x - trayRect.midX) <= geom.chipWidth / 2 else { return nil }

        let dy = chipsTopY - mouse.y
        guard dy >= 0, dy < naturalListH else { return nil }
        let rawIndex = Int(dy / m.chipRailStep)
        // 只吃「芯片胶囊自身高度 + 半个间距」的范围，芯片列下方的留白不算命中
        let inChip = dy - CGFloat(rawIndex) * m.chipRailStep
        guard inChip <= m.chipH + m.chipRailGap / 2 else { return nil }
        return min(max(rawIndex, 0), count - 1)
    }

    private func handleStripMouseDown(at mouse: CGPoint) -> Bool {
        guard !isExitingStrip else { return false }
        // 若指针落在托盘内容区内（不重叠条带），放行给托盘视图处理卡片/芯片点击
        if trayPanel?.isVisible == true,
           let trayRect = currentTrayContentRect,
           trayRect.contains(mouse),
           !(currentStripContentRect?.contains(mouse) ?? false) {
            return false
        }
        switch stripHitTarget(at: mouse) {
        case .tailToggle:
            toggleLaunchSegment()
            return true
        case .runningApp(let idx):
            confirmApp(at: idx)
            return true
        case .launchApp(let idx):
            if launchables.indices.contains(idx) {
                launchApp(launchables[idx])
                return true
            }
            return false
        case .none:
            return false
        }
    }

    private func pollHover() {
        guard isVisible, !isExitingStrip else { return }
        let mouse = NSEvent.mouseLocation
        syncPanelMousePassthrough(at: mouse)
        let now = CFAbsoluteTimeGetCurrent()
        let previousMousePoint = lastMousePoint
        lastMousePoint = mouse

        // 常驻态：只有「指针真在条带内容区内」或「托盘开着且指针在交互区内」才算**活跃交互**；
        // 仅仅停在条带外那圈 8pt 近场环里不算 —— 否则近场环就变成“60Hz 永动机”✗（P3 续航）
        // 离区超过 0.26s ⇒ 收托盘、清 hover、停定时器与直播流，退回真正的 0Hz 空闲（条带本身不动）✓
        // 宽限期内**冻结 hover 状态**（别把托盘提前抡掉）：0.26s 正是 `DockTriggerMachine` 的离区宽限。
        if isShowingPersistentStrip {
            let trayOpen = trayPanel?.isVisible == true
            let insideStrip = currentStripContentRect?.contains(mouse) ?? false
            let activeInteraction = insideStrip || (trayOpen && isPointInInteractiveRegion(mouse))

            if activeInteraction {
                alwaysOnLeaveStartedAt = nil
            } else {
                if alwaysOnLeaveStartedAt == nil {
                    alwaysOnLeaveStartedAt = now
                }
                if let startedAt = alwaysOnLeaveStartedAt, now - startedAt >= Self.alwaysOnLeaveGrace {
                    endAlwaysOnInteraction(exitLaunchSegment: false)
                    return
                }
                // 指针已在条带外：托盘没开、也不在未启动段、没有任何 hover 目标
                // ⇒ 没什么可等的，立刻停掉 60Hz 轮询，真正退回 0Hz（指针再靠近会由近场监听唤醒）✓
                if !trayOpen, !showingLaunchSegment, hoveredAppIndex == nil,
                   hoveredLaunchIndex == nil, !hoveredTailToggle {
                    stopHoverPolling()
                }
                return
            }
        }

        // 指针本帧是否真的在「朝托盘方向推进」：纯沿条带横向/纵向平移或停住都不算推进，
        // 避免斜向起手后再沿条带慢滑时把宽限无限续命。
        let isAdvancing: Bool = previousMousePoint.map { previous in
            switch position {
            case .bottom: return (mouse.y - previous.y) >= 0.4
            case .left:   return (mouse.x - previous.x) >= 0.4
            case .right:  return (previous.x - mouse.x) >= 0.4
            }
        } ?? true

        // 若指针正落在 currentTrayContentRect 内，保持当前 hoveredAppIndex 不变（绝不清空托盘）
        if trayPanel?.isVisible == true,
           let trayRect = currentTrayContentRect,
           trayRect.contains(mouse) {
            // 已经进托盘 ⇒ 上一段「斜向移入」判定结束，清掉宽限态避免跨段残留
            if diagonalHoldStartedAt != nil || lastSafeAnchorPoint != nil {
                resetDiagonalGuard()
            }
            if hoveredTailToggle { hoveredTailToggle = false }
            if hoveredLaunchIndex != nil { hoveredLaunchIndex = nil }
            // 侧边芯片叠卡几何兜底触发：防止非激活 NSPanel 内 SwiftUI .onHover 漏触发；
            // 仅当指针落入下方芯片叠卡区时展开，停在上方预览卡时不展开、展开后回上方也不收起。
            if position.isVertical,
               WindowLayout.current == .rail,
               !isSideChipStackExpanded,
               let group = activeHoveredGroup,
               group.windows.count > 1 {
                let geom = metrics.sideRailGeometry(
                    windows: group.windows,
                    maxHeight: trayAvailableSize.height,
                    expanded: isSideChipStackExpanded
                )
                let stackBandH = metrics.trayPadBottom + geom.collapsedListHeight + geom.sectionGap * 0.5
                if mouse.y <= trayRect.minY + stackBandH {
                    expandSideChipStack()
                }
            }
            // 展开态芯片几何兜底：非激活 NSPanel 内 SwiftUI `.onHover` 在 `setFrame` 撑高后
            // 会滞后/丢事件 ⇒ 60Hz 轮询自己按几何算「鼠标压在第几枚芯片上」，命中即切选中窗。
            if let idx = expandedSideChipHitIndex(at: mouse) {
                hoverWindow(at: idx)
            }
            return
        }

        // Safe-Triangle 防误串：托盘在场、且已有一个被 hover 的图标时，从它斜向移往托盘途中
        // 压到隔壁图标不立刻抢切（详见 `shouldHoldDiagonalApproach`）。
        let trayApproachRect = (trayPanel?.isVisible == true) ? currentTrayContentRect : nil
        let canHoldForTray = (trayApproachRect != nil) && (hoveredAppIndex != nil)

        switch stripHitTarget(at: mouse) {
        case .tailToggle:
            if hoveredLaunchIndex != nil { hoveredLaunchIndex = nil }
            if !hoveredTailToggle {
                if canHoldForTray,
                   let trayRect = trayApproachRect,
                   shouldHoldDiagonalApproach(at: mouse, trayRect: trayRect, now: now, isAdvancing: isAdvancing) {
                    return
                }
                hoveredTailToggle = true
                diagonalHoldStartedAt = nil
            }
        case .runningApp(let idx):
            if hoveredTailToggle { hoveredTailToggle = false }
            if hoveredAppIndex != idx {
                if canHoldForTray,
                   let trayRect = trayApproachRect,
                   shouldHoldDiagonalApproach(at: mouse, trayRect: trayRect, now: now, isAdvancing: isAdvancing) {
                    // 宽限期内保持当前图标与托盘不动（绝不切格）
                    return
                }
                hoverApp(at: idx)
                lastSafeAnchorPoint = mouse
                diagonalHoldStartedAt = nil
            } else {
                // 指针就压在「当前 hovered 图标自身」上 ⇒ 这个位置是斜向移入的合法起点
                lastSafeAnchorPoint = mouse
            }
        case .launchApp(let idx):
            if hoveredTailToggle { hoveredTailToggle = false }
            if hoveredLaunchIndex != idx {
                hoveredLaunchIndex = idx
            }
        case .none:
            if hoveredTailToggle { hoveredTailToggle = false }
            if hoveredLaunchIndex != nil { hoveredLaunchIndex = nil }
        }
    }

    // MARK: - Safe-Triangle 防误串（斜向移入托盘不误切隔壁图标）

    /// 返回 true 表示「本帧不要切图标」：指针正沿 triangle 斜向推进到当前托盘里。
    ///
    /// 三条分支：
    /// - 不在 triangle 内（纯沿条带横扫 / 远离托盘 / 偏出锥区）⇒ 立刻返回 false，调用方保持 0ms 瞬时切格；
    /// - 刚进宽限 ⇒ 记时，本帧不切；
    /// - 已超 `diagonalHoldGraceLimit` 且指针停住 ⇒ 用户真的停在隔壁图标上，放行切格并清宽限态。
    private func shouldHoldDiagonalApproach(
        at point: CGPoint,
        trayRect: CGRect,
        now: CFAbsoluteTime,
        isAdvancing: Bool
    ) -> Bool {
        guard let anchor = lastSafeAnchorPoint,
              DockLayoutGeometry.isPointInTrayApproachTriangle(
                point: point,
                anchor: anchor,
                trayRect: trayRect,
                position: position
              ) else {
            diagonalHoldStartedAt = nil
            return false
        }

        if diagonalHoldStartedAt == nil {
            diagonalHoldStartedAt = now
        }
        guard let startedAt = diagonalHoldStartedAt else { return false }
        let elapsed = now - startedAt
        // 还在斜向推进 ⇒ 一直保持；已经停住 ⇒ 只给 0.18s 宽限
        if isAdvancing || elapsed <= Self.diagonalHoldGraceLimit {
            return true
        }
        diagonalHoldStartedAt = nil
        return false
    }

    /// 重置 Safe-Triangle 防误串状态（开局 / 收局 / 收起托盘 / 进出托盘段时调用，避免跨局残留 anchor）。
    private func resetDiagonalGuard() {
        lastSafeAnchorPoint = nil
        diagonalHoldStartedAt = nil
        lastMousePoint = nil
    }

    // MARK: - 系统监听与缓存续鲜

    /// 按**进程存活**洗一遍名单：`didTerminate` 通知还在队列里排队时，缓存/枚举结果里
    /// 依旧会带着刚退出的 App（病例 2026-11-27：微信刚退出就贴边唤起，它死死钉在排头第一位）✗
    ///
    /// - Parameter prunedSince: 非 nil 时额外剪掉「这时刻之后被通知显式剪过的 PID」
    ///   （通知比枚举晚到那一类：缓存 epoch 已变，枚举还在路上）✓
    private func filterAliveGroups(_ list: [AppGroup], prunedSince: CFAbsoluteTime? = nil) -> [AppGroup] {
        let alivePIDs = Set(
            NSWorkspace.shared.runningApplications.lazy
                .filter { !$0.isTerminated }
                .map(\.processIdentifier)
        )
        let pruned = prunedSince.map { activePrunedPIDs(since: $0) } ?? []
        return list.filter { alivePIDs.contains($0.pid) && !pruned.contains($0.pid) }
    }

    /// 自动隐藏态（非常驻）：terminate / hide 时**立即**从当前屏幕上的条带名单里剪掉该 PID。
    ///
    /// 病例（2026-11-27）：老三段只调了 `prunePIDFromCache`（剪后台缓存），
    /// 屏幕上正在显示的 `groups` 一个字没动 ⇒ 已退出的 App 直到下一次真实枚举才消失 ✗
    private func prunePIDFromVisibleAutoHideGroups(_ pid: pid_t) {
        guard !isAlwaysOnActive, isVisible, !isExitingStrip,
              groups.contains(where: { $0.pid == pid }) else { return }

        // hover 身份按 **PID** 记：删项后下标会错位，按下标重映射必然点错 App ✗
        let hoveredPIDNow: pid_t? = hoveredAppIndex.flatMap { groups.indices.contains($0) ? groups[$0].pid : nil }
        var remaining = groups
        remaining.removeAll { $0.pid == pid }
        groups = remaining

        if let hoveredPIDNow, hoveredPIDNow != pid,
           let newIndex = groups.firstIndex(where: { $0.pid == hoveredPIDNow }) {
            hoveredAppIndex = newIndex
            let windowCount = groups[newIndex].windows.count
            selectedWindowIndex = min(selectedWindowIndex, max(0, windowCount - 1))
            if trayPanel?.isVisible == true, let screen = activeScreen {
                updateTray(for: newIndex, on: screen)
            }
        } else if hoveredPIDNow != nil {
            hoveredAppIndex = nil
            selectedWindowIndex = 0
            isSideChipStackExpanded = false
            hideTray()
        }

        // 立刻重排：`layoutAndShowStrip` 内部会把 `runningSlots` 同步成新名单（无幽灵槽）✓
        if let screen = activeScreen ?? activeDisplayID.flatMap(Self.screen(for:)) {
            layoutAndShowStrip(on: screen)
        }
    }

    private func prunePIDFromCache(_ pid: pid_t) {
        cacheEpoch &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        recentlyPrunedPIDs[pid] = now
        recentlyPrunedPIDs = recentlyPrunedPIDs.filter { now - $0.value <= 2.0 }
        for displayID in freshGroupsByDisplay.keys {
            freshGroupsByDisplay[displayID]?.groups.removeAll { $0.pid == pid }
        }
    }

    private func activePrunedPIDs(since timestamp: CFAbsoluteTime) -> Set<pid_t> {
        var result: Set<pid_t> = []
        for (pid, prunedAt) in recentlyPrunedPIDs where prunedAt >= timestamp {
            result.insert(pid)
        }
        return result
    }

    private func scheduleCacheRefreshSoon(markDirty: Bool) {
        cacheEpoch &+= 1
        if markDirty {
            for displayID in freshGroupsByDisplay.keys {
                freshGroupsByDisplay[displayID]?.updatedAt = 0
                // 标脏 = 名单不再可信，下次唤起必须重枚举；干净的缓存才能 0ms 直出 ✓
                freshGroupsByDisplay[displayID]?.isFresh = false
            }
        }
        guard !isVisible else { return }
        debouncedRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.refreshAllDisplaysCacheInBackground()
        }
        debouncedRefreshWork = work
        // 避开切焦后 0~400ms 的目标 App 激活窗口（旧 0.15s 会在 Chrome/ELYTerminal 刚激活时立刻去扫 kAXWindowsAttribute 争抢 IPC ✓）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func refreshAllDisplaysCacheInBackground() {
        let screensSnapshot: [(CGDirectDisplayID, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (num.uint32Value, screen)
        }
        guard !screensSnapshot.isEmpty else { return }
        let epochAtStart = cacheEpoch

        Task.detached(priority: .utility) {
            let rawByDisplay: [(CGDirectDisplayID, NSScreen, [AppGroup])] = screensSnapshot.map { displayID, screen in
                (displayID, screen, WindowEnumerator.rawGroups(on: screen, includeMinimized: true))
            }
            let candidates = DockAppsProvider.computeCandidates()
            let running = DockAppsProvider.computeRunningSet()

            await MainActor.run { [weak self] in
                guard let self, epochAtStart == self.cacheEpoch else { return }
                DockAppsProvider.storeCandidates(candidates)
                DockAppsProvider.storeRunningSet(running)
                let updatedAt = CFAbsoluteTimeGetCurrent()
                for (displayID, originalScreen, raw) in rawByDisplay {
                    let currentScreen = Self.screen(for: displayID) ?? originalScreen
                    let ordered = WindowEnumerator.orderByMRU(raw, on: currentScreen)
                    self.freshGroupsByDisplay[displayID] = CachedGroups(
                        groups: self.filterAliveGroups(ordered),
                        updatedAt: updatedAt,
                        isFresh: true
                    )
                }
            }
        }
    }

    private func installSystemObservers() {
        let lockToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 锁屏：常驻模式**不关**（解锁后就该还在），只把临时交互收一下；
                // 锁屏伴随的屏幕休眠会走 screensDidSleepNotification，唤醒时 resync 接回来 ✓
                if self.isAlwaysOnActive {
                    self.endAlwaysOnInteraction(exitLaunchSegment: true)
                    return
                }
                self.dismiss(reason: "锁屏")
            }
        }
        distributedObservers.append(lockToken)

        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 休眠：常驻态只收临时交互，**不清 isAlwaysOnActive**（唤醒后恢复）✓
                    if self.isAlwaysOnActive {
                        self.endAlwaysOnInteraction(exitLaunchSegment: true)
                        return
                    }
                    self.dismiss(reason: "系统休眠")
                }
            }
            observers.append(token)
        }

        // 唤醒：常驻态接回条带；自动隐藏态顺手后台预热缓存，避免久置唤醒后首次贴边冷启空窗 ✓
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isAlwaysOnActive {
                        self.resyncAlwaysOnAfterWake()
                    } else {
                        self.scheduleCacheRefreshSoon(markDirty: false)
                    }
                }
            }
            observers.append(token)
        }

        // 退出 / 隐藏：同步立刻从所有屏缓存中剪掉该 PID，并做轻防抖后台续鲜。
        // 常驻态还要**立即**从条带名单里剪掉并原地重排（不等后台枚举）✓
        for name in [
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
        ] {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let pid {
                        self.prunePIDFromCache(pid)
                    }
                    if self.isAlwaysOnActive {
                        if let pid {
                            self.prunePIDFromAlwaysOnGroups(pid)
                        }
                        // 退出可能是被卸载 ⇒ 顺手重扫 candidates；隐藏只是状态变化 ⇒ 不重扫 ✓
                        let needsCandidates = (name == NSWorkspace.didTerminateApplicationNotification)
                        self.refreshAlwaysOnGroupsSoon(includeCandidates: needsCandidates)
                    } else if let pid {
                        // ★★ 2026-11-27:自动隐藏态（用户默认口径）也得把**屏幕上正在显示的**名单
                        //   就地剪一遍 —— 只剪后台缓存的话，已退出的 App 会一直钉在排头第一位 ✗
                        self.prunePIDFromVisibleAutoHideGroups(pid)
                    }
                    self.scheduleCacheRefreshSoon(markDirty: false)
                }
            }
            observers.append(token)
        }

        // 激活 / 启动 / 取消隐藏 / 切空间：标脏缓存并在关闭态下轻防抖（0.15s）后台续鲜；
        // 常驻态额外重评全屏避让（切换全屏 App / 切 Space 都会走这里）并防抖续鲜名单 ✓
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleCacheRefreshSoon(markDirty: true)
                    if self.isAlwaysOnActive {
                        self.scheduleAlwaysOnFullscreenEvaluation()
                        // 只有「新 App 起来了」才需要重扫 Dock plist / LaunchServices；
                        // 切 App / 取消隐藏 / 换 Space 只刷窗口名单（didActivate 一天上千次，重扫太贵）✓
                        let needsCandidates = (name == NSWorkspace.didLaunchApplicationNotification)
                        self.refreshAlwaysOnGroupsSoon(includeCandidates: needsCandidates)
                    }
                }
            }
            observers.append(token)
        }

        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.freshGroupsByDisplay.removeAll()
                self.lastPrewarmStartedAt.removeAll()
                self.prewarmInFlightDisplays.removeAll()
                self.prewarmEpochByDisplay.removeAll()
                self.prewarmStartedAtByDisplay.removeAll()
                self.debouncedRefreshWork?.cancel()
                self.debouncedRefreshWork = nil
                self.cacheEpoch &+= 1
                // 常驻态：重新解析目标屏 + 重评全屏 + 原地重排，**不** dismiss 掉常驻模式 ✓
                if self.isAlwaysOnActive {
                    self.handleAlwaysOnScreenParametersChanged()
                    return
                }
                if self.isVisible {
                    self.dismiss(reason: "屏幕参数变化")
                }
                // 屏参变化清完旧屏缓存后立即排一趟后台预热，下次贴边直接 0ms 热出 ✓
                self.scheduleCacheRefreshSoon(markDirty: false)
            }
        }
        observers.append(screenToken)

        let iconToken = NotificationCenter.default.addObserver(
            forName: IconProvider.iconCacheDidFill,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // ★★ 2026-11-25 根因 C:即使此刻 `!isVisible` 也要自增 —— 下一局首次求值时就是新值,
                //   不会把旧 token 带过去 ✓(自增本身只是几纳秒,不值得为它加条件)
                self.iconRevision &+= 1
                guard self.isVisible else { return }
                self.objectWillChange.send()
            }
        }
        observers.append(iconToken)
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }
}
