/// 同一个 App 的窗口环 —— "⌘` 下一步该去哪一扇"这个**决定**。
///
/// 病例(2026-09-22 用户实报):「我内建屏 idea 有 4 个窗口, 只能在 2 个之间使用 cmd ` 切换」
/// 日志把真因写得很清楚:
/// ```text
/// [接管⌘`] IntelliJ IDEA 在焦点屏(Built-in Retina Display) 4 扇窗 → 跳第 2 扇 wid=447
/// [接管⌘`] IntelliJ IDEA 在焦点屏(Built-in Retina Display) 4 扇窗 → 跳第 2 扇 wid=9896
/// ```
/// ⇒ 池子里 4 扇一个不少 ✓ 真因是**永远跳 `pool[1]`** ✗,而池子是按"最近使用"排的:
///   换到第 2 扇之后它就成了"最近" ⇒ 下一次的 `pool[1]` 又是原来那扇 ⇒ **任何 N 扇都会退化成 2 扇来回跳** ✗
/// ⇒ 两件事必须同时成立才对:
///   ① 环的顺序**稳定**(不随"谁刚被激活"重排 ✓ —— 所以用窗口 id 升序当环 ✓)
///   ② 起点是**当前落焦的那一扇**,然后沿环**走一格** ✓
public enum WindowRing {

    /// 沿环走一格。`current` = 当前落焦窗在环里的下标(`nil` = 不认识 ⇒ 从头起 ✓)
    public static func nextIndex(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 1 else { return nil }                       // 一扇窗没有"下一扇" ✓
        guard let current, (0..<count).contains(current) else { return forward ? 1 : count - 1 }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }
}
