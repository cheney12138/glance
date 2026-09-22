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

    /// 实报(2026-09-22,带截图):「回来还是在 Chrome 上」——
    /// 环序本该 `[当前 App, 上一个, …]`,落点 = 第二格 ✓;
    /// 但那次第一格是 IntelliJ、当前 App 是 **Chrome(第 2 格)** ✗
    /// ⇒ 老口径(固定取第 1 格)落到了 **Chrome 自己**身上 ✗(按一下什么都没换)。
    /// 新口径:显式传"当前 App 在第几格"⇒ 无论顺序怎么偏,**落点都跳过自己** ✓
    @Test("落点从「当前 App 的位置」算:顺序偏了也不许落到自己身上")
    func landingSkipsCurrentWhereverItIs() {
        // 3 个 App,当前在第 2 格(下标 1)⇒ 正向落第 3 格(下标 2)、反向落第 1 格(下标 0)
        #expect(LandingRule.landingIndex(count: 3, from: 1, reverse: false) == 2)
        #expect(LandingRule.landingIndex(count: 3, from: 1, reverse: true) == 0)
        // 当前在最后一格 ⇒ 正向绕回第 1 格
        #expect(LandingRule.landingIndex(count: 3, from: 2, reverse: false) == 0)
        // 只有一个 App ⇒ 只能落它自己(没得选 ✓)
        #expect(LandingRule.landingIndex(count: 1, from: 0, reverse: false) == 0)
        // 越界/负数也不许崩(调用方算出来的下标可能来自"没找到" ✓)
        #expect(LandingRule.landingIndex(count: 3, from: -1, reverse: false) == 1)
        #expect(LandingRule.landingIndex(count: 3, from: 7, reverse: false) == 2)
    }
}
