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
    private var previewPanel: NSPanel?
    private var previewHosting: NSHostingController<PreviewPanelView>?
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
        case .quitApp: destructive(.quit)
        case .closeWindow: destructive(.close)
        case .minimizeWindow: destructive(.minimize)
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
        panelOpenPoint = NSEvent.mouseLocation
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
        updatePreview(animated: false)
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
        previewPanel?.orderOut(nil)
        isVisible = false
        print("[T6] \(reason):面板关闭")
        groups = []
        panelOpenPoint = nil
        onSessionEnd?()
    }

    /// contextScreen 可视区正中出现(自家窗口的锚定纪律与引导窗一致)
    private func centerFrame(for size: NSSize) -> NSRect? {
        guard let area = contextScreen?.visibleFrame ?? contextScreen?.frame ?? NSScreen.main?.visibleFrame else { return nil }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// brand-spec v0.2 度量(主面板只装长条):格 84 / 距 20 / 顶 22 名 18 距 20 底 26。
    /// 预览框不再计入住——它是独立浮窗(分容器构型,见 updatePreview)
    func contentSize() -> NSSize {
        let nApps = CGFloat(max(groups.count, 1))
        let w = max(nApps * 84 + max(nApps - 1, 0) * 20 + 60, 280)
        return NSSize(width: w, height: 22 + 18 + 20 + 84 + 26)
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
        panel = makeChromePanel()
        let hosting = NSHostingController(rootView: PanelView(controller: self))
        panel!.contentViewController = hosting
        self.hostingController = hosting
    }

    private func makeChromePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // 阴影由 SwiftUI 层绘制
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.acceptsMouseMovedEvents = true // hover 即选中依赖它
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        return p
    }

    // MARK: - 预览浮窗(分容器构型:与主面板同皮不同窗,中心正对选中 App 头顶)

    private func buildPreviewPanelIfNeeded() {
        guard previewPanel == nil else { return }
        previewPanel = makeChromePanel()
        let hosting = NSHostingController(rootView: PreviewPanelView(controller: self, snapshotter: Snapshotter.shared))
        previewPanel!.contentViewController = hosting
        previewHosting = hosting
    }

    /// 预览框内容尺寸 = 卡片区 + 四周 28 阴影呼吸区(与 PreviewPanelView .padding 口径一致)
    private func previewSize() -> NSSize {
        let n = CGFloat(expandedCount)
        guard n > 0 else { return .zero }
        return NSSize(
            width: n * 320 + max(n - 1, 0) * 16 + 24 + 56,
            height: 200 + 24 + 56
        )
    }

    /// 选中图标的屏幕坐标 X:内容起点 = 28(阴影区) + 30(h padding);格步进 = 84 + 20
    private func iconCenterXInScreen(_ i: Int) -> CGFloat? {
        guard let panel else { return nil }
        return panel.frame.minX + 28 + 30 + CGFloat(i) * 104 + 42
    }

    /// 预览框正中 = 选中 App 头顶;超界时收进语境屏可视区(内 12)
    private func previewFrame() -> NSRect? {
        guard expandedCount > 0, let panel, let area = contextScreen?.visibleFrame else { return nil }
        let size = previewSize()
        let cx = iconCenterXInScreen(appIndex) ?? panel.frame.midX
        let x = min(max(cx - size.width / 2, area.minX + 12), area.maxX - size.width - 12)
        let y = panel.frame.maxY + 12
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updatePreview(animated: Bool) {
        guard let frame = previewFrame() else {
            previewPanel?.orderOut(nil)
            return
        }
        buildPreviewPanelIfNeeded()
        guard let previewPanel else { return }
        if !previewPanel.isVisible {
            previewPanel.alphaValue = 0
            previewPanel.setFrame(frame, display: false)
            previewPanel.orderFrontRegardless()
        }
        if animated && !reduceMotion {
            // SwiftUI 布局递归前科:动画帧推下一圈 runloop
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.1
                    previewPanel.animator().setFrame(frame, display: true)
                    previewPanel.animator().alphaValue = 1
                }
            }
        } else {
            previewPanel.setFrame(frame, display: true)
            previewPanel.alphaValue = 1
        }
    }

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        appIndex = (appIndex + delta + groups.count) % groups.count
        winIndex = 0
        relayout(animated: true)
        print("[T6] 选中: [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
        refreshSnapshotForSelection()
        updatePreview(animated: true)
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
    /// 防抖:同一组 0.5s 内不重复拍(横扫面板时边缘组会被扫过多次)
    private var lastRefreshAt: [pid_t: CFAbsoluteTime] = [:]

    private func refreshSnapshotForSelection() {
        guard let g = currentGroup else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastRefreshAt[g.pid], now - last < 0.5 { return }
        lastRefreshAt[g.pid] = now
        let targets = g.windows
        let name = g.appName
        Task {
            await Snapshotter.shared.precapture(targets)
            print("[T11] 现拍: \(name) \(targets.count) 窗")
        }
    }

    /// 面板出现那一刻的指针位。"谁后动听谁的"的仲裁缺陷修复:
    /// 指针杵着不动 ≠ 指针动过——面板在指针底下撑开/展开层重排帧时,
    /// SwiftUI 会把静止悬停当成 hover 事件,把键盘刚移走的选中拽回来(实机现形:
    /// 面板开在指针下方时 ⌘Tab 移不动)。gate:指针自面板出现起没挪过窝,hover 一律不算数
    private var panelOpenPoint: CGPoint?

    private func pointerHasSpoken() -> Bool {
        guard let p = panelOpenPoint else { return true }
        let m = NSEvent.mouseLocation
        return abs(m.x - p.x) > 1 || abs(m.y - p.y) > 1
    }

    /// hover 从 SwiftUI 直接进来;与键盘共写 appIndex/winIndex,天然"谁后动听谁的"
    func hoverApp(_ i: Int) {
        // 选中没变 = 同块地砖上挪指针,免工——onHover 每像素都发声,不设闸就是现拍风暴
        // (实机现形:日志被系统 QUARANTINED 截流)
        guard pointerHasSpoken(), groups.indices.contains(i), i != appIndex else { return }
        appIndex = i
        winIndex = 0
        relayout(animated: true)
        refreshSnapshotForSelection()
        updatePreview(animated: true)
    }

    func hoverWindow(_ i: Int) {
        guard pointerHasSpoken(), i != winIndex else { return }
        winIndex = i
    }

    // MARK: - 确认与放弃

    /// 松手不合面板(T10 毕业为设置面板正式项,UserDefaults key 不变):松手语义在
    /// 触发层处理(那边保持导航态、不发确认),这里只剩一件事——面板外点击是否免死
    private var pinPanelDebug: Bool { UserDefaults.standard.bool(forKey: "debug.pinPanelOnRelease") }

    // MARK: - T12 破坏性键盘操作(CONTEXT.md「破坏性键盘操作」:有键无钮)

    private enum DestructiveOp { case quit, close, minimize }

    private func destructive(_ op: DestructiveOp) {
        guard groups.indices.contains(appIndex) else { return }
        let g = groups[appIndex]
        switch op {
        case .quit:
            print("[T12] 退出应用: \(g.appName)")
            WindowFocuser.quitApp(pid: g.pid)
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 最小化: \(g.appName) — \(w.title)")
            WindowFocuser.minimize(window: w)
        }
        // 停一拍让窗口真的死掉/收走,再守着语境屏原地重枚举(CONTEXT.md:破坏性操作后原地重枚举)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reEnumerate()
        }
    }

    private func reEnumerate() {
        guard isVisible else { return }
        groups = WindowEnumerator.enumerate(owning: contextScreen)
        guard !groups.isEmpty else {
            dismiss(reason: "窗口都关完了")
            return
        }
        appIndex = min(appIndex, groups.count - 1)
        winIndex = min(winIndex, max(groups[appIndex].windows.count - 1, 0))
        Snapshotter.shared.clear()
        let targets = groups.flatMap { $0.windows }
        Task { [targets] in await Snapshotter.shared.precapture(targets) }
        relayout(animated: false)
        updatePreview(animated: false)
        print("[T12] 重枚举: \(groups.count) 个 App 在列")
    }

    /// 确认 = 唯一的"生效"动作:聚焦选中的那一扇窗(CONTEXT.md「确认」)。
    /// 到达路径:未钉住时松 ⌥;钉住时 Enter。
    func confirmSelection() {
        guard groups.indices.contains(appIndex) else {
            dismiss(reason: "确认(空列表)")
            return
        }
        let g = groups[appIndex]
        // 无窗应用(T15)不是"空列表"——确认 = 激活(App 自己处理开窗与还原)
        if !g.windows.indices.contains(winIndex) {
            WindowFocuser.focusWindowlessApp(pid: g.pid)
            dismiss(reason: "确认(无窗应用)")
            return
        }
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
