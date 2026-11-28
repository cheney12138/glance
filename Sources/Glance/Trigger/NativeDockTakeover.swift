import Foundation
import GlanceCore

/// 原生 Dock（`com.apple.dock`）的自动隐藏接管与四重恢复守卫（见 ADR-0018）。
///
/// 职责边界：
/// - 只读写 `com.apple.dock` 的 `autohide` 与 `autohide-delay`，接管/恢复决策全部委托给 `GlanceCore.DockTakeoverPlan`；
/// - 接管前将用户原始偏好持久化快照写入 `UserDefaults.standard`（键 `Keys.dockSavedSnapshot`），
///   并在 `~/Library/Application Support/Glance/dock-takeover.marker` 落脏标记文件；
/// - 只有变更真正落盘且与当前系统值存在实际差异时，才调 `/usr/bin/killall Dock` 重载一次；
/// - `restoreIfNeeded()` 为 `nonisolated`，供正常退出与信号源直接调用；未捕获异常走
///   `emergencyRestoreOnCrash()`（不阻塞等锁，崩溃时也能保证原生 Dock 被救回来）。
@MainActor
enum NativeDockTakeover {
    private nonisolated static let dockDomain = "com.apple.dock" as CFString
    private nonisolated static let autohideKey = "autohide" as CFString
    private nonisolated static let autohideDelayKey = "autohide-delay" as CFString
    private nonisolated static let doubleEqualityTolerance = 0.0001
    private nonisolated static let lock = NSLock()

    // MARK: - 公开入口

    /// 按开关状态幂等应用或归还原生 Dock 接管。
    static func apply(enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            // ★ 交互式入口（设置页开关 / 滑杆 / 分级重算）⇒ **不等** Dock 重载：
            //   这条路径跑在主线程上，`waitUntilExit()` 会把 UI 卡住几百毫秒（滑杆拖动时更明显）。
            //   killall 已经 spawn 出去了，重载与我们无关 ✓
            applyTakeoverLocked(waitForExit: false)
        } else {
            restoreLocked(forceDefaultIfMissing: false, waitForExit: false)
        }
    }

    /// 供退出 / 信号守卫调用的兜底恢复：若存在脏标记或备份快照，立即还原并清理标记与快照。
    ///
    /// 这里**必须** `waitForExit: true`：调用点（`willTerminate` / 信号源）之后进程立刻就走，
    /// 不等 `killall Dock` 完成，重载可能连同进程一起消失 ⇒ 原生 Dock 留在接管态 ✗
    /// （崩溃处理器用的是另一个入口 `emergencyRestoreOnCrash()`：它不能阻塞等锁，见下）
    nonisolated static func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard markerExistsLocked() || hasRawSnapshotLocked() else { return }
        restoreLocked(forceDefaultIfMissing: false, waitForExit: true)
    }

    /// **崩溃专用**兜底恢复：未捕获异常处理器调用。
    ///
    /// 与 `restoreIfNeeded()` 的唯一区别是**绝不阻塞**：
    /// - 崩溃可能正好发生在**别人持锁的那一瞬间**（`apply` / `restore` 的执行体中段）⇒ 若这里
    ///   `lock.lock()`，崩溃处理器会永久卡在等锁上，原生 Dock 就再也救不回来了 ✗
    /// - 所以先 `try()`：拿到锁走完整恢复（有快照就还原用户原值）；没拿到锁就走**无锁硬恢复**，
    ///   直接把两个键钉回「原生默认」（`autohide = false`、删掉 `autohide-delay`）——
    ///   宁可丢掉用户的原始快照细节，也不能让 Dock 一直不自动隐藏 ✓
    nonisolated static func emergencyRestoreOnCrash() {
        if lock.try() {
            defer { lock.unlock() }
            restoreLocked(forceDefaultIfMissing: false, waitForExit: false)
            return
        }

        glog("[Dock接管] 崩溃兜底未取到锁（崩溃发生在持锁瞬间），改走无锁硬恢复")
        CFPreferencesSetAppValue(autohideKey, kCFBooleanFalse, dockDomain)
        CFPreferencesSetAppValue(autohideDelayKey, nil, dockDomain)
        _ = CFPreferencesAppSynchronize(dockDomain)
        reloadDockProcess(waitForExit: false)
    }

    /// 启动自愈：若上次退出遗留了脏标记（如被 SIGKILL 强杀），打印日志并按当前开关决定恢复或重同步。
    static func recoverDirtyTakeoverOnLaunchIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        let hasMarker = markerExistsLocked()
        let dockEnabled = Keys.isDockEnabled

        if hasMarker {
            glog("[Dock接管] 检测到上次遗留的脏标记（可能被强杀），当前 dock.enabled=\(dockEnabled)")
            if dockEnabled {
                applyTakeoverLocked(waitForExit: false)
            } else {
                restoreLocked(forceDefaultIfMissing: false, waitForExit: false)
            }
            return
        }

        if !dockEnabled && hasRawSnapshotLocked() {
            glog("[Dock接管] 发现残留原生 Dock 快照且功能已关闭，执行恢复")
            restoreLocked(forceDefaultIfMissing: false, waitForExit: false)
        }
    }

    /// 供设置页应急按钮调用：强制恢复原生 Dock 并将 `Keys.dockEnabled` 置为 `false`。
    static func forceRestoreNativeDock() {
        UserDefaults.standard.set(false, forKey: Keys.dockEnabled)
        lock.lock()
        defer { lock.unlock() }
        // 设置页按钮 ⇒ 交互式路径，不等 Dock 重载（同 `apply(enabled:)`）
        restoreLocked(forceDefaultIfMissing: true, waitForExit: false)
    }

    // MARK: - 内部实现（需在 lock 内调用）

    private nonisolated static func applyTakeoverLocked(waitForExit: Bool) {
        let mutations = DockTakeoverPlan.takeoverMutations()

        // ★ 2026-11-25 病例（滑杆拖一下就读一次盘 / 同步一次 CFPreferences）：
        //   设置页拖动图标/预览速度滑杆会**高频**回调到 `apply(enabled: true)`，而原实现每次都
        //   `CFPreferencesAppSynchronize` + `writeMarkerLocked()`（原子写一个新文件）。
        //   ⇒ 快路径：脏标记在 + 原始快照在 + 偏好已经是接管值 ⇒ 没有任何事要做，直接早退：
        //     零 `CFPreferencesAppSynchronize`、零磁盘写、零 `killall Dock` ✓
        //   读值走 `read*Locked`（`CFPreferencesCopyAppValue`）⇒ 不触盘 ✓（代价：外部改过的
        //   Dock 偏好可能在本进程缓存里看不到；首接管那次没有标记，走下面的全路径，那里有 synchronize）
        if markerExistsLocked(), hasRawSnapshotLocked(), !mutations.contains(where: needsWriteLocked) {
            return
        }

        _ = CFPreferencesAppSynchronize(dockDomain)
        let currentAutohide = readDockAutohideLocked()
        let currentDelay = readDockAutohideDelayLocked()

        // 仅在尚未保存原始快照、且当前系统值不是“我们接管态”时才记录快照，防二次接管覆盖原始值。
        if !hasRawSnapshotLocked(),
           !DockTakeoverPlan.looksLikeOurTakeover(autohide: currentAutohide, autohideDelay: currentDelay) {
            let snapshot = DockPreferencesSnapshot(autohide: currentAutohide, autohideDelay: currentDelay)
            saveSnapshotLocked(snapshot)
        }

        writeMarkerLocked()

        applyMutationsAndReloadIfChangedLocked(mutations, waitForExit: waitForExit)
    }

    /// 只读判据：这条 mutation **会不会**真的改变当前值。零写入、零同步（同步只发生在真的有改动后）✓
    private nonisolated static func needsWriteLocked(_ mutation: DockPreferenceMutation) -> Bool {
        switch mutation {
        case .setBool(let key, let value):
            return readBoolLocked(key: key as CFString) != value
        case .setDouble(let key, let value):
            let current = readDoubleLocked(key: key as CFString)
            return current.map { abs($0 - value) >= doubleEqualityTolerance } ?? true
        case .remove(let key):
            return CFPreferencesCopyAppValue(key as CFString, dockDomain) != nil
        }
    }

    private nonisolated static func restoreLocked(forceDefaultIfMissing: Bool, waitForExit: Bool) {
        _ = CFPreferencesAppSynchronize(dockDomain)
        let currentAutohide = readDockAutohideLocked()
        let currentDelay = readDockAutohideDelayLocked()
        let snapshot = loadSnapshotLocked()

        let mutations: [DockPreferenceMutation]?
        if let snapshot {
            mutations = DockTakeoverPlan.restoreMutations(from: snapshot)
        } else if forceDefaultIfMissing
                    || DockTakeoverPlan.looksLikeOurTakeover(autohide: currentAutohide, autohideDelay: currentDelay) {
            let fallback = DockPreferencesSnapshot(autohide: false, autohideDelay: nil)
            mutations = DockTakeoverPlan.restoreMutations(from: fallback)
        } else {
            mutations = nil
        }

        if let mutations {
            applyMutationsAndReloadIfChangedLocked(mutations, waitForExit: waitForExit)
        }

        UserDefaults.standard.removeObject(forKey: Keys.dockSavedSnapshot)
        deleteMarkerLocked()
    }

    private nonisolated static func applyMutationsAndReloadIfChangedLocked(_ mutations: [DockPreferenceMutation],
                                                                         waitForExit: Bool) {
        var changed = false

        // 只有真正需要写的那些才 set（判据与上面的快路径同一份，见 `needsWriteLocked`）
        for mutation in mutations where needsWriteLocked(mutation) {
            switch mutation {
            case .setBool(let key, let value):
                CFPreferencesSetAppValue(key as CFString, value ? kCFBooleanTrue : kCFBooleanFalse, dockDomain)

            case .setDouble(let key, let value):
                CFPreferencesSetAppValue(key as CFString, NSNumber(value: value), dockDomain)

            case .remove(let key):
                CFPreferencesSetAppValue(key as CFString, nil, dockDomain)
            }
            changed = true
        }

        guard changed else { return }
        guard CFPreferencesAppSynchronize(dockDomain) else {
            glog("[Dock接管] 写入 com.apple.dock 偏好同步失败，跳过重载")
            return
        }
        reloadDockProcess(waitForExit: waitForExit)
    }

    /// 重载原生 Dock。
    ///
    /// `waitForExit` 的语义是**调用点要不要等这件事做完**：
    /// - `true`：退出 / 信号 / 崩溃前的恢复。调用点之后进程立刻消失，不等就可能把重载一起带走；
    /// - `false`：交互式入口（设置页开关、滑杆）与崩溃兜底。这些路径跑在**主线程**或**崩溃线程**上，
    ///   `waitUntilExit()` 会把它们卡住（崩溃线程尤其致命：卡在那里 = 崩溃处理器永不返回）⇒ fire-and-forget。
    ///
    /// 不等的分支让 `Process` 对象自然析构：`posix_spawn` 在 `run()` 返回时已经完成，子进程照常跑完
    /// `killall` 并退出，我们不等也不影响它 ✓（僵尸进程由系统回收，而 App 这时通常正在退出）。
    private nonisolated static func reloadDockProcess(waitForExit: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        do {
            try task.run()
        } catch {
            glog("[Dock接管] 无法执行 killall Dock: \(error.localizedDescription)")
            return
        }
        guard waitForExit else { return }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            glog("[Dock接管] killall Dock 退出码 \(task.terminationStatus)")
        }
    }

    // MARK: - 偏好读写

    private nonisolated static func readDockAutohideLocked() -> Bool? {
        readBoolLocked(key: autohideKey)
    }

    private nonisolated static func readDockAutohideDelayLocked() -> Double? {
        readDoubleLocked(key: autohideDelayKey)
    }

    private nonisolated static func readBoolLocked(key: CFString) -> Bool? {
        guard let raw = CFPreferencesCopyAppValue(key, dockDomain) else { return nil }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    private nonisolated static func readDoubleLocked(key: CFString) -> Double? {
        guard let raw = CFPreferencesCopyAppValue(key, dockDomain) else { return nil }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - 快照与脏标记

    private nonisolated static func hasRawSnapshotLocked() -> Bool {
        UserDefaults.standard.object(forKey: Keys.dockSavedSnapshot) != nil
    }

    private nonisolated static func saveSnapshotLocked(_ snapshot: DockPreferencesSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Keys.dockSavedSnapshot)
    }

    private nonisolated static func loadSnapshotLocked() -> DockPreferencesSnapshot? {
        guard let raw = UserDefaults.standard.object(forKey: Keys.dockSavedSnapshot) else { return nil }
        let data: Data?
        if let rawData = raw as? Data {
            data = rawData
        } else if let rawString = raw as? String {
            data = rawString.data(using: .utf8)
        } else {
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(DockPreferencesSnapshot.self, from: data)
    }

    private nonisolated static var markerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Glance", isDirectory: true)
            .appendingPathComponent("dock-takeover.marker")
    }

    private nonisolated static func markerExistsLocked() -> Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    private nonisolated static func writeMarkerLocked() {
        let url = markerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? Data("dock-takeover".utf8).write(to: url, options: .atomic)
    }

    private nonisolated static func deleteMarkerLocked() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
