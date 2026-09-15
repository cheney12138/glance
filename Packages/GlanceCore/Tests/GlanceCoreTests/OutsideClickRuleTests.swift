import XCTest
@testable import GlanceCore

/// 「点空白 = 关面板」的判据。2026-09-15 病例:用户报「点面板周围的空白区域不关闭」——
/// 透明呼吸区不吃点击,但事件**不会**转给下层 App,全局监听收不到,于是这一格点击掉在地上。
/// 修法是本地监听 + 这条判据,所以这里把它钉住。
final class OutsideClickRuleTests: XCTestCase {
    private let panel = CGRect(x: 100, y: 100, width: 400, height: 80)
    private let tray = CGRect(x: 150, y: 20, width: 300, height: 70)

    func testInsidePanelIsNotOutside() {
        XCTAssertFalse(OutsideClickRule.isOutside(point: CGPoint(x: 300, y: 140),
                                                  panelContent: panel, trayContent: tray))
    }

    func testInsideTrayIsNotOutside() {
        XCTAssertFalse(OutsideClickRule.isOutside(point: CGPoint(x: 200, y: 60),
                                                  panelContent: panel, trayContent: tray))
    }

    /// 呼吸区(玻璃外、窗口内)= 外。这正是用户点的那一格
    func testPaddingBetweenGlassAndWindowIsOutside() {
        XCTAssertTrue(OutsideClickRule.isOutside(point: CGPoint(x: 300, y: 95),
                                                 panelContent: panel, trayContent: tray))
        XCTAssertTrue(OutsideClickRule.isOutside(point: CGPoint(x: 95, y: 140),
                                                 panelContent: panel, trayContent: tray))
    }

    func testFarAwayIsOutside() {
        XCTAssertTrue(OutsideClickRule.isOutside(point: CGPoint(x: 1400, y: 900),
                                                 panelContent: panel, trayContent: tray))
    }

    /// 边界属于"里"(contains 含下边界不含上边界,这里只钉"贴着玻璃边的那一下不算外")
    func testGlassEdgeCountsAsInside() {
        XCTAssertFalse(OutsideClickRule.isOutside(point: CGPoint(x: panel.minX, y: panel.minY),
                                                 panelContent: panel, trayContent: tray))
    }

    /// 托盘还没出屏(没有当前 App)时只看面板;两个都不可见 → **不判外**(别凭一次点击就关)
    func testNilRects() {
        XCTAssertTrue(OutsideClickRule.isOutside(point: CGPoint(x: 1400, y: 900),
                                                 panelContent: panel, trayContent: nil))
        XCTAssertTrue(OutsideClickRule.isOutside(point: CGPoint(x: 1400, y: 900),
                                                 panelContent: nil, trayContent: tray))
        XCTAssertFalse(OutsideClickRule.isOutside(point: CGPoint(x: 1400, y: 900),
                                                  panelContent: nil, trayContent: nil))
    }
}
