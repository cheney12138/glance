import XCTest
@testable import GlanceCore

final class ScreenMovePolicyTests: XCTestCase {

    // 两块屏（Quartz：原点在主屏左上 ⇒ 左边那块 y 可以是负的 ✓）
    private let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)       // 外接 60Hz
    private let left  = CGRect(x: -1728, y: -37, width: 1728, height: 1117) // 内建

    func testSizeNeverChanges() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left, placement: .keepSize)
        XCTAssertEqual(out.size, w.size, "搬窗只改位置 —— 尺寸(pt)必须原样 ✓")
    }

    func testRelativeLandingKeepsProportions() {
        // 源屏上偏右上 ⇒ 目标屏上也偏右上 ✓
        let w = CGRect(x: right.minX + right.width * 0.6, y: right.minY + right.height * 0.1,
                       width: 400, height: 300)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left,
                                               placement: .keepSize, landing: .relative)
        XCTAssertEqual((out.minX - left.minX) / left.width, 0.6, accuracy: 0.001)
        XCTAssertEqual((out.minY - left.minY) / left.height, 0.1, accuracy: 0.001)
    }

    func testCenterLandingPutsWindowInTheMiddle() {
        let w = CGRect(x: 0, y: 0, width: 400, height: 300)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left,
                                               placement: .keepSize, landing: .center)
        XCTAssertEqual(out.midX, left.midX, accuracy: 0.001)
        XCTAssertEqual(out.midY, left.midY, accuracy: 0.001)
    }

    func testClampKeepsWindowInsideWhenItFits() {
        // 贴在源屏右下角 ⇒ 映射过去会越界 ⇒ 必须被夹回目标矩形内 ✓
        let w = CGRect(x: right.maxX - 400, y: right.maxY - 300, width: 400, height: 300)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left,
                                               placement: .keepSize, landing: .relative)
        XCTAssertGreaterThanOrEqual(out.minX, left.minX)
        XCTAssertLessThanOrEqual(out.maxX, left.maxX)
        XCTAssertGreaterThanOrEqual(out.minY, left.minY)
        XCTAssertLessThanOrEqual(out.maxY, left.maxY)
    }

    func testOversizedWindowKeepsItsTopEdgeVisible() {
        // 窗比目标屏还高 ⇒ 上沿(minY)必须落在目标屏上沿 ✓（标题栏在那一侧 ✓）
        let w = CGRect(x: 0, y: 0, width: 400, height: 2000)
        let out = ScreenMovePolicy.clamp(w, into: left)
        XCTAssertEqual(out.minY, left.minY, accuracy: 0.001, "太高的窗要保住上沿 ✓")
        XCTAssertEqual(out.size, w.size, "夹紧不改尺寸 ✓")
    }

    // MARK: 撑满(2026-09-22 用户口径:「移动过去之后能默认撑满整个屏幕吗, 不是全屏」)

    func testDefaultPlacementIsAdaptive_BigWindowFills() {
        // 大窗(1500x1000 ≈ 源屏 72%)⇒ 默认(按占比自适应)下撑满 ✓(09-22 口径对大窗不变 ✓)
        let big = CGRect(x: 100, y: 100, width: 1500, height: 1000)
        let out = ScreenMovePolicy.targetFrame(current: big, source: right, target: left)
        XCTAssertEqual(out, left, "默认(自适应)下,占比 ≥ 门槛的窗应当撑满 ✓")
    }

    func testFillScreenIgnoresCurrentSizeAndLanding() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 150)
        let big = CGRect(x: 100, y: 100, width: 1600, height: 1000)
        let a = ScreenMovePolicy.targetFrame(current: small, source: right, target: left, placement: .fillScreen)
        let b = ScreenMovePolicy.targetFrame(current: big, source: right, target: left,
                                             placement: .fillScreen, landing: .center)
        XCTAssertEqual(a, left)
        XCTAssertEqual(b, left, "撑满时:原尺寸与落点档都不参与 ✓")
    }

    // MARK: 按占比自适应(2026-09-25 用户口径:「有的窗口不适合全屏…超过 1/2 原显示器占比的才全屏」)

    func testAdaptiveKeepsSmallWindowSize() {
        // 小窗(800x600 ≈ 源屏 23%)⇒ 默认(自适应)下保持原尺寸,位置按相对落点 ✓
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left)
        XCTAssertEqual(out.size, w.size, "占比 < 门槛 ⇒ 保持原尺寸(小窗不该被撑爆 ✓)")
    }

    func testAdaptiveBoundaryHalfSnappedWindowDoesNotFill() {
        // 半屏贴边(960x1080 = **正好 50%**)⇒ 用户口径"**超过** 1/2 才全屏" ⇒ 边界归保持 ✓
        let half = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let out = ScreenMovePolicy.targetFrame(current: half, source: right, target: left,
                                               fillMinRatio: 0.5)
        XCTAssertEqual(out.size, half.size, "占比恰好 50% ⇒ 不撑(严格大于 ✓)")
        XCTAssertFalse(ScreenMovePolicy.shouldFill(window: half.size, inVisible: right.size, minRatio: 0.5))
    }

    func testAdaptiveThresholdKnob() {
        let w = CGSize(width: 800, height: 600)   // ≈ 23%
        XCTAssertTrue(ScreenMovePolicy.shouldFill(window: w, inVisible: right.size, minRatio: 0),
                      "门槛 0 ⇒ 一律撑满(≈ 09-22 旧默认 ✓)")
        XCTAssertFalse(ScreenMovePolicy.shouldFill(window: w, inVisible: right.size, minRatio: 1),
                       "门槛 1 ⇒ 一律保持(≈ keepSize ✓)")
    }

    func testKeepSizeStillWorksWhenAsked() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left, placement: .keepSize)
        XCTAssertEqual(out.size, w.size, "显式要 keepSize 时,尺寸仍然原样 ✓")
    }

    /// 用户口径(2026-09-22):「如果是 >2 display 的场景…给窗口排个序, 123 循环移动就行了」
    /// —— 他**测不了**三块屏 ⇒ 至少让纯核把这条循环证明掉 ✓
    func testThreeScreenCycleVisitsEveryDisplayThenWraps() {
        var seen: [Int] = []
        var i = 0
        for _ in 0..<3 {
            seen.append(i)
            i = ScreenMovePolicy.nextScreenIndex(current: i, count: 3)!
        }
        XCTAssertEqual(seen, [0, 1, 2], "1→2→3 走满一遍 ✓")
        XCTAssertEqual(i, 0, "第四下回到第一块 ✓(123 循环 ✓)")
    }

    func testFourAndMoreScreensStillWrap() {
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 3, count: 4), 0, "4 块屏也要回卷 ✓")
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 4, count: 5), 0)
    }

    func testNextScreenIndexCyclesAndRejectsSingleScreen() {
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 0, count: 2), 1)
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 1, count: 2), 0, "两块屏要能来回 ✓")
        XCTAssertNil(ScreenMovePolicy.nextScreenIndex(current: 0, count: 1), "单屏没有目的地 ✓")
        XCTAssertNil(ScreenMovePolicy.nextScreenIndex(current: 5, count: 2), "越界下标要挡住 ✓")
    }
}
