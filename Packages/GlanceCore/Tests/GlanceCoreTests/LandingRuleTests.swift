import Testing
import GlanceCore

/// 唤起落点的环序(见 `LandingRule` 的文档)。
/// 这组用例存在的理由:**这条规则被写错过一次** —— 第一版用 `swapAt(0,1)` 让高亮落到了第一格,
/// 却把当前 App 放到了第二格,于是"按一下 Tab 又回到自己"。观感对了、环序错了,
/// 用户只会报一句"开关没生效"。所以这里钉的是**走一圈的整条路径**,不是落点那一格。
@Suite("唤起落点的环序")
struct LandingRuleTests {
    /// MRU 序:当前 App 在最前,越往后越久没用
    private let mru = ["当前", "上一个", "更早1", "更早2", "最久没用"]

    @Test("开关开:左旋一格 —— 当前 App 沉到队尾,队首是上一个 App")
    func rotatesInsteadOfSwapping() {
        let rotated = LandingRule.rotatedForAdvance(mru)
        #expect(rotated == ["上一个", "更早1", "更早2", "最久没用", "当前"])
        // 反例护城河:交换两格会让"当前"停在第二格 —— 那正是上一版的错
        var swapped = mru
        swapped.swapAt(0, 1)
        #expect(swapped[1] == "当前")
        #expect(rotated[1] != "当前")
    }

    @Test("开关开:正向 Tab 的下一站不是当前 App(原生环序)")
    func nextStopIsNotCurrentApp() {
        let rotated = LandingRule.rotatedForAdvance(mru)
        let start = LandingRule.landingIndex(count: rotated.count, reverse: false)
        #expect(rotated[start] == "上一个")          // 落点 = 上一个 App
        let next = (start + 1) % rotated.count
        #expect(rotated[next] == "更早1")            // 下一站是更早的那个,不是"当前"
    }

    @Test("开关开:反向 ⇧Tab 从落点往回一格 = 当前 App(原生也是这样)")
    func previousStopIsCurrentApp() {
        let rotated = LandingRule.rotatedForAdvance(mru)
        let start = LandingRule.landingIndex(count: rotated.count, reverse: false)
        let back = (start - 1 + rotated.count) % rotated.count
        #expect(rotated[back] == "当前")
    }

    @Test("开关开:走满一圈,每个 App 各出现一次,当前 App 最后才到")
    func fullCycleVisitsEveryAppOnce() {
        let rotated = LandingRule.rotatedForAdvance(mru)
        var seen: [String] = []
        var i = LandingRule.landingIndex(count: rotated.count, reverse: false)
        for _ in 0..<rotated.count {
            seen.append(rotated[i])
            i = (i + 1) % rotated.count
        }
        #expect(seen == rotated)
        #expect(seen.last == "当前")
        #expect(Set(seen) == Set(mru))
    }

    @Test("反向唤起:落到队尾,且不左旋(原生 ⇧⌘Tab 落在最久没用的那个)")
    func reverseLandsOnLast() {
        #expect(LandingRule.landingIndex(count: 5, reverse: true) == 4)
        #expect(LandingRule.rotatedForAdvance(mru).last == "当前") // 旋过之后队尾才是"当前"
        #expect(mru.last == "最久没用")                            // 不旋的话队尾是最久没用的
    }

    @Test("退化:0/1 个元素不旋,落点恒为 0")
    func degenerateCases() {
        #expect(LandingRule.rotatedForAdvance([] as [String]) == [])
        #expect(LandingRule.rotatedForAdvance(["只有一个"]) == ["只有一个"])
        #expect(LandingRule.landingIndex(count: 0, reverse: false) == 0)
        #expect(LandingRule.landingIndex(count: 1, reverse: true) == 0)
    }
}
