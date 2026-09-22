import Testing
@testable import GlanceCore

/// 触感的"能调"与"不能调"要分清楚 —— 分不清就会去调一个不存在的旋钮 ✗
@Suite("触感")
struct HapticPolicyTests {

    /// 用户实报(2026-09-22):「没感受到震感, 是不是强度太低了」——
    /// 于是把档位暴露到设置里,并且**默认抬一档**(轻 → 中)。
    /// 断言:三档**必须**是不同的手感,而且"强"就是那张最重的牌 ✓
    @Test("三档强度映射到三张不同的牌,且顺序单调")
    func strengthLadder() {
        #expect(HapticStrength.light.pattern == .alignment)
        #expect(HapticStrength.medium.pattern == .levelChange)
        #expect(HapticStrength.strong.pattern == .generic)
        #expect(HapticStrength.allCases.count == 3)
        // 三档互不相同(否则"调了没变化" ⇒ 又是一个假旋钮 ✗)
        #expect(Set(HapticStrength.allCases.map(\.pattern)).count == 3)
    }

    /// 只有 hover 类事件会震(2026-09-20 用户裁定:「只保留 hover 的」)——
    /// 别的动作即使强度拉满也不许震 ✓(否则"设置里开着"会变成一条到处乱震的承诺 ✗)
    @Test("非 hover 事件一律不震(与强度档无关)")
    func nonHoverEventsStaySilent() {
        for e in HapticEvent.allCases where e != .hoverAppRow && e != .hoverPreviewThumb {
            #expect(HapticPolicy.pattern(for: e, enabled: true) == .none, "\(e) 不该震")
        }
    }

    /// 总开关关掉 ⇒ 一律不震(设置是绝对权威 ✓)
    @Test("总开关关掉就通通不震")
    func masterSwitchWins() {
        #expect(HapticPolicy.pattern(for: .hoverAppRow, enabled: false) == .none)
        #expect(HapticPolicy.pattern(for: .hoverPreviewThumb, enabled: false) == .none)
    }
}
