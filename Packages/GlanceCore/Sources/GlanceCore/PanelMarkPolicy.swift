/// 环上那枚图标该显示什么状态 —— **决定**,不是动作(ADR-0015 ✓)。
///
/// 病例(2026-09-22 用户):「又退回不可见的角标了, 不是遗照灰」✗
/// ⇒ 一个 App 同时满足"有窗被我们收进 Dock"与"系统说它 hidden"时,原来**隐藏优先** ⇒ 显示角标 ✗
///   用户的预期是**灰**(他刚按的是 ⌘M ✓,要的是"那扇窗收起来了"这件事被看见 ✓)
/// ⇒ 现在:**有收纳就显示灰** ✓;只有"真的被隐藏、又没有收纳"才走角标 ✓
/// 环上图标的**状态记号**(两态 ✓;它怎么画留在 App 层 ✓ —— 领域层不该认识 SF Symbol 名 ✗)
public enum PanelMark: Equatable {
    case tucked    // 有窗被我们收进 Dock(⌘M)⇒ 整枚图标变灰
    case hidden    // App 被隐藏(⌘H)⇒ 右下角角标
}

public enum PanelMarkPolicy {

    /// - Parameters:
    ///   - hidden: 系统说这个 App 藏着(`isHidden` ✓)
    ///   - tucked: 有窗被我们收进 Dock(⌘M ✓)
    public static func mark(hidden: Bool, tucked: Bool) -> PanelMark? {
        if tucked { return .tucked }      // ← 用户口径:按完 ⌘M 就该看到灰 ✓
        if hidden { return .hidden }
        return nil
    }
}
