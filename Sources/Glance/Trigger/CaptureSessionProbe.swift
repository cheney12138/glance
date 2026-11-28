import AppKit
import CoreGraphics
import GlanceCore

/// 截图会话的**证据采集**(plumbing)。裁决在核里:`GlanceCore.CaptureSessionRule`。
///
/// 分工的理由见那个文件的头注:判断"这颗回车归谁"是纯逻辑(可单测),
/// 而"读前台 App / 读窗口清单"是 AppKit 与窗口服务器的事(只能真机验)。
///
/// 调用点只有一处:`HotkeyTapCenter.captureSessionTookOver`(**导航期的固定键**:回车/方向/Esc/QWM…),
/// 另一个入口是**触控按下时的预热**(`ThreeFingerTap.contactFrame` ⇒ `prewarmAsync()`,见下)。
///
/// 证据带一层**微缓存**(见 `cacheTTL`):导航键会被长按连发(方向键 ~30 发/秒),
/// 而每次采集都要问一次窗口服务器 —— 缓存放进来之后,事件路径上的开销与按键频率无关了。
/// 0.25s 的陈旧度对"取景框在不在"这件事完全够用:用户在按回车/方向键之前,取景框已经开了一会儿。
///
/// ## 为什么要 `prewarmAsync`(2026-11-25 病例:偶发唤起延迟)
///
/// 原先 `verdict()` **只在主线程被调**(三指抬手 → `DispatchQueue.main.async` → 判卷),
/// 微缓存一 miss 就在主线程同步跑 `CGWindowListCopyWindowInfo` + `NSWorkspace.runningApplications`
/// —— 实测 5–40ms 的偶发卡顿,正好落在"抬手 → 面板上屏"那一拍上,读起来就是"有时候要等一下才弹"。
/// ⇒ 三指**按下**(到抬手天然有 50–180ms)时先把证据在**后台**采好写好缓存,
///   抬手判卷那一步就稳定命中热缓存(0ms)✓。
///
/// 线程纪律:缓存/日志去重/预热状态都受 `lock` 保护;`evidence()` 只做**只读查询**
/// (`CGWindowListCopyWindowInfo`、`NSWorkspace.runningApplications`、`NSWorkspace.frontmostApplication`、
/// `NSRunningApplication.bundleIdentifier`、`UserDefaults` 读)⇒ 在后台线程安全 ✓;
/// 这里**不碰**任何 UI 对象,也不调用 `NSWorkspace.open/activate` 一类会摸 `NSApp` 的接口 ✗。
enum CaptureSessionProbe {
    /// 判定。返回值里的 `reason` 进日志 —— 这类规则只在真机被咬到才复现,
    /// 事后必须能一眼看出"当时按哪一条判的"。
    /// ⚠️ 它在**主线程**(事件路径)上被调 ⇒ 走不到这里的那一半必须靠 `prewarmAsync` 预付 ✓
    static func verdict() -> CaptureSessionRule.Verdict {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let cache = cached, now - cache.at < cacheTTL {
            let hit = cache.verdict
            lock.unlock()
            return hit
        }
        lock.unlock()
        // 缓存 miss:仍然当场采一次(正确性优先 —— 宁可这一拍慢,也不能拿过期结论判卷)
        // ★ 采集**开始**的时刻先记下来(见 `store` 里的"旧证据不覆盖新裁决")
        let startedAt = CFAbsoluteTimeGetCurrent()
        let fresh = CaptureSessionRule.verdict(evidence(), extraBundleIDs: extraBundleIDs)
        // ⚠️ 时间戳在**采集之后**取:预热线程可能同时写缓存 ⇒ 用"算完的时刻"可保证
        //   两个写者不会把 `at` 推回去(否则缓存会被误判成更陈旧,白多采一次)✓
        store(fresh, startedAt: startedAt, at: CFAbsoluteTimeGetCurrent())
        return fresh
    }

    /// **后台预热**(三指/四指按下时由 `contactFrame` 调,见上)。
    /// 只做一件事:把 `evidence()` + 裁决提前算好写进缓存 ⇒ 抬手判卷时 `verdict()` 稳定 0ms 命中。
    /// 防刷爆:缓存还热(< `prewarmMinInterval`)、已经有一次预热在途、或距上次预热太近 ⇒ 直接跳过
    /// (每帧都来问也无所谓 ✓)。
    static func prewarmAsync() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if prewarmInFlight {
            lock.unlock(); return
        }
        if let cache = cached, now - cache.at < prewarmMinInterval {
            lock.unlock(); return
        }
        guard now - lastPrewarmAt >= prewarmMinInterval else {
            lock.unlock(); return
        }
        prewarmInFlight = true
        lastPrewarmAt = now
        lock.unlock()
        // ★ 2026-11-25 病例(预热把**更新**的裁决盖成旧的):
        //   T0 预热开始采 → T1 主线程 `verdict()` 采完写入 → T3 预热才落盘,用 T3 的陈旧证据
        //   盖掉了 T1 那份更新的 ⇒ 抬手判卷拿到的是"更早那一刻"的取景框状态 ✗
        //   ⇒ 采集**开始**的时刻随结果一起走,落盘时谁更旧谁让路(见 `store`)。
        //   必须在 `evidence()` **之前**取:在它之后取就退化成"谁算完谁赢"✓
        let startedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .userInitiated).async {
            // 只读采集(见文件头注的线程纪律)⇒ 后台跑没问题 ✓
            let fresh = CaptureSessionRule.verdict(evidence(), extraBundleIDs: extraBundleIDs)
            store(fresh, startedAt: startedAt, at: CFAbsoluteTimeGetCurrent())
            // ⚠️ 无论这次结果是否被丢弃,在途标记都必须复位 —— 否则预热从此再也不发生 ✗
            lock.lock()
            prewarmInFlight = false
            lock.unlock()
        }
    }

    /// 写缓存 + "裁决变化时才打一行"(主线程与预热线程共用 ⇒ 全部在锁内改,日志出锁再打)
    /// - Parameter startedAt: 这次证据**开始采集**的时刻。已有缓存是更新的那次采集 ⇒ 直接丢弃本次结果。
    private static func store(_ fresh: CaptureSessionRule.Verdict, startedAt: CFAbsoluteTime, at now: CFAbsoluteTime) {
        lock.lock()
        // ★ 旧证据不许覆盖新裁决(T0 预热 vs T1 主线程那条病例,见 `prewarmAsync`)
        if let cache = cached, cache.startedAt > startedAt {
            lock.unlock()
            return
        }
        cached = (at: now, startedAt: startedAt, verdict: fresh)
        let changed = lastLoggedReason != fresh.reason
        if changed { lastLoggedReason = fresh.reason }
        lock.unlock()
        // **裁决变化时才打一行**(不是每一次按键):2026-09-15 的 `CGEData` 病例里,
        // 裁决从"无截图会话"永久翻成"截图会话",所有导航键静默放行 —— 只有变化点那一行日志
        // 能让这类"永久误报"一眼现形;按按键频率打会刷屏,反而没人看
        guard changed else { return }
        glog("[T32] 截图裁决 → \(fresh.isCapture ? "认作截图会话" : "无截图会话"): \(fresh.reason)")
    }

    /// 缓存 / 日志去重 / 预热状态的总锁。只保护这几个标量,临界区里**不做 IO、不采集** ✓
    private static let lock = NSLock()

    /// 上一次打过的理由(只在变化时打)
    private static var lastLoggedReason: String?

    /// 微缓存。**不是定时器**:没有轮询,只是"算过就记一下,下次离得近就直接用"
    /// `startedAt` = 这份证据**开始采集**的时刻(不是算完/落盘的时刻)⇒ 用来挡"旧结果覆盖新裁决"
    private static var cached: (at: CFAbsoluteTime, startedAt: CFAbsoluteTime, verdict: CaptureSessionRule.Verdict)?
    private static let cacheTTL: CFAbsoluteTime = 0.25

    /// 预热的最小间隔(与"缓存够不够新"同一量级):按住三/四指的整段时间里不让它反复采 ✓
    private static let prewarmMinInterval: CFAbsoluteTime = 0.15
    /// 已有一次预热在途(采集中)⇒ 后来的请求全部跳过
    private static var prewarmInFlight = false
    /// 上一次发起预热的时刻(节流用;受 `lock` 保护)
    private static var lastPrewarmAt: CFAbsoluteTime = 0

    /// 用户手工口径:白名单天生不全,但**不上设置界面**(设置面板只留开关与 bar,见 T18)。
    /// 要用就这么写一行(不用重启 App,`UserDefaults` 每次现读):
    ///
    ///     defaults write com.cheney12138.macswitcher switch.captureApps -array "com.foo.bar"
    private static var extraBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Keys.switchCaptureApps) ?? [])
    }

    // MARK: - 采集

    /// ⚠️ 线程口径(2026-11-25):这个函数**会在后台线程被调**(`prewarmAsync` 的预热路)。
    /// 它只做只读查询 —— 窗口服务器(`CGWindowListCopyWindowInfo`)、`NSWorkspace` 的
    /// `frontmostApplication` / `runningApplications`、`NSRunningApplication.bundleIdentifier`,
    /// 都是**查询型**接口(不碰 UI 对象、不碰 `NSApp`、不改状态)⇒ 后台读安全 ✓。
    /// 将来若往里加"打开/激活/发通知"一类接口,必须挪回主线程 ✗(那类接口会摸 `NSApp`)。
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
                    // ★ 2026-10-19:`screencaptureui` 是后台型进程(activationPolicy == .prohibited),
                    //   个别系统版本里 `bundleIdentifier` 读出来是 nil ⇒ 取景框归因不上 ⇒
                    //   裁决退回"无截图会话",回车又会被两边各收一次(T32 复发)。
                    //   窗口属主名是硬的,读不到 bundleID 时用它补一个规范 id ✓
                    ownerBundleID: Self.bundleID(pid: pid, windows: windows)
                )
            }
        )
    }

    private static func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// 属主 pid → bundle id;读不到时按**窗口属主名**补系统截图 UI 的规范 id。
    private static func bundleID(pid: pid_t, windows: [[String: Any]]) -> String? {
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return id }
        let owner = windows.first { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid }
            .flatMap { $0[kCGWindowOwnerName as String] as? String }
        return owner.flatMap { name in
            (name == "screencaptureui" || name == "screencapture") ? "com.apple.screencaptureui" : nil
        }
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
