import XCTest
@testable import GlanceCore

/// 「从图标里挑主色」的口径（病例：原来是固定白高光 ⇒ 改成跟着选中的 App 走 ✓）
final class VibrantColorTests: XCTestCase {

    /// 典型图标 = 白底 + 一块彩标 ⇒ 必须挑到**彩标**那个颜色，而不是被白底冲淡的灰白 ✓
    func testPicksTheLogoNotTheWhiteBackground() {
        let samples = [VibrantColor.Sample(r: 1, g: 1, b: 1),      // 白底（饱和度 0 ⇒ 丢掉 ✓）
                       VibrantColor.Sample(r: 1, g: 1, b: 1)]
            + Array(repeating: VibrantColor.Sample(r: 0.92, g: 0.26, b: 0.21), count: 6)  // 红标
        let t = VibrantColor.pick(samples: samples)
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.r, 0.92, accuracy: 0.05)
        XCTAssertEqual(t!.g, 0.26, accuracy: 0.05)
        XCTAssertEqual(t!.b, 0.21, accuracy: 0.05)
    }

    /// 全灰图标（终端 / Finder 那类）⇒ nil ⇒ 调用方退回白色 ✓（宁可不变，也不要灰蒙蒙 ✗）
    func testGrayIconReturnsNil() {
        let gray = (0..<10).map { _ in VibrantColor.Sample(r: 0.5, g: 0.5, b: 0.5) }
        XCTAssertNil(VibrantColor.pick(samples: gray))
    }

    /// 透明像素不算数（图标画布外那一圈）
    func testTransparentPixelsAreIgnored() {
        var s = Array(repeating: VibrantColor.Sample(r: 1, g: 0, b: 0, a: 0), count: 50)
        s.append(VibrantColor.Sample(r: 0.1, g: 0.4, b: 0.9, a: 1))
        let t = VibrantColor.pick(samples: s)
        XCTAssertEqual(t?.b ?? 0, 0.9, accuracy: 0.05)
    }

    /// **同像素数**时，更鲜艳的那一块权重更大（权重 = 饱和度 × 亮度 ✓）
    /// ⚠️ 权重是**逐像素**的 ⇒ 一块淡色只要面积大得多，照样能把结果拉过去 ✓
    ///   （第一版测试我写的是"最鲜艳的赢" ✗ —— 那是错的期望，被这条测试当场纠正 ✓）
    func testVividBlockOutweighsPaleBlockOfEqualSize() {
        let samples = Array(repeating: VibrantColor.Sample(r: 0.6, g: 0.6, b: 0.35), count: 10)  // 淡黄
            + Array(repeating: VibrantColor.Sample(r: 0.95, g: 0.85, b: 0.1), count: 10)          // 鲜黄
        let t = VibrantColor.pick(samples: samples)!
        XCTAssertGreaterThan(t.g, 0.75, "同面积时应当偏向更鲜艳的那一块")
        XCTAssertLessThan(t.b, 0.25)
    }

    /// 面积大的那一块说话更响（逐像素权重 ⇒ 这是刻意的 ✓）
    func testBiggerBlockPullsTheResult() {
        let pale = Array(repeating: VibrantColor.Sample(r: 0.6, g: 0.6, b: 0.35), count: 20)
        let vivid = Array(repeating: VibrantColor.Sample(r: 0.95, g: 0.85, b: 0.1), count: 5)
        let t = VibrantColor.pick(samples: pale + vivid)!
        XCTAssertLessThan(t.g, 0.8, "小块鲜艳色不该独吞结果")
        XCTAssertGreaterThan(t.g, 0.59, "20 淡 + 5 鲜(同一色相家族)⇒ 结果落在偏淡那侧")
    }

    /// 空输入 / 全透明 ⇒ nil（调用方不必特判 ✓）
    func testEmptyInput() {
        XCTAssertNil(VibrantColor.pick(samples: []))
    }

    // MARK: - 2026-09-24 用户实报:「idea、datagrip 这种色调比较多的, 看起来几乎没有晕染」

    /// ★ **多色图标不许被平均成灰**：红/绿/蓝各占三分之一 ⇒ 旧版平均值 ≈ 灰白 ✗
    ///   新版按色相投票 ⇒ 拿到的是**某一族鲜艳色**(饱和度高 ✓),读起来才是"染上了色" ✓
    func testMulticolorIconYieldsAVividFamilyNotGray() {
        let third = 30
        var s: [VibrantColor.Sample] = []
        s += Array(repeating: .init(r: 0.9, g: 0.15, b: 0.15), count: third)   // 红
        s += Array(repeating: .init(r: 0.15, g: 0.8, b: 0.25), count: third)   // 绿
        s += Array(repeating: .init(r: 0.15, g: 0.3, b: 0.9), count: third)    // 蓝
        let t = VibrantColor.pick(samples: s)!
        let maxC = max(t.r, t.g, t.b), minC = min(t.r, t.g, t.b)
        let sat = (maxC - minC) / maxC
        XCTAssertGreaterThan(sat, 0.5, "必须是某一族鲜艳色,不能是平均出来的灰 ✗(实际 \(t))")
    }

    /// ★ **又暗又灰的图标要能提纯成"能发光的"**：JetBrains 那族是深蓝灰底 ✓
    ///   提纯只动饱和与亮度，**色相必须保持不变** ✓
    func testGlowBoostsDarkColorKeepingHue() {
        let navy = VibrantColor.Tint(r: 0.10, g: 0.14, b: 0.28)     // DataGrip 那种深海军蓝
        let g = VibrantColor.glow(from: navy)
        let maxC = max(g.r, g.g, g.b), minC = min(g.r, g.g, g.b)
        XCTAssertGreaterThanOrEqual(maxC, 0.85 - 1e-9, "亮度要提到能发光的那一档")
        XCTAssertGreaterThanOrEqual((maxC - minC) / maxC, 0.55 - 1e-9, "饱和也要提上来")
        XCTAssertEqual(VibrantColor.hueDegrees(r: g.r, g: g.g, b: g.b),
                       VibrantColor.hueDegrees(r: navy.r, g: navy.g, b: navy.b), accuracy: 1.0,
                       "色相不许变(变了他看到的就不是这枚图标的颜色了 ✗)")
    }

    /// 已经够鲜艳的颜色不该被提纯改动(幂等 ✓)
    func testGlowIsIdempotentForAlreadyVividColors() {
        let orange = VibrantColor.Tint(r: 0.95, g: 0.55, b: 0.1)
        let once = VibrantColor.glow(from: orange)
        let twice = VibrantColor.glow(from: once)
        XCTAssertEqual(once.r, twice.r, accuracy: 1e-9)
        XCTAssertEqual(once.g, twice.g, accuracy: 1e-9)
        XCTAssertEqual(once.b, twice.b, accuracy: 1e-9)
    }
}
