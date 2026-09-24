import XCTest
@testable import GlanceCore

/// 「陈旧名单能不能先上屏」的四道门槛（病例见 `StaleListPolicy` 头注 ✓）
final class StaleListPolicyTests: XCTestCase {

    func testAllowsOnGoodStaleList() {
        XCTAssertTrue(StaleListPolicy.canShowStale(enabled: true, listCount: 8,
                                                   windowCount: 16, sameScreen: true))
    }

    /// ★ 跨屏名录不许用：那会画出**另一块屏**的 App（ADR-0008 按屏归属 ✓）
    func testRejectsOtherScreenList() {
        XCTAssertFalse(StaleListPolicy.canShowStale(enabled: true, listCount: 8,
                                                   windowCount: 16, sameScreen: false))
    }

    /// 空名单 / 有 App 但一扇窗都没有 ⇒ 画出来会"闪一局面板再拆掉" ✗
    func testRejectsEmptyOrWindowlessList() {
        XCTAssertFalse(StaleListPolicy.canShowStale(enabled: true, listCount: 0,
                                                    windowCount: 0, sameScreen: true))
        XCTAssertFalse(StaleListPolicy.canShowStale(enabled: true, listCount: 3,
                                                    windowCount: 0, sameScreen: true))
    }

    /// 档位关掉（A/B 用）⇒ 回到"等枚举"的旧行为 ✓
    func testRespectsSwitch() {
        XCTAssertFalse(StaleListPolicy.canShowStale(enabled: false, listCount: 8,
                                                    windowCount: 16, sameScreen: true))
    }
}
