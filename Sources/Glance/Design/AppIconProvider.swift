import SwiftUI
import AppKit

/// 真实 App 图标(`NSRunningApplication.icon`)与它的缓存。属于 `Design/` 的 UI 原语:
/// 谁要画图标都来这里取,缓存口径只有一份。
///
/// ⚠️⚠️ 2026-11-19 病例(用户:「三指唤起之后延迟巨大,今天上午都很卡」)—— 主线程**绝不碰** `app.icon`:
///   sample 铁证(2332/2332 样本):`showPanel → setFrameIfNeeded → NSHostingView.layout`(SwiftUI 布局)
///   → `IconCell.body → IconProvider.art(pid)` 缓存未命中 → `app.icon` 的 NSImage
///   → `cgImage(forProposedRect:)` → IconServices **同步 XPC**(iconservicesagent)→ mach_msg 等 **14.7 秒**。
///   叠加因素:① 启动之后**新启动的 App**(新 pid)不在 warmIconsInBackground 预热名单里,首次被
///   面板画到时才第一次取图标;② 系统忙时(上午 AX 都慢 151ms)iconservicesagent 的同步 XPC 回包
///   能等十几秒;③ 调用点在 SwiftUI 布局中 ⇒ 整条主线程冻结,三指/⌘Tab 全失联。
///   ⇒ 未命中路径改为:主线程立即返回**通用占位图标**(不进缓存,不固化),解析整段挪后台;
///     后台落缓存后发 `iconCacheDidFill` 通知,由视图层触发一次重画。
enum IconProvider {
    struct Art {
        /// 256×256 物理像素高清图：专用于主环 / 程序坞大图标（36…120pt），杜绝挑中 64px 变糊
        let image: NSImage
        /// 原始多分辨率 `.icns` 图标：专用于轨道/卡片 15pt 迷你芯片图标（命中系统原生 32px 手绘表示，避免大降采样过度锐化）
        let smallImage: NSImage
        /// 画布 ÷ 画面(≥1)。外面乘进 scaleEffect,画面就正好铺满 78pt 格子
        let fill: CGFloat

        init(image: NSImage, smallImage: NSImage? = nil, fill: CGFloat) {
            self.image = image
            self.smallImage = smallImage ?? image
            self.fill = fill
        }
    }

    /// 图标账本:pid → 画面 + **取图时的 bundle id**。bundle 记进来是为了防两类错图:
    ///   ① 瞬时查不到(如 App 刚启动,NSWorkspace 还没登记它)—— 曾兜底到自家图标
    ///      (`NSImage(named: applicationIconName)` 就是 Glance 的!)且**永固化**,
    ///      那个 App 到进程退出都顶着错的图标(2026-09-18 用户实报 Obsidian);
    ///   ② pid 被系统回收复用 —— 旧 App 的缓存会顶到新 App 头上。
    /// 命中时核对 bundle 仍相符,不符就当没缓存过重取;查不到时**不缓存**、
    /// 兜底系统通用图标,下一帧重试真身。
    private struct Entry { let art: Art; let bundleID: String? }
    private static var cache: [pid_t: Entry] = [:]

    /// ★★ 2026-11-25 病例(用户:「新打开的 App 加到环/程序坞之后,先是白纸图标,要等一会才有真 logo」)
    ///   —— **二级缓存:bundleID → 真图标**。
    ///   pid 账本只认进程,而**重开一个 App 就是新 pid**;未启动环里早已加载过图标的 App,
    ///   真跑起来又是新 pid ⇒ 两条路都必然 miss ⇒ 各自白纸一次起 ✗
    ///   图标本身跟进程无关(它只跟 bundle 有关)⇒ 按 bundleID 再兜一层,命中就 0ms 出真 logo ✓
    ///   ⚠️ **只存真图标,永不存 placeholder**(白纸一旦进二级缓存,所有入口就都顶着它了 ✗)
    ///   ⚠️ 只在主线程读写(与 `cache` 同一线程纪律 ✓)
    private static var bundleCache: [String: Art] = [:]

    /// 正在后台解析的 pid(去重:同一帧里多个格子/多次询问只发一次后台任务)
    private static var inflight: Set<pid_t> = []

    /// 「新 App 启动」观察者已注册(幂等闸)
    nonisolated(unsafe) private static var observingLaunches = false

    /// 后台解析完成的通知:object = pid。视图层监听并触发一次重画。
    static let iconCacheDidFill = Notification.Name("glance.iconCacheDidFill")

    /// 占位图标:系统通用 App 图标。**永不进缓存** —— 它只是"真图标在路上"的临时画面。
    private static let placeholder = Art(image: NSWorkspace.shared.icon(for: .application), fill: 1)

    static func art(for pid: pid_t, bundleID: String? = nil) -> Art {
        // ★★ 2026-10-20 病例(用户:「退出了之后,所有 app 短暂变成空白文件 logo 了」):
        //   图标**不会变**:缓存过就永远用缓存,除非调用方给出的 bundleID 与缓存明明白白对不上
        //   (那才是 pid 被复用,见文件头第 ② 条)✓
        // ★★ 2026-11-20 性能修复:缓存命中路径**不再在主线程调 `NSRunningApplication(processIdentifier:)`**
        //   (每次调用都是一次 LaunchServices 同步 XPC;面板每重算一帧 N 个图标就发 N 次 XPC ✗)。
        //   `AppGroup.bundleID` 在枚举阶段(后台线程)已经拿好,直接内存比对零 XPC ✓。
        if let e = cache[pid] {
            if bundleID == nil || e.bundleID == nil || bundleID == e.bundleID { return e.art }
        }
        // ★★ pid 未命中 ⇒ **先按 bundleID 查二级缓存**(0ms 出真图标,不画白纸)。
        //   这条路覆盖两种以前必 miss 的情形:重开 App(新 pid)、未启动环里早就加载过的 App。
        if let bid = bundleID, let hit = fillFromBundleCache(pid: pid, bundleID: bid) { return hit }
        // ★ 2026-11-19 病例(见文件头):未命中 → 后台解析,主线程只给占位。
        //   这里连 `NSRunningApplication(processIdentifier:)` 都不在主线程做
        //   (LaunchServices 查询本身也是一次同步 XPC,系统忙时同样会卡帧)。
        //   去重:inflight 有它 = 后台已经在路上,直接占位。
        resolveInBackground(pid: pid, bundleID: bundleID) { $0?.icon }
        return placeholder
    }

    /// 后台解析一枚图标并落账(「去重 → 后台解析 → 回主线程落表 + 广播」只有这一份写法 ✓)
    /// - Parameter image: 在**后台线程**上从已查到的 App 上取图(拿不到就返回 nil ⇒ 不落缓存,下次再试 ✓)
    private static func resolveInBackground(pid: pid_t, bundleID: String?,
                                            image: @escaping (NSRunningApplication?) -> NSImage?) {
        guard !inflight.contains(pid) else { return }
        inflight.insert(pid)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { inflight.remove(pid) } }
            let app = NSRunningApplication(processIdentifier: pid)
            // 查不到 / 刚拉起的进程还没有图标 ⇒ **不落缓存**(9-18 病例语义:占位绝不许固化),下次重试 ✓
            guard let img = image(app) else { return }
            let crisp = crispImage(from: img)
            let art = Art(image: crisp, smallImage: img, fill: fillRatio(of: crisp))
            DispatchQueue.main.async {
                store(pid: pid, bundleID: app?.bundleIdentifier ?? bundleID, art: art)
            }
        }
    }

    /// bundleID 二级缓存命中 ⇒ **当场**回填 pid 主缓存并返回(0ms 出真 logo ✓)。未命中返回 nil。
    ///
    /// ⚠️ 为什么命中之后还要派一次后台复核:二级缓存是**跨 pid** 的 —— 一个 App 升级换了图标,
    ///   它不会自己失效(那就变成"换了图标重启 App,Glance 里还是旧图"✗)。
    ///   复核成本很低:每个 pid **只发一次**(`inflight` 去重),图标没变时原地覆盖、零视觉变化 ✓
    private static func fillFromBundleCache(pid: pid_t, bundleID: String) -> Art? {
        guard let hit = bundleCache[bundleID] else { return nil }
        cache[pid] = Entry(art: hit, bundleID: bundleID)
        resolveInBackground(pid: pid, bundleID: bundleID) { $0?.icon }
        return hit
    }

    /// 落账(**只许主线程调**):pid 主缓存 + bundleID 二级缓存 + 广播一次 ✓
    private static func store(pid: pid_t, bundleID: String?, art: Art) {
        cache[pid] = Entry(art: art, bundleID: bundleID)
        if let bid = bundleID, !bid.isEmpty { bundleCache[bid] = art }
        NotificationCenter.default.post(name: iconCacheDidFill, object: pid)
    }

    /// 后台预热单枚图标(由启动保温在后台线程调用:计算 fillRatio 也在后台完成,回主线程仅落表)
    static func prewarm(pid: pid_t, bundleID: String?, image: NSImage) {
        let crisp = crispImage(from: image)
        let a = Art(image: crisp, smallImage: image, fill: fillRatio(of: crisp))
        DispatchQueue.main.async {
            // 二级缓存先落(它跟 pid 无关,谁先到都算数 ✓;已有真图标就不覆盖)
            if let bid = bundleID, !bid.isEmpty, bundleCache[bid] == nil { bundleCache[bid] = a }
            if let e = cache[pid], bundleID == nil || e.bundleID == nil || bundleID == e.bundleID { return }
            cache[pid] = Entry(art: a, bundleID: bundleID)
        }
    }

    /// **给二级缓存预填**一枚真图标(供 `DockAppsProvider` 在后台加载"未启动 App"图标时顺手调 ✓)。
    /// 为什么需要它:未启动环 / 系统 Dock 里的 App 早就被 `NSWorkspace.icon(forFile:)` 加载过一遍真图标了 ——
    /// 它一旦真跑起来,面板/程序坞那张图**本来就在手里**,没必要再从 pid 重新解析一次(那一次就是白纸 ✓)。
    /// ⚠️ 已有就不覆盖(先落的那份一定来自真实进程/真实 bundle,可信度更高 ✓)
    /// ⚠️ 可在任意线程调用:二级缓存是主线程账本,后台线程写一律切回主线程 ✓
    static func seedBundleCache(bundleID: String, image: NSImage, smallImage: NSImage, fill: CGFloat) {
        guard !bundleID.isEmpty else { return }
        let art = Art(image: image, smallImage: smallImage, fill: fill)
        if Thread.isMainThread {
            if bundleCache[bundleID] == nil { bundleCache[bundleID] = art }
        } else {
            DispatchQueue.main.async {
                if bundleCache[bundleID] == nil { bundleCache[bundleID] = art }
            }
        }
    }

    /// ★★ 根因 A 修复(2026-11-25):**新拉起的 App 也必须有人预热**。
    /// 原来只有 `warmIconsInBackground` 在 Glance 启动那一刻给"当时的"在跑 App 预热;
    /// 之后新开的 App 谁也管不到 ⇒ 首次被画到必然 miss ⇒ 先白纸,等后台解析落账才换真 logo ✗
    /// ⇒ 挂 `didLaunchApplication` 通知:新 App 一落地就在后台把它那枚图标解析好,
    ///   等用户唤起面板/程序坞时它**已经在账上**了(0ms 出真 logo ✓)。
    /// 幂等:只注册一次 ✓
    static func startObservingLaunches() {
        guard !observingLaunches else { return }
        observingLaunches = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier
            // 已在账上且 bundle 对得上 ⇒ 不用动(pid 复用/重复通知都在这里挡住 ✓)
            if let e = cache[pid], bid == nil || e.bundleID == nil || bid == e.bundleID { return }
            if let bid, fillFromBundleCache(pid: pid, bundleID: bid) != nil { return }
            // ⚠️ 刚拉起的一瞬 `icon` 可能还是 nil ⇒ 不落缓存(见 `resolveInBackground`),
            //   下一帧 `art(for:)` 看到 inflight 清空会自己重试 ✓
            resolveInBackground(pid: pid, bundleID: bid) { _ in app.icon }
        }
    }

    /// 把"还没命中的"新 pid 一次性派给后台预热 —— 兜住**不产生 `didLaunch` 通知**的那些进程
    /// (辅助 App、由别的进程拉起且系统没发通知的、以及我们自己启动得太快的那一瞬 ✓)。
    /// 幂等且便宜:已命中/已 inflight 的直接跳过,主线程只做字典查询 ✓
    static func prewarmMissing(for apps: [(pid: pid_t, bundleID: String?)]) {
        for app in apps {
            if let e = cache[app.pid], app.bundleID == nil || e.bundleID == nil || app.bundleID == e.bundleID {
                continue
            }
            if let bid = app.bundleID, fillFromBundleCache(pid: app.pid, bundleID: bid) != nil { continue }
            resolveInBackground(pid: app.pid, bundleID: app.bundleID) { $0?.icon }
        }
    }

    /// 从多分辨率 `.icns` `NSImage` 中显式提取 256×256 物理像素的高清位图（128×128pt @2x）。
    ///
    /// 病例(2026-11-24 用户实拍反馈程序坞图标缩小后变糊):
    /// `NSRunningApplication.icon` 默认 `size = 32×32 pt`，SwiftUI `Image(nsImage:)` 在缩放时可能挑中
    /// 64×64px 低分表示再放大到 56pt×1.24(140px 物理像素)，导致边缘发虚。
    /// 在后台线程显式提 256px 源图后，任意 36…120pt 展示都走高清下采样，边缘与原生 Retina 一致锐利。
    nonisolated static func crispImage(from source: NSImage, pixels: Int = 256) -> NSImage {
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        guard let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: hints) else {
            return source
        }
        let logical = CGFloat(pixels) / 2.0
        return NSImage(cgImage: cg, size: NSSize(width: logical, height: logical))
    }

    /// 量画面占画布的比例(取倒数 = 补偿倍率)。
    ///
    /// 采样口径是标定过的:**128×128 + 最近邻 + alpha > 128(半透明边缘算画面边界)**,
    /// 与全分辨率真值误差 ≤0.001。换成 96px 双线性、或阈值放到 alpha>8(会把图标自带那圈
    /// 极淡的外发光/投影也算进画面)都会偏 3~5%,务必别改。
    ///
    /// 这套口径下 Finder/Safari/Xcode/Terminal/Chrome/Ghostty 一致落在 **0.805** ——
    /// 正好是 Apple 图标模板的安全区(1024 画布里的 824,squircle 外留 100px 给投影),
    /// 也就是说**画面只占画布 80.5%**。自定义全出血图标会量到 ~1.0,自然不放大。
    ///
    /// ⚠️ 只在后台队列调用(2026-11-19 起):`cgImage(forProposedRect:)` 会触发 IconServices
    ///    同步 XPC,主线程调用 = 2026-11-19 卡死 14.7s 的根因。
    nonisolated static func fillRatio(of image: NSImage) -> CGFloat {
        let side = 128
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 1 }
        ctx.interpolationQuality = .none // 最近邻:双线性的模糊边会把包围盒撑大 3~5%
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            let row = buf + y * side * 4
            for x in 0..<side where row[x * 4 + 3] > 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return 1 }
        let covered = max(CGFloat(maxX - minX + 1) / CGFloat(side),
                          CGFloat(maxY - minY + 1) / CGFloat(side))
        // 夹在 1…1.3:全出血的自定义图标不放大,边距离谱的也别放太狠
        return min(max(1 / covered, 1), 1.3)
    }
}
