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
        XCTAssertGreaterThan(t.g, 0.6)
    }

    /// 空输入 / 全透明 ⇒ nil（调用方不必特判 ✓）
    func testEmptyInput() {
        XCTAssertNil(VibrantColor.pick(samples: []))
    }
}
