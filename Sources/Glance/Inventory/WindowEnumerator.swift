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
/// `bundleID` 给预览卡标题用:终端要 tab 名、编辑器要工程名,两条规则不同(GlanceCore.WindowTitle)
struct AppGroup {
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var windows: [WindowRecord]
}

/// 窗口枚举:只认 CONTEXT.md 三个定义。
///   本屏窗   = 归属屏恰为语境屏(几何交占比最大)且占比 ≥20%
///   不可见窗 = 没 ordered-in 的一律不要(.optionOnScreenOnly 天然排除最小化/⌘H 隐藏)
///   排序     = MRU 证据(ADR-0003)
/// 幽灵窗日志去重用的锁与上次内容(见 `WindowEnumerator.logGhostOnce`)。
/// 文件级:枚举在后台线程跑,碰不到 actor 状态。
private let ghostLogLock = NSLock()
nonisolated(unsafe) private var seenGhostLines: Set<String> = []

@MainActor
enum WindowEnumerator {
    private static let ownershipThreshold: CGFloat = 0.2

    static func enumerate(owning screen: NSScreen?) -> [AppGroup] {
        guard let screen else { return [] }
        return orderByMRU(rawGroups(on: screen))
    }

    /// 枚举里**与主线程无关**的那一半:CGWindowList 与 NSWorkspace 都是线程安全的读操作。
    /// 拆出来是为了能在后台跑 —— 这几十毫秒压在事件 tap 的回调里,系统会判回调超时把 tap 停用,
    /// 漏出去的那几颗 ⌘Tab 就是“用着用着变成原生切换器”的现场(实机量到 begin 后主线程被占 ~110ms)。
    /// 剩下的排序证据(`MruEvidence`)是主线程状态,由 `orderByMRU` 在主线程补上。
    nonisolated static func rawGroups(on screen: NSScreen) -> [AppGroup] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var candidates: [WindowRecord] = []
        for info in infos {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,                                   // 自家窗(面板)不进列表
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0, // 只收普通 app 窗
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1
            else { continue }

            // 幽灵窗廉价启发式(不做 alt-tab 的完整探测器——不做清单;两条规则挡 90%):
            //   ① alpha ≈ 0 的隐形窗  ② 任一维度 <50pt 的迷你窗
            // Chrome 等 Electron 系会在 layer 0 挂无标题隐形辅助窗(实机现形:
            // 一个真窗口冒出第二个空白无标题窗)
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.05 || bounds.width < 50 || bounds.height < 50 {
                let ownerForLog = info[kCGWindowOwnerName as String] as? String ?? "?"
                Self.logGhostOnce("\(ownerForLog) alpha=\(alpha) \(Int(bounds.width))x\(Int(bounds.height))")
                continue
            }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let owner = info[kCGWindowOwnerName as String] as? String ?? "(未知应用)"
            candidates.append(WindowRecord(wid: wid, pid: pid, ownerName: owner, title: title, bounds: bounds))
        }

        // **AX 认可过滤**:杀掉"空壳 surface"(病例:Chrome 只有一扇窗却出两张卡片,那张无标题卡
        // 快照还是一片空白 —— Chromium 挂在 layer 0、alpha 1、尺寸正常的辅助 surface)。
        // 判据照 AltTab 的 WindowAdmissionResolver:可切换目标必须在 AX 侧也对得上。
        // 安全阀:AX 没话说(nil)时**不过滤**,否则会把不暴露 AX 的 App 整组清空。
        var axFiltered: [WindowRecord] = []
        axFiltered.reserveCapacity(candidates.count)
        for (pid, group) in Dictionary(grouping: candidates, by: \.pid) {
            guard let admission = AXWindowList.admission(ofPID: pid) else {
                axFiltered.append(contentsOf: group)
                continue
            }
            let kept = group.filter { admission.admitted.contains($0.wid) }
            let dropped = group.filter { !admission.admitted.contains($0.wid) }
            if !dropped.isEmpty {
                Self.logGhostOnce("\(group.first?.ownerName ?? "?"):AX 不认 \(dropped.count)/\(group.count) 扇 — "
                      + dropped.map { "#\($0.wid)\"\($0.title)\"(\(admission.rejected[$0.wid] ?? "?"))" }
                                .joined(separator: ", "))
            }
            axFiltered.append(contentsOf: kept)
        }

        // 归属过滤:只留本屏窗
        let records = axFiltered.filter { ownsByContextScreen($0.bounds, contextScreen: screen) }
        var byPID: [pid_t: AppGroup] = [:]
        for r in records {
            byPID[r.pid, default: AppGroup(pid: r.pid, appName: r.ownerName,
                                            bundleID: NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier,
                                            windows: [])].windows.append(r)
        }

        // 无窗应用(T15,用户拍板):全系统一扇可见窗都没有的已打开 App,
        // 不划分显示器分组,任何语境屏都展示;确认 = 激活该 App。
        // 判断面是 candidates(已通过幽灵窗启发式的全系统可见窗),不是本屏 records
        let hasWindowPIDs = Set(candidates.map(\.pid))
        let excludedSystemApps: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui"]
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  !hasWindowPIDs.contains(app.processIdentifier),
                  !excludedSystemApps.contains(app.bundleIdentifier ?? ""),
                  !app.isTerminated else { continue }
            byPID[app.processIdentifier] = AppGroup(
                pid: app.processIdentifier,
                appName: app.localizedName ?? "(未知应用)",
                bundleID: app.bundleIdentifier,
                windows: []
            )
        }

        return Array(byPID.values)
    }

    /// 幽灵窗日志**同一条只记一次**(2026-09-15):它每局枚举都会重印,而内容几乎永远一样
    /// (CatDesk 的空壳窗、Chrome 的查找条)—— 一天上千行,把真信号淹了。
    /// 只在**内容变化**时打:新出现的幽灵窗仍然一眼可见,重复的不再刷屏。
    /// 被 `nonisolated` 的枚举路径调用(枚举跑后台),所以状态放文件级全局 + 加锁 ——
    /// 挂在 `@MainActor` 的 enum 上是编译不过的,这不是绕路,是它本来就跨线程。
    nonisolated private static func logGhostOnce(_ line: String) {
        ghostLogLock.lock()
        defer { ghostLogLock.unlock() }
        // ⚠️ 原来只跟"上一条"比 —— 而两条幽灵窗日志是**交替**出现的
        // (CatDesk 的空壳窗 / Chrome 的查找条),于是每局都把两条重印一遍 ✗
        // (2026-09-15 实测:一份日志里同两条各出现 7 次)。改成"见过的就不再印"。
        guard !seenGhostLines.contains(line) else { return }
        seenGhostLines.insert(line)
        print("[幽灵窗滤除] \(line)")
    }

    /// MRU 证据排序(主线程状态,必须在主线程调用)
    static func orderByMRU(_ groups: [AppGroup]) -> [AppGroup] {
        let byPID = Dictionary(groups.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return MruEvidence.shared.ordered(pids: Array(byPID.keys)).compactMap { byPID[$0] }
    }

    /// 归属判定:与所有屏求几何交集,占比最大的屏是归属屏;必须正好是语境屏且占比达标。
    ///
    /// 坐标系注意:CGWindowList 的 bounds 是 Quartz 坐标(主屏左上原点),
    /// NSScreen.frame 是 AppKit 坐标(主屏左下原点),Y 轴反向。
    /// 交集前必须统一,否则外接屏恒无交集(T4 双屏实机现形)。
    /// `nonisolated`:归属判定要跟着枚举一起下后台(见 `rawGroups`);`NSScreen.screens` 是快照式读取。
    nonisolated private static func ownsByContextScreen(_ bounds: CGRect, contextScreen: NSScreen) -> Bool {
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
    nonisolated static func quartzFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.origin.x, y: primaryHeight - f.origin.y - f.height, width: f.width, height: f.height)
    }
}
