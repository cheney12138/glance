import AppKit

/// MRU 证据(ADR-0003):前台 App 激活序列。窗口级严格时序不做。
/// 排序语义:见过的按激活序;没见过的**首次露面时登记到队尾**(2026-10-14 病例修复 ✓):
/// 原来按"原输入序"接尾部 —— 而输入是 `Array(byPID.keys)` = 字典序 ✗,
/// 环里窗一开一关哈希布局就变 ⇒ 没被激活过的 App 位置跟着字典序乱跳 ✗✗
/// (用户实报「app 从左到右按最近使用倒序,有时候位置乱跳」✓)
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
        let known = order.filter { pids.contains($0) }
        let fresh = pids.filter { !order.contains($0) }
        // ★ 首次露面即登记 ✓:此后位置固定,不再依赖字典序 ✗
        //   (登记到队尾 = "最不近用"那头 ✓,与激活时前插的 MRU 语义对齐 ✓)
        if !fresh.isEmpty {
            order.append(contentsOf: fresh)
            if order.count > 120 { order.removeFirst(order.count - 120) }   // 小账本,够用 ✓
        }
        return known + fresh
    }
}
