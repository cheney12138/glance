import XCTest
@testable import GlanceCore

/// 窗数记账法(圆点=1 / 短横=5)+ 自适应收窄。
/// 2026-09-15 定稿:逐窗一粒点在 13 扇时铺满格子、20 扇溢出 1.56 倍,且同色点只能默数 ——
/// 换成 5 进制记号 + 收窄兜底。这里把口径钉住。
final class WindowTallyTests: XCTestCase {
    private let m = WindowTally.Metrics(dot: 4.8, dashWidth: 12.0, gap: 3.6, minDot: 3.0, minGap: 2.0)
    private let cell: CGFloat = 105.6   // PanelMetrics.icon @1.2

    // MARK: - 记号序列

    func testMarksIsBase5Tally() {
        XCTAssertEqual(WindowTally.marks(for: 0), [])
        XCTAssertEqual(WindowTally.marks(for: 1), [.dot])
        XCTAssertEqual(WindowTally.marks(for: 4), [.dot, .dot, .dot, .dot])
        XCTAssertEqual(WindowTally.marks(for: 5), [.dash])
        XCTAssertEqual(WindowTally.marks(for: 6), [.dash, .dot])
        XCTAssertEqual(WindowTally.marks(for: 12), [.dash, .dash, .dot, .dot])
    }

    /// 短横在前(罗马数字读法):XII = X + II,不是 II + X
    func testDashesComeFirst() {
        let marks = WindowTally.marks(for: 17)
        XCTAssertEqual(marks, [.dash, .dash, .dash, .dot, .dot])
    }

    func testTwentyFiveIsFiveDashes() {
        XCTAssertEqual(WindowTally.marks(for: 25), Array(repeating: .dash, count: 5))
        XCTAssertEqual(WindowTally.marks(for: 26), Array(repeating: .dash, count: 5) + [.dot])
    }

    /// 负数/异常输入不该画出东西(窗口数理论上不会负,但裁量函数不该依赖调用方保证)
    func testNonPositiveIsEmpty() {
        XCTAssertEqual(WindowTally.marks(for: -3), [])
    }

    // MARK: - 宽度:记账法比逐窗点窄一个数量级

    func testWidthIsMuchNarrowerThanOnePerWindow() {
        // 20 扇:逐窗 20 粒 = 20*4.8 + 19*3.6 = 164.4pt(1.56 倍格子);记账法 4 个横
        let tally = WindowTally.layout(windows: 20, available: cell, metrics: m)
        XCTAssertEqual(tally.marks.count, 4)
        XCTAssertEqual(tally.sizes.scale, 1, "20 扇远没到需要收窄的程度")
        XCTAssertLessThan(WindowTally.rowWidth(tally.marks, metrics: m, scale: 1), cell)
    }

    /// 24 → 25 会因为进位突然变短 —— 记账制天生的跳变(罗马数字 IV→V),这里是**有意保留**的
    func testCarryMakesItShorterAndThatIsIntentional() {
        let w24 = WindowTally.rowWidth(WindowTally.marks(for: 24), metrics: m, scale: 1)
        let w25 = WindowTally.rowWidth(WindowTally.marks(for: 25), metrics: m, scale: 1)
        XCTAssertLessThan(w25, w24)
    }

    // MARK: - 自适应收窄(兜底)

    /// 现实窗数不该触发收窄 —— 收窄是兜底,不是主力。
    /// 临界值随 token 走:横 12.0pt 时 **35 扇**正好铺满一格(7 横 = 105.6pt),第 36 扇才开始收窄
    func testRealisticCountsDoNotShrink() {
        for n in [1, 4, 6, 12, 20, 25, 30, 35] {
            XCTAssertEqual(WindowTally.layout(windows: n, available: cell, metrics: m).sizes.scale, 1,
                           "\(n) 扇不该收窄")
        }
    }

    func testHugeCountsShrinkButNeverOverflow() {
        for n in [60, 99, 200, 999] {
            let l = WindowTally.layout(windows: n, available: cell, metrics: m)
            XCTAssertGreaterThanOrEqual(l.sizes.scale, m.minScale - 0.0001, "\(n) 扇:不能缩过下限")
            XCTAssertLessThanOrEqual(WindowTally.rowWidth(l.marks, metrics: m, scale: l.sizes.scale),
                                     cell + 0.0001, "\(n) 扇:一行不许溢出格子")
        }
    }

    /// 到下限还放不下时,从**尾部摘圆点**(保留"几组 5"= 仍然读作"很多")
    func testTruncationDropsTrailingDotsFirst() {
        let l = WindowTally.layout(windows: 999, available: 20, metrics: m)
        XCTAssertEqual(l.sizes.scale, m.minScale, accuracy: 0.0001)
        XCTAssertEqual(l.marks.last, .dash, "摘的应该是个位数那一头")
        XCTAssertLessThanOrEqual(WindowTally.rowWidth(l.marks, metrics: m, scale: l.sizes.scale), 20 + 0.0001)
    }

    func testZeroWindowsDrawsNothing() {
        let l = WindowTally.layout(windows: 0, available: cell, metrics: m)
        XCTAssertTrue(l.marks.isEmpty)
        XCTAssertEqual(WindowTally.rowWidth([], metrics: m, scale: 1), 0)
    }
}
