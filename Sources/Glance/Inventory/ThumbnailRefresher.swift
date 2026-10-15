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
    /// ★★ 破环冷却(2026-10-14 病例:三指被拖死 ✓):屏参数事件后到这个时刻之前**一律不拍**。
    ///   环是这样的:屏事件 → 缓存全清 + 手势重挂 → 全量重拍(SCK 连发)→ SCK 又触发屏事件 ✗✗
    ///   ⇒ 给屏事件后的重拍加冷却,环断供就停 ✓(每次事件都重置 ⇒ 事件停了 8s 后才恢复拍 ✓)
    private var captureCooldownUntil: CFAbsoluteTime = 0

    // MARK: - 轻扫的"自适应"(2026-10-10)
    ///
    /// 用户实报「刚才疯狂掉帧」+「面板没开、平时也觉得顿」⇒ 对着日志量到:
    /// ```
    /// [保温] 开窗拍:22 窗(枚举 …)     本局 1170 次
    ///   枚举 P50 **90ms** · P90 120ms · **max 1417ms** ✗
    /// ```
    /// 而那次轻扫的注释写着"枚举在后台毫秒级、常驻成本可忽略" ✗ —— 那是早年量的;
    /// 窗口数涨到 22 之后早就不成立 ✓(而且**每 5 秒**就来一下 ✗)。
    /// 更冤的是:窗口没变时这一趟 **一枚快门都不会发生**(TTL 全过滤 ✓)⇒ 纯白付枚举的钱 ✗
    ///
    /// 口径(两条互不相干,各自都能省):
    ///   ① **窗口集合没变 ⇒ 跳过**:用只读 `CGWindowList` 取一份便宜指纹(不碰 AX ✓),
    ///      与上次一致、且距上次完整扫 < 30s ⇒ 这一趟不必跑(至少每 30s 还是会走一趟 ✓
    ///      —— TTL 刷新那条路不能彻底断 ✓)
    ///   ② **上次越贵 ⇒ 下次间隔越长**:5s 起、30s 封顶 ✓
    /// (用户可见的"新鲜度"本来就不靠它:开面板那一路有 0.45s 补拍,
    ///  App 切换那一路有激活即拍 ⇒ 轻扫只是额外的暖 ✓)
    private var lastSweepSignature: [Int] = []
    private var lastSweepAt: CFAbsoluteTime = 0
    private var lastSweepCost: Double = 0        // 秒

    /// 便宜的窗口指纹(只读 CGWindowList ⇒ 不碰 AX ✓):窗口 id + 位置尺寸
    /// 位置也算进去:窗口挪了/缩了 ⇒ 它的图就旧了 ⇒ 这一趟值得跑 ✓
    nonisolated static func windowSignature() -> [Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [Int] = []
        for d in list {
            guard let wid = d[kCGWindowNumber as String] as? Int,
                  let raw = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: raw) else { continue }
            out.append(wid &+ Int(r.minX) &* 7 &+ Int(r.minY) &* 3
                       &+ Int(r.width) &+ Int(r.height))
        }
        return out.sorted()
    }

    /// 下次轻扫等多久 —— 两道闸分开算(2026-10-14 改 ✓):
    ///
    /// 用户口径:「预览应该 app图标兜底 → 快照 → live,层层降级,任何场景都不显示异常」✓
    ///   ⇒ 兜底(图标)那一层之所以还能看见,就是因为**新开的窗要等到下一趟轻扫才被拍** ✗
    ///     实测:轻扫间隔 5s 起 ⇒ 新窗最多 5 秒没有快照 ⇒ 一打开面板就是图标 ✓
    ///
    /// 但"扫得勤"不等于"拍得勤"(那 90ms 的枚举就是当年被否掉的那条 ✗):
    ///   · **指纹检查**(`windowSignature`,只读 CGWindowList 的 id/位置尺寸)很便宜 ✓
    ///     ⇒ 间隔压到 **1.5s** 也不会掉帧 ✓(跑不跑全量由指纹决定 ✓)
    ///   · **全量轻扫**仍然"窗口没变就跳过" + "上次贵就拉长" ✓
    /// 判据:新开一扇窗后 ≤1.5s 应有它的快照 ✓;(指纹闸保证了常态零枚举 ✓)
    private func adaptiveSweepDelay() -> Double {
        guard lastSweepCost > 0 else { return 1.5 }
        return min(30, max(1.5, 1.5 * (lastSweepCost / 0.05)))
    }

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
                self.captureCooldownUntil = CFAbsoluteTimeGetCurrent() + 8   // ★ 破环 ✓(每次事件重置 ✓)
                self.invalidateAll(reason: "显示器参数变化")
            }
        })
        lastScreenSignature = Self.screenSignature()
        schedulePeriodicSweep()
        // ★★ 2026-10-14 病例(用户:「重启之后还是有很明显的 app 图标」✓):
        //   上面那趟周期性轻扫的**第一趟要等 `adaptiveSweepDelay()`(≥5s)** ✗
        //   ⇒ 启动后那 5 秒里打开面板,**一扇窗都没拍过** ⇒ 卡片全是 App 图标兜底 ✓
        //   ⇒ 启动后立刻补一趟"首扫"(稍等 0.8s,别跟启动那堆活抢资源 ✓)
        //   用户的架构口径(2026-10-14):「**App 图标兜底 → 快照 → live 接入**,层层降级,
        //     任何场景下都不显示异常 ✓」—— 图标那一档是**最后**一档,不该是最常见的一档 ✓
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.sweepAllScreens(reason: "启动首扫")
        }
        if isTraceEnabled {
            glog("[保温] 已上线:App 激活 → 抓它的窗;显示器变化 → 整块缓存作废;开窗拍 → 5s 轻扫")
        }
    }

    /// **开窗拍**(2026-09-18 用户:「所有 app 都需要这个钩子,不是只对 glance」):
    /// 任何 App 新开的窗,不该等用户下一次唤起面板才第一次被拍。macOS 没有"别家开新窗"
    /// 的通知,就用**低频轻扫**兜住 —— 与关面板预拍同一条路:sweepAllScreens 全量走 TTL
    /// 过滤(谁新谁不拍),没有新窗、没有过期时**一枚快门都不发生**。
    /// ⚠️ 但"不发生快门"**不等于"不花钱"** ✗ —— 枚举本身实测 P50 90ms / max 1417ms,
    ///   而原来**每 5 秒**就来一下 ⇒ 早就不是"成本可忽略"了(见 `lastSweepSignature` 那段病例 ✓)。
    ///   现在:窗口没变就跳过 + 上次贵就拉长间隔 ✓;Glance 自己的设置窗另有 0.6s 即时钩子 ✓
    private func schedulePeriodicSweep() {
        DispatchQueue.main.asyncAfter(deadline: .now() + adaptiveSweepDelay()) { [weak self] in
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
            // ★★ 2026-10-14 病例(用户:「等了 2s 还是有图标出现」✓,量尺当场指出来):
            //   原来只要**面板在台上**就整趟跳过 ✗ —— 那条例外当初是为了"别跟入场抢 GPU"
            //   (15 窗全量预拍实测 652ms 长帧 ✗ ✓)。但代价是:
            //   **新开的窗**如果出现在"面板开着"这段里,就一次次被跳过 ⇒ 永远是图标 ✓
            //   (日志铁证:`[保温] 开窗拍 跳过:面板已在台上` 紧跟着 `[缺图] wid=… 首次缺` ✓)
            //   ⇒ 收窄成两条:
            //     ① 让开入场:等 0.6s 再走(入场动画那几拍不动它 ✓)
            //     ② **只补"没有图/图太旧"的窗**(`maxAge: 2` ✓)—— 全量重拍仍然不做 ✓
            // ★ 破环冷却(见 captureCooldownUntil 的注释 ✓):屏事件后 8s 内不拍,
            //   断掉「屏事件 → 全量重拍 → 更多屏事件」的环 ✓(真实插拔屏代价 ≤8s 图标 ✓ 可接受 ✓)
            let cooldownUntil = await MainActor.run { self.captureCooldownUntil }
            if CFAbsoluteTimeGetCurrent() < cooldownUntil {
                if isTraceEnabled { glog("[保温] 跳过:屏变化后截屏冷却中 ✓") }
                return
            }
            let onStage = await MainActor.run(body: { PanelStageProbe.isVisible() })
            if onStage {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            // ★ 先拿便宜指纹(不碰 AX ✓):窗口集合 + 位置尺寸都没变 ⇒ 这一趟没必要跑 ✓
            //   (至少每 30s 还是会完整走一趟 —— TTL 刷新那条路不断 ✓)
            let signature = Self.windowSignature()
            let (lastSignature, idle) = await MainActor.run { (self.lastSweepSignature, CFAbsoluteTimeGetCurrent() - self.lastSweepAt) }
            if reason == "开窗拍", !signature.isEmpty, signature == lastSignature, idle < 30 {
                if isTraceEnabled { glog("[保温] \(reason) 跳过:窗口集合没变(省掉一次 ~90ms 的枚举 ✓)") }
                return
            }
            let beganAt = CFAbsoluteTimeGetCurrent()
            // rawGroups 的归属判定保证一扇窗只属于一块屏:按屏枚举天然不重不漏
            var windows: [WindowRecord] = []
            for screen in NSScreen.screens {
                windows.append(contentsOf: WindowEnumerator.rawGroups(on: screen).flatMap(\.windows))
            }
            guard !windows.isEmpty else { return }
            // ★★ 2026-10-14 病例(用户:「重启之后第一次切换到访达就看到 app 图标了」✓):
            //   20 窗 × ~30–100ms ⇒ 整趟首扫要 **0.6–2s** ✗ ⇒ 这期间打开面板,轮到没轮到的窗
            //   就只能是 App 图标 ✓ —— 而"第一次打开"几乎必然是**当前最前面那个 App** ✓
            //   ⇒ 把它的窗排到队伍最前面(其余顺序不动,稳定分区 ✓)
            //   判据:重启后 ≤1s 内切到最前面那个 App,应有快照、无图标 ✓
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let mine = windows.filter { $0.pid == front }
                if !mine.isEmpty, mine.count != windows.count {
                    windows = mine + windows.filter { $0.pid != front }
                }
            }
            if isTraceEnabled {
                let ms = Int((CFAbsoluteTimeGetCurrent() - beganAt) * 1000)
                glog("[保温] \(reason):\(windows.count) 窗(枚举 \(ms)ms)→ 交预截")
            }
            // 面板在台上 ⇒ **只补冷窗**(缓存里真没有的 ✓)
            //   (2026-10-14 病例:原来 maxAge:2 ⇒ "超 2s 全重拍" ⇒ 面板开着期间
            //    每 1.5s 一轮 18 连拍 ✗✗ = 掉帧真凶,帧账铁证 @2-3s×2 max42ms 与
            //    [批次] 18 连发同时刻 ✓)
            if onStage {
                await Snapshotter.shared.precapture(windows, onlyMissing: true)
            } else {
                await Snapshotter.shared.precapture(windows)
            }
            // ⚠️ 2026-10-14 撤销:曾在这里给"最前面那个 App"做 10s 轮询保鲜 ✗✗
            //   病例:屏参数事件(哪怕一次)会触发「整块缓存作废」⇒ 下一趟轻扫发现 20 窗全没图
            //   ⇒ 全量重拍(SCK 连发)⇒ 又触发屏参数事件 ⇒ 重挂风暴 ⇒ MT 投递拖死 ✗✗✗
            //   (用户实报「三指死了」;日志:13.5s 里 10 次重挂 + "要拍 20 窗(无图 20,曾拍到过 20)")
            //   改前指纹没变的轻扫会整趟跳过 ⇒ 这个环转不起来 ✓
            //   教训:**任何绕过指纹闸的周期性 SCK 调用都是给"屏事件↔重拍"环供燃料** ✗
            //   保鲜的正路是事件驱动(App 激活钩子 ✓ 已有),不是轮询 ✗
            
            // 记下这一趟的指纹/代价 ⇒ 下次既知该不该跳过、也知道该等多久 ✓
            let cost = CFAbsoluteTimeGetCurrent() - beganAt
            await MainActor.run {
                self.lastSweepSignature = signature
                self.lastSweepAt = CFAbsoluteTimeGetCurrent()
                self.lastSweepCost = cost
            }
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
