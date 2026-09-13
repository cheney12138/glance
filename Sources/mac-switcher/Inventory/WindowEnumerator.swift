import AppKit

/// 一扇被枚举出来的窗的最小事实。
struct WindowRecord {
    let wid: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
}

/// 一个 App 与其本屏窗的聚合(CONTEXT.md「本屏窗」)。
struct AppGroup {
    let pid: pid_t
    let appName: String
    var windows: [WindowRecord]
}

/// 窗口枚举:只认 CONTEXT.md 三个定义。
///   本屏窗   = 归属屏恰为语境屏(几何交占比最大)且占比 ≥20%
///   不可见窗 = 没 ordered-in 的一律不要(.optionOnScreenOnly 天然排除最小化/⌘H 隐藏)
///   排序     = MRU 证据(ADR-0003)
@MainActor
enum WindowEnumerator {
    private static let ownershipThreshold: CGFloat = 0.2

    static func enumerate(owning screen: NSScreen?) -> [AppGroup] {
        guard let screen else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var records: [WindowRecord] = []
        for info in infos {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,                                   // 自家窗(面板)不进列表
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0, // 只收普通 app 窗
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1
            else { continue }

            guard ownsByContextScreen(bounds, contextScreen: screen) else { continue }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let owner = info[kCGWindowOwnerName as String] as? String ?? "(未知应用)"
            records.append(WindowRecord(wid: wid, pid: pid, ownerName: owner, title: title, bounds: bounds))
        }

        var byPID: [pid_t: AppGroup] = [:]
        for r in records {
            byPID[r.pid, default: AppGroup(pid: r.pid, appName: r.ownerName, windows: [])].windows.append(r)
        }
        return MruEvidence.shared.ordered(pids: Array(byPID.keys)).compactMap { byPID[$0] }
    }

    /// 归属判定:与所有屏求几何交集,占比最大的屏是归属屏;必须正好是语境屏且占比达标。
    ///
    /// 坐标系注意:CGWindowList 的 bounds 是 Quartz 坐标(主屏左上原点),
    /// NSScreen.frame 是 AppKit 坐标(主屏左下原点),Y 轴反向。
    /// 交集前必须统一,否则外接屏恒无交集(T4 双屏实机现形)。
    private static func ownsByContextScreen(_ bounds: CGRect, contextScreen: NSScreen) -> Bool {
        let area = bounds.width * bounds.height
        guard area > 0 else { return false }
        var bestScreen: NSScreen?
        var bestRatio: CGFloat = 0
        for s in NSScreen.screens {
            let rect = bounds.intersection(quartzFrame(of: s))
            guard !rect.isNull else { continue }
            let ratio = (rect.width * rect.height) / area
            if ratio > bestRatio { (bestScreen, bestRatio) = (s, ratio) }
        }
        return bestScreen == contextScreen && bestRatio >= ownershipThreshold
    }

    /// NSScreen.frame(AppKit)→ Quartz 坐标。只需翻转 Y:qy = 主屏高 - y - 高
    static func quartzFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.origin.x, y: primaryHeight - f.origin.y - f.height, width: f.width, height: f.height)
    }
}
