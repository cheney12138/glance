import AppKit

/// "面板现在在台上吗" —— 只为一个用途存在:**别让预拍与入场抢资源** ✓
/// (2026-09-22 掉帧病例,见 `DebugFlags.sweepDelayMs` 的注释 ✓)
/// 做成 MainActor 上的一个小探针:既不让 Inventory 反向依赖面板层 ✓,
/// 也避开"从后台任务里读 @Published"这类数据竞争 ✗
@MainActor
enum PanelStageProbe {
    static var isVisible: () -> Bool = { false }
}

/// 缩略图的后台"保温" —— 照 AltTab 的取法:**窗口/应用事件驱动刷新**,而不是只在开局那一刻拍。
///
/// 为什么需要:我们已经有了"跨会话保活 + 按显示优先抓图 + 回填重试",所以面板第一帧**总有图**;
/// 但那张图可能是十几分钟前的(内容是旧的),或者那扇窗是刚开1的(缓存里根本没有)。
/// 用户口径是"用 alt tab 永远秒开、秒显示" —— 那就得让缓存**跟着系统事件走**,而不是等开局才补。
///
/// **只用公开事件源**(不碰 AltTab 那条 WindowServer 私有通知层,见 ADR-0002 的圈禁区):
///   · App 激活     → 抓**它自己**的窗(用户刚切过去的那一个,最可能是下一局的首选);
///   · App 退出     → 该 App 的图已经没意义,但真正清账在开局剪枝里做(这里只记账);
///   · 显示器变化   → 尺寸全变了,整块缓存作废(下一局重拍)。
///
/// **刻意不用定时器**:空闲期每隔几秒就抓一遍是拿电池换边际收益。ADR-0004 的教训在这里同样成立 ——
/// 该问的是"有没有必要知道",不是"怎么能知道得更快"。
@MainActor
final class ThumbnailRefresher {
    static let shared = ThumbnailRefresher()
    private init() {}

    private var observers: [NSObjectProtocol] = []
    /// 上一次的屏幕指纹(见 `screenSignature`)—— 用来筛掉 macOS 那些"勤快但没意义"的通知
    private var lastScreenSignature: String = ""
    /// 同一个 App 的刷新节流(快速连续切换时别重复抓)
    private var lastRefreshAt: [pid_t: CFAbsoluteTime] = [:]
    /// 上一次被激活的 App pid(= 在下一次激活发生时刚刚失焦的那个)。见 `handleActivation` 的失焦拍
    private var lastActivatedPID: pid_t?

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleActivation(note) }
        })
        // 屏幕参数变化发在**默认**通知中心上(不是 NSWorkspace 那个,也不是 NSApplication 的)
        //
        // ⚠️ 这条通知 macOS 发得**很勤**,远不止"换了显示器" ✗ —— 菜单栏显隐、分辨率重协商、
        // 显示器休眠唤醒都会发。原来只要收到就整块作废,代价是**下一局重拍十几扇窗**
        // (2026-09-15 实测:一次没有切屏的会话里突然出现 `预截 要拍 10 窗`)。
        // 现在先**比对屏幕清单**(displayID + 尺寸 + 缩放),真的变了才作废。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Self.screenSignature()
                guard now != self.lastScreenSignature else { return }   // 只是通知勤,屏没变
                self.lastScreenSignature = now
                self.invalidateAll(reason: "显示器参数变化")
            }
        })
        lastScreenSignature = Self.screenSignature()
        schedulePeriodicSweep()
        if isTraceEnabled {
            glog("[保温] 已上线:App 激活 → 抓它的窗;显示器变化 → 整块缓存作废;开窗拍 → 5s 轻扫")
        }
    }

    /// **开窗拍**(2026-09-18 用户:「所有 app 都需要这个钩子,不是只对 glance」):
    /// 任何 App 新开的窗,不该等用户下一次唤起面板才第一次被拍。macOS 没有"别家开新窗"
    /// 的通知,就用**低频轻扫**兜住 —— 与关面板预拍同一条路:sweepAllScreens 全量走 TTL
    /// 过滤(谁新谁不拍),没有新窗、没有过期时**一枚快门都不发生**;枚举在后台毫秒级,
    /// 常驻成本可忽略。Glance 自己的设置窗另有一个 0.6s 的即时钩子(开窗即拍,不等扫)。
    private func schedulePeriodicSweep() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.sweepAllScreens(reason: "开窗拍")
            self?.schedulePeriodicSweep()
        }
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              !app.isTerminated else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        // **失焦拍**(T86):本次激活把谁挤下了台,谁就是刚被切走的那个 —— 它的画面停在
        // 用户离开的那一刻(最鲜),而它恰好是下一次唤起面板的"显示组"(唤起即切换落在上一个 App)。
        // 之前只有"激活拍":App 上台那刻拍一次,之后用户用多久图就旧多久 —— 当前 App 的图
        // 永远停在"它上台的那一刻",这是保温体系最后的盲区(T85 账:唤起的显示组 = 上一个 App)。
        // 先记账再走节流:被节流的那次切换,被切走的 App 只上台了不到 1s,它的激活拍还很新,
        // 失焦拍本来也拍不了几下 —— 账不能丢,不然下下局的"上一个 App"就认错了人。
        let deactivated = lastActivatedPID
        lastActivatedPID = pid
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastRefreshAt[pid], now - last < 1.0 { return }
        lastRefreshAt[pid] = now

        // 语境屏取"光标所在屏":刚切过去的那个 App 就在用户眼前,先拍它、且只拍它
        guard let screen = CursorScreenAnchor.cursorScreen else { return }
        Task.detached(priority: .utility) {
            let groups = WindowEnumerator.rawGroups(on: screen)
            if let group = groups.first(where: { $0.pid == pid }), !group.windows.isEmpty {
                if isTraceEnabled {
                    glog("[保温] \(group.appName) 激活 → 拍它 \(group.windows.count) 窗")
                }
                // 激活即重拍(force):刚切过去的那个 App 画面最可能刚变过(换了主题/文件/内容)
                await Snapshotter.shared.precapture(group.windows, force: true)
            }
            // 失焦拍(maxAge 2s):刚切走的那个 App 补一张 —— 2s 内拍过的(快速来回切)不重复。
            // 它不在这块屏上时(跨屏切换)枚举里找不到,交给开局 0.45s 补拍兜底
            if let prev = deactivated, prev != pid,
               let group = groups.first(where: { $0.pid == prev }), !group.windows.isEmpty {
                await Snapshotter.shared.precapture(group.windows, maxAge: 2.0)
            }
        }
    }

    // MARK: - 语境屏保温 sweep(T86)

    /// 冷启动预拍只发一次:onAppear 在 SwiftUI 里可能不止跑一遍,重复 sweep = 全量白拍一遍
    private var didColdStartSweep = false

    /// 把**每一块屏**都枚举一遍,所有本屏窗交给预截(TTL 过滤,谁的图新谁不拍)。
    ///
    /// 为什么全屏:T87 v3 修掉"开局剪枝扔别屏窗"之后(screenshot → `Snapshotter.reapAlive`),
    /// 别屏窗的图**留得住**了 —— 用户会换屏,全屏 sweep 让每一块屏的缓存都是热的,
    /// 换屏唤起不再闪"截图中…"(2026-09-17 用户实测病例:启动时光标在外接,
    /// 切到内建唤起 = 全空)。T86 首轮"只扫光标屏"的裁定随保活修正一并作废,
    /// 当时它治的"拍了就被扔"病根在剪枝,不在 sweep。
    ///
    /// 两个挂载点:
    ///   · **冷启动**(GlanceApp 启动后空闲 2.5s 调)—— T85 实测账:首局唤起上屏 353ms,
    ///     其中冷枚举 256ms(CGWindowList / AX 首连 / SCK 全是第一次)+ 缓存全空。
    ///     sweep 把这套管线在没人看的时候整个暖一遍,首局唤起直接吃热路径;
    ///   · **关面板后**(PanelController.teardownPanel 调)—— 刚关面板时屏幕上就是用户
    ///     刚看到的内容,此刻拍的图对下一次唤起 100% 新鲜,下次唤起的 0.45s 补拍基本空转。
    func sweepAllScreens(reason: String) {
        Task.detached(priority: .utility) {
            // ★ 先让开:关面板那一刻正在收场(托盘/环/图标都在动),紧接着往往就是下一次唤起
            //   ⇒ 15 窗的预拍与入场抢 GPU ⇒ 实测 652ms 长帧 + 下一张缩略图 +546ms 迟到 ✗
            let waitMs = DebugFlags.sweepDelayMs
            if waitMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }
            if await MainActor.run(body: { PanelStageProbe.isVisible() }) {
                glog("[保温] \(reason) 跳过:面板已在台上(不与入场抢资源 ✓)")
                return
            }
            let beganAt = CFAbsoluteTimeGetCurrent()
            // rawGroups 的归属判定保证一扇窗只属于一块屏:按屏枚举天然不重不漏
            var windows: [WindowRecord] = []
            for screen in NSScreen.screens {
                windows.append(contentsOf: WindowEnumerator.rawGroups(on: screen).flatMap(\.windows))
            }
            guard !windows.isEmpty else { return }
            if isTraceEnabled {
                let ms = Int((CFAbsoluteTimeGetCurrent() - beganAt) * 1000)
                glog("[保温] \(reason):\(windows.count) 窗(枚举 \(ms)ms)→ 交预截")
            }
            await Snapshotter.shared.precapture(windows)
            // 只在"这次确实很贵"时说话(常态静默 ✓ —— 本仓日志预算:一次唤起 ≤2 行 ✓)
            let total = Int((CFAbsoluteTimeGetCurrent() - beganAt) * 1000)
            if total > 150 {
                glog("[保温] \(reason) 共 \(windows.count) 窗 · 用时 \(total)ms(>150ms ⇒ 可能压住入场)")
            }
        }
    }

    /// 冷启动专用入口:一次性闸 + sweep
    func coldStartSweep() {
        guard !didColdStartSweep else { return }
        didColdStartSweep = true
        sweepAllScreens(reason: "冷启动预拍")
    }

    /// 屏幕清单指纹:displayID + 尺寸 + 缩放。"屏没变"时它一定相等。
    private static func screenSignature() -> String {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "?"
            return "\(id):\(Int(s.frame.width))x\(Int(s.frame.height))@\(Int(s.backingScaleFactor * 100))"
        }.joined(separator: "|")
    }

    private func invalidateAll(reason: String) {
        // **不挂 trace**:整块作废意味着下一局要重拍十几扇窗(实打实的 GPU 活 + 与入场抢资源),
        // 这种事必须天天可见,而不是"开了 trace 才看得到"(2026-09-15:那份日志里它一次都没露面,
        // 我们是靠"突然出现 10 窗重拍"反推出来的 —— 以后不用反推)。
        print("[保温] \(reason) → 缩略图缓存作废(下一局重拍)")
        Snapshotter.shared.prune(keeping: [])
    }
}
