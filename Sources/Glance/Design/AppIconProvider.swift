import SwiftUI
import AppKit

/// 真实 App 图标(`NSRunningApplication.icon`)与它的缓存。属于 `Design/` 的 UI 原语:
/// 谁要画图标都来这里取,缓存口径只有一份。
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

    static func art(for pid: pid_t) -> Art {
        if let e = cache[pid],
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == e.bundleID {
            return e.art
        }
        guard let app = NSRunningApplication(processIdentifier: pid), let img = app.icon else {
            return Art(image: NSWorkspace.shared.icon(for: .application), fill: 1)
        }
        let a = Art(image: img, fill: fillRatio(of: img))
        cache[pid] = Entry(art: a, bundleID: app.bundleIdentifier)
        return a
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
    private static func fillRatio(of image: NSImage) -> CGFloat {
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
