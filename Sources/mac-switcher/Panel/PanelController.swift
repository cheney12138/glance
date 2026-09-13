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
    /// 确认涟漪的令牌(demo .ripple):每次确认 +1,`PanelView` 靠它的变化重挂涟漪视图重播一遍
    @Published private(set) var confirmPulse = 0

    private var panel: NSPanel?
    private var hostingView: ClickThroughHostingView<PanelView>?
    private var previewPanel: NSPanel?
    private var previewHostingView: ClickThroughHostingView<PreviewPanelView>?
    private var contextScreen: NSScreen?
    private var outsideClickMonitor: Any?
    /// 退场演出期间的窗口拆迁单(见 `dismiss`):淡出/涟漪播完才 orderOut,
    /// 新一轮 `begin` 会把它撤掉
    private var teardown: DispatchWorkItem?
    /// 导航期间的 App Nap 豁免票:菜单栏型 App 在"用户没在动它"时会被系统降优先级,
    /// 表现就是动画掉帧、动效发涩。一局切换器只活几百毫秒,全程按住不放,代价可忽略
    private var activityToken: NSObjectProtocol?

    /// dismiss 时通知触发层收尸(见 HotkeyTapCenter.endSession)。App 装配时接线
    var onSessionEnd: (() -> Void)?

    private var reduceMotion: Bool { MotionPolicy.reduced }

    /// 指针在「面板内容坐标」(PanelView 里那个 ZStack 的坐标系,原点左上、y 向下)里的位置。
    ///
    /// 光晕每帧问一次这里 —— **不走鼠标事件**:面板是 nonactivating,永不成 key,
    /// AppKit 的 mouseMoved 只投给 key 窗口,监听/追踪区都收不到(上一版光晕从来没亮过就是这原因)。
    /// `NSEvent.mouseLocation` 是全局读数,与 key、与有没有事件都无关。
    /// 返回 nil = 指针不在面板上(或面板正在退场)
    func pointerInContent() -> CGPoint? {
        guard let panel, isVisible, !panel.ignoresMouseEvents else { return nil }
        let size = contentSize()
        guard size.width > 0, size.height > 0 else { return nil }
        // 窗口坐标 y 向上;内容区在窗口里还要扣掉四周的阴影呼吸区
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let p = CGPoint(
            x: local.x - PanelMetrics.shadowPadStrip,
            y: panel.frame.height - local.y - PanelMetrics.shadowPadStrip
        )
        guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return nil }
        return p
    }

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
        // 动效在不在线,一眼可见(系统"减弱动态效果"会把弹簧静默压成淡入淡出)
        print("[T6] 动效:\(MotionPolicy.describe)")
        showPanel()
    }

    private func showPanel() {
        buildPanelIfNeeded()
        // 上一轮的退场演出还没拆完就又开一局:先把拆迁单撤了,否则它会把新面板一起 orderOut
        teardown?.cancel()
        teardown = nil
        panelOpenPoint = NSEvent.mouseLocation
        guard let panel, let target = centerFrame(for: paddedSize()) else { return }
        isVisible = true
        // 退场演出期间关掉的事件耳,开新局要还回来
        panel.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        beginActivity()

        // 入场动效在 SwiftUI 层(demo .switcher-wrap 的 scale .90→1 + 渐入),窗口只负责就位
        panel.alphaValue = 1
        setFrameIfNeeded(panel, target)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
        updatePreview()
    }

    /// 动窗框的唯一入口:**帧没变就不动**。
    /// 旧病:hover 每挪一格都 `setFrame` 一次(哪怕目标帧跟当前一模一样),在 SwiftUI 动画
    /// 途中强插一轮窗口布局 —— 横扫面板一顿一顿的,一半的账在这。
    /// 顺带说明:面板尺寸只由 App 数量决定,选中移动从来不改尺寸,所以选中路径根本不该碰窗框。
    private func setFrameIfNeeded(_ panel: NSPanel, _ frame: NSRect?) {
        guard let frame, !panel.frame.nearlyEquals(frame) else { return }
        panel.setFrame(frame, display: true)
    }

    /// 收场:先让两块玻璃按 demo 的曲线淡出,窗口拆迁排在演出之后。
    /// 旧行为 `dismiss` 当场 `orderOut` —— 面板"啪"地消失,demo 的退场与确认涟漪被整段砍掉。
    /// `flourish` = 带涟漪的确认退场,多留一会儿给白光炸完。
    private func dismiss(reason: String, flourish: Bool = false) {
        removeOutsideClickMonitor()
        isVisible = false
        // 演出期间别再吃 hover / 点击(外面那圈透明呼吸区也在放事件)
        panel?.ignoresMouseEvents = true
        previewPanel?.ignoresMouseEvents = true
        print("[T6] \(reason):面板关闭")

        // 拆迁不能早于淡出:早了就是"半透明啪一下没了"。降级动效模式没有涟漪,淡出也短,跟着缩
        let hold: Double = reduceMotion ? 0.22 : (flourish ? PanelMetrics.tFlourish : PanelMetrics.tFade)
        teardown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.teardownPanel() }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    private func beginActivity() {
        endActivity()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Glance 导航态:动效与画面优先级拉满,不许 App Nap 抽帧"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    /// 真正的拆窗:orderOut + 清场。与 `dismiss` 分开,是为了让退场动画有地方播
    private func teardownPanel() {
        endActivity()
        panel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        panel?.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        groups = []
        panelOpenPoint = nil
        teardown = nil
        onSessionEnd?()
    }

    /// contextScreen 可视区正中出现(自家窗口的锚定纪律与引导窗一致)
    private func centerFrame(for size: NSSize) -> NSRect? {
        guard let area = contextScreen?.visibleFrame ?? contextScreen?.frame ?? NSScreen.main?.visibleFrame else { return nil }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 长条内容尺寸 = 图标 78 × n + 间距 6 + 左右缘 26;高 = 上下缘 22 + 图标 78
    /// 预览托盘不计入住——它是独立浮窗,中心正对选中 App 头顶
    func contentSize() -> NSSize {
        let nApps = CGFloat(max(groups.count, 1))
        let w = max(
            nApps * PanelMetrics.icon + max(nApps - 1, 0) * PanelMetrics.iconGap + PanelMetrics.rowPadX * 2,
            PanelMetrics.minStripWidth
        )
        return NSSize(width: w, height: PanelMetrics.rowPadY * 2 + PanelMetrics.icon)
    }

    /// 窗口尺寸 = 内容 + 阴影呼吸区(四周 shadowPadStrip)。
    /// 必须与 PanelView 的 .padding(shadowPadStrip) 严格一致——两套尺寸账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    private func paddedSize() -> NSSize {
        let c = contentSize()
        let pad = PanelMetrics.shadowPadStrip * 2
        return NSSize(width: c.width + pad, height: c.height + pad)
    }

    // MARK: - 面板本体

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        panel = makeChromePanel()
        let hosting = ClickThroughHostingView(rootView: PanelView(controller: self))
        hosting.pad = PanelMetrics.shadowPadStrip // 透明呼吸区不吃点击
        hosting.autoresizingMask = [.width, .height]
        panel!.contentView = hosting
        self.hostingView = hosting
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
        // 托盘低一层:它向下的阴影尾会伸进长条的呼吸区,demo 里长条(后一个兄弟)盖住托盘阴影,
        // 托盘在上就会把那层灰纱糊到长条玻璃顶上——"黑影"换个地方复活
        previewPanel!.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        let hosting = ClickThroughHostingView(rootView: PreviewPanelView(controller: self, snapshotter: Snapshotter.shared))
        hosting.pad = PanelMetrics.shadowPadPop
        hosting.autoresizingMask = [.width, .height]
        previewPanel!.contentView = hosting
        previewHostingView = hosting
    }

    /// 托盘内容尺寸 = 题头行 + 一排 128 缩略图 + 内边(16/18/14)。
    /// 与 PreviewPanelView 的 .frame(previewContentSize) 同源
    func previewContentSize() -> NSSize {
        guard let g = currentGroup, !g.windows.isEmpty else { return .zero }
        let n = CGFloat(g.windows.count)
        let cardsW = n * PanelMetrics.thumbW + max(n - 1, 0) * PanelMetrics.thumbGap
        return NSSize(
            width: cardsW + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop + PanelMetrics.captionH + PanelMetrics.trayGap
                + PanelMetrics.thumbH + PanelMetrics.trayPadBottom
        )
    }

    private func previewSize() -> NSSize {
        let c = previewContentSize()
        let pad = PanelMetrics.shadowPadPop * 2
        return NSSize(width: c.width + pad, height: c.height + pad)
    }

    /// 托盘正中 = 长条正中(demo 的 .switcher-wrap 是 column 居中,托盘不跟图标滑移);
    /// 超界时收进语境屏可视区(内 12);视觉缝 = seam
    private func previewFrame() -> NSRect? {
        guard expandedCount > 0, let panel, let area = contextScreen?.visibleFrame else { return nil }
        let size = previewSize()
        let x = min(max(panel.frame.midX - size.width / 2, area.minX + 12), area.maxX - size.width - 12)
        // 缝是两块**玻璃**之间的空当,不是两个窗框之间:缝 = padPop + padStrip - 帧距,
        // 反解出帧距 = padPop + padStrip - seam(两窗在各自的透明呼吸区里大幅重叠,靠点击穿透互不相扰)
        let frameGap = PanelMetrics.shadowPadPop + PanelMetrics.shadowPadStrip - PanelMetrics.seam
        let y = panel.frame.maxY - frameGap
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updatePreview() {
        guard let frame = previewFrame() else {
            previewPanel?.orderOut(nil)
            return
        }
        buildPreviewPanelIfNeeded()
        guard let previewPanel else { return }
        // 换组只换内容,窗不滑(demo 行为);入场由 SwiftUI 播放。
        // 帧一样就不 setFrame:hover 每格都来一次,白白发一轮窗口布局
        previewPanel.alphaValue = 1
        setFrameIfNeeded(previewPanel, frame)
        if !previewPanel.isVisible { previewPanel.orderFrontRegardless() }
    }

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        appIndex = (appIndex + delta + groups.count) % groups.count
        winIndex = 0
        // 不动窗框:面板尺寸只跟 App 数量有关,选中移动不改尺寸(旧病见 setFrameIfNeeded)
        print("[T6] 选中: [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
        refreshSnapshotForSelection()
        updatePreview()
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
        refreshSnapshotForSelection()
        updatePreview()
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

    private enum DestructiveOp { case quit, close, minimize, zoom }

    /// 红绿灯按钮入口(T14):wid 反查组内位置后,走破坏性操作同一闸
    func closeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .close) }
    func minimizeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .minimize) }
    func zoomWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .zoom) }

    private func trafficOp(_ wid: CGWindowID, _ op: DestructiveOp) {
        for (ai, g) in groups.enumerated() {
            guard let wi = g.windows.firstIndex(where: { $0.wid == wid }) else { continue }
            appIndex = ai
            winIndex = wi
            destructive(op)
            return
        }
    }

    private func destructive(_ op: DestructiveOp) {
        guard groups.indices.contains(appIndex) else { return }
        let g = groups[appIndex]
        switch op {
        case .quit:
            print("[T12] 退出应用: \(g.appName)")
            WindowFocuser.quitApp(pid: g.pid)
            dismiss(reason: "退出应用,收工")
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
            dismiss(reason: "关闭窗口,收工")
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 最小化: \(g.appName) — \(w.title)")
            WindowFocuser.minimize(window: w)
            dismiss(reason: "最小化,收工")
        case .zoom:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 缩放(Z): \(g.appName) — \(w.title)")
            WindowFocuser.zoom(window: w)
            return // 走完会期(不重枚举):窗还活着,只是尺寸剧变——面板继续陪
        }
        // 处决三段 = 本轮事务死透(用户终审拍板:不留"它是退了还是只关窗"的歧义,
        // 要再切就让用户重新 ⌘Tab 一局);无"重枚举占位"工序
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
            confirmPulse += 1
            dismiss(reason: "确认(无窗应用)", flourish: true)
            return
        }
        let w = g.windows[winIndex]
        WindowFocuser.focus(window: w)
        // 涟漪令牌先 +1 再退场:demo 是"炸开白光 → 90ms 后面板淡出",不是"啪一下没了"
        confirmPulse += 1
        dismiss(reason: "确认", flourish: true)
    }

    /// 面板外点击 = 放弃(CONTEXT.md)。钉住模式下不装——要的就是能切出去截图
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        if pinPanelDebug { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // 判"外"要判玻璃,不是窗口:呼吸区 96pt 是透明且点击穿过的,
                // 点在那儿等于点在面板外(事件已经落到桌面/别的 App)
                let glass = panel.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
                if !glass.contains(NSEvent.mouseLocation) {
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

// MARK: - 窗框差分

extension NSRect {
    /// 半点以内算同一帧。`setFrame` 哪怕目标帧与当前一模一样也会发一轮窗口布局,
    /// 而窗口布局是**同步**的 —— 动画途中插一轮就是一帧卡顿
    func nearlyEquals(_ other: NSRect, eps: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) < eps
            && abs(origin.y - other.origin.y) < eps
            && abs(size.width - other.size.width) < eps
            && abs(size.height - other.size.height) < eps
    }
}
