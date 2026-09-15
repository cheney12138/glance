import Testing
import GlanceCore

/// 唤起落点(见 `LandingRule` 的文档)。这条规则写错过两次,所以用例钉的是**两个面**:
/// 「第一眼版式」(第一格是当前 App、高亮在第二格)与「整条环怎么走」(当前 App 最后才到)。
/// 只钉其中一个面的测试,前两版都能通过 —— 那正是它们上线的理由。
@Suite("唤起落点的环序")
struct LandingRuleTests {
    /// MRU 原序:当前 App 在最前,越往后越久没用
    private let ring = ["当前", "上一个", "更早1", "更早2", "最久没用"]

    @Test("第一眼:高亮落在第二格 = 上一个 App(第一格是当前 App,原生如此)")
    func landsOnSecondCell() {
        let i = LandingRule.landingIndex(count: ring.count, reverse: false)
        #expect(i == 1)
        #expect(ring[i] == "上一个")
        #expect(ring[0] == "当前") // 当前 App 仍在第一格 —— 版式不动
    }

    @Test("护城河 v1:交换两格会让第二格变成当前 App —— 一按 Tab 又回到自己")
    func swapIsStillWrong() {
        var swapped = ring
        swapped.swapAt(0, 1)
        #expect(swapped[1] == "当前")
        #expect(ring[1] != "当前")
    }

    @Test("护城河 v2:左旋一格会让第二格越过上一个 App,且第一格不再是当前 App")
    func rotationIsStillWrong() {
        var rotated = ring
        rotated.append(rotated.removeFirst())
        #expect(rotated[0] == "上一个")   // 第一格被换成了上一个 App —— 与原生第一眼不符
        #expect(rotated[1] == "更早1")    // 落点(第二格)跨过了上一个 App
    }

    @Test("环序:从落点走满一圈,当前 App 最后才到")
    func fullCyclePutsCurrentLast() {
        var seen: [String] = []
        var i = LandingRule.landingIndex(count: ring.count, reverse: false)
        for _ in 0..<ring.count {
            seen.append(ring[i])
            i = (i + 1) % ring.count
        }
        #expect(seen == ["上一个", "更早1", "更早2", "最久没用", "当前"])
        #expect(seen.last == "当前")
        #expect(Set(seen) == Set(ring))
    }

    @Test("环序:从落点往回一格 = 当前 App(原生也是这样)")
    func previousStopIsCurrent() {
        let start = LandingRule.landingIndex(count: ring.count, reverse: false)
        let back = (start - 1 + ring.count) % ring.count
        #expect(ring[back] == "当前")
    }

    @Test("反向唤起 ⇧⌘Tab:落到末格(最久没用的那个)")
    func reverseLandsOnLast() {
        let i = LandingRule.landingIndex(count: ring.count, reverse: true)
        #expect(i == ring.count - 1)
        #expect(ring[i] == "最久没用")
    }

    @Test("退化:0/1 个 App 时落点恒为 0(没有可换的对象)")
    func degenerateCases() {
        #expect(LandingRule.landingIndex(count: 0, reverse: false) == 0)
        #expect(LandingRule.landingIndex(count: 1, reverse: true) == 0)
        #expect(LandingRule.landingIndex(count: 2, reverse: false) == 1)
    }
}
