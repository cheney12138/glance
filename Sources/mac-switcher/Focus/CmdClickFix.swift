import AppKit

/// ⌘+click 补焦(T7.5,二期功能因用户实机被咬提前)。
/// Q9 冻结语义:
///   ①只响应 ⌘+左键,普通点击一概不碰
///   ②只对非前台 App 的窗口动手
///   ③复用 WindowFocuser 的单窗聚焦(ADR-0002 收口,不加新私有面)
///   ④自家面板打开期间挂起(由触发层的 navigating 状态保证)
///   ⑤绝不吞事件:原点击照常送达;补焦在事件送达前同步完成(激活先行)
@MainActor
enum CmdClickFix {
    static func handle(point: CGPoint) {
        // CGEvent.location 与 CGWindowList bounds 同为 Quartz 全局坐标,直接可比
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 列表按 z 序由前到后。只解析"光标正下第一扇候选窗",命中即定案,
        // 绝不穿透过它再往下看(穿透已实机现形:对着前台 IDEA 的弹窗点击,
        // 焦点被送给了更下面的 Xcode —— T7.5 验收复盘)
        for info in infos {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }

            if pid == ownPID || pid == frontPID { return } // 自家窗/前台窗:收兵,不穿透

            let owner = info[kCGWindowOwnerName as String] as? String ?? "(未知应用)"
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let record = WindowRecord(wid: wid, pid: pid, ownerName: owner, title: title, bounds: bounds)
            print("[T7.5] ⌘+click 补焦: \(owner) — \(title)")

            // 事件送达前就位(本函数由事件 tap 回调同步调用):让原点击按"激活态 App"
            // 的常例被接收,弹窗/列表才能自然拿到键盘焦点。不吞事件,只是提前把世界摆好。
            WindowFocuser.focus(window: record)
            return
        }
    }
}
