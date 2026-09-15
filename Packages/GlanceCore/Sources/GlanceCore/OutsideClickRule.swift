import CoreGraphics

/// 「这一下点击算不算点在了面板外」—— 判据只有一条:**落在两个内容矩形之外**。
///
/// 为什么不能判窗口:窗口比玻璃大(四周是 `shadowPadStrip`/`shadowPadPop` 的**透明呼吸区**),
/// 而窗口按整局最大布局开(ADR-0006),所以窗口矩形根本不代表"看得见的面板"。
///
/// 为什么需要这条规则(2026-09-15 病例:点面板周围的空白不关闭):
/// 透明呼吸区只是 `ClickThroughHostingView.hitTest` 返回 nil —— **不吃点击**,但 AppKit 里
/// 这**不会**把事件转给下层的 App ✗;面板又是 nonactivating,事件也不进任何视图 ✗。
/// 于是这个点击既不属于"别的 App"(全局监听收不到)、也没有 view 处理 —— 掉在地上。
/// 所以 App 侧装两个监听(全局 + 本地),**共用这一条判据**。
public enum OutsideClickRule {

    /// - Parameters:
    ///   - panelContent: 面板玻璃的矩形(窗口内缩 shadowPadStrip),nil = 面板不可见
    ///   - trayContent: 托盘玻璃的矩形(窗口内缩 shadowPadPop),nil = 托盘不可见
    /// - Returns: true = 点在**所有**可见内容之外,该关面板。
    ///   **两个都 nil 时返回 false** —— 看不见任何内容时不该凭一次点击就关(那是误判,不是判断)。
    public static func isOutside(point: CGPoint, panelContent: CGRect?, trayContent: CGRect?) -> Bool {
        if let panelContent, panelContent.contains(point) { return false }
        if let trayContent, trayContent.contains(point) { return false }
        return panelContent != nil || trayContent != nil
    }
}
