/// 「能不能用**上一局的名单**先把面板画出来」—— 决定，不是动作（ADR-0015 ✓）。
///
/// 起因（2026-09-24 的账，用户要"提高帧率/流畅度"那一轮）：
/// ```text
/// [打卡] 唤起 共 85.9ms | 枚举 44.8 · 落点 16.0 · 开窗 17.4 · 首帧 7.7
/// [T8]   按键→枚举就位 40–63ms
/// ```
/// ⇒ 枚举占了一多半，而它**挡在面板出现之前** ✗ ⇒ 入口那两根弹簧的头 3 帧被白白等掉 ✓
/// 现在改成"陈旧先上屏 + 枚举回来刷新"（AltTab / DockDoor 都是这个路子 ✓）
///
/// 这里只放**门槛**（什么时候**不许**用陈旧名单 ✓），动作与刷新时机留在 App 层 ✓：
/// 门槛错一条就会出现"用别块屏的名单画面板"这种一眼假 ✗
public enum StaleListPolicy {

    /// - Parameters:
    ///   - enabled: 档位（`debug.staleListFirst`，默认开 ✓）
    ///   - listCount: 手里这份名单有几个 App
    ///   - windowCount: 这些 App 一共几扇窗
    ///   - sameScreen: 这份名单是不是**本局的语境屏**枚举出来的
    public static func canShowStale(enabled: Bool,
                                    listCount: Int,
                                    windowCount: Int,
                                    sameScreen: Bool) -> Bool {
        guard enabled else { return false }
        // ★ 屏必须同源：名单是按"归属屏 = 语境屏"筛出来的（ADR-0008 ✓）
        //   跨屏拿去用 ⇒ 画出来的 App 全是另一块屏上的 ✗
        guard sameScreen else { return false }
        guard listCount > 0 else { return false }
        // ★ 一扇窗都没有的名单不许用：那说明上次收场时窗全没了，
        //   画出来就是"一局没有窗口的面板"，紧接着刷新再拆掉 ⇒ 闪一下 ✗
        guard windowCount > 0 else { return false }
        return true
    }
}
