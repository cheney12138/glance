import AppKit
import CoreGraphics

/// 全屏 Space 探针:判断**某一块屏**当前是不是被一个全屏窗口占着(见 ADR-0018 常驻模式方案 A)。
///
/// 用途:Glance 程序坞常驻(`always-on`)时,若用户把某个 App 切进全屏,全屏窗口会拿到**独立 Space**,
/// 常驻条带应当**自动避让**(隐藏);退出全屏后再回来。判据只需要回答"这块屏有没有全屏窗",
/// 不需要知道是谁 —— 所以这里只做**只读几何判定**,零私有 API、零 AX 调用。
///
/// 为什么不问 `NSWorkspace`/`NSWindow`:全屏窗口在 `NSApplication` 侧是别人的窗,我们看不到;
/// 而窗口服务器的 `CGWindowListCopyWindowInfo` 是公开接口、单次调用在毫秒级(与 `WindowEnumerator` 同源)。
///
/// 坐标系:CGWindowList 的 bounds 是 **Quartz 坐标**(主屏左上原点,Y 向下),
/// `NSScreen.frame` 是 **AppKit 坐标**(主屏左下原点,Y 向上)⇒ 只翻 Y:`y = 主屏高 - cgRect.maxY`。
/// (2026-11-25 同一类坑:`WindowEnumerator.ownsByContextScreen` 的注释,外接屏不翻 Y 恒不命中。)
///
/// 线程纪律:纯只读(CG 查询 + `NSScreen` 快照)⇒ 任意线程可调;这里不碰任何 UI 对象 ✓
/// (与 `WindowEnumerator.ownsByContextScreen` 同一条约定。)
enum DockFullscreenProbe {
    /// 全屏窗口与屏框的容差(pt)。全屏窗的 bounds 与 `screen.frame` 实测可差 1pt 上下
    /// (缩放屏、刘海机型的安全区换算)⇒ 卡死在 0 会漏判。
    private static let tolerance: CGFloat = 2

    /// 只排**系统壳**进程的窗:它们的 layer 可能是 0 但显然不是"用户的全屏 App"。
    ///
    /// 注意**不要**顺手把 `Finder` 排掉:Finder 的桌面窗 layer 是 `kCGDesktopWindowLevel != 0`,
    /// 下面第一道 `layer == 0` 已经把它挡掉了 ✓;而 Finder **真全屏**时确实是用户要避让的场景 ✓
    /// (同理 `Control Center` / `Notification Center` 也不在列表里 —— 它们要么 layer != 0,
    ///  要么 bounds 与屏框差得远,几何判定天然不会误判;多排一条只会把"按名字过滤"变成猜测。)
    private static let shellOwnerNames: Set<String> = ["Window Server", "Dock", "Wallpaper"]

    /// 这块屏当前是否被全屏窗口覆盖。
    ///
    /// 判定链(命中即 `true`,全部走完则 `false`):
    /// 1. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` 取**在屏**窗口;
    /// 2. `layer == 0`(普通窗口层级)—— 排除桌面/状态栏/浮动层;
    /// 3. `ownerPID != 自己` —— 自己的窗(常驻条带、面板)当然不能算;
    /// 4. `ownerName` 不在 `shellOwnerNames`;
    /// 5. `alpha > 0.01` —— 淡出中的窗(切换动画尾巴)不算;
    /// 6. 窗口框**覆盖整块屏**:宽/高 ≥ 屏框 ± 2pt、中心偏差 ≤ 2pt。
    static func isScreenInFullscreen(_ screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        // 主屏高(Quartz → AppKit 的翻转轴)。用"origin 为 .zero 的那块屏"而不是 `NSScreen.main`:
        // `main` 是"当前接收键盘事件"的屏,鼠标在副屏时会变;AppKit 全局坐标原点却始终锚在 .zero 那块 ✓
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let screenFrame = screen.frame
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ownPID else { continue }
            if let ownerName = info[kCGWindowOwnerName as String] as? String,
               shellOwnerNames.contains(ownerName) {
                continue
            }
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            guard cgRect.width > 0, cgRect.height > 0 else { continue }

            let appKitRect = CGRect(
                x: cgRect.minX,
                y: primaryHeight - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            if coversScreen(windowFrame: appKitRect, screenFrame: screenFrame) {
                return true
            }
        }
        return false
    }

    /// 一扇窗是否**铺满整块屏**(全屏 Space 的定义)。
    ///
    /// 与 `GlanceCore.DockAlwaysOnPolicy.coversScreen` 同口径(2pt 容差 + 中心偏差 ≤ 2pt),
    /// 这里内联一份是为了让探针**零跨模块依赖**:Dock 模块内部两个 worker 并行时,
    /// 谁先落地都不会产生瞬时编译依赖 ✓
    private static func coversScreen(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        guard windowFrame.width >= screenFrame.width - tolerance,
              windowFrame.height >= screenFrame.height - tolerance else { return false }
        return abs(windowFrame.midX - screenFrame.midX) <= tolerance
            && abs(windowFrame.midY - screenFrame.midY) <= tolerance
    }
}
