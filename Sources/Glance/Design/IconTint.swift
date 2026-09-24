import AppKit
import GlanceCore

/// 从 App 图标里取「这枚图标的主色」。
///
/// 病例与用途（2026-09-24 用户口径）：「目前的高光有点亮了, 能不能把固定的高光变成**选中 app
/// 图标本身的颜色晕染**」—— 光环原来画的是固定白色径向渐变 ⇒ 现在跟着**选中的那个 App** 走 ✓
///
/// 口径只有一份：**像素怎么采**在这里（32×32 + alpha > 0.5 ⇒ 丢掉透明边），
/// **颜色怎么挑**在 `GlanceCore.VibrantColor`（纯函数 + 单测 ✓）。
/// 缓存按稳定身份（`pid:bundle` / `launch:<id>`）—— 与 `IconProvider` 同一套纪律 ✓
enum IconTint {
    /// 值也是可选的：`nil` = 这枚图标基本是灰的（终端 / Finder 那类）⇒ **记住这个结论**，不重复算 ✓
    private static var cache: [String: NSColor?] = [:]
    private static let side = 32

    /// - Parameters:
    ///   - image: 图标（`IconProvider.art(for:).image` 或未启动名单里的 `icon`）
    ///   - key: 稳定身份 —— 缓存键（pid 会被系统复用 ⇒ 必须带上 bundle id ✓）
    /// - Returns: nil ⇒ 调用方退回白色（宁可不变，也不要灰蒙蒙 ✗）
    static func color(for image: NSImage, key: String) -> NSColor? {
        if let hit = cache[key] { return hit }      // 含"上次算出来就是 nil" ✓
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = compute(image)
        cache[key] = c
        // 它**唯一的真实代价**就是这第一次(32×32 位图 + 1024 个采样 ⇒ 每枚图标一次/进程 ✓)
        // ⇒ 把数字打出来,别把它留成"感觉上很贵" ✗(一次查询 = 查表 ⇒ 每帧的成本可忽略 ✓)
        if isTraceEnabled {
            glog(String(format: "[光晕] 首次取色 %@ 用时 %.2fms(之后都是查表 ✓)", key, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
        return c
    }

    private static func compute(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium   // 取色不需要最近邻（要的是"平均意义上的那块彩标" ✓）
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var samples: [VibrantColor.Sample] = []
        samples.reserveCapacity(side * side)
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let a = Double(buf[i + 3]) / 255
            guard a > 0.5 else { continue }          // 画布外那圈透明不算数 ✓
            samples.append(.init(r: Double(buf[i]) / 255,
                                 g: Double(buf[i + 1]) / 255,
                                 b: Double(buf[i + 2]) / 255, a: a))
        }
        guard let t = VibrantColor.pick(samples: samples) else { return nil }
        // ★ 再过一道"发光提纯":图标本身的颜色常常又暗又灰(JetBrains 那族 ✗),
        //   直接拿去画 0.17~0.20 的光读不出来 ⇒ 保留色相、把饱和/亮度抬到能发光的那一档 ✓
        let g = VibrantColor.glow(from: t)
        return NSColor(srgbRed: g.r, green: g.g, blue: g.b, alpha: 1)
    }
}
