import AppKit
import ScreenCaptureKit

/// 预截(brand-spec「展开层 0ms」的前提):面板出现那一刻,截图必须已在手。
/// 时序:begin 先拍全部组,T6 面板只读 cache。
///
/// **为什么整类不能是 @MainActor**(2026-09-14 掉帧实评的根因):
/// 这里是 `SCShareableContent` 全系统窗枚举 + 逐窗截图 + 建 NSImage 的场所,而
/// `Task { await … }` 从主线程上下文发出去后**仍然跑在主 actor 上**——本来以为是"异步的",
/// 实际上是:每一次选中变化都在主线程上排一遍全系统窗枚举。指针横扫 12 个图标 = 12 遍。
/// 现在拍图全程离开主线程,回主线程只做一次发布。
@MainActor
final class Snapshotter: ObservableObject {
    static let shared = Snapshotter()
    private init() {}

    /// cache 与面板同呼吸:新一轮枚举必须清场,否则展开层会显示"昨天的窗"(T5 实机现形 19/13)
    @Published private(set) var cache: [CGWindowID: NSImage] = [:]
    /// 每张图**写入的时刻**(`precapture` 靠它判断"还新不新")
    private var cacheAt: [CGWindowID: CFAbsoluteTime] = [:]
    /// 预览图的保鲜期。超过就重拍 —— 与 `ThumbnailRefresher` 的"激活即重拍"互补:
    /// 那一条管"正在用的 App",这一条兜"没被激活但已经放很久"的窗。
    private static let cacheTTL: CFAbsoluteTime = 60

    /// 会期世代:`clear()` 一次 = 上一局的图全部作废。
    ///
    /// **不要再加"批次世代"**(2026-09-14 真 bug):曾经让新一批拍图把旧一批标记作废,
    /// 结果横扫几个组之后,被作废那几批的图**永远不会写进 cache** —— 回到那些组就是
    /// "截图中…"一直空着。图是按 `wid` 存的,后来拍的同一扇窗只会更新、不会盖错,
    /// 作废批次没有意义。
    private var session = 0

    /// cache **跨会话保活**(2026-09-14 用户实评:"用 alt tab 不会看到\"截图中…\",永远秒开" ——
    /// 延迟就是体验)。曾经的 `clear()` 让每开一局都从零重拍:拍图是串行的,还没轮到你看的那一扇,
    /// 卡片就先显示占位符 —— 那一下就是"败体验"的真身。
    /// AltTab 的做法也是这个:缩略图缓存保活 + 后台刷新,UI 永远先出图。
    ///
    /// 所以开局只做**剪枝**,不清场:留着的图仍能立即上屏,新图回来再覆盖。
    /// 曾经成功拍到过的 window id(只增不减;`prune` 不动它)。见 `precapture` 的 missLost 分账。
    private var everCaptured: Set<CGWindowID> = []

    /// 缓存的字节量(粗账:逐张按位图 `bytesPerRow × height` 累加,不追 CGImage 内部对齐)。
    /// 用途:LumaRing 式懒加载("非热组不预截")的**先量后议**(2026-09-16 用户问,裁决:内存是
    /// 懒加载唯一真值,交互不动)—— 账挂在 `[唤起]` 行天天可见,有数才有"值不值得省"的裁决
    var cacheMemoryBytes: Int {
        cache.values.reduce(0) { acc, img in
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return acc + cg.bytesPerRow * cg.height
            }
            return acc
        }
    }

    func prune(keeping liveWindows: Set<CGWindowID>) {
        // ⚠️ 2026-09-15:原来这里**无条件** `session &+= 1` —— 而这个函数在每次列表刷新时都会被调用,
        // 于是"开局发出去的预拍"经常在飞回来的路上被判成"上一局",整批丢掉 ✗。
        // 日志证据:每局都要重拍十几扇窗,而且**永远是「无图」、零个「过期」** ——
        // 图不是过期,是压根没留下来。现在只有**真的有窗口消失**才作废在途批次。
        let removed = cache.keys.contains { !liveWindows.contains($0) }
        if removed {
            session &+= 1
            // 出声(2026-09-15):日志显示 miss 绝大多数是"曾拍到过"(= 拍到又被丢)✗,
            // 而作废在途批次的入口就是这个计数器。它每次加一都打一行,好和"无图"对齐时间;
            // 只在 trace 下打,平时不占日志预算。
            if isTraceEnabled { glog("[保温] 在途批次作废(窗口集合变了,session → \(session))") }
        }
        cache = cache.filter { liveWindows.contains($0.key) }
        cacheAt = cacheAt.filter { liveWindows.contains($0.key) }
        Task { await failedOnce.reset() } // 窗口列表变了,失败记录重来(权限也可能刚修好)
    }

    /// 同一扇窗的失败只报第一次(访达等 SCK 截不了的窗会屡败屡试;现拍风暴期曾刷屏)
    private let failedOnce = FailureLog()

    /// 对一批窗做预截。**不阻塞调用方**(内部自管任务):调用方是主线程上的选中变化热点。
    ///
    /// **数组顺序就是抓图顺序**:调用方把"正在显示的那一组"放前面 —— 卡片要等的是自己那一张,
    /// 它先到,面板看上去就是秒显(共 30 扇窗时串行拍完要一两秒,先后顺序就是体验)。
    ///
    /// `attempt` 是回填重试的轮次:没拍到的窗隔一会儿再试,上限 3 轮。
    /// 照 AltTab 的口径——**UI 先出来、缩略图异步补**,而不是"没拍到就永远空着":
    /// 实测"截图中…"绝大多数是**瞬时**失败(窗口刚创建、正在动画、SCK 忙),不是永久失败。
    /// `force` = 无视缓存与 TTL,一律重拍。
    ///
    /// 用在**用户正在看的那一组**上(面板里选中的那个 App、激活的那个 App):
    /// 应用**内部**的画面变化(换主题、切文件、编辑内容)系统**不发任何事件** ——
    /// 没有激活、没有窗口变化、AX 也不动,所以"事件驱动刷新"对这类变化天然无效。
    /// 唯一能抓住它的时机就是"这一组被显示出来"的这一刻。
    /// 病例(2026-09-15):用户把 IDE 换成浅色主题,唤起两次卡片仍是深色
    /// —— 上一版给缓存加了 60s TTL,把这条"显示即重拍"也一起跳过了。
    func precapture(_ windows: [WindowRecord], attempt: Int = 1, force: Bool = false) {
        guard !windows.isEmpty else { return }
        // **缓存命中就不重拍**(2026-09-15 修):以前这里把整批目标原样丢给 ScreenCaptureKit,
        // 于是每次唤起都在后台重拍十几扇窗(每扇 26–52ms 的 GPU/WindowServer 活)——
        // 与入场上浮抢资源,而且缓存本来就是为了"不用重拍"才存在的(T25 的本意)。
        // 实机证据:`[T5] 预截回填 10/10 窗` 每局必现。
        //
        // 新鲜度怎么保证:① `ThumbnailRefresher` 在 App 激活时重拍它的窗(切过去就是新的);
        // ② 这里再兜一道 TTL —— 超过 `cacheTTL` 的照样重拍。窗口尺寸/内容都是低频变化,
        // 一分钟的预览图足够准,而"每次唤起十几发截屏"是实打实的代价。
        let now = CFAbsoluteTimeGetCurrent()
        // 为什么这一批要拍?**分清两种原因**(2026-09-15):「要拍 10 窗」每局都出现,
        // 但"整块作废"那条日志从没打过 ——
        // 说明图不是被删的,而是"压根没存进去"或"过期了"。这两种原因对应完全不同的修法,
        // 所以直接量出来,不再靠推理(本次会话已经因为推理翻过两次车)。
        var missNoEntry = 0, missExpired = 0, missLost = 0
        let stale = force ? windows : windows.filter { w in
            guard cache[w.wid] != nil else {
                missNoEntry += 1
                if everCaptured.contains(w.wid) { missLost += 1 }   // 拍到过却没留下来 = 真丢了
                return true
            }
            if now - (cacheAt[w.wid] ?? 0) > Self.cacheTTL { missExpired += 1; return true }  // 太老
            return false
        }
        guard !stale.isEmpty else {
            // (全部命中不再打账:它曾是"缓存生效"的证据,但每次移动指针都来一行太吵;
            //  缺图那一侧仍然无条件上报,见下面的 else)
            return
        }
        let windows = stale
        let current = session
        Task.detached(priority: .userInitiated) { [weak self] in
            let (images, missing) = await Self.capture(windows, failedOnce: self?.failedOnce)
            guard let self else { return }
            if isTraceEnabled {
                // 规模计数:掉帧若随"外接屏 App 多"来,这一行是第一个证人 ——
                // 它会告诉我们**这一局实际拍了多少扇窗**(缓存命中后本该远小于窗口总数)
                let why = force ? "强制"
                    : "无图 \(missNoEntry)\(missLost > 0 ? "(其中 \(missLost) 曾拍到过)" : "") / 过期 \(missExpired)"
                print("[T5] 预截 要拍 \(windows.count) 窗(\(why))→ 回填 \(images.count) 窗"
                      + (missing.isEmpty ? "" : "(缺 \(missing.count),第 \(attempt) 轮)"))
            } else if !missing.isEmpty {
                // 没拍到就**不打折地报**,不靠 GLANCE_TRACE:面板上空一个卡片就是用户看得见的毛病,
                // 日志必须自己说清是"没拍到"还是"清单里没有"(之前就因为静默吃了一次盲改的苦)
                print("[T5] 预截缺 \(missing.count)/\(windows.count) 窗(第 \(attempt) 轮):"
                      + missing.map { "\($0.ownerName)#\($0.wid)" }.joined(separator: ", "))
            }
            if !images.isEmpty {
                await MainActor.run {
                    // 只挡"上一局的图":本会期里飞在半路的批次一律允许回填
                    guard current == self.session else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    self.cache.merge(images) { _, new in new }
                    // "曾经拍到过"的账:prune 时不清,用来区分下面两种"无图"——
                    //   从来没拍到过(SCK 不给 / 键不匹配)vs 拍到过但没留下来(丢了)
                    self.everCaptured.formUnion(images.keys)
                    // 首图上屏时刻(相对按键):trace 下单独一行。窗口多 → 这一批图多 →
                    // 主线程合并 + SwiftUI 重绘的代价全在这一刻,正是"体感掉帧"的嫌疑人
                    SessionMarks.noteFirstThumb(images.count)
                    for id in images.keys { self.cacheAt[id] = now }
                }
            }
            guard !missing.isEmpty, attempt < 3 else { return }
            try? await Task.sleep(nanoseconds: UInt64(250_000_000) * UInt64(attempt))
            await MainActor.run {
                guard current == self.session else { return }
                self.precapture(missing, attempt: attempt + 1)
            }
        }
    }

    /// 重活全在这里:全系统窗枚举 + 逐窗截图。**不在主 actor 上**,可后台跑
    private nonisolated static func capture(_ windows: [WindowRecord],
                                            failedOnce: FailureLog?) async -> ([CGWindowID: NSImage], [WindowRecord]) {
        var out: [CGWindowID: NSImage] = [:]
        var missing: [WindowRecord] = []
        do {
            let content = try await shareable.current()
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for w in windows {
                if Task.isCancelled { break }
                guard let scWindow = byID[w.wid] else {
                    missing.append(w)
                    await failedOnce?.noteOnce(w.wid, "[T5] \(w.ownerName) wid=\(w.wid) 不在 SCShareableContent 清单里,待回填")
                    continue
                }
                let (image, reason) = await captureImage(of: scWindow, w)
                guard let image else {
                    missing.append(w)
                    await failedOnce?.noteOnce(w.wid, "[T5] \(w.ownerName) wid=\(w.wid) 截屏失败: \(reason ?? "未知")(待回填)")
                    continue
                }
                out[w.wid] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        } catch {
            await failedOnce?.note("[T5] SCShareableContent 获取失败: \(error.localizedDescription)(屏幕录制权限?)")
            return (out, windows)
        }
        return (out, missing)
    }

    /// 单窗抓图。
    ///
    /// **macOS 26 走新 API `captureScreenshot`**(AltTab 的结论,不是我们的偏好):旧的
    /// `captureImage` 在 26 上每次调用都要起一个短命 capture stream,WindowServer 内存会漏,
    /// 成批调用还会把 replayd 卡死(alt-tab-macos#5786 / #5861);新 API 没有这层 churn。
    /// 14/15 没有新 API,沿用旧的。
    private nonisolated static func captureImage(of scWindow: SCWindow,
                                                 _ w: WindowRecord) async -> (CGImage?, String?) {
        // 出图规格:宽 720px(卡片≈3x retina 余量),高按窗口比例,上下封顶防极端形状
        // (竖条/横幅)出 4000px 大图(T6 实机现形:320px 高糊成马赛克)
        let aspect = w.bounds.width / max(w.bounds.height, 1)
        let pxW = 720
        let pxH = min(max(Int(720 / aspect), 48), 1500)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        if #available(macOS 26.0, *) {
            let config = SCScreenshotConfiguration()
            config.width = pxW
            config.height = pxH
            config.showsCursor = false
            return await withCheckedContinuation { (cont: CheckedContinuation<(CGImage?, String?), Never>) in
                // **超时兜底**(2026-09-14 实机病):SCK 的回调**可能永远不回来** ——
                // 而 withCheckedContinuation 会一直等,于是整批拍图卡在第一个窗上:
                // 后面的窗一律拿不到图,回填重试也永不触发,面板就一直是"截图中…"。
                // 这里用一次性旗票保证**恰好 resume 一次**,谁先到谁说话。
                let once = Once()
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
                    guard once.claim() else { return }
                    if let error {
                        cont.resume(returning: (nil, error.localizedDescription))
                    } else {
                        cont.resume(returning: (output?.sdrImage, nil))
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                    guard once.claim() else { return }
                    cont.resume(returning: (nil, "SCK 回调超时(1.2s 未回)"))
                }
            }
        }

        let config = SCStreamConfiguration()
        config.width = pxW
        config.height = pxH
        config.showsCursor = false
        config.scalesToFit = true
        do {
            return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// `SCShareableContent` 的短命缓存:这个枚举**很贵**(要跟 WindowServer 打一轮),
/// AltTab 也是缓存复用同一份。1 秒新鲜度对"缩略图"这件事完全够。
private let shareable = ShareableCache()

private actor ShareableCache {
    private var cached: SCShareableContent?
    private var at = Date.distantPast

    func current() async throws -> SCShareableContent {
        if let cached, Date().timeIntervalSince(at) < 1.0 { return cached }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cached = fresh
        at = Date()
        return fresh
    }
}

/// 一次性旗票:保证一段回调链里**恰好只有一个**能继续(超时与真回调抢同一个位置)
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 日志门:同一扇窗的失败只报第一次(访达等 SCK 截不了的窗会屡败屡试)
private actor FailureLog {
    private var seen: Set<CGWindowID> = []

    func note(_ line: String) { print(line) }

    func noteOnce(_ wid: CGWindowID, _ line: String) {
        guard seen.insert(wid).inserted else { return }
        print(line)
    }

    func reset() { seen.removeAll() }
}
