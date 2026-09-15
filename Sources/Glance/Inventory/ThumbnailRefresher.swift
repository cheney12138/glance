import AppKit

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
        if isTraceEnabled {
            glog("[保温] 已上线:App 激活 → 抓它的窗;显示器变化 → 整块缓存作废")
        }
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              !app.isTerminated else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastRefreshAt[pid], now - last < 1.0 { return }
        lastRefreshAt[pid] = now

        // 语境屏取"光标所在屏":刚切过去的那个 App 就在用户眼前,先拍它、且只拍它
        guard let screen = CursorScreenAnchor.cursorScreen else { return }
        Task.detached(priority: .utility) {
            let groups = WindowEnumerator.rawGroups(on: screen)
            guard let group = groups.first(where: { $0.pid == pid }), !group.windows.isEmpty else { return }
            if isTraceEnabled {
                glog("[保温] \(group.appName) 激活 → 拍它 \(group.windows.count) 窗")
            }
            // 激活即重拍(force):刚切过去的那个 App 画面最可能刚变过(换了主题/文件/内容)
            await Snapshotter.shared.precapture(group.windows, force: true)
        }
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
