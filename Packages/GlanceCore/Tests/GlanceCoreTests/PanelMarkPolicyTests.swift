import XCTest
@testable import GlanceCore

/// 状态记号的优先级(病例:⌘M 之后显示的是"隐藏"角标,而不是"已收纳"的灰 ✗)
final class PanelMarkPolicyTests: XCTestCase {

    func testTuckedWinsOverHidden() {
        XCTAssertEqual(PanelMarkPolicy.mark(hidden: true, tucked: true), .tucked,
                       "同时成立时必须显示灰(用户按的是 ⌘M ✓)")
    }

    func testTuckedAloneShowsGray() {
        XCTAssertEqual(PanelMarkPolicy.mark(hidden: false, tucked: true), .tucked)
    }

    func testHiddenAloneShowsBadge() {
        XCTAssertEqual(PanelMarkPolicy.mark(hidden: true, tucked: false), .hidden)
    }

    func testNeitherIsNoMark() {
        XCTAssertNil(PanelMarkPolicy.mark(hidden: false, tucked: false))
    }
}
