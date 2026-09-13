import AppKit

/// T4–T5 临时胶水:T6 起由 PanelController 正式接管 onAction,本类退役。
/// 职责:ADR-0001 语境锁定(快照仅存活在导航态内)+ 库存日志 + 迷你选中模型。
@MainActor
final class DebugSessionLogger {
    private var groups: [AppGroup] = []
    private var appIndex = 0
    private var winIndex = 0

    func handle(_ action: HotkeyTapCenter.Action) {
        switch action {
        case .begin:
            begin()
        case .next: moveApp(1)
        case .prev: moveApp(-1)
        case .windowLeft: moveWindow(-1)
        case .windowRight: moveWindow(1)
        case .confirm: confirm()
        case .cancel:
            print("[T4] 放弃:面板关闭,不动任何窗口")
            reset()
        }
    }

    private func begin() {
        // 触发即定场,活着期间世界不变(ADR-0001):语境快照只活在这次导航态里
        let screen = CursorScreenAnchor.cursorScreen
        groups = WindowEnumerator.enumerate(owning: screen)
        appIndex = 0
        winIndex = 0
        print("[T4] 语境屏 = \(screen?.localizedName ?? "?")(锁定)")
        guard !groups.isEmpty else { print("[T4] 本屏无窗"); return }
        let totalWindows = groups.reduce(0) { $0 + $1.windows.count }
        let snapshotTargets = groups.flatMap { $0.windows }
        Snapshotter.shared.clear()
        Task { [snapshotTargets] in
            await Snapshotter.shared.precapture(snapshotTargets)
            print("[T5] 预截完成: \(Snapshotter.shared.cache.count)/\(snapshotTargets.count),样张目录 → \(Snapshotter.shared.dumpDir.path)")
        }
        print("[T4] 本屏窗 \(totalWindows) 扇,\(groups.count) 个 App:")
        for (i, g) in groups.enumerated() {
            print("  \(i + 1). \(g.appName) (\(g.windows.count) 窗)\(i == 0 ? " ← 初始选中" : "")")
            for w in g.windows { print("     - \(w.title)") }
        }
    }

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        appIndex = (appIndex + delta + groups.count) % groups.count
        winIndex = 0
        let g = groups[appIndex]
        print("[T4] 选中: [\(appIndex + 1)/\(groups.count)] \(g.appName)(共 \(g.windows.count) 窗)")
    }

    private func moveWindow(_ delta: Int) {
        guard !groups.isEmpty else { return }
        let n = groups[appIndex].windows.count
        guard n > 0 else { return }
        winIndex = (winIndex + delta + n) % n
        print("[T4] 窗口选中: \(groups[appIndex].windows[winIndex].title)")
    }

    private func confirm() {
        guard !groups.isEmpty else { reset(); return }
        let g = groups[appIndex]
        let w = g.windows[winIndex]
        print("[T4] 确认将聚焦(T7): \(g.appName) — \(w.title)")
        reset()
    }

    private func reset() {
        groups = []
        appIndex = 0
        winIndex = 0
    }
}
