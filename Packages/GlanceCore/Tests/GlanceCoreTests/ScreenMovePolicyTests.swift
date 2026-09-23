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

    func testDefaultPlacementFillsTheWholeTargetArea() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left)
        XCTAssertEqual(out, left, "默认应当**撑满目标可见区**(而不是保持 800x600 挪过去 ✓)")
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

    func testKeepSizeStillWorksWhenAsked() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        let out = ScreenMovePolicy.targetFrame(current: w, source: right, target: left, placement: .keepSize)
        XCTAssertEqual(out.size, w.size, "显式要 keepSize 时,尺寸仍然原样 ✓")
    }

    func testNextScreenIndexCyclesAndRejectsSingleScreen() {
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 0, count: 2), 1)
        XCTAssertEqual(ScreenMovePolicy.nextScreenIndex(current: 1, count: 2), 0, "两块屏要能来回 ✓")
        XCTAssertNil(ScreenMovePolicy.nextScreenIndex(current: 0, count: 1), "单屏没有目的地 ✓")
        XCTAssertNil(ScreenMovePolicy.nextScreenIndex(current: 5, count: 2), "越界下标要挡住 ✓")
    }
}
