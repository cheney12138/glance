import AppKit
import CoreGraphics

/// 权限门禁:辅助功能 + 屏幕录制两项系统权限的检测 / 申请 / 轮询。
/// 门禁语义:任一项缺失即未就绪,后续 T3 起的功能模块只读 `allGranted`,不各自再查。
@MainActor
final class PermissionMonitor: ObservableObject {			
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenCaptureGranted = false

    var allGranted: Bool { accessibilityGranted && screenCaptureGranted }
    var statusLine: String { allGranted ? "权限 ✅ 全部就绪" : "权限 ⚠️ 需要授权" }

    private var pollTimer: Timer?

    /// 拉取最新授权状态;齐了停轮询,没齐继续轮询(用户正在系统设置里勾选中,回来要给反馈)
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if allGranted {	
            stopPolling()
        } else {
            startPolling()
        }
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

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        print("[mac-switcher] 权限就绪,门禁打开")
    }
}
