import XCTest
@testable import GlanceCore

/// 塞不下的时候切哪边（病例：DataGrip 从外接搬到内建，最小宽度 1752 > 可见区 1728 ⇒ 右沿跑出去 24pt ✓）
final class ScreenMoveOverflowTests: XCTestCase {

    // 内建屏可见区(Quartz 坐标,与日志里那次实测一致 ✓)
    private let target = CGRect(x: -1728, y: -37, width: 1728, height: 1084)

    /// 现状:保住左沿 ⇒ 右边超出去 24pt(用户看到的就是这个 ✓)
    func testKeepLeftMatchesCurrentBehavior() {
        let p = ScreenMovePolicy.anchorOversized(achieved: CGSize(width: 1752, height: 1084),
                                                 in: target, rule: .keepLeft)
        XCTAssertEqual(p.x, -1728, accuracy: 0.01)
    }

    /// 居中:两边各切 12pt ✓
    func testCenterSplitsTheOverflow() {
        let p = ScreenMovePolicy.anchorOversized(achieved: CGSize(width: 1752, height: 1084),
                                                 in: target, rule: .center)
        XCTAssertEqual(p.x, -1728 - 12, accuracy: 0.01)
    }

    /// 保住右沿:左沿切 24pt(右沿正好落在可见区右沿 ✓)
    func testKeepRightPinsTheRightEdge() {
        let p = ScreenMovePolicy.anchorOversized(achieved: CGSize(width: 1752, height: 1084),
                                                 in: target, rule: .keepRight)
        XCTAssertEqual(p.x + 1752, target.maxX, accuracy: 0.01)
    }

    /// 放得下的时候这一档不参与(横向不动 ✓),纵向一律保住上沿 ✓
    func testFittingWindowKeepsTargetOrigin() {
        let p = ScreenMovePolicy.anchorOversized(achieved: CGSize(width: 1200, height: 900),
                                                 in: target, rule: .center)
        XCTAssertEqual(p.x, target.minX, accuracy: 0.01)
        XCTAssertEqual(p.y, target.minY, accuracy: 0.01)
    }
}
