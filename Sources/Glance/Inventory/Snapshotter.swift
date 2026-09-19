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

    /// 全量保活剪枝(T87 v3):按**系统当前所有在屏窗** reap,而不是只按面板的语境屏。
    ///
    /// 为什么要改:面板是单屏语境的,但用户会**换屏** —— 旧剪枝在每次开局把别屏窗的图
    /// 全扔了,于是"外接 → 内建"一换屏,内建全空,卡片闪"截图中…"(2026-09-17 用户实测)。
    /// sweep 明明拍过那些窗,是剪枝亲手扔的。
    ///
    /// 为什么可以**整个挪后台**:死窗的缓存条目本来就不会被展示(窗不在本局枚举里,
    /// 就没有那张卡片),开局剪枝真正服务的只有两件 —— ① 内存回收;② 作废打到死窗上的
    /// 在途批次。两件都不要求同步。这里的存活清单用 bare CGWindowList(**不过 AX 准入**,
    /// 毫秒级):多保一张"AX 不认的幽灵窗"的图只是几 MB 内存,会在它关闭时被正常 reap。
    func reapAlive() {
        Task.detached(priority: .userInitiated) {
            guard let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return }
            var alive: Set<CGWindowID> = []
            for info in infos {
                // ★ 不再按 pid 排除自家窗(2026-09-18):设置窗口进环后,它的缓存条目曾被这里
                // 当"死窗"剪掉 ⇒ 每次唤起都闪「截图中…」。悬浮面板是 popUpMenu 图层(≠0),
                // 下面那道 layer 过滤天然挡住,不需要 pid 特判
                guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      let layer = info[kCGWindowLayer as String] as? Int, layer == 0
                else { continue }
                alive.insert(wid)
            }
            let aliveSet = alive // 值捕获:别把 var 提进并发闭包(Swift 6 会拒)
            await MainActor.run { self.prune(keeping: aliveSet) }
        }
    }

    /// 同一扇窗的失败只报第一次(访达等 SCK 截不了的窗会屡败屡试;现拍风暴期曾刷屏)
    private let failedOnce = FailureLog()

    /// 拍下本进程自己的普通图层窗(设置/权限窗口)。**窗刚建好、渲染落定后调用** ——
    /// 这些窗是打开时才建的,冷启动预热拍不到,不补这一拍的话,它们入环后的第一眼
    /// 就是「截图中…」(2026-09-18 用户实报)。悬浮面板是 popUpMenu 图层,天然不在名单里
    func precaptureOwnWindows() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .userInitiated) {
            guard let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return }
            let records: [WindowRecord] = infos.compactMap { info in
                guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID,
                      let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width > 1, bounds.height > 1
                else { return nil }
                let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
                return WindowRecord(wid: wid, pid: pid, ownerName: "Glance",
                                    title: title, bounds: bounds)
            }
            guard !records.isEmpty else { return }
            await MainActor.run { Snapshotter.shared.precapture(records, force: true) }
        }
    }

    /// 对一批窗做预截。**不阻塞调用方**(内部自管任务):调用方是主线程上的选中变化热点。
    ///
    /// **数组顺序就是抓图顺序**:调用方把"正在显示的那一组"放前面 —— 卡片要等的是自己那一张,
    /// 它先到,面板看上去就是秒显(共 30 扇窗时串行拍完要一两秒,先后顺序就是体验)。
    ///
    /// `attempt` 是回填重试的轮次:没拍到的窗隔一会儿再试,上限 3 轮。
    /// 照 AltTab 的口径——**UI 先出来、缩略图异步补**,而不是"没拍到就永远空着":
    /// 实测"截图中…"绝大多数是**瞬时**失败(窗口刚创建、正在动画、SCK 忙),不是永久失败。
    /// `force` = 无视缓存与新鲜度,一律重拍。
    /// `maxAge` = 自定义新鲜度(秒),nil 用 `cacheTTL`。**失焦拍**(T86)给 2s:
    /// 2s 内拍过的(快速来回切)不重复拍,又不像 60s TTL 那样把"刚切走"当"还很新"。
    ///
    /// 用在**用户正在看的那一组**上(面板里选中的那个 App、激活的那个 App):
    /// 应用**内部**的画面变化(换主题、切文件、编辑内容)系统**不发任何事件** ——
    /// 没有激活、没有窗口变化、AX 也不动,所以"事件驱动刷新"对这类变化天然无效。
    /// 唯一能抓住它的时机就是"这一组被显示出来"的这一刻。
    /// 病例(2026-09-15):用户把 IDE 换成浅色主题,唤起两次卡片仍是深色
    /// —— 上一版给缓存加了 60s TTL,把这条"显示即重拍"也一起跳过了。
    nonisolated private static func logPermissionSkip(windows: Int) {
        if permissionSkipLogged { return }
        permissionSkipLogged = true
        print("[T5] 屏幕录制权限未授权,后台截图停摆(每批跳过;弹窗只留给权限引导窗)")
    }

    func precapture(_ windows: [WindowRecord], attempt: Int = 1, force: Bool = false, maxAge: Double? = nil) {
        guard !windows.isEmpty else { return }
        // ★ **录屏权限预检**(2026-09-19 用户实报「怎么老是弹录屏授权」):后台 sweep(5s 开窗拍)
        // 触发 SCK 时,若权限缺失/失效(重签名、系统更新都会让 TCC 记录失效),macOS 就弹授权框
        // —— 用户被骚扰,而弹窗本该只属于权限引导流程。`CGPreflightScreenCaptureAccess`
        // **不弹窗**地查权限:没授权就整个批次跳过(引导窗负责催授权,这里只管安静)。
        guard CGPreflightScreenCaptureAccess() else {
            Self.logPermissionSkip(windows: windows.count)
            return
        }
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
            if now - (cacheAt[w.wid] ?? 0) > (maxAge ?? Self.cacheTTL) { missExpired += 1; return true }  // 太老
            return false
        }
        guard !stale.isEmpty else {
            // (全部命中不再打账:它曾是"缓存生效"的证据,但每次移动指针都来一行太吵;
            //  缺图那一侧仍然无条件上报,见下面的 else)
            return
        }
        let batch = stale
        let current = session
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // **逐窗拍、逐张回主**(T86):整批拍完一次性合并 = 一批图同时到的爆发,
            // 是 T76 之前掉帧的真身(整批合并曾量到 140.7ms 长帧)。现在每拍完一张就回主
            // 落一张账,单次合并不到 1ms,十张图分十拍落地,不再有可观测的合并峰值。
            var missing: [WindowRecord] = []
            var captured = 0
            do {
                let content = try await shareable.current()
                let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
                for w in batch {
                    if Task.isCancelled { break }
                    guard let scWindow = byID[w.wid] else {
                        missing.append(w)
                        await self.failedOnce.noteOnce(w.wid, "[T5] \(w.ownerName) wid=\(w.wid) 不在 SCShareableContent 清单里,待回填")
                        continue
                    }
                    let (image, reason) = await Self.captureImage(of: scWindow, w)
                    guard let image else {
                        missing.append(w)
                        await self.failedOnce.noteOnce(w.wid, "[T5] \(w.ownerName) wid=\(w.wid) 截屏失败: \(reason ?? "未知")(待回填)")
                        continue
                    }
                    captured += 1
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    await self.publish(wid: w.wid, image: nsImage, batch: current, first: captured == 1, batchSize: batch.count)
                }
            } catch {
                await self.failedOnce.note("[T5] SCShareableContent 获取失败: \(error.localizedDescription)(屏幕录制权限?)")
                missing = batch
            }
            if isTraceEnabled {
                // 规模计数:掉帧若随"外接屏 App 多"来,这一行是第一个证人 ——
                // 它会告诉我们**这一批实际拍了多少扇窗**(缓存命中后本该远小于窗口总数)
                let why = force ? "强制"
                    : "无图 \(missNoEntry)\(missLost > 0 ? "(其中 \(missLost) 曾拍到过)" : "") / 过期 \(missExpired)"
                print("[T5] 预截 要拍 \(batch.count) 窗(\(why))→ 回填 \(captured) 窗"
                      + (missing.isEmpty ? "" : "(缺 \(missing.count),第 \(attempt) 轮)"))
            } else if !missing.isEmpty {
                // 没拍到就**不打折地报**,不靠 GLANCE_TRACE:面板上空一个卡片就是用户看得见的毛病,
                // 日志必须自己说清是"没拍到"还是"清单里没有"(之前就因为静默吃了一次盲改的苦)
                print("[T5] 预截缺 \(missing.count)/\(batch.count) 窗(第 \(attempt) 轮):"
                      + missing.map { "\($0.ownerName)#\($0.wid)" }.joined(separator: ", "))
            }
            guard !missing.isEmpty, attempt < 3 else { return }
            try? await Task.sleep(nanoseconds: UInt64(250_000_000) * UInt64(attempt))
            let pending = missing // 值捕获:别把 var 提进并发闭包(Swift 6 会拒)
            await MainActor.run {
                guard current == self.session else { return }
                self.precapture(pending, attempt: attempt + 1, force: force, maxAge: maxAge)
            }
        }
    }

    /// 单张图落账(主线程)。`batch` = 发单时的会期号,只挡"上一局的图":
    /// 本会期里飞在半路的批次一律允许回填。
    @MainActor
    private func publish(wid: CGWindowID, image: NSImage, batch: Int, first: Bool, batchSize: Int) {
        guard batch == session else { return }
        cache[wid] = image
        // "曾经拍到过"的账:prune 时不清,用来区分两种"无图"——
        //   从来没拍到过(SCK 不给 / 键不匹配)vs 拍到过但没留下来(丢了)
        everCaptured.insert(wid)
        cacheAt[wid] = CFAbsoluteTimeGetCurrent()
        // 首图上屏时刻(相对按键):trace 下单独一行。逐张合并后它量的是
        // 第一张图落地的时刻,比旧的整批合并时刻更贴近用户第一次看见图的那一拍
        if first { SessionMarks.noteFirstThumb(batchSize) }
    }

    /// **透明衬边裁切**(T88 v2):自绘窗(微信登录窗那类)的窗体 backing 常比可见内容大 ——
    /// 系统影子已被 `ignoreShadows` 关掉,但 App 自己画在窗里的透明圈(圆角外圈/自绘影)还在,
    /// 内容贴左上、右下留白,卡底色从透明区透出来(2026-09-17 用户实拍)。
    ///
    /// 做法:把图 8× 缩采样画进 alpha-only 位图,找"含接近不透明像素"的行列包围盒,按盒裁原图。
    /// 设计三条:
    ///   · 普通窗口四边都有不透明内容 ⇒ 包围盒 = 全图,原样返回(唯一开销是一次缩采样);
    ///   · 阈值取 96:窗口内容边缘是全不透明(255),烤进图里的软影远低于此 —— 行列里有
    ///     任何一个近不透明像素就算内容,所以抗锯齿的圆角边不会被误裁;
    ///   · 一切失败路径(画不出/全透明/包围盒即全图)一律返回原图 —— 宁可有边,不裁错。
    private nonisolated static func trimTransparentEdges(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w > 16, h > 16 else { return image }
        let stride = 8
        let sw = w / stride, sh = h / stride
        // RGBA 位图(不用 alphaOnly:Swift 绑定的 space 参数不收 nil),读每采样点的 alpha 字节
        guard sw > 0, sh > 0, let ctx = CGContext(
            data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = CGInterpolationQuality.medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let buf = ctx.data else { return image }
        let data = buf.bindMemory(to: UInt8.self, capacity: sw * sh * 4)
        var minX = sw, minY = sh, maxX = -1, maxY = -1
        for y in 0..<sh {
            for x in 0..<sw {
                if data[(y * sw + x) * 4 + 3] > 96 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // 位图内存行 0 = 图的顶行(上下文按 CG 坐标画、内存按图像行序排),
        // 与 `cropping(to:)` 的左上原点同系,直接乘步长换算
        let rect = CGRect(x: minX * stride, y: minY * stride,
                          width: min(w, (maxX - minX + 1) * stride),
                          height: min(h, (maxY - minY + 1) * stride))
        guard rect.width < CGFloat(w) || rect.height < CGFloat(h),
              let cropped = image.cropping(to: rect) else { return image }
        return cropped
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
            // **不拍影子**(T88):默认把窗口阴影一起拍进画面 —— 那是一圈**透明像素**,
            // 撑大了画面、缩小的内容浮在中间,卡底色从透明区透出来 = 微信登录窗那种
            // 自绘窗四圈"大灰边"(2026-09-17 用户实拍)。关掉后画面 = 窗口本体,
            // 与出图比例推导用的 `bounds` 口径一致,fill 裁切也不再吃空边
            config.ignoreShadows = true
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
                    } else if let img = output?.sdrImage {
                        cont.resume(returning: (Self.trimTransparentEdges(img), nil))
                    } else {
                        cont.resume(returning: (nil, nil))
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
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (Self.trimTransparentEdges(img), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// 录屏权限未授权的跳过账:**每进程只喊一次**(sweep 5s 一轮,不设闸就刷屏)
nonisolated(unsafe) private var permissionSkipLogged = false

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
