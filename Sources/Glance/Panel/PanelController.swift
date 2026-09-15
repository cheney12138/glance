import AppKit
import GlanceCore
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
    /// 本局托盘窗口开的**最大**内容尺寸(见 `previewSize()`)。
    ///
    /// 病例(2026-09-15 实测量到):`[工] 托盘改尺寸 主线程 23.3ms`,而外层 `键盘换选中` 26.3ms
    /// —— 每按一次 Tab,托盘卡片数变 → 窗口尺寸变 → `setFrame` 同步窗口布局,吃掉 1–1.5 帧,
    /// 入场上浮时正好被这 14–26ms 压住,读起来就是"上浮不流畅"。
    /// 解法:窗口按**整局所有组里最大的那个布局**开一次,之后换选中只换内容不换窗框。
    /// (内容在窗口里**底部对齐、水平居中**,所以小布局看起来与今天完全一样。)
    private var trayMaxContentSize: NSSize = .zero

    /// "只在变化时打"用的状态位(见 `applySessionScaleCap` 的档位行与那行动效状态)。
    /// 理由同一句话:**常量不该每局重印** —— 日志的价值在"变了没有",不在"还是那样"。
    private static var lastScaleLine: String?
    private static var lastMotionDescribe: String?

    /// 上一局结束时托底所在的格(视图复用,那就是它现在的实际位置)。nil = 这是第一次出现。
    /// 用来判断入场是"滑"还是"升" —— 见 `showPanel`。
    private var lastLandedIndex: Int?

    /// 入场升起偏移。作用对象 = **托底 + 选中的那一格图标**(其余图标不动):
    /// 只挂托底会读成"两个动作各走各的";整行一起升又太重("全部图标一起弹出来")。
    /// 这一档正是"正常 Tab 切换"的范围 —— 切换时动的永远只有托底与新选中的那个图标
    @Published private(set) var contentEntryRise: CGFloat = 0
    /// 确认涟漪的令牌(demo .ripple):每次确认 +1,`PanelView` 靠它的变化重挂涟漪视图重播一遍

    private var panel: NSPanel?
    private var hostingView: ClickThroughHostingView<PanelView>?
    private var previewPanel: NSPanel?
    private var previewHostingView: ClickThroughHostingView<PreviewPanelView>?
    private var contextScreen: NSScreen?
    private var outsideClickMonitor: Any?
    /// 自己窗口的点击(全局监听看不见自己家的事件,见 `installOutsideClickMonitor`)
    private var localClickMonitor: Any?
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

    /// 本局内被 H 隐藏的 App。为什么要记:
    /// 隐藏是**异步**的(0.2–0.3s 动画),这期间重枚举**还看得见它的窗** ——
    /// 不记住的话,卡片会在 0.18s 后闪回来(用户实报:「先是消失了,然后又出现了」)。
    private var hiddenPIDs: Set<pid_t> = []

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
        // 截图会话里的回车(T32):面板退场、**不聚焦任何窗**。
        // 语义上它就是"放弃"(不生效),但理由不同 —— 用户不是不要了,是那一发回车归截图工具,
        // 所以日志里必须分得清这两件事(否则复盘时会把"截图让权"读成"用户反悔")
        case .yieldToCapture: dismiss(reason: "截图会话让权")
        case .quitApp: destructive(.quit)
        case .closeWindow: destructive(.close)
        case .minimizeWindow: destructive(.minimize)
        case .toggleFullscreen: destructive(.fullscreen)
        case .hideApp: destructive(.hide)
        }
    }

    // MARK: - 生命周期

    private func begin(reverse: Bool) {
        // 打卡器开账:一局的环节时间轴从这里起算(见 `SessionMarks`)
        SessionMarks.begin("唤起")
        // **先抢优先级,再干活**:`.latencyCritical` 这条断言要从按键那一刻生效,不能等到 `showPanel`
        // 才拿 —— "隔一段时间不用、再唤起就顿"最可能的原因就是这期间进程被挂起(App Nap)、
        // 窗口后备存储被 WindowServer 回收,而**最贵的几帧恰好是刚回来的这几帧**。
        // 之前它在 `showPanel` 里拿,枚举那一段连同回来的首帧是裸奔的。
        beginActivity()
        // ADR-0001:触发即定场。语境屏快照只活在本轮导航态里
        guard let screen = CursorScreenAnchor.cursorScreen else {
            print("[T6] 取不到语境屏,面板不出现")
            endActivity() // 早退也要还回去,否则这条"不许抽帧"的断言会一直挂着(白耗电)
            return
        }
        contextScreen = screen
        hiddenPIDs.removeAll() // 新一局:以系统现在的真实状态为准,清掉上一局的隐藏记忆
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
        SessionMarks.step("枚举")
        // 上一局已被新一局取代(连按 ⌘Tab):旧结果直接丢,别把面板闪回旧内容
        guard generation == beginGeneration else { return }
        let screen = contextScreen
        groups = WindowEnumerator.orderByMRU(raw)
        // **唤起落点**(2026-09-14 做成开关;用户口径:"默认肯定是用 macOS 原生的习惯,不要调教用户"):
        //   开(**默认**)= 直接落在"上一个 App" —— 一次 ⌘Tab 就完成一次切换,这是 macOS 原生节奏;
        //   关        = 落在第一个(当前 App),要再按一次 Tab 才切走 —— 留给"先唤起看清列表再决定"的人。
        // 默认值必须是原生的那个:开关是给少数人的出口,不是让所有人先改一次习惯。
        // 反向(⇧⌘Tab)对应地落到**最后一个**:方向从触发层传下来(HotkeyTapCenter.handleHotKey)。
        //
        // ★ 2026-09-14 二修:原生的"落点"与**原生的循环序**是两件事,上一版只做对了一半。
        // `orderByMRU` 给的是 [**当前 App**, 上一个 App, 更早的…, 最久没用的]。
        // 原生 ⌘Tab 的环是:**上一个 App → 更早的… → 最久没用的 → 当前 App → 回到上一个 App**
        // (即"当前 App 只在绕完一圈后才出现")。落点必须是环上的第一格 = 上一个 App。
        //
        // 上一版用的是 `swapAt(0,1)`:高亮是落到第一格了(修掉了"选中第二个"的观感),
        // 但它把**当前 App 放到了第二格** —— 于是环变成"上一个 App → 当前 App → …",
        // 用户按一下 Tab 就绕回了自己所在的地方。实机日志对得上账:唤起后第一发 Tab 落在
        // `[2/6]` 而那一格正是当前 App(实评:"这个开关没生效,我还是能选中第一个")。
        // 开关其实生效了,是**环走错了** —— 循环序错了,落点对也白搭。
        //
        // 正解是**左旋一格**(当前 App 从队首沉到队尾),不是交换:
        //   · 落点 = 队首 = 上一个 App   (与上一版一致,观感不变)
        //   · 正向 Tab  → 更早的… → 最久没用的 → 最后才轮到当前 App(与原生同序)
        //   · 反向 ⇧Tab → 直接到队尾 = 当前 App(原生也是这样:从第 2 格往回一格就是第 1 格)
        // 交换只能改两格的相对位置,旋转改的是整条环 —— 这是两种完全不同的操作。
        let advanceOnOpen = UserDefaults.standard.object(forKey: "switch.advanceOnOpen") as? Bool ?? true
        // ★ 2026-09-15 三修:前两版都在"重排顺序"上找答案,都是错的(见 LandingRule 文档里的三段历史)。
        // 正解是什么都不做 —— MRU 原序天然就是原生的第一眼版式:
        //   第一格 = 当前 App(它在,但没被选中),第二格 = 上一个 App(高亮落这里 = 唤起即切换),
        //   往后走到最久没用的,绕回第一格时当前 App 才出现(普通取模自动给出这条环)。
        // 所以这里只算**下标**,不再 `swapAt`(v1)也不再左旋(v2)。
        // 托底**上一次画在哪一格**:视图是复用的,它就停在上局结束时的落点 ——
        // 入场动效要靠它判断"这一局托底到底会不会滑"(见 showPanel 的两条路)
        lastLandedIndex = appIndex
        SessionMarks.step("落点")
        appIndex = advanceOnOpen ? LandingRule.landingIndex(count: groups.count, reverse: reverse) : 0
        // 落点这行**每次都打**:开关 × 正反向 × 环序有四种走法,只看"高亮在第几格"分不清是哪一种 ——
        // 下次再说"开关没生效",看这一行就够(第一格是不是当前 App、落点是不是上一个 App 一目了然)
        if groups.indices.contains(appIndex) {
            print("[落点] \(advanceOnOpen ? "唤起即切换" : "停在当前") · \(reverse ? "反向" : "正向")"
                  + " · [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
            trace("[T6] 落点顺序 [\(groups.map(\.appName).joined(separator: " | "))]")
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
        // 正在显示的那一组**强制重拍**(用户正看着它,要求此刻是准的);
        // 其余组走缓存 —— 它们的图只用来保证"Tab 过去的第一帧有东西",不要求绝对新鲜
        Snapshotter.shared.precapture(shown, force: true)
        Snapshotter.shared.precapture(allWindows.filter { !shownIDs.contains($0.wid) })
        let ms = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
        trace(String(format: "[T8] 按键→枚举就位 %.0fms(后台枚举,不卡按键)", ms))
        guard !groups.isEmpty else {
            print("[T6] 本屏无窗,面板不出现(语境屏 = \(screen?.localizedName ?? "?"))")
            endActivity() // 同上:早退要还
            return
        }
        // 面板出现那行并入 `showPanel` 的"唤起结算"(那里才有"按键→上屏"的读数)
        applySessionScaleCap(on: screen)
        // **收紧之后**再算托盘窗口的最大布局:所有度量都随 sessionCap 变,算早了就是上一局的尺寸
        // (与 `[尺寸]` 那行注释里同一条教训:行/列要在收紧之后算)
        trayMaxContentSize = groups.reduce(NSSize.zero) { acc, g in
            let c = previewContentSize(for: g)
            return NSSize(width: max(acc.width, c.width), height: max(acc.height, c.height))
        }
        // 动效在不在线,一眼可见(系统"减弱动态效果"会把弹簧静默压成淡入淡出)
        // 动效状态**只在变化时打**:它在一台机器上是常量,每局重印就是噪音
        if Self.lastMotionDescribe != MotionPolicy.describe {
            Self.lastMotionDescribe = MotionPolicy.describe
            print("[动效] \(MotionPolicy.describe)")
        }
        showPanel(beganAt: beganAt, enumerateMs: ms)
    }

    /// 本会期托盘可用的**玻璃**空间(2026-09-14 换行那轮引入)。
    /// 宽 = 可视宽 − 两侧安全边;高 = 长条**头顶**那一半 —— 长条是垂直居中的,
    /// 托盘挂在它上沿之上,所以只有 (可视高 − 长条高) / 2 可用,不是整个屏高。
    private var trayRoomW: CGFloat = 1440
    private var trayRoomH: CGFloat = 420

    /// 把本会期的尺寸上限算出来(放不下就收紧,见 `PanelMetrics.sessionCap`)。
    ///
    /// ★ 2026-09-14 改「托盘不再替长条决定尺寸」:
    /// 旧算法是 `min(宽够不够长条, 宽够不够托盘一行摆完)` —— 托盘一旦摆不下就一路把
    /// **整块面板**(连带长条图标)压下去。实测 14" MBP / 12 扇窗:整块缩到 **57%**,
    /// 图标只剩 51pt、缩略图 113×70 —— 那已经不是"缩",是看不清了。
    ///
    /// 用户的裁决是"整块面板跟着缩,跟长条一个做法"(2026-09-14)。顺着它推到底就会撞上一件事:
    /// **长条只能缩**(托底在横轴上滑,没法换行),而托盘**可以换行**。
    /// 让一个能换行的容器去压一个不能换行的容器,是把最不灵活的那个逼到墙上。
    ///
    /// 于是分工改成:
    ///   · 长条 = 唯一的**缩**驱动者(App 越多越小,与用户记忆里"长条到上限就缩"一致);
    ///   · 托盘 = 先跟着一起缩,缩到**一行摆不下**就换行(`trayFitScale` 取能用的最大尺寸)。
    /// 结果:12 扇窗从 57% 回到 **98%**(2 行),20 扇窗 69%(2 行),24 扇窗 66%(3 行)。
    ///
    /// 不手写第二份几何公式 —— 直接把限制解掉后读真实的布局数学再除回来,
    /// 这样任何度量改动都会自动跟着走(手写的话一定会漂)。
    private func applySessionScaleCap(on screen: NSScreen?) {
        // 量的是**玻璃**的可用宽(透明呼吸区可以出屏,不参与"放不放得下")。
        // 口径与 previewFrame 的收边共用 PanelMetrics.screenMargin,见那里的注释
        let frame = screen?.visibleFrame
        let margin = PanelMetrics.screenMargin
        let availW = (frame?.width ?? 1440) - margin * 2
        let saved = PanelMetrics.sessionCap
        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        // 长条按**固定档**估高(它与本局 cap 无关):托盘的竖向空间 = 长条头顶那一半,
        // 这一步只决定"要几行",估值的误差远小于一行卡片的高度,不会翻盘
        let stripH = PanelMetrics.rowPadY * 2 + PanelMetrics.icon // 与 contentSize() 同源
        let seam = PanelMetrics.seam // 同档读,别让它跟着上一局的 cap 变
        PanelMetrics.sessionCap = saved
        let availH = ((frame?.height ?? 900) - stripH) / 2 - margin - seam
        trayRoomW = max(availW, 320)
        // 高度的下限只兜"取不到屏"的病态情况(140pt 还放得下一行小卡);
        // 真拿到了屏就按真值算 —— 抬高低限等于允许托盘顶出屏外
        trayRoomH = max(availH, 140)

        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        let s = PanelMetrics.scale
        let stripBase = contentSize().width / s
        PanelMetrics.sessionCap = saved

        var cap = availW / max(stripBase, 1)
        var worstN = 0
        var worstScale = CGFloat.greatestFiniteMagnitude
        for g in groups where !g.windows.isEmpty {
            let fit = trayFitScale(count: g.windows.count).scale
            cap = min(cap, fit)
            if fit < worstScale { worstScale = fit; worstN = g.windows.count }
        }
        PanelMetrics.sessionCap = cap
        // 行/列要在**收紧之后**再算:列数取的是当前尺寸下能放几张,
        // 收紧前算出来的会是上一局的尺寸(日志里就会看到对不上的行 × 列)
        let worstLayout = trayLayout(count: worstN)
        // **只在档位变化时打**:同一台机器上它几乎每局一样,重印就是噪音;变了一定要看
        if Self.lastScaleLine == String(format: "%.3f/%.3f", s, cap) { return }
        Self.lastScaleLine = String(format: "%.3f/%.3f", s, cap)
        print(String(format: "[尺寸] 固定 %.0f%% · 本局 %.0f%% · 长条 %.0fpt(基准) · 托盘最挤 %d 窗 → %d 行 × %d 列 · 玻璃 %.0f/%.0fpt%@",
                     s * 100, cap * 100, stripBase, worstN, worstLayout.rows, worstLayout.cols,
                     cap * stripBase, availW,
                     cap < s - 0.001 ? " → 已收紧" : ""))
        // (托盘窗口尺寸那行撤了:它是"整局只 setFrame 一次"的验证账,已验证完;
        //  要复核时看 `[工] 托盘改尺寸` 是否只在开局出现即可)
        if cap < 0.6 {
            print("[尺寸] 提示:本局 < 60%,面板会明显偏小 —— 是 App 数太多(长条压尺寸),不是托盘")
        }
    }

    /// 托盘在 `count` 扇窗下能拿到的**最大**尺寸:穷举行数 1…`trayMaxRows`,
    /// 每个行数取「宽与高都放得下」的尺寸上限,取最大的那个。
    ///
    /// 为什么不固定"一行摆完":一行摆完意味着窗数一多就一路缩到看不清(12 窗 → 57%)。
    /// 为什么不固定"两行":6 窗明明一行放得下,分两行是把能用 113% 的一局压到 98% —— 白牺牲。
    /// 所以是**取最大可用尺寸**,行数只是它的副产品。
    private func trayFitScale(count n: Int) -> (scale: CGFloat, rows: Int, cols: Int) {
        guard n > 0 else { return (.greatestFiniteMagnitude, 0, 0) }
        let saved = PanelMetrics.sessionCap
        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        let s = PanelMetrics.scale
        // 每行/每列在 1.0 倍下的占位(含间隙;末尾那一份间隙要减掉,所以 pad 里是减不是加)
        let cardW = (PanelMetrics.thumbW + PanelMetrics.thumbGap) / s
        let padW = (PanelMetrics.trayPadX * 2 - PanelMetrics.thumbGap) / s
        let rowH = (PanelMetrics.thumbH + PanelMetrics.trayRowGap) / s
        let padH = (PanelMetrics.trayPadTop + PanelMetrics.trayPadBottom - PanelMetrics.trayRowGap) / s
        PanelMetrics.sessionCap = saved

        var best = (scale: CGFloat(0), rows: 1, cols: n)
        for r in 1...min(n, PanelMetrics.trayMaxRows) {
            let c = (n + r - 1) / r
            let fit = min(trayRoomW / (CGFloat(c) * cardW + padW),
                          trayRoomH / (CGFloat(r) * rowH + padH))
            if fit > best.scale { best = (fit, r, c) }
        }
        return best
    }

    /// 托盘的行 × 列 —— **唯一来源**:视图排网格与 `previewContentSize` 都取它。
    /// 两处各算一遍必然漂(上一次漂的代价是"托盘出屏")。
    ///
    /// 取**放得下的最少行数**(不是"一行塞到最满"):最小行数意味着每行列数均衡 ——
    /// 8 扇窗在 1512 上贪心会排成 **7 + 1**(末行孤零零一张),取最少行数是 **4 + 4**。
    ///
    /// `+ 0.5` 是**容差**,不是凑数:尺寸上限就是按"刚好放满"解出来的,于是
    /// `c × 卡宽 == 可用宽` 是这里的常态输入 —— 纯浮点下这一步会随机掉一个
    /// (15 窗 / 2 行:8 列正好 1464.0pt,算出来 7 列 → 行数 2 变 3 → 托盘**竖向**溢出)。
    /// 0.5pt 肉眼不可见,但足以让"刚好放得下"稳定成立。
    func trayLayout(count n: Int) -> (rows: Int, cols: Int) {
        guard n > 0 else { return (0, 1) }
        let cardW = PanelMetrics.thumbW + PanelMetrics.thumbGap
        let padW = PanelMetrics.trayPadX * 2 - PanelMetrics.thumbGap
        for r in 1...min(n, PanelMetrics.trayMaxRows) {
            let c = (n + r - 1) / r
            if CGFloat(c) * cardW + padW <= trayRoomW + 0.5 { return (r, c) }
        }
        // 病理兜底:几十扇窗时行数顶穿 `trayMaxRows`,那时宁可让宽度溢出
        // (由调用方按"内容居中 + 两端对称地切"兜底)也不往上堆成一面墙
        let r = min(n, PanelMetrics.trayMaxRows)
        return (r, (n + r - 1) / r)
    }

    private func showPanel(beganAt: CFAbsoluteTime, enumerateMs: Double) {
        buildPanelIfNeeded()
        panelOpenPoint = NSEvent.mouseLocation
        gateBlockedLogged = false
        trayOverflowLogged = false
        guard let panel, let target = centerFrame(for: paddedSize()) else { return }
        isVisible = true
        // 退场演出期间关掉的事件耳,开新局要还回来
        panel.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        // (优先级断言已在 `begin()` 拿到:这里不再重复拿,免得 end→begin 把优先级抖一下)

        // 入场分**两层**,不是二选一(2026-09-15 用户口径:"上浮是通用的,从 c 滑动到 a 是额外的动效"):
        //   ① **上浮 = 通用**:托底 / 选中的那一格 / 整块托盘从原位置下方浮上来 —— 每次都有,没有开关;
        //   ② **滑过来 = 额外**:托底额外从"上一局停的那一格"横滑到本局落点(设置里可开)。
        //      两局同格时它没得滑,自然只剩上浮。
        // 所以这里不再"二选一":上浮的起点照摆,再单独决定托底要不要**上膛**(上膛 = 位移走弹簧)。
        //
        // 顺序要紧:起点必须在 `orderFrontRegardless()` **之前**写好。
        // 写在后面的话第一帧会先在选中格把托底画出来,再瞬移到板外去 —— 屏幕上一道闪。
        let willSlide = MotionPolicy.slideFromLastApp
            && lastLandedIndex != nil && lastLandedIndex != appIndex
        selectionArmed = willSlide                          // 要滑才上膛,否则第一帧定死
        contentEntryRise = MotionPolicy.entryFloatDistance   // 上浮:两种情形都有
        trace("[T6] 入场:上浮" + (willSlide
            ? " + 从上一格滑过来(托底 \(lastLandedIndex! + 1) → \(appIndex + 1))"
            : ""))

        // 入场动效在 SwiftUI 层(demo .switcher-wrap 的 scale .90→1 + 渐入),窗口只负责就位
        panel.alphaValue = 1
        setFrameIfNeeded(panel, target)
        panel.orderFrontRegardless()
        // 打**延迟**而不是时间点:绝对时间戳对"这次慢不慢"毫无用处(上一版就栽在这),
        // 要看的是"从按键到上屏多少毫秒、其中枚举占多少"
        // **一次唤起的全部结算,一行**:语境屏 + App 数 + 按键→上屏(含枚举)。
        // 这三件事永远同时发生,原来占三行(`[T8]` / 面板出现 / `[T6] 按键→上屏`)
        print(String(format: "[唤起] %@, %d 个 App · 按键→上屏 %.0fms(枚举 %.0fms)",
                     contextScreen?.localizedName ?? "?", groups.count,
                     (CFAbsoluteTimeGetCurrent() - beganAt) * 1000, enumerateMs))
        SessionMarks.step("开窗")
        // 首帧:下一次 runloop 回来 ≈ 第一帧已经上屏(`FrameProbe` 那边有精确帧账,这里只求"环节到哪")
        DispatchQueue.main.async {
            SessionMarks.step("首帧")
            SessionMarks.finish()
        }
        installOutsideClickMonitor()
        updatePreview()

        // 起点已就位:首帧提交后把上浮归零 —— "通用"那一层,任何时候都发生
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.entryDelay) { [weak self] in
            guard let self, self.isVisible else { return }
            self.selectionArmed = true // 之后会话内的选中变化照常走弹簧
            withAnimation(MotionPolicy.animation(PanelMotion.entrance)) { self.contentEntryRise = 0 }
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
        trace("[T6] \(reason):面板关闭")
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
        let n = g.windows.count
        // 一行摆不下就换行:宽度按**实际列数**算(不是总窗数),高度按行数叠加。
        // 行/列只从 `trayLayout` 出 —— 与 PreviewPanelView 的网格同源,不许各算各的
        let (rows, cols) = trayLayout(count: n)
        let c = CGFloat(cols)
        let r = CGFloat(max(rows, 1))
        return NSSize(
            width: c * PanelMetrics.thumbW + max(c - 1, 0) * PanelMetrics.thumbGap
                + PanelMetrics.trayPadX * 2,
            // 题头行已去掉,高度里也不再留它
            height: PanelMetrics.trayPadTop
                + r * PanelMetrics.thumbH + max(r - 1, 0) * PanelMetrics.trayRowGap
                + PanelMetrics.trayPadBottom
        )
    }

    func previewContentSize() -> NSSize { previewContentSize(for: currentGroup) }

    /// 托盘**窗口**尺寸:本局最大布局 + 两侧呼吸区。
    /// 用它(而不是当前组的内容)是为了让窗口在整局里**只 setFrame 一次**(病例见 `trayMaxContentSize`)。
    private func previewSize() -> NSSize {
        let c = trayMaxContentSize.width > 0 ? trayMaxContentSize : previewContentSize()
        let pad = PanelMetrics.shadowPadPop * 2
        return NSSize(width: c.width + pad, height: c.height + pad)
    }

    /// 面板**内容**(玻璃)在本屏坐标里的矩形。面板窗口 = 内容 + 四周 shadowPadStrip,所以窗口往内收
    /// 一圈就是玻璃。与 `previewContentRect()` 同一个口径(ADR-0006 的推论:凡判"指针/点击在不在"都用内容矩形)。
    func panelContentRect() -> NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
    }

    /// 托盘**内容**(玻璃)在本屏坐标里的矩形。窗口可能比内容大,所以凡是判"托盘在哪"的地方
    /// (指针重定位、面板外点击)都必须用这个,不能用窗口 frame。
    func previewContentRect() -> NSRect? {
        guard let p = previewPanel, p.isVisible else { return nil }
        let c = previewContentSize()
        guard c.width > 0, c.height > 0 else { return nil }
        // 内容在窗口里:水平居中、**底部对齐**(与窗口等尺寸时 = 今天的布局,一个像素不差)
        return NSRect(x: p.frame.midX - c.width / 2,
                      y: p.frame.minY + PanelMetrics.shadowPadPop,
                      width: c.width, height: c.height)
    }

    /// 托盘出屏的兜底日志:一个会期只喊一次(见 `previewFrame`)
    private var trayOverflowLogged = false

    /// 托盘正中 = 长条正中(demo 的 .switcher-wrap 是 column 居中,托盘不跟图标滑移);
    /// 超界时**只在玻璃层面**收进语境屏;视觉缝 = seam。
    ///
    /// ★ 2026-09-14 修「窗口一多,最左边那张预览卡被推出屏幕」:
    ///
    /// 旧写法是 `min(max(desired, area.minX + 12), area.maxX - size.width - 12)` —— 边界里的
    /// `size` 是**窗口**宽 = 玻璃 + 两侧 `shadowPadPop`(96pt)的**透明呼吸区**。透明区根本不渲染,
    /// 它越出屏幕什么也看不见,拿它算"放不放得下"是算错了对象;更要命的是**呼吸区一旦把可用宽吃穿,
    /// 两条边界就反向**(lo > hi),`min(max())` 静默退化成"把右缘钉在 area.maxX - 12":
    ///
    ///   实测(14" MBP,屏宽 1512,6 扇窗 → 会话上限把 scale 收到 113.5%):
    ///     玻璃 1464 + 呼吸区 192 = 窗口 1656  >  可用 1488
    ///     → 窗口 x = -156,玻璃左缘 **-60**,右缘 1404(离屏右还白空 108)
    ///     → 最左那张卡左缘 -35:卡被切掉 35pt,托盘的左圆角与左边距整片出屏,右侧却对着空气
    ///
    /// 现在把约束换成玻璃:只要玻璃放得下(会话上限保证了这一点),**一定居中且不出屏**。
    private func previewFrame() -> NSRect? {
        guard expandedCount > 0, let panel, let area = contextScreen?.visibleFrame else { return nil }
        let size = previewSize()
        let contentW = previewContentSize().width
        let inset = (size.width - contentW) / 2 // 内容在窗口里的左右留白
        var x = panel.frame.midX - size.width / 2 // 内容居中 ⇒ 与长条同轴
        let margin = PanelMetrics.screenMargin
        if contentW <= area.width - margin * 2 {
            x = min(max(x, area.minX + margin - inset), area.maxX - margin - contentW - inset)
        } else if !trayOverflowLogged {
            trayOverflowLogged = true
            glog("[尺寸] 托盘玻璃 \(Int(contentW))pt > 可用 \(Int(area.width - margin * 2))pt,已居中(两端会被切)")
        }
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
        let before = previewPanel.frame
        // 单独记账:换选中时托盘的**卡片数**变了 → 窗口尺寸跟着变 → `setFrame` 是**同步**的窗口布局
        // (整块 tray 内容重排 + 后备存储重分配)。实机日志里 `[工] 键盘换选中 主线程 13–26ms`
        // 基本都出在这里,这会直接吃掉 1–1.5 帧 —— 入场上浮时再按一下 Tab 就"顿"一下
        traceCost("托盘改尺寸") {
            setFrameIfNeeded(previewPanel, frame)
        }
        if !previewPanel.isVisible { previewPanel.orderFrontRegardless() }
        // 帧变了 = 卡片在指针底下挪了位,必须自己重判一次(见 resyncSelectionUnderPointer 的病例)
        if previewPanel.frame != before { resyncSelectionUnderPointer() }
    }

    /// 视图在指针底下**自己挪位**时,SwiftUI 不会补发 hover(它只在指针移动时发声)→
    /// 选中态停在旧位置,用户读作"指针移过去了但选中不跟,要等一下"。
    ///
    /// 病例(2026-09-14,用户报"⌘Tab 起来后选多窗口 App,再移向对应窗口约 0.5s 延迟"):
    /// 日志里每一对 `hover 到窗` → `窗口选中(指针)` 都相差 **0ms**,说明我们处理零延迟;
    /// 而托盘**换组会换宽度**(1 扇 288pt、2 扇 540pt,各自按长条中线居中)→
    /// 卡片整体平移 ~126pt,比一张卡还宽 —— 指针其实已经骑在另一张卡上,
    /// 却没有任何事件告诉我们(手还在动,但一直落在"同一张卡"里)。
    ///
    /// 所以:尺寸变了之后,**自己按指针位置重判一次**,不依赖 hover。
    /// 长条(图标)不走这条路:本局 App 数不变,长条宽度就是常量,图标不会在指针底下来回挪。
    private func resyncSelectionUnderPointer() {
        guard isVisible, pointerHasSpoken() else { return } // 指针没挪过窝就别抢选中(与 hover 同一道闸)
        guard let g = currentGroup, g.windows.count > 1 else { return }
        let p = NSEvent.mouseLocation
        // 窗框 ≠ 玻璃(窗口按整局最大布局开,内容底部居中)→ 必须用内容矩形
        guard let glass = previewContentRect(), glass.contains(p) else { return }
        // 玻璃 → 内容:视图是 .padding(top: trayPadTop, horizontal: trayPadX, bottom: trayPadBottom),
        // 卡片那一横条因此从玻璃下沿 + trayPadBottom 起算
        let x = p.x - glass.minX - PanelMetrics.trayPadX
        let y = p.y - glass.minY - PanelMetrics.trayPadBottom
        guard x >= 0, y >= 0, y <= PanelMetrics.thumbH else { return }
        let pitch = PanelMetrics.thumbW + PanelMetrics.thumbGap
        let i = Int(x / pitch)
        guard i >= 0, i < g.windows.count, x - CGFloat(i) * pitch <= PanelMetrics.thumbW else { return }
        guard i != winIndex else { return }
        winIndex = i
        trace("[T6] 视图挪位后指针重定位(卡片): [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)")
    }

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        traceCost("键盘换选中") {
            appIndex = (appIndex + delta + groups.count) % groups.count
            winIndex = 0
            // 不动窗框:面板尺寸只跟 App 数量有关,选中移动不改尺寸(旧病见 setFrameIfNeeded)
            trace("[T6] 选中(键盘 Tab): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        }
    }

    /// 主线程耗时记账(GLANCE_TRACE=1)。与 FrameProbe 分工:这里量的是"同步阻塞了多久",
    /// 那里量的是"帧间隔有没有崩" —— 两者对上就是结论
    private static let traceOn = isTraceEnabled

    /// trace 灰度里的行也带毫秒时间戳(原来它用裸 print,复盘时对不上别的时间)
    private func trace(_ line: String) {
        guard Self.traceOn else { return }
        glog(line)
    }

    /// 主线程耗时记账。**两道阈值,平时也开着**(2026-09-15 改,借 AltTab `MainThreadStall` 的口径):
    ///   · trace 全开(诊断中)→ 超过 **2ms** 就报,细到能做对照;
    ///   · 平时 → 超过 **16ms(一帧)** 才报 —— 那才是"用户看得见"的门槛。
    ///
    /// 为什么平时也要开:以前它是 trace 灰度的,于是**只有我在调的时候才有账**,用户平时卡了没记录;
    /// 更要命的是"关掉 trace 之后到底还卡不卡"这件事**测不出来**(量尺跟着一起关了)。
    /// 代价:每次调用两次取表(约几十纳秒),不超阈值不打印。
    private func traceCost(_ label: String, _ body: () -> Void) {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        // 子账(名字以 "↳" 开头)在 trace 下**无条件打**:2026-09-15 拆 `指针换选中`(外层 12ms),
        // 三笔子账一笔都没露面 —— 因为各自都 <2ms 门槛。可"外层 12ms、三笔加起来不到 2ms"
        // 本身就是最有价值的线索 ✗,不该被门槛藏起来。
        let isSub = label.hasPrefix("  ↳")
        if isSub {
            guard isTraceEnabled else { return }
        } else {
            guard ms > (Self.traceOn ? 2.0 : 16.0) else { return }
        }
        glog(String(format: "[工] %@ 主线程 %.1fms", label, ms))
    }

    private func moveWindow(_ delta: Int) {
        // 权责冻结(用户拍板):App 移动归 Tab 与指针,←→ 只管展开层的窗;
        // 组内 ≤1 窗时 ←→ 无语义,静默吞掉
        let n = expandedCount
        guard n > 1 else { return }
        // 补记账(2026-09-15):日志里出现过一局 `长帧 4(6%)`,全部落在连按 ←→ 的那 3 秒里 ——
        // 而这条路径一直没有括号,是个黑盒。和 `键盘换选中` 同一口径,方便直接比。
        traceCost("窗口选中") {
            winIndex = (winIndex + delta + n) % n
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        }
        trace("[T6] 窗口选中(键盘 ←→): \(groups[appIndex].windows[winIndex].title)")
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
        // **选中即重拍**(force):应用内部的画面变化系统不发事件,只有"被显示"这一刻能抓住它
        Snapshotter.shared.precapture(g.windows, force: true)
        // (这里不再另打一行账:与 Snapshotter 的 `[T5]` 重复,而 print 自己就吃主线程时间)
    }

    /// 面板出现那一刻的指针位。"谁后动听谁的"的仲裁缺陷修复:
    /// 指针杵着不动 ≠ 指针动过——面板在指针底下撑开/展开层重排帧时,
    /// SwiftUI 会把静止悬停当成 hover 事件,把键盘刚移走的选中拽回来(实机现形:
    /// 面板开在指针下方时 ⌘Tab 移不动)。gate:指针自面板出现起没挪过窝,hover 一律不算数
    private var panelOpenPoint: CGPoint?
    /// "hover 被闸掉"这行账每局只打一次(见 hoverAllowedByGate)
    private var gateBlockedLogged = false

    private func pointerHasSpoken() -> Bool {
        guard let p = panelOpenPoint else { return true }
        let m = NSEvent.mouseLocation
        return abs(m.x - p.x) > 1 || abs(m.y - p.y) > 1
    }

    /// 同一道闸,但**被闸掉时记一笔**(每局一次)。
    ///
    /// 2026-09-14 病例:用户报"多窗口 App 的卡片,指针移上去焦点不跟随、点不动,得等一会"。
    /// 那种描述有两种完全不同的病因,而日志里当时只有"没反应"——
    ///   · hover 事件**根本没到**(窗口/层级/事件投递问题);
    ///   · 事件到了但**被这道闸吃了**(面板恰好开在指针下方)。
    /// 有了这一行,下次一看就知道是哪一种,不用猜(本仓库的老规矩:先让它可观测,再改)。
    private func hoverAllowedByGate() -> Bool {
        if pointerHasSpoken() { return true }
        if !gateBlockedLogged {
            gateBlockedLogged = true
            trace("[T6] 指针 hover 被闸掉(面板开在指针下方,指针还没挪窝)")
        }
        return false
    }

    /// hover 从 SwiftUI 直接进来;与键盘共写 appIndex/winIndex,天然"谁后动听谁的"
    func hoverApp(_ i: Int) {
        // 选中没变 = 同块地砖上挪指针,免工——onHover 每像素都发声,不设闸就是现拍风暴
        // (实机现形:日志被系统 QUARANTINED 截流)
        guard hoverAllowedByGate(), groups.indices.contains(i), i != appIndex else { return }
        traceCost("指针换选中") {
            // App 层原来没有这行账(窗口层一直有),于是"指针选中"和"键盘 Tab"在日志里长得一样——
            // 查"指针到底有没有动"时只能猜。口径与窗口层拉齐:括号里写明来源
            trace("[T6] 选中(指针 hover): [\(i + 1)/\(groups.count)] \(groups[i].appName)"
                  + "(共 \(groups[i].windows.count) 窗)")
            // 拆账(2026-09-15):`指针换选中` 中位 12ms × 123 次,是现在最大的主线程开销 ✗。
            // 第一轮只拆了"拍图 / 托盘更新",结果**两笔都没超过 2ms** —— 说明钱不在这两处 ✗,
            // 于是把仅剩的候选(两个 @Published 写入,会同步惊动整棵观察者)也单独记一笔。
            traceCost("  ↳写状态") { appIndex = i; winIndex = 0 }
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        }
    }

    func hoverWindow(_ i: Int) {
        guard i != winIndex else { return } // 同一格的重复 hover(指针每像素都发声)不进账
        // **到达**与**接受**分两行记:这一行证明"hover 事件到了",下一行证明"我们认了"。
        // 两行之间的时间差 = 我们这边的处理耗时;两行都晚 = 事件本身就投递晚了(窗口/层级/系统侧)
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] hover 到窗 [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)(闸:\(pointerHasSpoken() ? "开" : "关"))")
        }
        guard hoverAllowedByGate() else { return }
        winIndex = i
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] 窗口选中(指针): [\(i + 1)/\(g.windows.count)] \(g.appName) — \(g.windows[i].title)")
        }
    }

    // MARK: - 确认与放弃

    /// 松手不合面板(T10 毕业为设置面板正式项,UserDefaults key 不变):松手语义在
    /// 触发层处理(那边保持导航态、不发确认),这里只剩一件事——面板外点击是否免死
    private var pinPanelDebug: Bool { UserDefaults.standard.bool(forKey: "debug.pinPanelOnRelease") }

    // MARK: - T12 破坏性键盘操作(CONTEXT.md「破坏性键盘操作」:有键无钮)

    /// 名字是历史(最早只有退出/关窗/最小化):它实际管的是「面板里**直接对窗或 App 生效**的动作」。
    /// 后来进来的 zoom / fullscreen / hide 都**不改列表语义**,只是窗或 App 的状态变了 ——
    /// 所以它们统一走这条"动作 → 重枚举 → 留在原地"的路(Snapshotter.prune 只剪被处决的那扇)。
    private enum DestructiveOp { case quit, close, minimize, zoom, fullscreen, hide }

    /// 红绿灯按钮入口(T14):wid 反查组内位置后,走破坏性操作同一闸
    func closeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .close) }
    func minimizeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .minimize) }
    func zoomWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .zoom) }

    /// **乐观本地摘除** —— 这一条是病例逼出来的,别删:
    ///
    /// 病例(2026-09-14,用户报 H):"隐藏之后 App 还在 Switcher 栏上,松开 ⌥ 就把选中那个又唤起来了"。
    /// 根因不在 H 的语义,而在**时间**:`NSRunningApplication.hide()` / AX 的关闭、最小化都是
    /// **异步**的(隐藏与最小化都有 0.2–0.3s 动画,App 忙时更久),而 `refreshAfterAction()` 只等 0.18s
    /// 重新枚举 —— 那一瞬间系统里那扇窗**还看得见**,分组没变、选中还停在它上面,
    /// 于是松开 ⌥ 走 SLPS 前置,又把刚隐藏的 App 唤起来了(它只是"被隐藏",并没有消失)。
    ///
    /// 所以:发完动作**立刻**按我们已知的结果改本地列表(面板当帧就对上,选中当场被钳走),
    /// 真数据 0.18s 后再来核对。**只摘确定的**:zoom/fullscreen 不摘 ——
    /// 全屏是进出 Space(进入会离开本列表,退出又会回来),猜错方向反而会把窗摘没了。
    private func optimisticRemoval(_ op: DestructiveOp, in g: AppGroup) {
        // 注意 H **不走这里**(见 .hide:它只清窗、不摘组)
        var next: [AppGroup] = []
        for group in groups {
            guard group.pid == g.pid else { next.append(group); continue }
            switch op {
            case .quit:
                continue // 整组离开:App 真的没了
            case .hide:
                continue // 理论到不了(H 自己处理),留着只为穷尽枚举
            case .close, .minimize:
                // 关掉 / 最小化的那扇窗离开列表(最小化窗我们本来就不列);组空了就把组也去掉
                let keep = group.windows.enumerated().filter { $0.offset != winIndex }.map(\.element)
                if !keep.isEmpty { next.append(AppGroup(pid: group.pid, appName: group.appName,
                                                        bundleID: group.bundleID, windows: keep)) }
            case .zoom, .fullscreen:
                next.append(group) // 不摘(见上面的理由),等核对
            }
        }
        let before = groups.reduce(0) { $0 + $1.windows.count }
        let after = next.reduce(0) { $0 + $1.windows.count }
        guard next.count != groups.count || after != before else { return } // zoom/fullscreen:没摘,不必走这一趟
        trace("[T12] 本地先摘: \(groups.count) 个 App / \(before) 窗 → "
              + "\(next.count) 个 App / \(after) 窗")
        applyRefreshed(next, keepPID: nil, keepWin: winIndex)
    }

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
            glog("[T12] 退出应用: \(g.appName)")
            WindowFocuser.quitApp(pid: g.pid)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 最小化: \(g.appName) — \(w.title)")
            WindowFocuser.minimize(window: w)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .fullscreen:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T29] 全屏切换(F): \(g.appName) — \(w.title)")
            WindowFocuser.toggleFullscreen(window: w)
            // 全屏会**进出独立 Space**:窗可能整扇离开当前语境屏 → 必须重枚举(与 Z 不同)
            refreshAfterAction()
        case .hide:
            let ok = WindowFocuser.hideApp(pid: g.pid)
            hiddenPIDs.insert(g.pid)
            glog("[T29] 隐藏 App(H): \(g.appName) → hide()=\(ok ? "已受理" : "被拒绝")")
            // **不摘组**:图标留在原位,只把它的窗清空 —— 用户实报的首版做法(摘整组)会让整条栏
            // 重排两次("乱跳"),而他期望的是"位置不变,只是窗口消失了"。
            // 系统那边隐藏完之前,枚举仍会报出它的窗,所以 hiddenPIDs 还要压住这一段(见 mergeRefreshed)
            var next = groups
            if let i = next.firstIndex(where: { $0.pid == g.pid }) {
                let keep = next[i]
                next[i] = AppGroup(pid: keep.pid, appName: keep.appName,
                                   bundleID: keep.bundleID, windows: [])
            }
            applyList(next, keepPID: g.pid, keepWin: 0)
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
        applyList(mergeRefreshed(raw), keepPID: keepPID, keepWin: keepWin)
    }

    /// 一局之内**顺序冻结**:本局的 App 顺序在开局那一刻定下(开局那次才走 MRU 排序),
    /// 中途任何动作都只改"窗",不改"位"。
    ///
    /// 病例(2026-09-14 用户实报):H 之后图标先消失又出现,整条栏跟着重排 ——「乱跳」,
    /// 期望是「位置不变,只是窗口消失了」。根因就是重枚举后又**按 MRU 排了一遍**,
    /// 而动过手之后 MRU 必然变(刚碰过的 App 排到最前)。
    /// macOS 自己的行为也是这样:按住 ⌘ 期间顺序是死的,MRU 只在**开局**那一刻起作用。
    private func mergeRefreshed(_ raw: [AppGroup]) -> [AppGroup] {
        let fresh = WindowEnumerator.orderByMRU(raw) // 只用来决定"本局中途新冒出来的 App"排哪
        var byPID: [pid_t: AppGroup] = [:]
        for g in fresh { byPID[g.pid] = g }
        var merged: [AppGroup] = []
        var seen = Set<pid_t>()
        for old in groups {
            seen.insert(old.pid)
            if hiddenPIDs.contains(old.pid) {
                // 被我们隐藏:窗当帧就没了,但系统那边的重枚举这 0.2–0.3s 还在骗我们
                merged.append(AppGroup(pid: old.pid, appName: old.appName,
                                       bundleID: old.bundleID, windows: []))
            } else if let f = byPID[old.pid] {
                merged.append(f) // 位置不动,只换内容(窗多了少了都还在这格)
            }
            // 不在 fresh 里 = 这个 App 真的没了(退出)→ 丢掉
        }
        for g in fresh where !seen.contains(g.pid) && !hiddenPIDs.contains(g.pid) {
            merged.append(g) // 本局中途新出现的 App 挂到**尾部**:不插队,免得又跳一次
        }
        return merged
    }

    /// 列表落地(内容 → 屏幕):钳选中、剪缓存、重拍、重排长条与托盘。
    private func applyList(_ fresh: [AppGroup], keepPID: pid_t?, keepWin: Int) {
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
        Snapshotter.shared.precapture(shown, force: true)
        Snapshotter.shared.precapture(groups.flatMap { $0.windows }.filter { !shownIDs.contains($0.wid) })
        // App 数可能变了 → 长条尺寸变、托盘内容也换;两窗各自就位(banner 不滑)
        if let panel, let target = centerFrame(for: paddedSize()) {
            setFrameIfNeeded(panel, target)
        }
        updatePreview()
        print("[处决后] \(groups.count) 个 App,选中 [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
        trace("[T12] 处决后顺序 [\(groups.map(\.appName).joined(separator: " | "))]")
    }

    /// 确认 = 唯一的"生效"动作:聚焦选中的那一扇窗(CONTEXT.md「确认」)。
    /// 到达路径:未钉住时松 ⌥;钉住时 Enter。
    func confirmSelection() {
        guard groups.indices.contains(appIndex) else {
            dismiss(reason: "确认(空列表)")
            return
        }
        let g = groups[appIndex]
        // 被 H 隐藏的组:**不许**落到下面那条"无窗应用 = 激活"上 ——
        // 那正是用户实报的原 bug(松开 ⌥ 又把刚隐藏的 App 唤起来了)。本轮到此结束,什么都不动。
        if hiddenPIDs.contains(g.pid) {
            glog("[T29] 选中的组已被隐藏:本轮结束,不唤起它")
            dismiss(reason: "确认(已隐藏)")
            return
        }
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
    ///
    /// **两个监听都要装**(2026-09-15 病例:"点面板周围的空白区域不关闭"):
    /// - **全局**监听收"落到别的 App / 桌面"的点击;
    /// - **本地**监听收"落在我们**自己**窗口里"的点击 —— 透明呼吸区只是
    ///   `ClickThroughHostingView.hitTest` 返回 nil(不吃点击),但 AppKit 里这**不会**把事件转给下层
    ///   的 App ✗;面板又是 nonactivating,事件也不进任何 view ✗。于是这一格点击既不属于"别的 App"
    ///   (全局监听收不到),也没人处理 —— 直接掉在地上,用户看到的是"点空白处没反应"。
    /// 两者共用同一条判据 `OutsideClickRule`(纯核 + 单测)。
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        if pinPanelDebug { return }

        // 全局:别人的点击,吞不掉(全局监听没有返回值的权力)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dismissIfClickOutside()
            }
        }

        // 本地:自己窗口的点击(**能吞**)——点空白就是关面板,不该顺手把下层那个 App 也点开
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.dismissIfClickOutside() ? nil : event
        }
    }

    /// 判"这一下点击在不在面板外";在的话关面板并返回 true。判据见 `OutsideClickRule`:
    /// **判玻璃,不判窗口** —— 窗口比玻璃大(透明呼吸区),而托盘还可能按整局最大布局开得更大
    /// (以前把托盘的呼吸区当成"里",点红绿灯就被误关,2026-09-14 实机现形)。
    @discardableResult
    private func dismissIfClickOutside() -> Bool {
        guard let panel, isVisible else { return false }
        let point = NSEvent.mouseLocation
        let panelRect = panel.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
        guard OutsideClickRule.isOutside(point: point, panelContent: panelRect,
                                         trayContent: previewContentRect()) else { return false }
        dismiss(reason: "面板外点击,放弃")
        return true
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        localClickMonitor = nil
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
