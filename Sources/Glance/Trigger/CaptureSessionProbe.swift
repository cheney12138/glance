import AppKit
import CoreGraphics
import GlanceCore

/// 截图会话的**证据采集**(plumbing)。裁决在核里:`GlanceCore.CaptureSessionRule`。
///
/// 分工的理由见那个文件的头注:判断"这颗回车归谁"是纯逻辑(可单测),
/// 而"读前台 App / 读窗口清单"是 AppKit 与窗口服务器的事(只能真机验)。
///
/// 调用点只有一处:`HotkeyTapCenter.captureSessionTookOver`(**导航期的固定键**:回车/方向/Esc/QWM…)。
///
/// 证据带一层**微缓存**(见 `cacheTTL`):导航键会被长按连发(方向键 ~30 发/秒),
/// 而每次采集都要问一次窗口服务器 —— 缓存放进来之后,事件路径上的开销与按键频率无关了。
/// 0.25s 的陈旧度对"取景框在不在"这件事完全够用:用户在按回车/方向键之前,取景框已经开了一会儿。
enum CaptureSessionProbe {
    /// 判定。返回值里的 `reason` 进日志 —— 这类规则只在真机被咬到才复现,
    /// 事后必须能一眼看出"当时按哪一条判的"。
    static func verdict() -> CaptureSessionRule.Verdict {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = cached, now - cache.at < cacheTTL { return cache.verdict }
        let fresh = CaptureSessionRule.verdict(evidence(), extraBundleIDs: extraBundleIDs)
        cached = (at: now, verdict: fresh)
        // **裁决变化时才打一行**(不是每一次按键):2026-09-15 的 `CGEData` 病例里,
        // 裁决从"无截图会话"永久翻成"截图会话",所有导航键静默放行 —— 只有变化点那一行日志
        // 能让这类"永久误报"一眼现形;按按键频率打会刷屏,反而没人看
        if lastLoggedReason != fresh.reason {
            lastLoggedReason = fresh.reason
            glog("[T32] 截图裁决 → \(fresh.isCapture ? "认作截图会话" : "无截图会话"): \(fresh.reason)")
        }
        return fresh
    }

    /// 上一次打过的理由(只在变化时打)
    private static var lastLoggedReason: String?

    /// 微缓存。**不是定时器**:没有轮询、没有后台线程,只是"算过就记一下,下次离得近就直接用"
    private static var cached: (at: CFAbsoluteTime, verdict: CaptureSessionRule.Verdict)?
    private static let cacheTTL: CFAbsoluteTime = 0.25

    /// 用户手工口径:白名单天生不全,但**不上设置界面**(设置面板只留开关与 bar,见 T18)。
    /// 要用就这么写一行(不用重启 App,`UserDefaults` 每次现读):
    ///
    ///     defaults write com.cheney12138.macswitcher switch.captureApps -array "com.foo.bar"
    private static var extraBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Keys.switchCaptureApps) ?? [])
    }

    // MARK: - 采集

    private static func evidence() -> CaptureSessionEvidence {
        let front = NSWorkspace.shared.frontmostApplication
        // 窗口清单只取一次,两条判据(系统 UI 在不在 / 有没有铺满屏的覆盖窗)共用
        let windows = onScreenWindows()
        let overlays = screenWideOverlays(in: windows)
        return CaptureSessionEvidence(
            frontmostBundleID: front?.bundleIdentifier,
            frontmostName: front?.localizedName,
            frontmostPID: front?.processIdentifier,
            systemCaptureUIRunning: systemCaptureUIRunning(windows: windows),
            screenWideOverlays: overlays.map { pid in
                CaptureSessionEvidence.ScreenWideOverlay(
                    ownerPID: pid,
                    ownerBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                )
            }
        )
    }

    private static func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// 系统截图 UI 在不在。两条路一起看,理由是它们的失效方式不同:
    ///   · `runningApplications` —— 对"后台型 App"(`activationPolicy == .prohibited`)的收录口径
    ///     在系统版本间变过,而 `screencaptureui` 恰好是这一类,只信它一条会漏;
    ///   · **窗口属主** —— 取景框/浮窗缩略图只要在屏幕上,窗口清单里就一定有。
    /// (第三条"前台就是它"由核负责:前台 bundle id 本来就在证据里。)
    private static func systemCaptureUIRunning(windows: [[String: Any]]) -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            guard let id = app.bundleIdentifier else { return false }
            return CaptureSessionRule.systemUIBundleIDs.contains(id)
        }) { return true }
        return windows.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String
            return owner == "screencaptureui" || owner == "screencapture"
        }
    }

    // MARK: - 通用判据:铺满屏幕的高层覆盖窗

    /// 取景框的层高门槛。实测坐标:普通窗 `layer = 0`,程序坞 20、菜单栏 24、控制中心 25;
    /// 取景框必须"压在一切之上"(各家用 `NSScreenSaverWindowLevel` 量级,远在 100 以上)。
    /// **我们自己的面板是 100 / 101** —— 靠 **PID 排除自己**,不靠层高,
    /// 免得哪天面板的层数一动,这条通用判据就变成"自己的面板把自己判成截图"。
    private static let overlayLayerFloor = 100
    /// 覆盖占比:取景框是整屏的(留几像素误差给不同工具的绘制方式)
    private static let overlayCoverage: CGFloat = 0.92

    /// 铺满屏的高层窗**是谁的**。归因这一层是 2026-09-15 的病例逼出来的(`CGEData`):
    /// 只回答"有没有"会把常驻的屏幕管理类覆盖窗认成取景框,裁决永久成立 → 整套导航键失效。
    private static func screenWideOverlays(in windows: [[String: Any]]) -> [pid_t] {
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let displays = activeDisplayBounds()
        var found: [pid_t] = []
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int else { continue }
            if ownerPID == myPID { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= overlayLayerFloor else { continue }
            // 全透明窗不算(有些工具会留一个不可见的空壳窗)
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha >= 0.05 else { continue }
            guard let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            if displays.contains(where: { covers(frame, $0) }) {
                // 同一进程可能有好几块(实测 DLP 每块屏一块)—— 按 pid 去重,裁决侧只看属主
                let pid = pid_t(ownerPID)
                if !found.contains(pid) { found.append(pid) }
            }
        }
        return found
    }

    /// 活动屏的 Quartz 全局坐标(`kCGWindowBounds` 与 `CGDisplayBounds` 同一套:原点在主屏左上)。
    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        return ids.map(CGDisplayBounds)
    }

    /// "这把窗盖住了这块屏"。只看占比,不要求不越界 —— 取景框常常比屏略大(画了阴影或边框)。
    private static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        let inter = window.intersection(display)
        guard !inter.isNull, display.width > 0, display.height > 0 else { return false }
        return (inter.width * inter.height) / (display.width * display.height) >= overlayCoverage
    }
}
