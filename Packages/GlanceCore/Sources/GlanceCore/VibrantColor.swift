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
        // ★ 2026-09-24 改成「**按色相投票选主色**」—— 用户实报:
        //   「像 Sublime、Apifox 这种(单色图标)有晕染;但 idea、datagrip 这种**色调比较多的**
        //     看起来几乎没有晕染」✓ 他完全说对了:
        //   旧版是**全体加权平均** ⇒ 多色图标把几种颜色**平均成灰** ✗(实测 IntelliJ 拿到 #9B607C
        //   一片暗紫,DataGrip 那种接近无色 ✗)⇒ 读起来就是"没染" ✓
        //   ⇒ 现在:先把色相分成 12 个 30° 的桶,按 (饱和度×亮度) 投票,取**票数最多的那个色相家族**,
        //     只在家族**内部**做加权平均 ⇒ 多色图标也会给出"最抢眼的那一族颜色" ✓
        var bins = [[Int]](repeating: [], count: 12)
        for (i, s) in samples.enumerated() {
            guard s.a >= minAlpha else { continue }
            let maxC = max(s.r, s.g, s.b), minC = min(s.r, s.g, s.b)
            let value = maxC
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            guard saturation >= minSaturation, value > 0.05 else { continue }
            let hue = hueDegrees(r: s.r, g: s.g, b: s.b)
            bins[min(11, Int(hue / 30))].append(i)
        }
        func weight(_ s: Sample) -> Double {
            let maxC = max(s.r, s.g, s.b), minC = min(s.r, s.g, s.b)
            return maxC <= 0 ? 0 : (maxC - minC) / maxC * maxC
        }
        // 家族票数 = 家族内权重之和(面积大又鲜艳的那一族赢 ✓)
        var best = -1, bestWeight = 0.0
        for (k, idxs) in bins.enumerated() {
            let w = idxs.reduce(0.0) { $0 + weight(samples[$1]) }
            if w > bestWeight { bestWeight = w; best = k }
        }
        guard best >= 0, bestWeight >= minWeight else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
        for i in bins[best] {
            let s = samples[i], w = weight(s)
            sr += s.r * w; sg += s.g * w; sb += s.b * w; sw += w
        }
        guard sw > 0 else { return nil }
        return Tint(r: sr / sw, g: sg / sw, b: sb / sw)
    }

    /// 色相(0…360)
    public static func hueDegrees(r: Double, g: Double, b: Double) -> Double {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return 0 }
        var h: Double
        if maxC == r { h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
        else if maxC == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        return h < 0 ? h + 360 : h
    }

    /// **把这枚颜色提纯成"能发光的"那一版**（保留色相，只抬饱和与亮度 ✓）。
    ///
    /// 病例(2026-09-24):JetBrains 那族的图标整体**又暗又灰**（IDEA/DataGrip 是深蓝灰底 ✓）
    /// ⇒ 哪怕选对了色相,拿原色去画 0.17~0.20 的光,在面板玻璃上也读不出来 ✗
    /// ⇒ 发光的颜色要**单独定**:色相照旧(`hue` 不动 ✓),饱和抬到 ≥0.55,亮度抬到 ≥0.85 ✓
    ///   —— 于是深海军蓝图标给出的是**明亮的蓝光** ✓,而不是一片灰 ✗
    public static func glow(from tint: Tint,
                            minSaturation: Double = 0.55,
                            minValue: Double = 0.85) -> Tint {
        let maxC = max(tint.r, tint.g, tint.b), minC = min(tint.r, tint.g, tint.b)
        let v = maxC
        let s = maxC <= 0 ? 0 : (maxC - minC) / maxC
        let h = hueDegrees(r: tint.r, g: tint.g, b: tint.b)
        let s2 = max(s, minSaturation), v2 = max(v, minValue)
        return hsv(h: h, s: s2, v: v2)
    }

    /// HSV → RGB（`h` 0…360, `s`/`v` 0…1）
    public static func hsv(h: Double, s: Double, v: Double) -> Tint {
        let c = v * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        return Tint(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}
