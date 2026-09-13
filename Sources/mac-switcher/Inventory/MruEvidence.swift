import AppKit

/// MRU 证据(ADR-0003):前台 App 激活序列。窗口级严格时序不做。
/// 排序语义:见过的按激活序;没见过的(本次会话从未切到过的 App)按原序接尾部。
@MainActor
final class MruEvidence {
    static let shared = MruEvidence()
    private init() {}

    private(set) var order: [pid_t] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if let front = NSWorkspace.shared.frontmostApplication {
            bump(front.processIdentifier)
        }
        // 每启动一个 App / 每次前台切换都算一次证据
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in MruEvidence.shared.bump(app.processIdentifier) }
            }
        }
    }

    private func bump(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    func ordered(pids: [pid_t]) -> [pid_t] {
        order.filter { pids.contains($0) } + pids.filter { !order.contains($0) }
    }
}
