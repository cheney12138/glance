/// 从一枚 App 图标的像素里挑出**能代表它**的那个颜色（决定 ⇒ 纯函数 + 单测 ✓）。
///
/// 用途（2026-09-24 用户口径）：「目前的高光有点亮了, 能不能把固定的高光变成**选中 app 图标
/// 本身的颜色晕染**」—— 光环现在画的是固定白色径向渐变 ⇒ 改成跟着**选中的那个 App** 走 ✓
///
/// 口径（为什么不是"平均值"）：
///  · 直接取平均 ⇒ 大多数图标是"白底 + 一块彩标" ⇒ 平均出来是灰白 ✗（那就等于没改）
///  · 所以：**先丢掉灰的**（饱和度 < `minSaturation`）、再丢掉透明的，
///    剩下的按 **饱和度 × 亮度** 加权平均 ⇒ 拿到的是"这块彩标"的颜色 ✓
///  · 全灰的图标（终端、Finder 那类）⇒ 返回 nil ⇒ 调用方退回白色 ✓（宁可不变，也不要灰蒙蒙 ✗）
public enum VibrantColor {

    /// 一个像素（各分量 0…1，`a` = alpha）
    public struct Sample: Equatable {
        public let r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    /// 挑出来的颜色（sRGB 各分量 0…1）
    public struct Tint: Equatable {
        public let r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    /// 加权平均后仍要够"有色"才认账：权重的总和太小 ⇒ 这枚图标基本是灰的 ⇒ nil
    public static let minWeight: Double = 0.02

    public static func pick(samples: [Sample],
                            minSaturation: Double = 0.18,
                            minAlpha: Double = 0.5) -> Tint? {
        var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
        for s in samples {
            guard s.a >= minAlpha else { continue }
            let maxC = max(s.r, s.g, s.b), minC = min(s.r, s.g, s.b)
            let value = maxC
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            guard saturation >= minSaturation, value > 0.05 else { continue }
            // 权重:越鲜艳、越亮 ⇒ 越能代表这枚图标（白底那块饱和度近 0 ⇒ 自动被压掉 ✓）
            let w = saturation * value
            sr += s.r * w; sg += s.g * w; sb += s.b * w; sw += w
        }
        guard sw >= minWeight else { return nil }
        return Tint(r: sr / sw, g: sg / sw, b: sb / sw)
    }
}
