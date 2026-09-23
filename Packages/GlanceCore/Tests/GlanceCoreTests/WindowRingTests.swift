import XCTest
@testable import GlanceCore

/// ⌘` 的环(病例:4 扇窗只能在 2 扇之间跳 —— 见 `WindowRing` 的头注 ✓)
final class WindowRingTests: XCTestCase {

    /// 这就是那次实报的形状:4 扇窗必须能走满一圈 ✓
    func testFourWindowsMakeAFullCycle() {
        var i = 0
        var seen = [i]
        for _ in 0..<3 {
            i = WindowRing.nextIndex(current: i, count: 4, forward: true)!
            seen.append(i)
        }
        XCTAssertEqual(seen, [0, 1, 2, 3], "4 扇窗要能走满(退化成 0/1 就是那次 bug ✗)")
        XCTAssertEqual(WindowRing.nextIndex(current: 3, count: 4, forward: true), 0, "回卷 ✓")
    }

    /// 反向:沿环**往回**走一格(不是"直接跳到最后" —— 那是老口径 ✓)
    func testReverseWalksBackwards() {
        XCTAssertEqual(WindowRing.nextIndex(current: 0, count: 4, forward: false), 3)
        XCTAssertEqual(WindowRing.nextIndex(current: 2, count: 4, forward: false), 1)
    }

    /// 不认识当前落焦窗(不在环里 ⇒ nil)时:正向从头跳第 2 扇、反向跳到最后一扇(照旧口径 ✓)
    func testUnknownCurrentFallsBackToOldBehaviour() {
        XCTAssertEqual(WindowRing.nextIndex(current: nil, count: 4, forward: true), 1)
        XCTAssertEqual(WindowRing.nextIndex(current: nil, count: 4, forward: false), 3)
    }

    /// 一扇窗 ⇒ 没有下一步(调用方据此不动作 ✓)
    func testSingleWindowHasNoNext() {
        XCTAssertNil(WindowRing.nextIndex(current: 0, count: 1, forward: true))
        XCTAssertNil(WindowRing.nextIndex(current: nil, count: 0, forward: true))
    }
}
