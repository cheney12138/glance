import AppKit
import CoreGraphics

/// 权限门禁:辅助功能 + 屏幕录制两项系统权限的检测 / 申请 / 轮询。
/// 门禁语义:任一项缺失即未就绪,后续 T3 起的功能模块只读 `allGranted`,不各自再查。
@MainActor
final class PermissionMonitor: ObservableObject {			
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenCaptureGranted = false
    /// 启动后已经真正查过一次权限(防止 onChange(initial:true) 读到"未验证的初值 false"
    /// ⇒ 权限明明齐着还弹引导窗 —— 2026-11-09 用户实报「每次启动都弹一个『全部就绪』的窗」)
    @Published private(set) var hasCheckedSinceLaunch = false
    /// 冷启动缺权 ⇒ 弹引导(初值 false,首次 refresh 缺权时置 true ⇒ 有变化,onChange 能触发 ——
    /// 冷启动 false→false 不触发的问题由它解决,不再靠 initial:true 读未刷新值)
    @Published private(set) var launchGuideNeeded = false

    var allGranted: Bool { accessibilityGranted && screenCaptureGranted }
    var statusLine: String { allGranted ? "权限已就绪" : "需要授权" }

    private var pollTimer: Timer?

    /// 拉取最新授权状态;**齐了降频轮询而不是停**(2026-11-05 病例:齐了停轮询 ⇒ 运行中
    /// 被删权永远检测不到 ⇒ 门禁永远不关,吞键 tap 继续在无权状态下跑 —— reviewer C1)。
    /// 没齐 = 1s(用户正在设置里勾选中,回来要给反馈);齐了 = 5s(低成本的保活对账)。
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !hasCheckedSinceLaunch {
            hasCheckedSinceLaunch = true
            launchGuideNeeded = !allGranted   // 冷启动缺权:让 onChange 看见一个真变化
        }
        startPolling(interval: allGranted ? 5.0 : 1.0)
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
