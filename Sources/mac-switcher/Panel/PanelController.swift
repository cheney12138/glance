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
    /// 选中态动效的**上膛标识**:开局第一帧必须不上膛(否则会从上一局的残影位置滑过来)。
    /// 上面说的"上一局残影"只在 `puckEntersFromLeft = false`(承接模式)时才是**故意**的 ——
    /// 那种情况下上膛反而要提前,见 showPanel。
    @Published private(set) var selectionArmed = false
    /// 托底的入场偏移(纵向,内容坐标系,渐近到 0)。只在"从底部升起"模式下非零
    @Published private(set) var puckEntryRise: CGFloat = 0
    /// 确认涟漪的令牌(demo .ripple):每次确认 +1,`PanelView` 靠它的变化重挂涟漪视图重播一遍

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
    /// begin 的世代号:后台枚举回来时,若已开了新一局就丢掉旧结果(连按 ⌘Tab 的竞态)
    private var beginGeneration = 0

    /// dismiss 时通知触发层收尸(见 HotkeyTapCenter.endSession)。App 装配时接线
    var onSessionEnd: (() -> Void)?

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
        case .begin: begin(reverse: false)
        case .beginReverse: begin(reverse: true)
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

    private func begin(reverse: Bool) {
        // ADR-0001:触发即定场。语境屏快照只活在本轮导航态里
        guard let screen = CursorScreenAnchor.cursorScreen else {
            print("[T6] 取不到语境屏,面板不出现")
            return
        }
        contextScreen = screen
        beginGeneration &+= 1
        let generation = beginGeneration
        // 新一局开始:旧的"退场拆迁单"当场作废。不在这里作废的话,下面几条早退路径
        // (取不到屏/本屏无窗)不会走到 showPanel,那张迟到的单子就会在新一局里执行,
        // 把触发层状态机一起打死 —— 之后 ⌘Tab 全部漏给系统 = macOS 原生切换器。
        teardown?.cancel()
        teardown = nil
        let beganAt = CFAbsoluteTimeGetCurrent()
        // 枚举搬后台(v1.12)。这不是性能微调,是 bug 修复:
        // 事件 tap 的 runloop 挂在主线程,枚举(几十毫秒)一旦压在 tap 回调里,系统会判回调超时
        // 把 tap 停用 —— 停用那一瞬漏出去的 ⌘Tab 就是 macOS 原生切换器(实机量到:
        // begin 之后主线程被占 ~110ms,期间投递的按键全在排队)。让回调立刻返回,枚举在后台跑。
        Task.detached(priority: .userInitiated) {
            let raw = WindowEnumerator.rawGroups(on: screen)
            await MainActor.run {
                self.finishBegin(raw, generation: generation, beganAt: beganAt, reverse: reverse)
            }
        }
    }

    private func finishBegin(_ raw: [AppGroup], generation: Int, beganAt: CFAbsoluteTime, reverse: Bool) {
        // 上一局已被新一局取代(连按 ⌘Tab):旧结果直接丢,别把面板闪回旧内容
        guard generation == beginGeneration else { return }
        let screen = contextScreen
        groups = WindowEnumerator.orderByMRU(raw)
        // **唤起落点**(2026-09-14 做成开关;用户口径:"默认肯定是用 macOS 原生的习惯,不要调教用户"):
        //   开(**默认**)= 直接落在"上一个 App" —— 一次 ⌘Tab 就完成一次切换,这是 macOS 原生节奏;
        //   关        = 落在第一个(当前 App),要再按一次 Tab 才切走 —— 留给"先唤起看清列表再决定"的人。
        // 默认值必须是原生的那个:开关是给少数人的出口,不是让所有人先改一次习惯。
        // 反向(⇧⌘Tab)对应地落到**最后一个**:方向从触发层传下来(HotkeyTapCenter.handleHotKey)。
        let advanceOnOpen = UserDefaults.standard.object(forKey: "switch.advanceOnOpen") as? Bool ?? true
        if advanceOnOpen, groups.count > 1 {
            appIndex = reverse ? groups.count - 1 : 1
        } else {
            appIndex = 0
        }
        winIndex = 0
        // 缩略图缓存**剪枝而不是清场**(2026-09-14):上一局的图还留着,第一帧就有图可上屏,
        // 不再先闪一下"截图中…"。AltTab 也是这个路子 —— 缓存保活 + 后台刷新。
        let allWindows = groups.flatMap { $0.windows }
        Snapshotter.shared.prune(keeping: Set(allWindows.map(\.wid)))
        // **正在显示的那一组排最前面**:卡片要等的就是它那一张。
        // 共 30 扇窗时串行拍完要一两秒,顺序直接决定"第一眼有没有图"
        let shown = groups.indices.contains(appIndex) ? groups[appIndex].windows : []
        let shownIDs = Set(shown.map(\.wid))
        Snapshotter.shared.precapture(shown + allWindows.filter { !shownIDs.contains($0.wid) })
        let ms = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
        print(String(format: "[T8] 按键→枚举就位 %.0fms(后台枚举,不卡按键)", ms))
        guard !groups.isEmpty else {
            print("[T6] 本屏无窗,面板不出现(语境屏 = \(screen?.localizedName ?? "?"))")
            return
        }
        print("[T6] 面板出现:语境屏 = \(screen?.localizedName ?? "?"),\(groups.count) 个 App")
        applySessionScaleCap(on: screen)
        // 动效在不在线,一眼可见(系统"减弱动态效果"会把弹簧静默压成淡入淡出)
        print("[T6] 动效:\(MotionPolicy.describe)")
        showPanel()
    }

    /// 把本会期的尺寸上限算出来(放不下就收紧,见 `PanelMetrics.sessionCap`)。
    ///
    /// 量的是**基准宽**(每 1.0 倍尺寸的面板宽度):长条按 App 数、托盘按本屏最大窗数,
    /// 两者取更紧的一个。不手写第二份几何公式 —— 直接把限制解掉后读真实的布局数学再除回来,
    /// 这样任何度量改动都会自动跟着走(手写的话一定会漂)。
    private func applySessionScaleCap(on screen: NSScreen?) {
        let avail = (screen?.visibleFrame.width ?? 1440) - 48 // 左右各留 24 的安全边
        let saved = PanelMetrics.sessionCap
        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        let s = PanelMetrics.scale
        let stripBase = contentSize().width / s
        let trayBase = groups.map { previewContentSize(for: $0).width / s }.max() ?? 0
        PanelMetrics.sessionCap = saved
        let cap = min(avail / max(stripBase, 1), avail / max(trayBase, 1))
        PanelMetrics.sessionCap = cap
        // 一行账,永远打:面板为什么变小了,看一眼日志就知道(比“尺寸不对但不知道为什么”值钱)
        print(String(format: "[尺寸] 固定 %.0f%% · 屏宽 %.0f · 本局上限 %.0f%% · 基准宽 %.0fpt(长条)/%.0fpt(托盘)%@",
                     s * 100, screen?.visibleFrame.width ?? 0, cap * 100, stripBase, trayBase,
                     cap < s - 0.001 ? " → 已收紧" : ""))
    }

    private func showPanel() {
        buildPanelIfNeeded()
        panelOpenPoint = NSEvent.mouseLocation
        guard let panel, let target = centerFrame(for: paddedSize()) else { return }
        isVisible = true
        // 退场演出期间关掉的事件耳,开新局要还回来
        panel.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        beginActivity()

        // 托底入场(两种模式的区别只在**起点**,都会滑):
        //   · 从底部升起(默认):先把托底按到选中格下方(那一帧它在面板下缘之外,
        //     被圆角裁掉),再上膛 + 升到选中格 —— 距离恒定且短;
        //   · 承接上一局:第一帧就上膛,弹簧自己会从"上一局那个格子"滑到新选中
        //     (窗口复用,上一局的偏移还在视图里 —— 那份残影在这里是故意的)。
        //
        // 顺序要紧:起点必须在 `orderFrontRegardless()` **之前**写好。
        // 写在后面的话第一帧会先在选中格把托底画出来,再瞬移到板外去 —— 屏幕上一道闪,
        // 本意(升起)反而变成了两跳。
        let risesFromBottom = MotionPolicy.puckRisesFromBottom
        if risesFromBottom {
            selectionArmed = false
            puckEntryRise = MotionPolicy.puckRiseDistance
        } else {
            puckEntryRise = 0
            selectionArmed = true
        }

        // 入场动效在 SwiftUI 层(demo .switcher-wrap 的 scale .90→1 + 渐入),窗口只负责就位
        panel.alphaValue = 1
        setFrameIfNeeded(panel, target)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
        updatePreview()

        // 起点已就位,等第一帧提交完再上膛、再升上来(动效仍是同一根弹簧,只换了方向)
        if risesFromBottom {
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.entryDelay) { [weak self] in
                guard let self, self.isVisible else { return }
                self.selectionArmed = true
                withAnimation(MotionPolicy.animation(PanelMotion.entrance)) { self.puckEntryRise = 0 }
            }
        }
        // 帧间隔探针只在本轮导航态里跑(GLANCE_TRACE=1):面板退场时打一行结论
        if let hostingView { FrameProbe.shared.start(on: hostingView, label: "面板\(groups.count)App") }
    }

    /// 换选中时该用的动效(nil = 不动)。两道门:面板在台上 + 已过开局第一帧
    /// (第一帧不上膛的用意:开局那一次落位是"就位",不是"从上一格滑过去")
    func selectionAnimation(_ full: Animation) -> Animation? {
        guard isVisible, selectionArmed else { return nil }
        return MotionPolicy.animation(full)
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
    /// 关闭 = **立刻消失**,没有淡出、没有演出(2026-09-14 用户实评:
    /// "不管是点击 app、松开 cmd tab、还是 esc,所有关闭环节都不要淡出,有点拖沓")。
    ///
    /// 曾经是"确认后留 0.45s 播涟漪、其余留 0.38s 播淡出"——那条设计的代价是**面板比动作多活一段**,
    /// 而切换器关闭时用户已经在看目标窗口了,再叠一层半透明就是在拖节奏。原生切换器也是啪一下就没。
    /// 代价:确认涟漪随之作废(它需要面板多留 0.45s 才看得见,与"立刻消失"互斥),`confirmPulse` 一并删。
    private func dismiss(reason: String) {
        // 先把在途的 begin 作废:枚举搬后台之后,"括键比枚举先到"是能发生的 ——
        // 不拦的话枚举回来会把面板在放弃之后又冒出来
        beginGeneration &+= 1
        removeOutsideClickMonitor()
        isVisible = false
        // 关闭期间别再吃 hover / 点击(外面那圈透明呼吸区也在放事件)
        panel?.ignoresMouseEvents = true
        previewPanel?.ignoresMouseEvents = true
        print("[T6] \(reason):面板关闭")
        teardownPanel(generation: beginGeneration)
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
    ///
    /// `generation` 是保险:这张拆迁单发出后,若又开了一局(`beginGeneration` 已变),
    /// 它既不能拆窗(窗正被新一局用着),也不能通知触发层收尸 —— 通知了就是把新一局
    /// 的状态机从 navigating 拉回 idle,接下来的 ⌘Tab 会全部漏给系统。
    private func teardownPanel(generation: Int) {
        guard generation == beginGeneration else {
            print("[T6] 过期的退场拆迁单(已开新局),作废")
            return
        }
        endActivity()
        FrameProbe.shared.stop() // 面板退场 = 本轮采样结束,直接打一行帧间隔结论
        PanelMetrics.sessionCap = .greatestFiniteMagnitude // 会期结束,限额随之失效(不留给设置页读到旧值)
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
    /// 与 PreviewPanelView 的 .frame(previewContentSize) 同源。
    /// 带参数的版本给"本会期尺寸上限"用:它要量**所有组**里最宽的那个,而不是当前选中组
    func previewContentSize(for group: AppGroup?) -> NSSize {
        guard let g = group, !g.windows.isEmpty else { return .zero }
        let n = CGFloat(g.windows.count)
        let cardsW = n * PanelMetrics.thumbW + max(n - 1, 0) * PanelMetrics.thumbGap
        return NSSize(
            width: cardsW + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop + PanelMetrics.captionH + PanelMetrics.trayGap
                + PanelMetrics.thumbH + PanelMetrics.trayPadBottom
        )
    }

    func previewContentSize() -> NSSize { previewContentSize(for: currentGroup) }

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
        traceCost("键盘换选中") {
            appIndex = (appIndex + delta + groups.count) % groups.count
            winIndex = 0
            // 不动窗框:面板尺寸只跟 App 数量有关,选中移动不改尺寸(旧病见 setFrameIfNeeded)
            print("[T6] 选中: [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
            refreshSnapshotForSelection()
            updatePreview()
        }
    }

    /// 主线程耗时记账(GLANCE_TRACE=1)。与 FrameProbe 分工:这里量的是"同步阻塞了多久",
    /// 那里量的是"帧间隔有没有崩" —— 两者对上就是结论
    private static let traceOn = ProcessInfo.processInfo.environment["GLANCE_TRACE"] != nil

    private func trace(_ line: String) {
        guard Self.traceOn else { return }
        print(line)
    }

    private func traceCost(_ label: String, _ body: () -> Void) {
        guard Self.traceOn else { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        // 只报"值得看"的:换选中本来应该是微秒级,超过 2ms 就写一行
        guard ms > 2 else { return }
        trace(String(format: "[工] %@ 主线程 %.1fms", label, ms))
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
        // 拍图全程在后台(见 Snapshotter 头注):这里只递一批目标,不发任务、不等结果
        Snapshotter.shared.precapture(g.windows)
        trace("[T11] 现拍(后台): \(g.appName) \(g.windows.count) 窗")
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
        traceCost("指针换选中") {
            appIndex = i
            winIndex = 0
            refreshSnapshotForSelection()
            updatePreview()
        }
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

    /// 处决类操作(Q/W/M 与红绿灯共走这里)。
    ///
    /// 2026-09-14 用户改判:处决之后**留在原地**。原语义是"处决三段 = 本轮事务死透"
    /// (避免"走了还是只关窗"的歧义),但实际用起来:关一扇窗、最小化一扇窗之后往往还想接着动
    /// 别的窗 —— 面板一消失,每动一次就要重新 ⌘Tab 开一局。现在动作做完就重枚举刷新,面板不散。
    private func destructive(_ op: DestructiveOp) {
        guard groups.indices.contains(appIndex) else { return }
        let g = groups[appIndex]
        switch op {
        case .quit:
            print("[T12] 退出应用: \(g.appName)")
            WindowFocuser.quitApp(pid: g.pid)
            refreshAfterAction()
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
            refreshAfterAction()
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 最小化: \(g.appName) — \(w.title)")
            WindowFocuser.minimize(window: w)
            refreshAfterAction()
        case .zoom:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 缩放(Z): \(g.appName) — \(w.title)")
            WindowFocuser.zoom(window: w)
            // 缩放不改列表:窗还在同一格,只是尺寸剧变 —— 不重枚举,面板继续陪
        }
    }

    /// 处决后的就地刷新:重枚举 + **尽量保住原来的选中**(按 pid 认 App,窗位夹紧)。
    ///
    /// 为什么要延迟一下:AX 的关闭/最小化是**异步生效**的,立刻枚举会把刚处决的那扇窗
    /// 又枚举回来(于是它在面板里"诈尸"一下再消失)。
    private func refreshAfterAction() {
        guard let screen = contextScreen else { return }
        let generation = beginGeneration
        let keepPID = groups.indices.contains(appIndex) ? groups[appIndex].pid : nil
        let keepWin = winIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.isVisible, self.beginGeneration == generation else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.isVisible, self.beginGeneration == generation else { return }
                    self.applyRefreshed(raw, keepPID: keepPID, keepWin: keepWin)
                }
            }
        }
    }

    private func applyRefreshed(_ raw: [AppGroup], keepPID: pid_t?, keepWin: Int) {
        let fresh = WindowEnumerator.orderByMRU(raw)
        guard !fresh.isEmpty else {
            dismiss(reason: "处决后无窗可切")
            return
        }
        groups = fresh
        if let keepPID, let ai = fresh.firstIndex(where: { $0.pid == keepPID }) {
            appIndex = ai
        } else {
            appIndex = min(appIndex, fresh.count - 1)
        }
        let windowCount = fresh[appIndex].windows.count
        winIndex = min(keepWin, max(windowCount - 1, 0))
        // 列表变了 → 截图重拍。同样**剪枝不清场**:别的窗的图还有效,只有被处决那扇会被剪掉
        let live = Set(groups.flatMap { $0.windows }.map(\.wid))
        Snapshotter.shared.prune(keeping: live)
        let shown = groups.first?.windows ?? []
        let shownIDs = Set(shown.map(\.wid))
        Snapshotter.shared.precapture(shown + groups.flatMap { $0.windows }.filter { !shownIDs.contains($0.wid) })
        // App 数可能变了 → 长条尺寸变、托盘内容也换;两窗各自就位(banner 不滑)
        if let panel, let target = centerFrame(for: paddedSize()) {
            setFrameIfNeeded(panel, target)
        }
        updatePreview()
        print("[T12] 处决后留在原地: \(groups.count) 个 App,选中 [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
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
                // 判"外"要判玻璃,不是窗口:呼吸区 96pt 是透明且点击穿过的,
                // 点在那儿等于点在面板外(事件已经落到桌面/别的 App)
                let point = NSEvent.mouseLocation
                let strip = panel.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
                // **托盘是另一扇窗**(与长条同皮不同窗):不把它算进来,点托盘上任何地方
                // (卡片、题头、红绿灯)都会被当成"面板外点击"把面板关掉 —— 实机现形:
                // 2026-09-14 用户报"用鼠标点红绿灯的操作也不关闭面板"
                let tray = self.previewPanel.flatMap { p -> NSRect? in
                    guard p.isVisible else { return nil }
                    return p.frame.insetBy(dx: PanelMetrics.shadowPadPop, dy: PanelMetrics.shadowPadPop)
                }
                if !strip.contains(point), !(tray?.contains(point) ?? false) {
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
