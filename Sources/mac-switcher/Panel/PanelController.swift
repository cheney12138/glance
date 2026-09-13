import AppKit
import SwiftUI

/// 面板控制器:导航态状态机的唯一权威。
/// 出现(begin)→ 选中移动(next/prev/windowLeft/windowRight/hover)→ 确认(confirm)/放弃(cancel),
/// 四状态无旁路。确认的真实聚焦在 T7 接 WindowFocuser,现在只打日志。
@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var groups: [AppGroup] = []
    @Published var appIndex = 0
    @Published var winIndex = 0
    @Published private(set) var isVisible = false

    private var panel: NSPanel?
    private var hostingController: NSHostingController<PanelView>?
    private var contextScreen: NSScreen?
    private var outsideClickMonitor: Any?

    /// dismiss 时通知触发层收尸(见 HotkeyTapCenter.endSession)。App 装配时接线
    var onSessionEnd: (() -> Void)?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var currentGroup: AppGroup? { groups.indices.contains(appIndex) ? groups[appIndex] : nil }
    var expandedCount: Int { currentGroup?.windows.count ?? 0 }

    // MARK: - 触发层入口

    func handle(_ action: HotkeyTapCenter.Action) {
        switch action {
        case .begin: begin()
        case .next: moveApp(1)
        case .prev: moveApp(-1)
        case .windowLeft: moveWindow(-1)
        case .windowRight: moveWindow(1)
        case .confirm: confirmSelection()
        case .cancel: dismiss(reason: "放弃")
        }
    }

    // MARK: - 生命周期

    private func begin() {
        // ADR-0001:触发即定场。语境屏快照只活在本轮导航态里
        let beganAt = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
            print(String(format: "[T8] 按键→枚举就位 %.0fms", ms))
        }
        let screen = CursorScreenAnchor.cursorScreen
        contextScreen = screen
        groups = WindowEnumerator.enumerate(owning: screen)
        appIndex = 0
        winIndex = 0
        Snapshotter.shared.clear()
        let targets = groups.flatMap { $0.windows }
        Task { [targets] in await Snapshotter.shared.precapture(targets) }
        guard !groups.isEmpty else {
            print("[T6] 本屏无窗,面板不出现(语境屏 = \(screen?.localizedName ?? "?"))")
            return
        }
        print("[T6] 面板出现:语境屏 = \(screen?.localizedName ?? "?"),\(groups.count) 个 App")
        showPanel()
    }

    private func showPanel() {
        buildPanelIfNeeded()
        relayout(animated: false)
        guard let panel, let target = centerFrame(for: paddedSize()) else { return }
        isVisible = true

        // 弹出:120ms,scale .96→1 + 渐入(brand-spec;reduced-motion 归零)
        let start = NSRect(
            x: target.midX - target.width * 0.48,
            y: target.midY - target.height * 0.48,
            width: target.width * 0.96,
            height: target.height * 0.96
        )
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        installOutsideClickMonitor()
    }

    private func relayout(animated: Bool) {
        guard let panel, let target = centerFrame(for: paddedSize()) else { return }
        // hover 高频路径:在 SwiftUI 布局 pass 内直接 setFrame 会撞
        // _NSDetectedLayoutRecursion 警告(实机现形),推到下一圈 runloop 再动窗框
        if animated && !reduceMotion {
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    panel.animator().setFrame(target, display: true)
                }
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func dismiss(reason: String) {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        isVisible = false
        print("[T6] \(reason):面板关闭")
        groups = []
        onSessionEnd?()
    }

    /// contextScreen 可视区正中出现(自家窗口的锚定纪律与引导窗一致)
    private func centerFrame(for size: NSSize) -> NSRect? {
        guard let area = contextScreen?.visibleFrame ?? contextScreen?.frame ?? NSScreen.main?.visibleFrame else { return nil }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// brand-spec 的度量:strip 80/格+6 间距;预览卡 320/张+12 间距;顶 18 名 16 距 14 底 22
    func contentSize() -> NSSize {
        let nApps = CGFloat(groups.count)
        let nCards = CGFloat(expandedCount)
        let stripW = nApps * 80 + max(nApps - 1, 0) * 6
        let rowW = nCards * 320 + max(nCards - 1, 0) * 12
        let w = max(stripW, rowW, 280) + 48
        var h: CGFloat = 18 + 16 + 14 + 80 + 22
        if expandedCount > 0 { h += 16 + (22 + 200) }
        return NSSize(width: w, height: h)
    }

    /// 窗口尺寸 = 内容 + 阴影呼吸区(四周 28pt)。
    /// 必须与 PanelView 的 .padding(28) 严格一致——两套尺寸账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    private func paddedSize() -> NSSize {
        let c = contentSize()
        return NSSize(width: c.width + 56, height: c.height + 56)
    }

    // MARK: - 面板本体

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // 阴影由 SwiftUI 层绘制(brand-spec 阴影值)
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true // hover 即选中依赖它
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        let hosting = NSHostingController(rootView: PanelView(controller: self, snapshotter: Snapshotter.shared))
        panel.contentViewController = hosting
        self.panel = panel
        self.hostingController = hosting
    }

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        appIndex = (appIndex + delta + groups.count) % groups.count
        winIndex = 0
        relayout(animated: true)
        print("[T6] 选中: [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
        refreshSnapshotForSelection()
    }

    private func moveWindow(_ delta: Int) {
        // 权责冻结(用户拍板):App 移动归 Tab 与指针,←→ 只管展开层的窗;
        // 组内 ≤1 窗时 ←→ 无语义,静默吞掉
        let n = expandedCount
        guard n > 1 else { return }
        winIndex = (winIndex + delta + n) % n
        print("[T6] 窗口选中: \(groups[appIndex].windows[winIndex].title)")
    }

    /// T11 选中项现拍:选中移到哪个组,就把那组窗重截一遍——触发瞬间的截图在
    /// 钉住浏览几秒后已是旧图。异步不阻塞导航;同 wid 后到覆盖先到,天然取新。
    private func refreshSnapshotForSelection() {
        guard let g = currentGroup else { return }
        let targets = g.windows
        let name = g.appName
        Task {
            await Snapshotter.shared.precapture(targets)
            print("[T11] 现拍: \(name) \(targets.count) 窗")
        }
    }

    /// hover 从 SwiftUI 直接进来;与键盘共写 appIndex/winIndex,天然"谁后动听谁的"
    func hoverApp(_ i: Int) {
        guard groups.indices.contains(i) else { return }
        appIndex = i
        winIndex = 0
        relayout(animated: true)
        refreshSnapshotForSelection()
    }

    func hoverWindow(_ i: Int) { winIndex = i }

    // MARK: - 确认与放弃

    /// 松手不合面板(T10 毕业为设置面板正式项,UserDefaults key 不变):松手语义在
    /// 触发层处理(那边保持导航态、不发确认),这里只剩一件事——面板外点击是否免死
    private var pinPanelDebug: Bool { UserDefaults.standard.bool(forKey: "debug.pinPanelOnRelease") }

    /// 确认 = 唯一的"生效"动作:聚焦选中的那一扇窗(CONTEXT.md「确认」)。
    /// 到达路径:未钉住时松 ⌥;钉住时 Enter。
    func confirmSelection() {
        guard groups.indices.contains(appIndex), groups[appIndex].windows.indices.contains(winIndex) else {
            dismiss(reason: "确认(空列表)")
            return
        }
        let g = groups[appIndex]
        let w = g.windows[winIndex]
        WindowFocuser.focus(window: w)
        dismiss(reason: "确认")
    }

    /// 面板外点击 = 放弃(CONTEXT.md)。钉住模式下不装——要的就是能切出去截图
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        if pinPanelDebug { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss(reason: "面板外点击,放弃")
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }
}
