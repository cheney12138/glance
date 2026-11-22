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
        let image: NSImage
        /// 画布 ÷ 画面(≥1)。外面乘进 scaleEffect,画面就正好铺满 78pt 格子
        let fill: CGFloat
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

    /// 正在后台解析的 pid(去重:同一帧里多个格子/多次询问只发一次后台任务)
    private static var inflight: Set<pid_t> = []

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
        // ★ 2026-11-19 病例(见文件头):未命中 → 后台解析,主线程只给占位。
        //   这里连 `NSRunningApplication(processIdentifier:)` 都不在主线程做
        //   (LaunchServices 查询本身也是一次同步 XPC,系统忙时同样会卡帧)。
        //   去重:inflight 有它 = 后台已经在路上,直接占位。
        if inflight.contains(pid) { return placeholder }
        inflight.insert(pid)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { self.inflight.remove(pid) } }
            guard let app = NSRunningApplication(processIdentifier: pid), let img = app.icon else {
                return // 查不到:不落缓存(9-18 病例语义),主线程下一帧重试
            }
            let a = Art(image: img, fill: fillRatio(of: img))
            DispatchQueue.main.async {
                cache[pid] = Entry(art: a, bundleID: app.bundleIdentifier)
                NotificationCenter.default.post(name: iconCacheDidFill, object: pid)
            }
        }
        return placeholder
    }

    /// 后台预热单枚图标(由启动保温在后台线程调用:计算 fillRatio 也在后台完成,回主线程仅落表)
    static func prewarm(pid: pid_t, bundleID: String?, image: NSImage) {
        let a = Art(image: image, fill: fillRatio(of: image))
        DispatchQueue.main.async {
            if let e = cache[pid], bundleID == nil || e.bundleID == nil || bundleID == e.bundleID { return }
            cache[pid] = Entry(art: a, bundleID: bundleID)
        }
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
