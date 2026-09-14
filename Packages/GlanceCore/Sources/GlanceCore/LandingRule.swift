/// 唤起落点的**环序**规则(2026-09-14)。
///
/// 为什么它值得单独存在、还带测试:这条规则被写错过一次,而写错的方式是**看起来对**的那种 ——
/// 只盯"高亮落在第几格",忘了"接下来按 Tab 走到哪"。这两件事一起才构成一次切换的手感,
/// 少了后者,开关生效了用户也只会说"没生效"。
///
/// 输入是 MRU 序(最近使用的排第一):`[当前 App, 上一个 App, 更早的…, 最久没用的]`。
/// 原生 ⌘Tab 的环是:
///
/// ```
/// 上一个 App → 更早的… → 最久没用的 → 当前 App → (回到)上一个 App
/// ```
///
/// 即"**当前 App 只在绕完一圈之后才出现**"。两个推论:
///   · 正向 Tab 的下一站**不是**当前 App;
///   · 反向 ⇧Tab 的下一站**是**当前 App(从第 2 格往回一格就是第 1 格)。
///
/// 把这条环序摆到"高亮必须落在第一格"的要求下(用户口径:不要一唤起就选中第二个),
/// 唯一的解是**左旋一格**:当前 App 从队首沉到队尾,队首即"上一个 App"。
public enum LandingRule {
    /// 「唤起即切换」时的列表序:MRU 序**左旋一格**。
    /// 元素 ≤ 1 个时原样返回(没有可旋的环)。
    public static func rotatedForAdvance<T>(_ items: [T]) -> [T] {
        guard items.count > 1 else { return items }
        var next = items
        next.append(next.removeFirst())
        return next
    }

    /// 落点下标。正向 = 队首(左旋后的"上一个 App");反向 = 队尾。
    /// 反向**不做左旋**:原生 ⇧⌘Tab 直接落在最后一个(最久没用的)App 上。
    public static func landingIndex(count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        return reverse ? count - 1 : 0
    }
}
