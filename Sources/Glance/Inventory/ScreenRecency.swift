import AppKit

/// **按屏记录"最近用过的 App"**(2026-09-22 用户实报后加)。
///
/// 病例(用户原话):「我在内建屏操作完之后, 回来外接屏直接选中默认选中 Chrome 了,
/// 但我外接屏本来就停留在 Chrome 的。应该是 Chrome 的上一个 —— ghostty」。
/// 真因:面板里的 App 集合是**按屏**的(ADR-0008 ✓),但**排序用的是全局 MRU** ✗
/// ⇒ 一旦在另一块屏上用过别的 App,这块屏的"上一个 App"就变了 ✗(用户看到落点跳到了错误的人身上)。
///
/// 口径:每块屏各记一本"最近用过的 pid(新→旧)" ✓。
/// 观测点用 `didActivateApplicationNotification`(系统**只报 App、不报屏** ✗)⇒
/// 归属屏取"那一刻该 App 最前一扇窗所在的那块屏" ✓ ——
/// 与切换用的归属判定**同一套规则**(`ownsByContextScreen` ✓,绝不自造第二套 ✓)。
final class ScreenRecency {
    static let shared = ScreenRecency()
    private init() {}

    private let lock = NSLock()
    /// 屏名(localizedName)→ pid(新 → 旧)
    private var byScreen: [String: [pid_t]] = [:]
    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.note(pid: app.processIdentifier)
        }
    }

    /// 该 pid 在某块屏上的名次(0 = 最近用过 ✓;没记录过 = nil ⇒ 调用方回落到全局 MRU ✓)
    func rank(of pid: pid_t, on screen: NSScreen) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let list = byScreen[screen.localizedName], let i = list.firstIndex(of: pid) else { return nil }
        return i
    }

    /// 前台 App 变了 ⇒ 记一笔(屏由"它最前一扇窗在哪"决定 ✓)
    private func note(pid: pid_t) {
        guard let screen = screenOwningFrontWindow(ofPID: pid) else { return }
        lock.lock()
        var list = byScreen[screen.localizedName] ?? []
        list.removeAll { $0 == pid }
        list.insert(pid, at: 0)
        if list.count > 40 { list.removeLast(list.count - 40) }   // 一本小账,够用就行 ✓
        byScreen[screen.localizedName] = list
        lock.unlock()
    }

    /// 该 App **最前一扇普通窗**归哪块屏 —— 与 `WindowEnumerator.ownsByContextScreen` 同一套规则 ✓
    private func screenOwningFrontWindow(ofPID pid: pid_t) -> NSScreen? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
        var bounds: CGRect?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
                  wd > 60, h > 60 else { continue }
            bounds = CGRect(x: x, y: y, width: wd, height: h)
            break                       // 列表是前→后 ⇒ 第一个命中的就是它的最前一扇 ✓
        }
        guard let bounds else { return nil }
        return NSScreen.screens.first { WindowEnumerator.ownsByContextScreen(bounds, contextScreen: $0) }
    }
}
