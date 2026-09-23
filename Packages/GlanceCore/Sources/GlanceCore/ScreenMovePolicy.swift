import CoreGraphics

/// 把一扇窗**搬到另一块屏**时的落点计算（纯函数，可单测）—— 2026-09-22 用户点名的 P2。
///
/// 口径三条（每一处都是"别自作主张"的结果 ✓）：
///  1. **尺寸不变**（pt 原样搬 ✓）。按目标屏比例缩放读起来像"窗口变了" ✗,
///     而用户要的是"把这扇窗挪过去" ✓。
///  2. **位置**由 `Landing` 决定,默认 `.relative`（源屏上的相对位置等比映射 ✓,
///     与用鼠标把窗口拖到另一块屏时 macOS 的表现一致 ✓）。想改成"落在那块屏正中" ⇒ 改一行 ✓
///  3. **夹紧**:放得下就完全放进目标矩形 ✓;放不下（窗比那块屏还大）⇒ 保证**上沿与左沿**可见
///     （Quartz 坐标里 y 越小越靠上 ⇒ 保住 `minY = target.minY` ✓）—— 标题栏在那一侧 ✓
///
/// ⚠️ 坐标系：**不在这里换算**。调用方给的三个矩形必须在**同一套坐标**里
///   （本仓统一用 Quartz 全局坐标 —— `WindowRecord.bounds` 与 `WindowEnumerator.quartzFrame(of:)`
///   都是这一套 ✓）。换算属于基础设施层，塞进纯函数就是下一次错位的温床 ✗
public enum ScreenMovePolicy {

    public enum Landing: String, CaseIterable {
        /// 保持它在源屏上的**相对位置**（等比映射）—— 默认 ✓
        case relative
        /// 落在那块屏的**正中** ✓
        case center

        public var displayName: String {
            switch self {
            case .relative: return "按相对位置"
            case .center: return "落在屏幕正中"
            }
        }
    }

    public static let defaultLanding: Landing = .relative

    public static func targetFrame(current: CGRect, source: CGRect, target: CGRect,
                                   landing: Landing = defaultLanding) -> CGRect {
        let size = current.size
        var origin: CGPoint
        switch landing {
        case .relative:
            let rx = source.width > 0 ? (current.minX - source.minX) / source.width : 0
            let ry = source.height > 0 ? (current.minY - source.minY) / source.height : 0
            origin = CGPoint(x: target.minX + rx * target.width, y: target.minY + ry * target.height)
        case .center:
            origin = CGPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
        }
        return clamp(CGRect(origin: origin, size: size), into: target)
    }

    /// 夹进目标矩形（见文件头第 3 条 ✓）
    public static func clamp(_ rect: CGRect, into target: CGRect) -> CGRect {
        var r = rect
        if r.width <= target.width {
            r.origin.x = min(max(r.minX, target.minX), target.maxX - r.width)
        } else {
            r.origin.x = target.minX
        }
        if r.height <= target.height {
            r.origin.y = min(max(r.minY, target.minY), target.maxY - r.height)
        } else {
            r.origin.y = target.minY       // 太高 ⇒ 保住**上沿**（标题栏那一侧 ✓）
        }
        return r
    }

    /// 下一块屏（多屏循环 ✓；只有一块屏 ⇒ nil）
    public static func nextScreenIndex(current: Int, count: Int) -> Int? {
        guard count > 1, current >= 0, current < count else { return nil }
        return (current + 1) % count
    }
}
