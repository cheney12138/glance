import AppKit
import Foundation

/// **0 窗僵尸查看器自动退出器**：
/// 针对 `预览（Preview）` / `QuickTime Player` / `文本编辑（TextEdit）` 这类文档查看型 App ——
/// 关光全部文档后进程仍常驻在切换器与 Dock 里，选中激活也唤不出窗口。
/// 仅当目标 App 已退出前台、且跨 Space / 全屏 / AX 均确认没有任何实窗与弹窗后，
/// 经短暂二次复查才安静发送 `terminate()`（有未保存文稿时窗口仍在 AX 清单里，绝不触发误关闭）。
@MainActor
final class ZombieAppReaper {
    static let shared = ZombieAppReaper()

    private static let launchGraceSeconds: TimeInterval = 3.0
    private static let zeroWindowConfirmDelay: TimeInterval = 0.5
    private static let periodicSweepInterval: TimeInterval = 3.0

    private var started = false
    private var firstZeroSeenAt: [pid_t: CFAbsoluteTime] = [:]
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]
    private var inFlightChecks: Set<pid_t> = []
    private var sweepTimer: Timer?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, Keys.autoQuitZombies,
                      let bid, Keys.zombieViewerBundleIDs.contains(bid) else { return }
                // 切走后 0.1s 做首次采集、+0.5s 复查，总计 ~0.6s 内干净收尾（不再拖 5–10 秒）✓
                self.scheduleCheck(for: pid, delay: 0.1)
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.resetTracking(for: pid) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.resetTracking(for: pid) }
        }

        sweepTimer = Timer.scheduledTimer(withTimeInterval: Self.periodicSweepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepBackgroundZombies() }
        }
        sweepTimer?.tolerance = 0.5
    }

    /// 面板收场或切焦后顺带快扫一次，缩短跨 App 关窗后的停留窗口。
    func sweepSoon(delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sweepBackgroundZombies()
        }
    }

    private func resetTracking(for pid: pid_t) {
        pendingChecks[pid]?.cancel()
        pendingChecks.removeValue(forKey: pid)
        firstZeroSeenAt.removeValue(forKey: pid)
    }

    private func scheduleCheck(for pid: pid_t, delay: TimeInterval) {
        pendingChecks[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChecks.removeValue(forKey: pid)
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                self.firstZeroSeenAt.removeValue(forKey: pid)
                return
            }
            self.evaluate(app)
        }
        pendingChecks[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sweepBackgroundZombies() {
        guard Keys.autoQuitZombies else {
            firstZeroSeenAt.removeAll()
            return
        }
        let targets = Keys.zombieViewerBundleIDs
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.isFinishedLaunching,
                  !app.isTerminated,
                  !app.isActive,
                  let bid = app.bundleIdentifier,
                  targets.contains(bid) else { continue }
            evaluate(app)
        }
    }

    private func evaluate(_ app: NSRunningApplication) {
        guard Keys.autoQuitZombies,
              app.activationPolicy == .regular,
              app.isFinishedLaunching,
              !app.isTerminated,
              !app.isActive,
              let bid = app.bundleIdentifier,
              Keys.zombieViewerBundleIDs.contains(bid) else { return }

        if let launchDate = app.launchDate, Date().timeIntervalSince(launchDate) < Self.launchGraceSeconds {
            return
        }
        let pid = app.processIdentifier
        guard !inFlightChecks.contains(pid) else { return }
        inFlightChecks.insert(pid)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let zero = AXWindowList.hasZeroRealWindows(ofPID: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightChecks.remove(pid)
                guard Keys.autoQuitZombies,
                      let current = NSRunningApplication(processIdentifier: pid),
                      !current.isTerminated,
                      current.isFinishedLaunching,
                      !current.isActive,
                      let curBid = current.bundleIdentifier,
                      Keys.zombieViewerBundleIDs.contains(curBid) else {
                    self.resetTracking(for: pid)
                    return
                }
                guard zero else {
                    self.firstZeroSeenAt.removeValue(forKey: pid)
                    return
                }
                let now = CFAbsoluteTimeGetCurrent()
                if let firstSeen = self.firstZeroSeenAt[pid] {
                    if now - firstSeen >= Self.zeroWindowConfirmDelay - 0.1 {
                        self.resetTracking(for: pid)
                        let terminated = current.terminate()
                        glog("[僵尸清理] 自动退出 0 窗应用: \(current.localizedName ?? "?")[\(curBid)] -> \(terminated ? "已安静退出" : "未能退出")")
                    }
                } else {
                    self.firstZeroSeenAt[pid] = now
                    self.scheduleCheck(for: pid, delay: Self.zeroWindowConfirmDelay)
                }
            }
        }
    }
}
