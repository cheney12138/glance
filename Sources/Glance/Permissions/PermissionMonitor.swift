import AppKit
import CoreGraphics

/// 权限门禁:辅助功能 + 屏幕录制两项系统权限的检测 / 申请 / 轮询。
/// 门禁语义:任一项缺失即未就绪,后续 T3 起的功能模块只读 `allGranted`,不各自再查。
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var screenCaptureGranted: Bool
    /// 启动后已经真正查过一次权限(防止 onChange(initial:true) 读到"未验证的初值 false"
    /// ⇒ 权限明明齐着还弹引导窗 —— 2026-11-09 用户实报「每次启动都弹一个『全部就绪』的窗」)
    @Published private(set) var hasCheckedSinceLaunch: Bool
    /// 冷启动缺权 ⇒ 弹引导(初值 false,经短延迟复核后仍缺权才置 true ⇒ 有变化,onChange 能触发 ——
    /// 冷启动 false→false 不触发的问题由它解决,不再靠 initial:true 读未刷新值；
    /// 重启刚拉起时 TCC 尚未暖机也不在首帧误报弹窗)。
    @Published private(set) var launchGuideNeeded = false
    /// 冷启动 TCC 暖机复核(+0.35s / +1.0s 两拍)是否**还在途**。
    /// 意义:这段时间里 `allGranted == false` **不可信**(重启后前 1s 内 AX / 录屏探测偶发返回 false),
    /// 消费方(GlanceApp.syncDockSubsystem)据此**暂缓**破坏性动作(还原原生 Dock = killall 一次)✓
    /// ★ 为什么是 `@Published` 而不是"由 `launchRecheckTask` 现算"的计算属性:消费方要靠
    ///   `onChange(of:)` 等它**落定那一拍**收口,而复核结束时 `refresh()` 往往一个权限值都没改
    ///   (只是确认"确实没给")⇒ 没有任何别的 `objectWillChange` 可搭车,计算属性翻不出去 ✗
    ///   值由 `launchRecheckTask` 的 `didSet` 单向派生,只在一处改 ✓
    @Published private(set) var isLaunchRechecking = false

    var allGranted: Bool { accessibilityGranted && screenCaptureGranted }
    var statusLine: String { allGranted ? "权限已就绪" : "需要授权" }

    private var pollTimer: Timer?
    /// 冷启动复核任务句柄。`isLaunchRechecking` 由它派生(唯一写点,不许两边各写一份 —— 见 Keys 那条同理)
    private var launchRecheckTask: Task<Void, Never>? {
        didSet {
            let running = launchRecheckTask != nil
            if isLaunchRechecking != running { isLaunchRechecking = running }
        }
    }
    /// 复核任务的世代号:老任务收尾时不许把**新任务**的句柄抹掉(否则 `isLaunchRechecking` 假阴性)✓
    private var launchRecheckGeneration = 0

    init() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        self.accessibilityGranted = ax
        self.screenCaptureGranted = sc
        self.hasCheckedSinceLaunch = true
        let granted = ax && sc
        startPolling(interval: granted ? 5.0 : 1.0)
        if !granted {
            scheduleLaunchRecheck()
        }
    }

    /// 拉取最新授权状态;**齐了降频轮询而不是停**(2026-11-05 病例:齐了停轮询 ⇒ 运行中
    /// 被删权永远检测不到 ⇒ 门禁永远不关,吞键 tap 继续在无权状态下跑 —— reviewer C1)。
    /// 没齐 = 1s(用户正在设置里勾选中,回来要给反馈);齐了 = 5s(低成本的保活对账)。
    func refresh() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        // 仅在值真变时写入 @Published,避免 5s 保活轮询每次空发两次 objectWillChange ✓
        if accessibilityGranted != ax { accessibilityGranted = ax }
        if screenCaptureGranted != sc { screenCaptureGranted = sc }
        if !hasCheckedSinceLaunch {
            hasCheckedSinceLaunch = true
        }
        if allGranted {
            cancelLaunchRechecks()
        }
        startPolling(interval: allGranted ? 5.0 : 1.0)
    }

    /// 重启/重装刚拉起时 TCC 服务可能还在暖机窗口,前几百毫秒内探测偶发返回 false。
    /// 首帧不立刻置 `launchGuideNeeded = true` 弹窗口,而是安排 +0.35s 与 +1.0s 短延迟复核:
    /// 复核变 true 则静默恢复正常图标,仍缺权才置 `launchGuideNeeded = true` 弹引导。
    private func scheduleLaunchRecheck() {
        cancelLaunchRechecks()
        launchRecheckGeneration &+= 1
        let generation = launchRecheckGeneration
        launchRecheckTask = Task { @MainActor [weak self] in
            // 无论下面从哪条 return 出去(成功 / 取消 / still 缺权),句柄都要清 ——
            // 否则 `isLaunchRechecking` 永远 true,消费方会永远暂缓原生 Dock 的收口 ✗
            defer { self?.endLaunchRecheck(generation: generation) }

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            if self.allGranted { return }

            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self.refresh()
            if !self.allGranted && !self.launchGuideNeeded {
                self.launchGuideNeeded = true
            }
        }
    }

    /// 复核任务收尾:只清**自己这一代**的句柄(被取消的老任务收尾时不许动新任务)✓
    private func endLaunchRecheck(generation: Int) {
        guard generation == launchRecheckGeneration else { return }
        launchRecheckTask = nil
    }

    private func cancelLaunchRechecks() {
        launchRecheckTask?.cancel()
        launchRecheckTask = nil
    }

    /// 申请辅助功能。系统弹窗每进程只弹一次,之后由轮询确认结果;同时打开设置页当兜底
    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openSettings(anchor: "Privacy_Accessibility")
    }

    /// 申请屏幕录制。CGRequest 只在首次弹窗,之后仅返回当前状态,故同时打开设置页兜底
    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startPolling(interval: TimeInterval) {
        if let t = pollTimer, t.timeInterval == interval { return }   // 间隔没变就不动(避免每次 refresh 重置)
        pollTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.2   // 允许系统定时器合并唤醒,省电 ✓
        pollTimer = t
    }
}
