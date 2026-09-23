import AppKit
import GlanceCore
import SwiftUI

/// 面板控制器:导航态状态机的唯一权威。
/// 出现(begin)→ 选中移动(next/prev/firstGroup/lastGroup/hover)→ 确认(confirm)/放弃(cancel),
/// 四状态无旁路。确认的真实聚焦在 T7 接 WindowFocuser,现在只打日志。
@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var groups: [AppGroup] = []
    @Published var appIndex = 0
    @Published var winIndex = 0
    @Published private(set) var isVisible = false
    /// 一局的不变量基线(开局时存;`SessionInvariants` 只读只报,不改行为 ✓)
    private var sessionBaseline: SessionSnapshot?
    /// 本局查过几次(防呆:不变量一旦违反会**每拍都报** ⇒ 只报第一次,免得刷屏 ✗)
    private var sessionFrameChecks = 0
    /// 本局开局时刻(开局 0.6s 内是"开门过程":窗口要经过 0x0 → 芯片 → 全量 两次布局 ⇒ 不比较 ✓)
    private var sessionOpenedAt: CFAbsoluteTime = 0
    /// 托盘窗的显隐状态机(懒建:窗口是 buildPreviewPanelIfNeeded 时才有的)
    private var trayChrome: ChromeWindow?
    /// 选中态动效的**上膛标识**:开局第一帧必须不上膛(否则会从上一局的残影位置滑过来)。
    /// 上面说的"上一局残影"只在 `puckEntersFromLeft = false`(承接模式)时才是**故意**的 ——
    /// 那种情况下上膛反而要提前,见 showPanel。
    @Published private(set) var selectionArmed = false
    /// 托底的入场偏移(纵向,内容坐标系,渐近到 0)。只在"从底部升起"模式下非零
    /// 本局托盘窗口开的**最大**内容尺寸(喂给 `TrayGeometry`,窗口尺寸由它算出)。
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

    /// 预截补拍的推迟量 = 入场弹簧的沉降时间。T86 起**整单都挪**:唤起零拍,所有补拍
    /// (显示组 force + 其余组 TTL)都发生在沉降之后 —— 见 `finishBegin` 的那段注释
    private static let recaptureDelay: Double = 0.45

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

    // MARK: 启动区(方案 E「入口槽」,T83;设计稿 design/启动区实验台.html,用户 2026-09-16 拍板)
    //
    // 未启动 App = Dock 常驻且没在跑的(「无窗应用」是**在跑没窗**,这是两个概念,别混)。
    // 它们不进主环 —— 主环是"切换的世界",一格 = 一个活跃 App;它们住在**入口槽后面的托盘里**:
    // 托盘本来就承载"选中格的内容"(活跃格 → 窗口卡,入口槽 → 启动图标行),零新增语法。
    // 常态下面板与今天一个像素不差(没有第二行);Tab 走到主环末尾再按一次 = 选中入口槽。
    /// Dock 常驻且未在跑的 App(每局 begin 时取一次,按 Dock 顺序)
    @Published private(set) var launchables: [DockAppsProvider.LaunchableApp] = []
    /// 入口槽被选中(托盘切到启动行)
    @Published private(set) var entrySelected = false
    /// 启动行内的选中下标(nil = 入口槽选中但还没进到行内某格)
    @Published private(set) var launchIndex: Int?
    /// T91:"换环到未启动"的意图(四指轻点专用)。
    /// 触发层那一发比后台枚举**先到**,名单还没装好 ⇒ 先记在这里,`finishBegin` 里兑现。
    private var pendingLaunchRing = false
    /// 意图的**出生时刻**。给意图加寿命是结构性兜底:它只可能活在"触发层比枚举先到"的那一瞬。
    /// 病例(2026-09-17,用户实报「启动之后唤起了一次, 后面就变成启动环了」)—— 症状=意图活了不止一瞬。
    /// 与其猜是哪条路漏了清,不如让**过期本身就等于丢弃**:这样无论漏清在哪,幽灵都活不过 1.5s。
    private var pendingLaunchAt: CFAbsoluteTime = 0
    private static let pendingMaxAge: Double = 1.5

    /// **名单还没到、手已经松了**的那一次确认(2026-09-22 用户实报「快速 cmd tab 连续切换, 偶尔换不起来」)。
    ///
    /// 病例(日志铁证):
    /// ```text
    /// [2125575ms] [tap] flagsChanged kc=55 down=true  state=idle
    /// [2125620ms] [tap] hotkey forward pressed …      → emit begin
    /// [2125668ms] [tap] flagsChanged kc=55 down=false … → emit confirm
    /// [2125668ms] [T6] 确认(空列表):面板关闭           ← 枚举(46–69ms)还没回来 ⇒ 什么都没换 ✗
    /// ```
    /// 枚举在**后台**跑(2026-09-22 之前就是:为了不卡 tap 回调 ✓),而"按下→松开"只要 40–60ms
    /// ⇒ 快速 ⌘Tab 会跑在名单前面 ✗ ⇒ 确认时 `groups` 还是空的 ✓
    /// 口径:**意图已经被接受,就必须执行** —— 先记下来,等名单落地(`finishBegin`)当场兑现 ✓
    /// (与 `pendingLaunchRing` 同款:触发层比枚举先到的那一瞬,只记意图 ✓)
    ///
    /// ⚠️ 这里**不能**顺手 `dismiss()`:那会 `beginGeneration += 1` ⇒ 枚举回来直接被丢弃 ✗
    ///    (所以这一局要留着等名单;万一名单永远不来,有 `confirmWaitWork` 兜底 ✓)
    private var confirmBeforeList = false
    /// 本局名单是否已落地(区分"还没到"与"真的空")✓
    private var listReady = false
    /// 等名单的兜底闹钟(见 `confirmBeforeList`)
    private var confirmWaitWork: DispatchWorkItem?

    /// 段切换的行进方向(见 `SegmentTravel`)。PanelView 靠它挑过渡:
    /// 沿环走 = 内容横滑,↓/↑ 跳段 = 淡切
    @Published private(set) var segmentTravel: SegmentTravel = .direct

    /// "换环进行中"的窗口(2026-09-22):托盘内容在换环那一拍要**当拍**换(与环的翻牌同步 ✓),
    /// 而 hover 换组时要**滑**(用户实报「hover app 托盘只会闪现, 没有滑动了」✓)。
    /// 用时间窗而不是开关:换环是同步一瞬间的事,没有"结束"回调可挂 ✓
    private var ringSwapUntil: CFAbsoluteTime = 0
    var isRingSwapInFlight: Bool { CFAbsoluteTimeGetCurrent() < ringSwapUntil }

    /// 启动行 hover 的**帧拍兜底**(与 SheenOverlay 同一哲学:非 key 窗口的事件投递靠不住
    /// —— 先"哑"后"迟钝"两次实咬 —— 每帧问一次全局指针位置,自己算格子,事件丢了也有帧拍)。
    /// 几何与 `hoverLaunchAt` 同源;由 PreviewPanelView 里的 TimelineView 每帧驱动,
    /// 只在启动区活着时跑。与逐格 onHover 并存:两边写同一个 launchIndex,等值守卫不抖。
    ///
    /// ⚠️ 本函数运行在 Canvas 的**绘制闭包**里(视图更新中)——**不许在这里直接写 @Published**,
    /// 否则 Runtime 警告 "Publishing changes from within view updates" 并引发布局递归
    /// (2026-09-16 实机两连:警告 + `-layoutSubtreeIfNeeded` 递归)。算好下标,异步一跳再落账。
    func pollLaunchHover() {
        guard entrySelected, isVisible, !launchables.isEmpty,
              let previewPanel, previewPanel.isVisible, !previewPanel.ignoresMouseEvents,
              let glass = previewContentRect() else { return }
        let p = NSEvent.mouseLocation
        guard glass.contains(p) else { return }
        let (rows, cols) = launchLayout(count: launchables.count)
        let rowH = PanelMetrics.icon + PanelMetrics.trayRowGap
        // 玻璃 → 内容:水平从 trayPadX − iconGap/2 起算(行两端负 padding),纵向自玻璃下沿 + trayPadBottom
        let x = p.x - glass.minX - PanelMetrics.trayPadX + PanelMetrics.iconGap / 2
        let yUp = p.y - (glass.minY + PanelMetrics.trayPadBottom)
        guard x >= 0, yUp >= 0 else { return }
        let c = max(0, min(cols - 1, RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap)))
        let r = max(0, min(max(rows - 1, 0), Int(yUp / rowH)))
        let i = r * cols + c
        guard launchables.indices.contains(i), i != launchIndex else { return }
        let hovered = i
        Task { @MainActor in
            // 异步一跳后核对:这一跳的间隙里可能已关面板/换局
            guard self.entrySelected, self.launchables.indices.contains(hovered) else { return }
            self.launchIndex = hovered
            trace("[T6] 启动区选中(帧拍): [\(hovered + 1)/\(self.launchables.count)] \(self.launchables[hovered].name)")
        }
    }
    /// 主环 hover 的**帧拍兜底**(与 pollLaunchHover / pollWindowHover 同一套哲学):非 key 窗口的
    /// 鼠标事件投递靠不住 —— 先"哑"后"迟钝"两次实咬,而主环此前只靠逐格 onHover,是三块里
    /// 唯一没有帧拍的。键盘操作必然让 strip 重渲染过,tracking area 哑掉,第一下 hover 被吞
    /// ⇒ 键盘→鼠标交接"慢半拍"(2026-09-18 用户实报)。每帧问一次全局指针位置、自己算格子:
    /// **指针动了 = 当帧接管**(事件一炮没到也接管);指针没动 = 闸还关着,键盘优先
    /// (见 panelOpenPoint —— 键盘唤起时鼠标恰好压在某格上,不许它抢选中)。
    /// 落账直接走 hoverApp(闸 / 等值守卫 / 拍图 / 托盘更新全在那边,不另立一本);
    /// 这里只做几何 + 等值预判 —— 每帧都进 hoverApp 会把 bumpIdle 的闲置计时天天清零,
    /// "指针停在面板上 = 永不闲置"是顺手改出来的语义,不是设计(见 bumpIdle)。
    func pollRingHover() {
        guard isVisible, hintText == nil,
              let panel, panel.isVisible, !panel.ignoresMouseEvents,
              let glass = panelContentRect() else { return }
        let p = samplePointer()   // 帧拍顺带采样指针位移(谁后动听谁的账本)
        guard glass.contains(p) else { return }
        // ★ **热区内缩**(2026-09-19 用户实报「碰到边边就选中」):hover 选中要求指针
        //   落在格子内缩后的中心区(见 pointerInRingHotZone);点按确认走点按手势不受影响。
        let x = p.x - glass.minX - ringContentLeftInset - PanelMetrics.rowPadX + PanelMetrics.iconGap / 2
        guard x >= 0 else { return }
        let i = RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap)
        guard pointerInRingHotZone(i) else { return }
        // 绘制闭包里**读**状态没问题(禁的是写),等值预判放同步侧:没变化连 Task 都不发
        let current = entrySelected ? (launchIndex ?? -1) : appIndex
        guard i != current else { return }
        let hovered = i
        Task { @MainActor in self.hoverApp(hovered, source: "帧拍 hover") }   // 异步一跳(病例见 pollLaunchHover 头注)
    }

    /// **指针帧拍的心跳**(2026-09-18 实测翻案):TimelineView(.animation) 在**静态窗口上不跳帧**
    /// —— macOS 不给静止的窗口排帧,所谓"每帧兜底"实际只在"有视图更新的那几拍"生效。
    /// 实测账:warp 挪指针后 300ms 内一次采样都没发生,直到下一次键盘动作触发重绘才补上
    /// —— 这就是"键盘操作完、鼠标接管慢半拍"的真身:兜底只在界面刚动过时活着,
    /// 而恰恰是"界面静止、指针开始动"的那一刻最需要它。
    /// 现在面板在台期间挂 60Hz 定时器,统一驱动主环与托盘的指针重定位;散场即停。
    private var hoverPollTimer: DispatchSourceTimer?

    private func startHoverPolling() {
        guard hoverPollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self, self.isVisible else { return }
            self.updateStripClickGate()   // Bug2:指针在托盘玻璃里就让长条对合成器隐身
            self.pollRingHover()
            self.resyncSelectionUnderPointer()
        }
        t.resume()
        hoverPollTimer = t
    }

    private func stopHoverPolling() {
        hoverPollTimer?.cancel()
        hoverPollTimer = nil
    }

    /// 启动区这局关了(设置开关/名单为空)—— 视图与键盘路径都靠它短路
    private var launchSectionEnabled: Bool { !launchables.isEmpty }

    /// **Tab 能不能进未启动段**(2026-09-18 用户要求,默认开)。关掉后 Tab/滚轮走到主环端点
    /// 就地折返(moveApp 的 else 分支照旧取模绕回),段只能靠 ↓/↑ 进出 —— 模型 C 的"逻辑一条环"
    /// 在这条开关下退化成"两条独立环"。滚轮走 handle(.next/.prev) 同路,自动跟着这个开关走
    private var tabEntersLaunchSection: Bool {
        UserDefaults.standard.object(forKey: Keys.panelTabEntersLaunchSection) as? Bool ?? true
    }

    // (2026-09-19)「悬停回退单」机制整段退役 —— 病例:四指/键盘进段后,指针不在面板上,
    // 0.12s 后段被它静默收掉,白名单 App 还没确认就回到主环(用户实报「白名单的 App 没办法启动」,
    // 日志:段内选中 → 半分钟后主环选中 → 确认,中间无任何段操作)。回退单是"入口槽 +
    // 悬停预览"时代的语义(指针离开启动区 = 用户不要了);模型 C 里段只能由 ↓/四指/Tab
    // **主动**进入,指针在不在面板上与段的生死无关 —— 段保持粘性,由 ↑/Tab/Esc/闲置超时收场。
    /// 本局内被 H 隐藏的 App。为什么要记:
    /// 隐藏是**异步**的(0.2–0.3s 动画),这期间重枚举**还看得见它的窗** ——
    /// 不记住的话,卡片会在 0.18s 后闪回来(用户实报:「先是消失了,然后又出现了」)。
    private var hiddenPIDs: Set<pid_t> = []

    /// 本局已被我们**退出**的 App(pid)。
    ///
    /// 和 hiddenPIDs 是**同一个病,换了个动作**:系统的 AX 窗口表在进程死透之前
    /// 那 0.2–0.3s 里仍然报得出它的窗,而 `mergeRefreshed` 对"重枚举里新出现的 App"
    /// 的处理是**挂到尾部**(不插队)—— 于是刚被处决的 App 在环尾复活。
    ///
    /// 病例(2026-09-16,用户实报):"cmd q 退出 app, 此时面板还没关闭, 就又出现在尾部了,
    /// 重新唤起面板后不再出现。" 日志一字不差:
    ///     [T12] 退出应用: zoom.us
    ///     [T12] 本地先摘: 8 个 App / 12 窗 → 7 个 App / 11 窗
    ///     [处决后] 7 个 App,选中 [2/7] 大象          ← 对了
    ///     [处决后] 8 个 App,选中 [2/8] 大象          ← 0.7s 后那次重枚举把它捞了回来
    ///     [T12] 处决后顺序 [… | DataGrip | zoom.us]   ← 复活的它挂在**末位**
    /// "重新唤起就没了"也对得上:新一局重新枚举,那时进程真的死透了 —— 所以这条记忆
    /// 只活一局(begin 里清空),不跨局。
    private var quitPIDs: Set<pid_t> = []

    /// 本局已被我们**关掉/最小化**的窗(CGWindowID),等着复核。
    ///
    /// 病例(2026-09-17,用户实报):"点击关闭之后, 面板没关闭, 就又出现了."
    /// 日志一字不差:`[T12] 关闭窗口: DataGrip — Confirm Exit` → `本地先摘 17 窗 → 16 窗`
    /// → 0.2s 后 `[处决后顺序]` 它又回来了,来回三次。
    /// **那扇窗是 App 自己的确认框**(modal alert),AX 的 close 对它无效 —— 它压根关不掉。
    /// 所以"先摘"必须像 `verifyQuit` 一样**复核**:真没了才留摘除的样子,还在就**放回原位**。
    private var purgedWIDs: Set<CGWindowID> = []
    /// **本局被我们缩小(Cmd+M)过的窗与 App**(2026-09-22 用户实报)。
    ///
    /// 病例:「唤起面板的时候, cmd m 会缩小, 这时候面板上的 app 是没变化的, 松开之后会立马把缩小的窗口
    ///   又换起来」✗ —— 最小化窗本来就不在列表里(`optimisticRemoval(.minimize)` ✓),但**组还在环里** ✓
    ///   ⇒ 松开时走 `confirmSelection` 的"无窗应用 ⇒ 激活它"那条路 ✗ ⇒ 刚缩下去的窗又被抬起来 ✓
    /// 这与当初 `H` 那个 bug **是同一个病**(「松开 ⌥ 又把刚隐藏的 App 唤起来了」✓)⇒ 照它的先例办:
    ///   **本局不许再唤醒它** ✓;顺带把 App 标记上(用户第 2 条诉求:标记被缩小收纳的 app ✓)
    /// ⚠️ **跨局常驻**(2026-09-22 用户第 2 条修正:「角标要常驻」✗ 只活一局是错的):
    /// 一扇窗被收进 Dock 之后,**只要它还在 Dock 里就该有记号** ✓ —— 与"这一局"无关 ✓
    /// ⇒ 记 `wid → pid`(pid 用来在 App 退出后剪掉 ✓,wid 用来认"还是那一扇窗" ✓)
    private var minimizedWIDs: [CGWindowID: pid_t] = [:]
    /// 环上要打"已收纳"记号的 App(由上面那张表推出来 ✓ —— 单一源 ✓)
    var minimizedPIDs: Set<pid_t> { Set(minimizedWIDs.values) }
    /// 让 `minimizedWIDs` 的变化**一定会**触发重绘(它是普通字典,不会自己 publish ✗)
    @Published private var marksRevision = 0
    /// 环上这枚图标该打什么记号 —— 判据在领域层(`PanelMarkPolicy` ✓),这里只喂两个事实 ✓
    ///
    /// ⚠️ 优先级 2026-09-22 反转过(用户:「又退回不可见的角标了, 不是遗照灰」✗):
    ///   原来"隐藏优先" ⇒ 一个 App 同时满足"有窗收在 Dock 里"与"系统说它 hidden"时,显示角标 ✗
    ///   而用户刚按的是 ⌘M,要看见的是"那扇窗收起来了" ⇒ **有收纳就显示灰** ✓
    func mark(for pid: pid_t) -> PanelMark? {
        PanelMarkPolicy.mark(hidden: hidingPIDs.contains(pid), tucked: minimizedPIDs.contains(pid))
    }

    /// **本局**被我们缩小过的 App —— 只给"松开时不许唤醒它"这条守卫用 ✓
    ///
    /// ⚠️ 它与上面那张**常驻**表是**两种寿命**,别混(2026-09-22 用户两条实报互相约束):
    ///   · ① 「cmd m 会缩小…松开之后会立马把缩小的窗口又换起来」✗ ⇒ 本局不许唤醒 ✓(否则那次缩小等于白按)
    ///   · ② 「关闭再唤起之后, 选中 app 拉不起窗口了」✗ ⇒ **另起一局**的确认必须能把它拉回来 ✓
    /// ⇒ 记号(视觉)常驻 ✓;守卫只活一局 ✓ —— 用户的手离开键盘之后再确认,就是"我要它回来" ✓
    private var sessionMinimizedPIDs: Set<pid_t> = []
    private var didObserveHiding = false

    /// 环上要打"已隐藏"记号的 App(**现读系统真实状态** ✓ ⇒ 只要还是 hide 就有记号 ✓,
    /// 自己从 Dock 点回来 ⇒ 记号自动消失 ✓ 不需要谁去清 ✗)
    @Published private(set) var hidingPIDs: Set<pid_t> = []

    // MARK: - 触发层入口

    func handle(_ action: HotkeyTapCenter.Action) {
        bumpIdle()
        noteKeyboardAction()   // 键盘发言:此后指针的旧位移不再有优先权(谁后动听谁)
        switch action {
        case .begin: begin(reverse: false)
        case .beginReverse: begin(reverse: true)
        case .next: moveApp(1)
        case .prev: moveApp(-1)
        case .firstGroup: jumpToGroupEdge(0)
        case .lastGroup: jumpToGroupEdge(groups.count - 1)
        case .enterLaunchRing: enterLaunchRing()
        case .leaveLaunchRing: leaveLaunchRing()
        case .cycleWindowPrev: moveWindow(-1)   // ` 循环窗口(与 ←/→ 分家)
        case .cycleWindowNext: moveWindow(1)
        case .pickWindow(let n):
            // 只在"当前 App 的窗口范围"内生效:越界 = 什么都不做
            // (跳到不存在的地方不该有副作用 —— 与"两端夹住、不环绕"同一个道理)
            // 启动区里数字键无语义(没有窗可选),静默吞掉
            guard !entrySelected,
                  groups.indices.contains(appIndex),
                  groups[appIndex].windows.indices.contains(n) else { return }
            winIndex = n
            trace("[T6] 窗口选中(键盘数字 \(n + 1)): \(groups[appIndex].windows[n].title)")
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

    // MARK: - T91 表一 ④:闲置超时(治"牛皮糖")

    /// 钉住的一局里 **3 秒没动静**就自己收。规格:`design/gesture-session-spec.md` 表一 ④。
    ///
    /// 用户原话:「三指/四指唤起的环, 只是在手指离开触摸板之后不会消失, 不代表有别的操作也不消失,
    /// 成牛皮糖了」。⇒ 判据很朴素:**用户在不在动它**。
    ///
    /// ⚠️ 只在"**触发键已经松开**"的局里计时:按住 ⌘Tab 时用户停下来看一眼是常态,
    /// 那不是"闲置",不该被收走。这个区分不需要问触发层 —— 直接看当前的修饰键。
    // MARK: - T91 表三:没有未启动的 App 时,说一句话(用户口径:文案要,但别盖图标、别闪)

    /// **说在长条自己那扇窗里,芯片形态** —— 环整条退场(opacity 0,当帧)、
    /// 窗口缩成 `hintContentSize` 那枚胶囊;文案结束 = 这一局**直接散场**。
    /// ⚠️ 三次错路记在这里,别再翻回去:
    ///   ① 文案以 overlay 压在环上 ⇒ 用户实拍「文案和环一起出现了」;
    ///   ② 环藏了,但文案结束后**又放环回来** ⇒ 「芯片消失, 环出来了, 不该出来」
    ///      ⇒ 正解是"文案结束即散场"(这一局本来就只为说一句话);
    ///   ③ 环的退场包在入场弹簧里 ⇒ 弹簧拖着 opacity 淡 ~0.3s,读作「环一闪而过」
    ///      ⇒ 说话局不带动画,第一帧就是成品芯片(2026-09-17)。
    /// 托盘**绝不参与**(守卫住在 previewFrame):托盘那本尺寸账与面板不同源,
    /// 上一版为显示文案去动它 ⇒ AppKit Update Constraints 布局递归,连触发层一起被带走。
    @Published private(set) var hintText: String?
    private var hintWork: DispatchWorkItem?

    private func showHint(_ text: String) {
        hintWork?.cancel()
        // ★ 不带动画(2026-09-17 修「环一闪而过」):
        // 原来包着入场弹簧 —— 环的退场(opacity 1→0)被弹簧拖住 ~0.3s,窗口上屏时环还
        // 几乎全亮地挂着再慢慢淡掉 ⇒ 用户看到的就是"环一闪而过"。这与上屏时机无关:
        // alpha 0 挡得住一帧,挡不住一整段弹簧。
        // 纪律与 2026-09-17 的入场裁定同一条(「不要动画,直接一步到位」):说话局的
        // 第一帧就是**成品芯片**,环当帧退场,不做渐变。
        hintText = text
        // 局中说话(按 ↓ 时名单空,面板已在台上):窗口跟着芯片缩,**同一拍** setFrame ——
        // 与 applyRingSwap 同一条"尺寸与内容同一拍"的路、同一本账(paddedSize 单一来源)。
        // 开局说话(四指那一发)面板还没上屏,showPanel 自己会落位,这里 isVisible 还没置 true,自然跳过
        if isVisible, let panel, let t = chipCenterFrame(for: paddedSize()) {
            setFrameIfNeeded(panel, t)
        }
        updatePreview()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 清账也不带动画:紧跟着就是散场(orderOut),这段动画没人看得见;
            // 留着只会让人以为"这里需要动效" —— 它不需要
            self.hintText = nil
            // ★ 文案结束 = 这一局结束:**散场**,不要让长条(环)回来 ——
            // 用户实拍第 2 张「芯片消失, 环出来了, 不该出来」。
            self.dismiss(reason: "文案结束(这一局只为说一句话)")
        }
        hintWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)   // 用户裁定:1 秒
    }

    private var idleWork: DispatchWorkItem?
    private static let idleLimit: Double = 3.0

    /// 任何"用户在动它"的动作都调它(键盘 / 指针 / 滚轮)。
    private func bumpIdle() {
        idleWork?.cancel()
        idleWork = nil
        let mods = NSEvent.modifierFlags
        guard !mods.contains(.option), !mods.contains(.command) else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.trace("[T91] 闲置 \(Int(Self.idleLimit))s 无操作 → 收面板")
            self.dismiss(reason: "闲置超时")
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit, execute: w)
    }

    // MARK: - 生命周期

    private func begin(reverse: Bool) {
        // ★ 连着快速 ⌘Tab:上一局那次"名单还没到"的确认还挂着 ⇒ **先兑现它**(一次按键 = 一次切换 ✓),
        //   否则那一发就白按了(用户实报的"偶尔换不起来"里有一部分就是这种叠加 ✓)
        if confirmBeforeList, listReady, !groups.isEmpty {
            confirmBeforeList = false
            confirmWaitWork?.cancel(); confirmWaitWork = nil
            glog("[T6] 新一局到来 ⇒ 先兑现上一局那一次确认")
            confirmSelection()      // 内部会 dismiss(收掉上一局)✓
        }
        confirmBeforeList = false
        confirmWaitWork?.cancel(); confirmWaitWork = nil
        listReady = false
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
        quitPIDs.removeAll()   // 同上:上一局处决过的 App,新一局以系统真实状态为准
        observeHidingChanges()  // 装一次即可(全局通知 ✓)—— 让"藏着"的角标当场跟上 ✓
        purgedWIDs.removeAll() // 同上:上一局被关/被最小化的窗
        // ★ "已收纳"的账**跨局保留**(用户 2026-09-22:「角标要常驻」✓)—— 只靠下面的自愈剪枝 ✓
        hidingPIDs.removeAll()          // 隐藏标记是现读系统的 ✓ 这里只是清掉上一帧的缓存
        sessionMinimizedPIDs.removeAll() // "不许唤醒"只活一局 ✓(记号常驻,守卫不常驻)
        // T91:换环意图只活一局。**只在它真的挂着时留账**(日志预算:常态两行,这里是例外才出声)
        if pendingLaunchRing { trace("[T91] 新一局:上一局的换环意图没兑现,丢掉") }
        pendingLaunchRing = false
        trayChrome?.beginSession()      // 新一局 ⇒ 重新允许托盘上屏(见 ChromeWindow.place 的病例 ✓)
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
        // ★ 落点排序要认**这块屏**(2026-09-22 病例:全局 MRU 会把另一块屏的"最近用过"
        //   带过来 ⇒ 落点跳到错误的 App ✗)。`contextScreen` 就是本局的屏(ADR-0001 ✓)
        groups = WindowEnumerator.orderByMRU(raw, on: screen ?? NSScreen.main ?? NSScreen.screens[0])
        // ★ 唤起**也要**剪一次记号(2026-09-22 用户实报「已经从缩率态回来了, 图标没有消失」的真因 ✓):
        //   剪枝原本只挂在 `applyRefreshed` 上 —— 而它只在我们**自己的动作后**才跑(⌘M/W/H ✓)。
        //   "从 Dock 把窗点回来"**不产生我们的任何动作** ✗ ⇒ 那条路根本没人剪 ✗
        //   ⇒ 局面重设的这一刻就是最好的机会(而且这里最便宜:一局一次 ✓)
        reconcileMinimizedMarks(raw)
        listReady = true
        // 启动区(方案 E):Dock 常驻 − 在跑的。**同步取** —— 长条宽度与托盘最大布局都依赖它,
        // 晚到 = 面板中途改尺寸(中途 setFrame 是 T76 之前那条老病,别回来)。
        // CFPreferences 读 + 解析是 1ms 级;图标首局逐个加载(几十 ms,一次性),之后走进程级缓存。
        // 新一局回到"主环第一格"的语义:上一局若停在启动区,这一局不带过去(主环才是本产品的主世界)
        entrySelected = false
        launchIndex = nil
        if UserDefaults.standard.object(forKey: Keys.panelShowLaunchables) as? Bool ?? true {
            // ⚠️ 2026-09-17 病例:除了 bundle id,**把 bundle 的路径也放进"在跑"的集合**。
            // 有些 Dock 常驻项取不到 bundleID(`DockApps.launchables` 里会退化成用 **path** 当 id),
            // 那时"在跑"的集合里只有 id ⇒ 两边**永远对不上** ⇒ 明明在跑的 App 也被列成"未启动"。
            // 用户实报:「app 全启动了, 但四指没有文案提示」—— 日志里正是 `未启动的 App(共 2 个)`。
            let runningApps = NSWorkspace.shared.runningApplications
            var running = Set(runningApps.compactMap(\.bundleIdentifier))
            running.formUnion(runningApps.compactMap { $0.bundleURL?.path })
            launchables = DockAppsProvider.launchables(excluding: running)
            // 诊断(只在真有名单时出声):把名字与 id 都打出来 —— 一眼能看出是谁、以及 id 退化没退化
            if isTraceEnabled, !launchables.isEmpty {
                trace("[T91] 未启动名单: " + launchables.map { "\($0.name)[\($0.id)]" }.joined(separator: " · "))
            }
        } else {
            launchables = []
        }
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
        let advanceOnOpen = UserDefaults.standard.object(forKey: Keys.switchAdvanceOnOpen) as? Bool ?? true
        // ★ 2026-09-15 三修:前两版都在"重排顺序"上找答案,都是错的(见 LandingRule 文档里的三段历史)。
        // 正解是什么都不做 —— MRU 原序天然就是原生的第一眼版式:
        //   第一格 = 当前 App(它在,但没被选中),第二格 = 上一个 App(高亮落这里 = 唤起即切换),
        //   往后走到最久没用的,绕回第一格时当前 App 才出现(普通取模自动给出这条环)。
        // 所以这里只算**下标**,不再 `swapAt`(v1)也不再左旋(v2)。
        // 托底**上一次画在哪一格**:视图是复用的,它就停在上局结束时的落点 ——
        // 入场动效要靠它判断"这一局托底到底会不会滑"(见 showPanel 的两条路)
        lastLandedIndex = appIndex
        SessionMarks.step("落点")
        // ★ 落点从"**当前 App 在哪一格**"算(2026-09-22 病例:第一格不一定是当前 App ✗ ⇒
        //   落点落到自己身上,用户按一下什么都没换 ✗)。顺序里的当前 App 用窗口表判 ✓
        let currentIdx = WindowEnumerator.frontmostPID(of: Set(groups.map(\.pid)))
            .flatMap { pid in groups.firstIndex { $0.pid == pid } } ?? 0
        appIndex = advanceOnOpen
            ? LandingRule.landingIndex(count: groups.count, from: currentIdx, reverse: reverse)
            : 0
        if isTraceEnabled {
            glog("[落点] 当前=第 \(currentIdx + 1) 格(\(groups.indices.contains(currentIdx) ? groups[currentIdx].appName : "?"))"
                 + " · 顺序 " + groups.prefix(4).map(\.appName).joined(separator: " > "))
        }
        // 落点这行**每次都打**:开关 × 正反向 × 环序有四种走法,只看"高亮在第几格"分不清是哪一种 ——
        // 下次再说"开关没生效",看这一行就够(第一格是不是当前 App、落点是不是上一个 App 一目了然)
        if groups.indices.contains(appIndex) {
            print("[落点] \(advanceOnOpen ? "唤起即切换" : "停在当前") · \(reverse ? "反向" : "正向")"
                  + " · [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
            trace("[T6] 落点顺序 [\(groups.map(\.appName).joined(separator: " | "))]")
        }
        winIndex = 0
        // ★ 上一发"手已经松了、名单还没到"的确认 ⇒ **就在这里兑现**(一次按键 = 一次切换 ✓)。
        //   放在预截/建窗**之前**:这一局的目的已经达成,不必再开面板、也不必白拍一批图 ✓
        if confirmBeforeList {
            confirmBeforeList = false
            confirmWaitWork?.cancel(); confirmWaitWork = nil
            let waited = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
            glog(String(format: "[T6] 名单晚到(等了 %.0fms)⇒ 兑现刚才那一次确认", waited))
            confirmSelection()
            return
        }
        // 缩略图缓存**剪枝而不是清场**(2026-09-14):上一局的图还留着,第一帧就有图可上屏,
        // 不再先闪一下"截图中…"。AltTab 也是这个路子 —— 缓存保活 + 后台刷新。
        // T87 v3 起剪枝改 `reapAlive()`(后台、全量保活):死窗条目本就不会被展示,
        // 同步剪枝真正服务的是内存与在途批次作废,都不需要同步;顺手修掉
        // "开局把别屏窗的图全扔了 ⇒ 换屏唤起闪『截图中…』"(用户实测病例)。
        let allWindows = groups.flatMap { $0.windows }
        Snapshotter.shared.reapAlive()
        // **正在显示的那一组排最前面**:卡片要等的就是它那一张。
        // 共 30 扇窗时串行拍完要一两秒,顺序直接决定"第一眼有没有图"
        let shown = groups.indices.contains(appIndex) ? groups[appIndex].windows : []
        let shownIDs = Set(shown.map(\.wid))
        // 两批预截**分流**(2026-09-16 用户裁决:"针对当前唤起选中的 app 实时填充,别的走异步替换")
        // → **T86 升级为"唤起零拍"**(用户裁决:"拍图跟唤起面板渲染能彻底做成异步的吗"):
        //
        //   · 开局**不发任何拍照单**:缓存的图(跨会话保活 + 关面板预拍 + 失焦预拍供着)
        //     第一帧直接上屏。T85 账:冷局首图 +416ms 全落在入场动画里;热局这条 force 单
        //     也是白拍 —— 图已在缓存,新图盖上肉眼看不出变化,反而多一次重绘。
        //
        //   · "显示即重拍"契约**整体挪到 +0.45s**(入场弹簧沉降之后),只挪时机不砍:
        //     其余组照旧 TTL 补拍;显示组照旧 force 重拍 —— 应用内部的变化(换主题/切文件)
        //     系统不发事件,仍要在"被显示"后抓一次,只是晚 0.45s,与"其余组"同一待遇。
        //
        //   · 头 0.45s 里卡片显示缓存旧图(跨会话保活 + 上局剪枝),不会闪"截图中…"。
        //     缓存缺失的窗(冷启动 sweep 没赶上/新开的窗)逐张回填(Snapshotter 已改
        //     逐张回主,单次合并 <1ms,不再有整批合并的爆发)。
        //
        // 世代守卫:中途开了新一局就作废这一单,免得与新一局的预截白拍两遍;
        // dismiss 自己会把 beginGeneration +1,所以"面板已关"也自动作废,不用另判 isVisible。
        let shownGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recaptureDelay) { [weak self] in
            guard let self, shownGeneration == self.beginGeneration else { return }
            Snapshotter.shared.precapture(allWindows.filter { !shownIDs.contains($0.wid) })
            Snapshotter.shared.precapture(shown, force: true)
        }
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
        // 启动行(方案 E)也是托盘的一种内容:它可能是本局**最大**的托盘(未启动比某组的窗多),
        // 不进 max 的话,选中入口槽那一下就会把托盘窗口撑到中途改尺寸
        if launchSectionEnabled {
            let c = previewContentSize(launchCount: launchables.count)
            trayMaxContentSize = NSSize(width: max(trayMaxContentSize.width, c.width),
                                        height: max(trayMaxContentSize.height, c.height))
        }
        // 动效在不在线,一眼可见(系统"减弱动态效果"会把弹簧静默压成淡入淡出)
        // 动效状态**只在变化时打**:它在一台机器上是常量,每局重印就是噪音
        if Self.lastMotionDescribe != MotionPolicy.describe {
            Self.lastMotionDescribe = MotionPolicy.describe
            print("[动效] \(MotionPolicy.describe)")
        }
        // ★ T91 表三:要是这一局只剩"一句话",必须在 showPanel **之前**就把环收掉 ——
        // 否则窗口会先按环的尺寸上屏一帧、再缩成芯片(用户实拍:「环闪了一下, 消失了, 然后又回来了」)。
        // 判据:这一次带着"换环意图",而名单是空的 ⇒ 没有可换之物 ⇒ 只说话。
        if pendingLaunchRing, launchables.isEmpty {
            pendingLaunchRing = false
            showHint("没有未启动的 App")
        }
        // ★ 四指**直入**未启动段(2026-09-18 用户裁定:「期望直接展示未启动环, 没有动效」):
        // 意图在 showPanel **之前**兑现 —— `entrySelected` 直接置好,showPanel 按段的尺寸开窗,
        // **第一帧就是未启动环**。曾经 showPanel 之后才 enterLaunchRing():先开主环、~90ms 后
        // 再带着同根变形换到段 —— 用户看到的就是"先闪一下主环,再变形"。
        // 这里刻意不走 setSegment:那是"面板已在台上"的换环路(带 setFrame/动画);开局直置
        // 状态,让 showPanel 的首次落位自己算对尺寸,天然零动效。
        if pendingLaunchRing {
            pendingLaunchRing = false
            let age = CFAbsoluteTimeGetCurrent() - pendingLaunchAt
            // 只兑现"刚发生"的意图。老到 1.5s 以上 = 它不可能是"比枚举先到"那一发
            // ⇒ 是漏清 ⇒ **丢掉**,面板留在主环(宁可这次不换环,也不接受"莫名其妙落在启动环")
            if age <= Self.pendingMaxAge {
                entrySelected = true
                launchIndex = nil
                trace(String(format: "[T91] 四指直入未启动段(等了 %.0fms,共 %d 个)",
                             age * 1000, launchables.count))
            } else {
                trace(String(format: "[T91] 换环意图已过期(%.1fs)—— 丢掉,面板留在主环", age))
            }
        }
        // (说话局"托盘绝不参与"的守卫住在 previewFrame —— 那是托盘上屏的唯一门口,
        //  这里打补丁拦不住 showPanel 末尾那次 updatePreview 的回拉)
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
        var worstAspects: [CGFloat] = []
        var worstN = 0
        var worstScale = CGFloat.greatestFiniteMagnitude
        for g in groups where !g.windows.isEmpty {
            let fit = trayFitScale(aspects: g.windows.map(\.aspect)).scale
            cap = min(cap, fit)
            if fit < worstScale {
                worstScale = fit
                worstN = g.windows.count
                worstAspects = g.windows.map(\.aspect)
            }
        }
        PanelMetrics.sessionCap = cap
        // 行/列要在**收紧之后**再算:列数取的是当前尺寸下能放几张,
        // 收紧前算出来的会是上一局的尺寸(日志里就会看到对不上的行 × 列)
        let worstLayout = trayLayout(widths: worstAspects.map { PanelMetrics.thumbWidth(aspect: $0) })
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
    private func trayFitScale(aspects: [CGFloat]) -> (scale: CGFloat, rows: Int, cols: Int) {
        guard !aspects.isEmpty else { return (.greatestFiniteMagnitude, 0, 0) }
        let saved = PanelMetrics.sessionCap
        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        let s = PanelMetrics.scale
        // 每行/每列在 1.0 倍下的占位(含间隙;末尾那一份间隙要减掉,所以 pad 里是减不是加)。
        // 卡宽随窗比例(T88):**必须在 ∞ 窗口内**由 aspect 推基准宽 —— 传入现成的宽
        // 会带着上一局的缩放,除回 s 也救不回来(k 是在取值那一刻生效的)
        // ★ 方案 A:缩放账的基准宽也走槽宽(**取基准宽里的最大值,一律同宽** ✓)
        //   否则"尺寸账"与"排布"口径不同 ⇒ 必然漂。必须在 ∞ 窗口内算(见上面注释)
        let slotBase = aspects.map { PanelMetrics.thumbWidth(aspect: $0) }.max() ?? PanelMetrics.thumbMinW
        let baseWidths = Array(repeating: slotBase, count: aspects.count)
        let padW = (PanelMetrics.trayPadX * 2 - PanelMetrics.thumbGap) / s
        let rowH = (PanelMetrics.thumbH + PanelMetrics.trayRowGap) / s
        let padH = (PanelMetrics.trayPadTop + PanelMetrics.trayPadBottom - PanelMetrics.trayRowGap) / s
        PanelMetrics.sessionCap = saved

        var best = (scale: CGFloat(0), rows: 1, cols: aspects.count)
        for r in 1...min(aspects.count, PanelMetrics.trayMaxRows) {
            let c = (aspects.count + r - 1) / r
            let fit = min(trayRoomW / (Self.maxRowWidth(baseWidths, rows: r, cols: c) + padW),
                          trayRoomH / (CGFloat(r) * rowH + padH))
            if fit > best.scale { best = (fit, r, c) }
        }
        return best
    }

    /// 给定行数与"按数量均分"的列数下,最宽那行的卡宽合计(含行内间隙,不含托盘内边)。
    /// 分布必须与 thumbGrid 的 HStack 完全一致(按数量均分、末行左对齐)—— 两处各算各的必然漂。
    /// 间隙取**取值那一刻**的 `thumbGap`:∞ 窗口内调用得基准值,正常 cap 下调用得缩放值,
    /// 与传入的 widths 口径自动一致
    /// 一组窗口的**卡片尺寸**(唯一来源:min(真窗, 上限) ⇒ `PanelMetrics.thumbSize`)。
    /// 行高不再有常量 —— 一行里最高的那张卡决定这一行的高度(卡片可大小不一,用户 2026-09-21 拍板)。
    // MARK: - 方案 A:槽位固定(2026-09-21 用户裁定)
    //
    // 病例(`[对位]` 实证):换组时行宽 195↔838 ⇒ 每张卡的 x = "前面那些卡的宽度之和" ✗
    //   ⇒ 你正看的卡**横着挪 200–300pt** ✗(用户原话:"不是窗框移动,是里面的快照移动了" ✓ 窗框确实没动 ✓)。
    // 口径:**卡仍按真窗比例画**(形状跟真窗走 ✓ 保住用户的设计 ✓),但它**占的槽位固定** = 本局最宽那张卡。
    //   ⇒ 换组时位置一个像素不动 ✓。代价:窄卡两侧留白(实测最窄 195 vs 最宽 274 ⇒ 左右各 ≈40pt ✓),
    //     且整行变宽 ⇒ 会话缩放比相应略降(卡片整体略小一点 ✓)。

    static func cardSizes(_ windows: [WindowRecord]) -> [CGSize] {
        windows.map { PanelMetrics.thumbSize(real: $0.bounds.size, aspect: $0.aspect) }
    }
    
    /// 分行后**每行的最大高度**(内容尺寸 / 命中判定 / 视图三处共用同一套数)
    /// 算式在 `GlanceCore.TrayGrid`(可单测);这里只把"这一局的尺子"喂进去。
    static func rowHeights(_ sizes: [CGSize], rows: Int, cols: Int) -> [CGFloat] {
        TrayGrid.rowHeights(sizes, rows: rows, cols: cols)
    }

    private static func maxRowWidth(_ widths: [CGFloat], rows: Int, cols: Int) -> CGFloat {
        TrayGrid.maxRowWidth(widths, rows: rows, cols: cols, gap: PanelMetrics.thumbGap)
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
    ///
    /// T88:卡宽随窗比例后不再有"每行等宽"的省事 —— 传入**缩放后的**每张卡宽
    /// (调用方在当前 cap 下用 `PanelMetrics.thumbWidth(aspect:)` 算好),
    /// 行数判定用"该分布下最宽那行"(`maxRowWidth`,分布与视图的 HStack 一致)
    func trayLayout(widths ws: [CGFloat]) -> (rows: Int, cols: Int) {
        TrayGrid.fitRows(widths: ws,
                         gap: PanelMetrics.thumbGap,
                         padW: PanelMetrics.trayPadX * 2 - PanelMetrics.thumbGap,
                         roomW: trayRoomW,
                         maxRows: PanelMetrics.trayMaxRows)
    }

    private func showPanel(beganAt: CFAbsoluteTime, enumerateMs: Double) {
        buildPanelIfNeeded()
        lastPointerMoveAt = 0                       // 开局面板底下的停驻不算"动过"(键盘=唤起者,后动)
        lastPointerSample = NSEvent.mouseLocation   // 从这一刻起采位移
        gateBlockedLogged = false
        startHoverPolling()
        trayOverflowLogged = false
        // 落位:说话局 = 芯片落**屏幕物理正中**(chipCenterFrame);正常召唤照旧 visibleFrame 居中
        let target = hintText != nil
            ? chipCenterFrame(for: paddedSize())
            : centerFrame(for: paddedSize())
        guard let panel, let target else { return }
        isVisible = true
        // ★ 一局的不变量基线(见 GlanceCore/SessionInvariants):开局存一份,**之后只比不改** ✓
        //   ★ 规则(冒烟三轮才定死):开局那 0.6s 内窗口要经过"0x0 → 芯片(552) → 全量(1259)"两次布局 ✗,
        //     那都是**开门过程**,不是"尺寸漂了" ⇒ 开局静默,0.6s 之后才开始比 ✓
        //     (真事故"634↔1509 当拍跳变"发生在**交互中**,远晚于 0.6s ⇒ 照样抓得住 ✓)
        sessionBaseline = SessionSnapshot(frameSize: .zero, ringWindowWidth: ringWindowWidth())
        sessionOpenedAt = CFAbsoluteTimeGetCurrent()
        sessionFrameChecks = 0
        trace(String(format: "[不变量] 开局基线:窗框 %.1fx%.1f / 环窗宽 %.1f",
                     panel.frame.width, panel.frame.height, ringWindowWidth()))
        // 退场演出期间关掉的事件耳,开新局要还回来
        panel.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        stripClickGateOn = false   // 与上一行同拍复位;闸的翻动交给 60Hz 帧拍
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
        // ⚡ 2026-09-17 用户裁定:「不要动画了, 直接一步到位吧。唤起面板就展示上浮之后的结果」。
        // 起点幅度给 **0** ⇒ 图标(上浮后的位置)/托底/托盘**第一帧就在终点**,入场动效整段消失。
        // 这也正是这个仓库最早的口径(见 PanelView 顶部注释:「⌘Tab 是效率动作, 面板要"已经在"」)——
        // 今晚从 0.16 → 0.11 → 0.08 → 0.03 一路提速都收不到"够快",答案是这段动画**根本不该有**。
        contentEntryRise = 0   // 不再是 entryFloatDistance
        // 把**这一次用的弹簧档位**写进日志 ✓(不然试完分不清刚才那个是哪个 ✗)
        trace("[T6] 入场:上浮(弹簧档 \(PanelMotion.entranceGearName))" + (willSlide
            ? " + 从上一格滑过来(托底 \(lastLandedIndex! + 1) → \(appIndex + 1))"
            : ""))

        // 入场动效在 SwiftUI 层(demo .switcher-wrap 的 scale .90→1 + 渐入),窗口只负责就位
        // ★★ 白光对策(不依赖"找出凶手",见 docs/白光排查记录.md):
        // 窗口先以 **alpha 0** 上屏 ⇒ 合成器会把这一帧**真的合成一次**(含材质),
        // 下一拍再拉到 1 ⇒ 用户看到的**第一帧**就是画好的内容,而不是"玻璃已上屏、内容还没到"。
        // ⚠️ 这不是入场动效(没有被看见的渐变):0→1 只隔一拍(~16ms),
        //    与"面板要已经在"这条纪律不冲突 —— 用户感知不到那一拍。
        panel.alphaValue = 0
        setFrameIfNeeded(panel, target)
        // ★★ T91:**先画这一帧,再上屏** —— 顺序反了就是那道白光。
        //
        // 病例(2026-09-17,用户实报「重启之后第一次唤起面板, 会闪一下, 有一道白光」):
        // 我们一直是"先 orderFront、内容后画"⇒ 屏幕上先出现一块**空的玻璃**
        // (浅色外观 + 材质 = 一道白光),下一帧才补上图标。
        // 它**不是帧率问题**:`[帧] … 长帧 0(0%)` —— 不卡,是顺序。所以帧探针抓不到,躲到现在。
        // `display()` 是同步的:在这里先把这一帧真画出来,窗口的**第一帧**就已经带着内容了。
        // 代价是几毫秒(本来就要画),换来"上屏即完整"。
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if isTraceEnabled { probeContentReady(panel) }   // 🔬 白光排查:上屏前量一次内容
        // ★★ T91 修「环一闪而过」(2026-09-17):说话局把上屏挪一拍。
        // hintText 与 orderFront 在同一拍里,SwiftUI 那一帧(芯片)还没提交进后备存储,
        // 先上屏的会是上一局画好的旧视图(环)。正常召唤仍走同步:**零延迟是常态的纪律**,
        // 只有"说话局"这个例外晚一拍 —— 那一局只是说一句话,16ms 没人感觉得到。
        // ⚠️ 散场守卫必须带:这一拍里若 dismiss 过,绝不能把已拆的窗再 orderFront 回来。
        if hintText != nil {
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.isVisible else { return }
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let panel else { return }
            panel.alphaValue = 1
            self?.bumpIdle()          // 表一 ④:从"看得见"那一刻开始计时
            // 🔬 连拍放在这里:拍的是"第一次被看见的那几帧",不是 alpha 0 的那几帧
            // ⚠️ 2026-09-21:重型探针**单独门禁**(原来只挂 `isTraceEnabled`)。
            // 病例:为了白光排查,这里一次唤起连抓 12 帧 `CGWindowListCreateImage`(单次 10–50ms ✗),
            // 而 debug.trace 一开它就一直在跑 ⇒ 唤起/早期交互的卡顿有它一份,还污染所有测量。
            // 纪律:重型诊断必须有自己的开关 + 默认关(见 AGENTS.md「诊断开关」)。
            if isTraceEnabled, DebugFlags.screenProbe {
                self?.probeShownFrames(panel)
            }
            // 🔬 120Hz 调查:面板上屏后做一次 A/B(只在 debug.hzProbe 打开时,一次性)
            if let hv = panel.contentView { HzCompare.shared.run(panelView: hv) }
            PanelScreen.update(self?.contextScreen)
        }
        // 打**延迟**而不是时间点:绝对时间戳对"这次慢不慢"毫无用处(上一版就栽在这),
        // 要看的是"从按键到上屏多少毫秒、其中枚举占多少"
        // **一次唤起的全部结算,一行**:语境屏 + App 数 + 按键→上屏(含枚举)。
        // 这三件事永远同时发生,原来占三行(`[T8]` / 面板出现 / `[T6] 按键→上屏`)
        print(String(format: "[唤起] %@, %d 个 App · 按键→上屏 %.0fms(枚举 %.0fms)· 缓存 %.1fMB/%d 张",
                     contextScreen?.localizedName ?? "?", groups.count,
                     (CFAbsoluteTimeGetCurrent() - beganAt) * 1000, enumerateMs,
                     Double(Snapshotter.shared.cacheMemoryBytes) / 1_048_576,
                     Snapshotter.shared.cache.count))
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
            // ★ 2026-09-22 用户实报「托盘冒头比 app 上浮快,等 app 上浮完成才能遮住它,不要让它露出来」:
            //   根因是**两者的运动不是同一种**——图标上浮是两根弹簧叠加
            //   (`contentEntryRise` 入场 + 自己的 `-iconLift` 选中),托盘只有入场这一根 ✗
            //   ⇒ 无论怎么对齐曲线,中间那几十毫秒都可能露 ✓
            //   ⇒ 结构性修法:**托盘比图标晚到**(图标先抬起来让开,托盘再上来 ⇒ 物理上不可能露 ✓)
            //   用已有的 `entryDelay`(0.06s),与"入场延迟"同一档参数 ✓
            // `MotionPolicy.animation` 是 `Animation?`(系统"减弱动态"时给 nil ⇒ 瞬时 ✓)
            if let rise = MotionPolicy.animation(PanelMotion.entrance) {
                withAnimation(rise.delay(PanelMotion.entryDelay)) { self.contentEntryRise = 0 }
            } else {
                self.contentEntryRise = 0
            }
        }
        // 帧间隔探针只在本轮导航态里跑(GLANCE_TRACE=1):面板退场时打一行结论
        if let hostingView { FrameProbe.shared.start(on: hostingView, label: "面板\(groups.count)App") }
        logRowAlignment("上屏")
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
    /// 🔬 对位笔(2026-09-21,查"换 app 时卡里的画面移了一下",**只在接外接屏时复现**):
    /// 窗口帧没变(已量 ✓),所以动的是**行在窗里的位置**。行是**居中**排的 ⇒
    /// 一换组(行宽变)⇒ 整行**左右平移** ✗ ⇒ 肉眼就是"错位/移动了一下" ✓(瞬时 ✓ 之后自动对齐 ✓)。
    /// 这一支把"窗宽 / 行宽 / 行原点"三个数一起写出来 ⇒ 一眼看出移了多少 ✓。
    /// 🔬 对位笔(2026-09-21,查"换 app 时卡里的画面移了一下",**只在接外接屏时复现**):
    /// 用户诉求(已确认):「选中 app 默认选中的就是第一个窗口,别的都有蒙层 ⇒
    /// **只要保证第一个容器里的卡片不动**就算解决」✓
    /// ⇒ 这一支直接报**屏幕绝对 x**:第一张卡(应当恒定 ✓)与第二张卡(应当随组变 ✓)。
    /// 口径:`窗左缘 + shadowPadPop + trayPadX`,再按槽宽/间隙推第二张。
    private func logRowAlignment(_ reason: String) {
        guard isTraceEnabled, let panel = previewPanel, let g = currentGroup else { return }
        let content = previewContentSize(for: g)
        let rowW = content.width - PanelMetrics.trayPadX * 2
        let f = panel.frame
        // 口径:居中(内容在托盘窗里居中)⇒ 第一张卡左缘 = 窗左缘 + (窗宽−行宽)/2 + 留白
        let x0 = (f.minX + (f.width - rowW) / 2 + PanelMetrics.shadowPadPop - PanelMetrics.shadowPadPop + PanelMetrics.trayPadX).rounded()
        let sizes = Self.cardSizes(g.windows)
        let x1 = sizes.first.map { first in (x0 + first.width + PanelMetrics.thumbGap).rounded() }
        let key = String(format: "%@|%.0f|%.0f", reason, x0, x1 ?? -1)
        guard lastRowAlignKey != key else { return }
        lastRowAlignKey = key
        glog(String(format: "[对位] %@ 托盘窗 %.0fx%.0f @%.0f,%.0f · 第一张卡屏幕x=%.0f(应恒定 ✓) · 第二张屏幕x=%.0f(应随组变 ✓) · 行宽 %.0f · app=%@",
                    reason, f.width, f.height, f.minX, f.minY, x0, x1 ?? -1, rowW, g.appName))
    }
    private var lastRowAlignKey: String = ""

    private func setFrameIfNeeded(_ panel: NSPanel, _ frame: NSRect?, caller: String = #function) {
        guard let frame, !panel.frame.nearlyEquals(frame) else { return }
        // ★★ 2026-09-21(分段计时抓到的最后一段账):`display: true` 会**当场**重绘 ✗
        //   ⇒ 实测 setFrame **9–12ms**(就是注释里那句"同步窗口布局 + 后备存储重分配"),
        //   而这一帧里滑块弹簧/图标上浮正在跑 ⇒ 掉帧。
        //   改成 `display: false`:尺寸照样立刻生效,但把重绘排到下一拍(不逼它当场画)✓
        // 只记"真的变了"的那些(托盘窗本该整局只变一次 ⇒ 一变就说明 trayMaxContentSize 的设计被绕过了)
        glog(String(format: "[窗框] %@(%@) %.1f,%.1f %.1fx%.1f → %.1f,%.1f %.1fx%.1f",
                    panel === previewPanel ? "托盘窗" : "主面板", caller,
                    panel.frame.origin.x, panel.frame.origin.y,
                    panel.frame.width, panel.frame.height,
                    frame.origin.x, frame.origin.y, frame.width, frame.height))
        panel.setFrame(frame, display: false)
        // ★ 一局的不变量:主面板的**尺寸**在整局内不许变(ADR-0006)——
        //   真事故:换环时窗框宽度 634 ↔ 1509 当拍跳变 ⇒ 用户看到"抖"(见 SessionInvariants 文件头)✗
        //   只对**主面板**断言:托盘窗的尺寸本来就随内容变 ✓(它由 paddedSize 的 ringWindowWidth 保证 ✓)
        //   ⚠️ 第二处假阳性(冒烟二轮抓到):开局那一步 `isVisible = true` 时窗口**还没布局** ⇒
        //      基线取成 0.0x0.0 ✗ ⇒ 首帧落地就被报成"尺寸变了" ✗
        //      ⇒ 基线为零尺寸时,把这一次当基线**补上**,不比较 ✓
        //   ⚠️ 排除 hintText(空名单"一枚芯片"态):那时 paddedSize 的宽度**本来就**取 c.width ✗
        //      ⇒ 芯片态进出不是违反 ✓(它自己是一种状态,不是"尺寸漂了")
        let settled = CFAbsoluteTimeGetCurrent() - sessionOpenedAt > 0.6 && hintText == nil
        if panel === self.panel, settled, var base = sessionBaseline, base.frameSize == .zero {
            base.frameSize = frame.size                                  // 第一帧"稳了"的尺寸 = 基线 ✓
            sessionBaseline = base
            trace(String(format: "[不变量] 基线=%0.1fx%.1f(开局静默后再取)", frame.width, frame.height))
        } else if panel === self.panel, settled, let base = sessionBaseline, sessionFrameChecks < 8 {
            sessionFrameChecks += 1
            let now = SessionSnapshot(frameSize: frame.size, ringWindowWidth: base.ringWindowWidth)
            for viol in SessionInvariants.violations(baseline: base, now: now) {
                glog("[不变量] ⚠️ \(viol)(caller=\(caller))")
            }
        }
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
    /// T91 表一 ⑤:别处有输入(非面板按键 / 面板外点击)⇒ 钉住的那一局自己收。
    /// 规格见 `design/gesture-session-spec.md` 表一 ⑤;理由写进日志,复盘时与"闲置超时"分得清。
    /// **起拖撤销**(2026-09-22):三指轻点与"三指起拖"在手指数据上无法区分 ✗,
    /// 触发层改为在生效后 0.3s 看一眼鼠标键 —— 真在拖东西就调这里收面板 ✓
    /// (与 `dismissForOutsideInput` 分开:日志里要能分清"用户点了别处"和"其实是拖动误触" ✓)
    func dismissAfterGestureMisfire() {
        guard isVisible else { return }
        trace("[指点按] 起拖撤销 ⇒ 收面板(这次唤起是拖拽误触)")
        dismiss(reason: "拖拽误触")
    }

    func dismissForOutsideInput() {
        guard isVisible else { return }
        trace("[T91] 别处有输入 → 收面板(表一 ⑤)")
        dismiss(reason: "别处输入")
    }

    private func dismiss(reason: String) {
        hintWork?.cancel(); hintWork = nil; hintText = nil
        idleWork?.cancel()   // 散场就把表撤掉(免得迟到的那一发对着已关的面板说话)
        idleWork = nil
        // 先把在途的 begin 作废:枚举搬后台之后,"括键比枚举先到"是能发生的 ——
        // 不拦的话枚举回来会把面板在放弃之后又冒出来
        beginGeneration &+= 1
        removeOutsideClickMonitor()
        entrySelected = false
        launchIndex = nil
        isVisible = false
        sessionBaseline = nil
        LivePreviewPool.shared.stopAll(reason: "面板关闭")
        // 关闭期间别再吃 hover / 点击(外面那圈透明呼吸区也在放事件)
        panel?.ignoresMouseEvents = true
        previewPanel?.ignoresMouseEvents = true
        stripClickGateOn = false   // 长条点击闸复位(下一局 showPanel 会重新按指针状态翻)
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
        // ★ 取证:收窗**之前**两扇窗各是什么状态(下次再看到"残留"时,这一行能分清
        //   是"有一扇本来就没收"还是"合成器把两次提交拆开了" ✓)
        trace("[T6] 收场:环 visible=\(panel?.isVisible ?? false) · 托 visible=\(previewPanel?.isVisible ?? false)")
        // 环与托盘**并进同一次 flush**(见 ChromeWindow.teardown 的病例 ✓)
        panel?.disableScreenUpdatesUntilFlush()
        panel?.orderOut(nil)
        // ★ 2026-09-21 修我自己引入的 bug:标记必须与 orderOut **成对**清掉。
        //   病例(用户实报「本次不显示预览窗了」):第一次收场把托盘 orderOut 了,而标记没清 ✗
        //   ⇒ 之后每一局都以为"它已经在台上" ⇒ **再也不 orderFront** ⇒ 托盘永不出现 ✓。
        //   ★ 这个坑现已由 ChromeWindow 从结构上消掉(placed/teardown 成对,写在同一个类里)✓
        trayChrome?.teardown()                       // 真的收窗 + 清账(与 place 配对)
        // ★ 兜底:0.25s 后再确认一次"托盘窗真下去了" —— 未知的迟到路径也不至于留窗 ✓
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isVisible, self.previewPanel?.isVisible == true else { return }
            glog("[T6] ⚠️ 收场后托盘窗还在台上 ⇒ 强制收掉(兜底)")
            self.previewPanel?.orderOut(nil)
        }
        panel?.ignoresMouseEvents = false
        previewPanel?.ignoresMouseEvents = false
        groups = []
        lastPointerSample = nil   // 结束采样:下一局第一帧不把跨局位移当成"指针动了"
        stopHoverPolling()
        teardown = nil
        onSessionEnd?()
        // **关面板预拍**(T86):窗一拆完,把当前屏幕状态全量拍一遍(TTL 过滤,谁新谁不拍)。
        // 此刻屏幕上就是用户刚看到的内容,拍的图对下一次唤起 100% 新鲜 —— 下次唤起第一帧
        // 全走缓存。延 0.25s 让拆窗收尾先落地;面板若已重开(快速连按)则跳过,新一局有自己的节奏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isVisible else { return }
            ThumbnailRefresher.shared.sweepAllScreens(reason: "关面板预拍")
        }
    }

    /// contextScreen 可视区正中出现(自家窗口的锚定纪律与引导窗一致)
    private func centerFrame(for size: NSSize) -> NSRect? {
        guard let area = contextScreen?.visibleFrame ?? contextScreen?.frame ?? NSScreen.main?.visibleFrame else { return nil }
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 芯片(说话局)的落位:**屏幕物理正中**,不计菜单栏与 Dock
    /// (2026-09-18 用户口径:「不在屏幕正中间,不管是哪款屏幕,都要相对居中」)。
    /// 为什么与 `centerFrame` 分两口:visibleFrame 的正中会跟着 Dock 的高度/横竖方向
    /// 偏出去几十 pt —— 大长条上看不出来,小芯片上非常显眼,而且每块屏偏得不一样。
    /// 环保持 visibleFrame 居中不动(用户从未对环的落位提过异议,别顺手改它)。
    private func chipCenterFrame(for size: NSSize) -> NSRect? {
        guard let f = contextScreen?.frame else { return nil }
        return NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 长条内容尺寸 = 图标 78 × n + 间距 6 + 左右缘 26;高 = 上下缘 22 + 图标 78
    /// 预览托盘不计入住——它是独立浮窗,中心正对选中 App 头顶
    /// T91:环里装什么,尺寸就跟什么走(两套)。尾格已撤 —— 入口改为键(↓/↑),不再占位
    func contentSize() -> NSSize {
        if hintText != nil { return PanelMetrics.hintContentSize }   // 表三:只剩那枚芯片
        // T91 **两套尺寸**(实验台 ③):环里装"已启动的 App 组"和装"未启动的 App"各一套,
        // 开局就能算(纯算术,按键那一刻只是查表)。用户裁定:「肯定计算两套尺寸效果会更好」——
        // "少的后面全空着"与"多的把图标挤小"两条路都不接受。
        // 数量少时**靠左**(与主环第一格对齐 ⇒ 读作"环短了"),格子尺寸与间距一个都不动。
        let w = ringContentWidth(launch: entrySelected)
        // 尾格(分割线 + 点阵)已随 T91 撤掉:入口靠键(↓),不再靠显眼的占位 ⇒ 不再留位
        return NSSize(width: w, height: PanelMetrics.rowPadY * 2 + PanelMetrics.icon)
    }

    /// 环内容在**玻璃**里的左缘(2026-09-22)。
    ///
    /// 病例:窗框宽度改成"两环更宽者"之后(为了换环不抖 ✓),**未启动环**比窗框窄 ⇒ 内容居中 ✓,
    ///   而命中区/帧拍仍在按"内容从玻璃左缘开始"算 ✗ ⇒ 整排选中**右移**,
    ///   用户实报:「目前未启动环指针 hover 选中的位置, 跟 app 是对不齐的」✓
    /// ⇒ 命中的横坐标必须**同时**扣掉这个居中偏移(主环偏移为 0 ⇒ 只有未启动环看得出 ✓)。
    private var ringContentLeftInset: CGFloat {
        let w = ringContentWidth(launch: entrySelected)
        return (ringWindowWidth() - w) / 2
    }

    /// 某一环的**内容宽**(纯算术,与 entrySelected 无关 ⇒ 可以随时问"另一环多宽")。
    private func ringContentWidth(launch: Bool) -> CGFloat {
        let count = CGFloat(max(launch ? launchables.count : groups.count, 1))
        let w = count * PanelMetrics.icon + max(count - 1, 0) * PanelMetrics.iconGap + PanelMetrics.rowPadX * 2
        return max(w, PanelMetrics.minStripWidth)
    }

    /// **一局的窗框宽度** = 两环里**更宽**的那个(2026-09-22 用户实报后定)。
    ///
    /// 病例:「上下切的时候,环有抖动…这不还是左右吗,从左边向右延伸出来的」+
    ///      「环是居中的,2 个环其中一个比另一个短的话,左端的延伸位置就会变化,很割裂」——
    ///   真因:窗框(= 玻璃)宽度**当拍**换成新环的宽度 ✗(634 ↔ 1509),而环是**居中**的 ⇒
    ///        左右两条边同时移动 ⇒ 读成"内容从左边长出来 / 左端在变" ✗ 且与内容动画不同拍 ⇒ 割裂 ✓
    /// 口径:**一局的窗框宽度是不变量**(与 ADR-0006「窗口尺寸是一局的不变量」同源 ✓)——
    ///        按两环更宽的那个开窗,换环只换**内容**(玻璃仍按各自环宽居中画 ✓),边缘一动不动 ✓
    /// 说话局(只剩芯片)不参与:那是"表三"的另一套尺寸,不跟环互换 ✓
    private func ringWindowWidth() -> CGFloat {
        max(ringContentWidth(launch: false), ringContentWidth(launch: true))
    }

    /// 🔬 首帧探针(T91「一道白光」排查)——只回答一个问题:**上屏那一刻,我们的内容画上去了没有。**
    ///
    /// 为什么需要它:这件事已经被三种方法试过都抓不到 ——
    ///   ① `[帧]` 帧率探针:它量的是"卡不卡",而白光**不卡**(`长帧 0(0%)`);
    ///   ② 肉眼+描述:只能描述现象("一排 app 上一条闪光"),定不到代码;
    ///   ③ `screencapture` 连拍:单次调用 200ms+,**追不上 16ms 的一帧**。
    ///
    /// 所以换一种问法:**不问"屏幕上闪过什么",问"我们交给屏幕的那一帧里有没有东西"**。
    /// 把当前 contentView 直接画进一张位图,量**顶部那条带**(图标上沿所在处,白光就闪在那里)的
    /// 平均亮度与标准差:
    ///   · mean 高 + σ 很小 ⇒ 那是一片**空的浅色**(内容还没画上 ⇒ 病在我们自己);
    ///   · σ 明显大      ⇒ 图标已经画上去了(病在合成器/材质那一帧 ⇒ 要去那边查)。
    ///
    /// 写在 `isTraceEnabled` 闸后:常态零开销。
    /// 🔬 上屏后连拍(2026-09-17 第四版,也是唯一有机会抓住"16ms 那一帧"的做法)。
    ///
    /// 前三版都错在**同一件事**上:量的是**图层**,不是**屏幕** ——
    /// 上屏前 SwiftUI 的内容还没提交进图层 ⇒ `cacheDisplay` / `layer.render` 每次都量到全 0
    /// (那是"没看见",不是"干净");动态色那版则证明颜色两次一样(不是它)。
    ///
    /// 这一版:上屏**之后**,用 `CGWindowListCreateImage` 取**我们自己的窗口**
    /// —— 与缩略图管线同一条路,权限早就有,拿到的是**合成器真正显示的东西**。
    /// 连抓 12 帧(每 4ms,覆盖上屏后 ~48ms)⇒ 屏幕上真闪过一条亮带,必然落在其中某一帧里。
    private func probeShownFrames(_ panel: NSPanel) {
        let wid = CGWindowID(panel.windowNumber)
        guard wid != 0 else { return }
        for i in 0..<12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.004) {
                guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                        [.boundsIgnoreFraming, .bestResolution]) else {
                    glog("[上屏探针] #\(i) 取不到图")
                    return
                }
                glog("[上屏探针] #\(i) " + Self.bandStats(img))
            }
        }
    }

    /// 取图片**顶部 15% 条带**的 mean/max(0…1)。白光就闪在图标那一排的上沿。
    private static func bandStats(_ img: CGImage) -> String {
        let w = 320, h = 64
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "ctx 失败" }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let bandH = max(ih * 0.15, 1)
        ctx.scaleBy(x: CGFloat(w) / iw, y: CGFloat(h) / bandH)
        ctx.translateBy(x: 0, y: -(ih - bandH))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        guard let data = ctx.data else { return "无数据" }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0.0, mx = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let l = (0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])) / 255.0
            sum += l; mx = max(mx, l)
        }
        return String(format: "mean=%.3f max=%.3f", sum / Double(w * h), mx)
    }

    private func probeContentReady(_ panel: NSPanel) {
        // 为什么改量**颜色本身**(2026-09-17,第三版探针):
        //   位图快照这条路已经走过两遍都瞎了 —— `cacheDisplay` 与 `layer.render` 在上屏前都拿到全 0,
        //   因为 SwiftUI 的内容那一刻**还没提交进图层**。那是"没看见",不是"干净"。
        //   而白光的假设是**颜色解析**:`glassLip`(玻璃边那道"软的受光唇")是**动态色**,
        //   浅色/深色各一套;进程起来后的**第一帧**里窗口外观还没落定 ⇒ 可能按**深色**解析 ⇒
        //   沿整条边一道亮线(用户原话:「一排 app 上很明显的一条闪光」);下一帧浅色生效 ⇒ 线消失。
        //   所以直接把这个值在**当前绘图外观**下解析出来打日志:第一次 vs 第二次,数值说话。
        var parts: [String] = []
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            let pairs: [(String, Color)] = [("lip", PanelColors.glassLip),
                                            ("top", PanelColors.glassTopEdge),
                                            ("inner", PanelColors.glassInner)]
            for (name, color) in pairs {
                let c = NSColor(color).usingColorSpace(.sRGB)
                parts.append(String(format: "%@=%.2f/%.2f/%.2f@%.2f", name,
                                    c?.redComponent ?? -1, c?.greenComponent ?? -1,
                                    c?.blueComponent ?? -1, c?.alphaComponent ?? -1))
            }
        }
        glog("[首帧探针] 动态色 @"
             + (panel.effectiveAppearance.name == .darkAqua ? "dark" : "light")
             + "  " + parts.joined(separator: "  "))
    }

    /// 窗口尺寸 = 内容 + 阴影呼吸区(四周 shadowPadStrip)。
    /// 必须与 PanelView 的 .padding(shadowPadStrip) 严格一致——两套尺寸账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    private func paddedSize() -> NSSize {
        let c = contentSize()
        let pad = PanelMetrics.shadowPadStrip * 2
        // ★ 宽度取"一局的窗框宽度"(两环更宽者)⇒ 换环时窗框/玻璃尺寸**一个字都不变** ✓
        //   (高度本来就没变:两环都是 icon 高 ✓)
        let w = hintText != nil ? c.width : ringWindowWidth()
        // ★ 断言"换环不改变窗框宽度"(2026-09-22 那个"抖"的根治手段,现在被钉住 ✓)
        if hintText == nil, let base = sessionBaseline, abs(w - base.ringWindowWidth) > SessionInvariants.tolerance {
            glog(String(format: "[不变量] ⚠️ 环窗口宽度变了 %.1f → %.1f(两环更宽者才是一局的不变量)", base.ringWindowWidth, w))
        }
        return NSSize(width: w + pad, height: c.height + pad)
    }

    // MARK: - 面板本体

    /// 面板窗预热(T86):两块玻璃(NSPanel + SwiftUI hosting)在启动后建好但不 orderFront ——
    /// 首局唤起的"开窗 80.4ms"(T85 实测)是两块窗的首次构建,在这里花掉就不占唤起那一拍。
    /// 只构建不显示:borderless + nonactivatingPanel,不 orderFront 就没有任何可见副作用。
    func prewarmPanels() {
        buildPanelIfNeeded()
        buildPreviewPanelIfNeeded()
        warmFirstFrame()
    }

    /// T91:把"**本次进程的第一帧**"提前在这里付掉。
    ///
    /// 病例(2026-09-17,用户实报「重启之后**第一次**唤起面板, 会闪一下, 有一道白光」——
    /// 注意"只在重启之后第一次"这个条件,它是冷启动的签名):
    ///   ① SwiftUI hosting view 的**首次布局**(窗口/图层第一次真正上屏才发生);
    ///   ② 图标 NSImage 的**首次解码**(NSImage 是懒解码的,第一次真画到屏幕上才解)。
    /// 平时这两笔看不见(窗口还没出来),而进程重启后的第一次唤起正好撞上它们 ⇒
    /// 玻璃先上屏、内容后到 ⇒ 屏幕上一块**空的白色玻璃** = 用户说的"一道白光"。
    ///
    /// 注意它**不是**帧率问题:`[帧] … 长帧 0(0%)` —— 不是卡了一帧,是那一帧画出来是空的。
    /// 所以帧探针抓不到它,这也是它躲到现在的原因。
    ///
    /// 做法:① 以 **alpha 0** 上屏一帧再收回去(0 就是 0,用户看不见任何东西,但布局真跑过了);
    ///      ② 把所有会用到的图标先**离屏解码**一次。
    /// 窗口本来就是 borderless + nonactivatingPanel,不上屏没有副作用;这一次上屏是完全透明的。
    private func warmFirstFrame() {
        guard let panel else { return }
        // ⚠️ 2026-09-17 修正:第一次写成"启动途中就 orderFrontRegardless" —— 实机 Console 里
        // 立刻出现三条 `unable to send initialization message … Attempting to send message using a
        // canceled session`(窗口服务/XPC 会话那时还没建好);而且**闪光依旧** ⇒ 那个动作既惹事又没用。
        // 现在两条都改了:① 等启动完成(0.4s)再跑;② **挪到屏幕外** + alpha 0(双保险 ——
        // 即使合成器真出了一帧,也不落在任何屏幕上)。
        // ⚠️ 2026-09-17 第二次修正 —— 记清楚这一前一后,别再翻回去:
        //   版本① 屏幕内 + alpha 0(一开始那样) ⇒ **用户报"没有闪光了"** ✓
        //   版本② 屏幕外 + 延迟 0.4s         ⇒ **用户报"闪光又出现了"** ✗
        // 中间我还把三条 XPC 日志算在它头上 ✗ —— 后来系统日志证明那是 `Df` 级别的**系统自述**
        // (`UIIntelligenceSupport` 自己建会话、自己 manually canceled),与我无关。
        // 教训:别把"同时发生"当因果,更别为一个不属于自己的噪音去改能治病的东西。
        // ⇒ 回到版本①:**在屏幕内**、alpha 0、上屏一帧(front)再收回(out)。
        // 材质(material)只有真正在屏幕上过一帧才会被合成,挪到屏幕外等于什么都没预热。
        for w in [panel, previewPanel].compactMap({ $0 }) {
            let savedAlpha = w.alphaValue
            w.alphaValue = 0
            w.orderFrontRegardless()
            w.orderOut(nil)
            w.alphaValue = savedAlpha
        }
        glog("[保温] 首帧合成已预热(屏幕内 + 全透明,用户看不见)")
        // 图标的首次解码 —— "白光"的另一半。列一份名单画一遍,解码就发生了
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in DockAppsProvider.launchables(excluding: running) { Self.decodeIcon(app.icon) }
        for app in NSWorkspace.shared.runningApplications {
            if let icon = app.icon { Self.decodeIcon(icon) }
        }
        glog("[保温] 首帧已预热(布局 + 图标解码)—— 冷启动的第一次唤起不再交这笔钱")
    }

    /// 把 NSImage 真正解码一次:画进一张 1pt 的离屏位图。
    /// 预热必须花在**启动时**,不能花在唤起那一帧 —— 这是这个仓库对"唤起要快"的一贯口径。
    private static func decodeIcon(_ image: NSImage) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// key 状态变化账(2026-09-19):验证「点托盘 → 长条丢 key → 玻璃变浅 + 首击被吞」的理论
    private func installKeyTransitionLogging() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                // `queue: .main` 只保证"送到主队列";闭包本身是 @Sendable ⇒
                // 读主线程隔离状态必须**显式**声明(否则两条 warning ✗)
                MainActor.assumeIsolated {
                    guard let w = note.object as? NSWindow, w is GlancePanel else { return }
                    let role = w == self.panel ? "长条" : w == self.previewPanel ? "托盘" : "其它"
                    glog("[T6] key 变化: \(name == NSWindow.didBecomeKeyNotification ? "获得" : "失去") → \(role)(win=\(w.windowNumber))")
                }
            }
        }
    }

    private func buildPanelIfNeeded() {
        installKeyTransitionLogging()
        guard panel == nil else { return }
        panel = makeChromePanel(keyable: false)
        let hosting = ClickThroughHostingView(rootView: PanelView(controller: self))
        hosting.pad = PanelMetrics.shadowPadStrip // 透明呼吸区不吃点击
        hosting.autoresizingMask = [.width, .height]
        panel!.contentView = hosting
        self.hostingView = hosting
    }

    private func makeChromePanel(keyable: Bool = true) -> NSPanel {
        let p = GlancePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.keyable = keyable
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // 阴影由 SwiftUI 层绘制
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.acceptsMouseMovedEvents = true // hover 即选中依赖它
        // ★ **点按不触发 key 分配**(2026-09-19 用户实报「指针选 A 的窗口,第一次点击没响应」):
        // 托盘不是 key 窗口,真鼠标第一击会被 AppKit 拿去"把托盘设成 key"而**不派发给视图**
        // (SwiftUI 内部视图不回 `acceptsFirstMouse`,宿主上的 override 管不到 deepest hit view),
        // 第二击托盘已是 key 才送达 —— 就是"得点两次"。`becomesKeyOnlyIfNeeded` 让点按
        // 直达视图,key 只在真正需要第一响应者的时刻才设置。合成 HID 点击绕过这套逻辑,
        // 所以我自动化复现不出来 —— 这次靠真机现场抓的。
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        // 2026-09-21 查证:`NSWindow` 上**没有** `maximumFramesPerSecond`(AppKit SDK 里不存在该属性)
        // ⇒ 之前"面板被锁在 60fps"的猜测**不成立**,已撤回。若之后要动刷新率,先确认真实 API 再改。
        return p
    }

    // MARK: - 预览浮窗(分容器构型:与主面板同皮不同窗,中心正对选中 App 头顶)

    private func buildPreviewPanelIfNeeded() {
        guard previewPanel == nil else { return }
        previewPanel = makeChromePanel(keyable: false)
        if let previewPanel { trayChrome = ChromeWindow(previewPanel) }
        // 托盘低一层:它向下的阴影尾会伸进长条的呼吸区,demo 里长条(后一个兄弟)盖住托盘阴影,
        // 托盘在上就会把那层灰纱糊到长条玻璃顶上——"黑影"换个地方复活
        // (2026-09-19 Bug2 期间做过"翻到长条前面"的判别实验,已还原:点击死区由
        // `updateStripClickGate` 的合成器闸解决,不需要动 z 序)
        previewPanel!.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        let hosting = ClickThroughHostingView(rootView: PreviewPanelView(controller: self, snapshotter: Snapshotter.shared))
        hosting.pad = PanelMetrics.shadowPadPop
        hosting.autoresizingMask = [.width, .height]
        previewPanel!.contentView = hosting
        previewHostingView = hosting
    }

    /// 托盘内容尺寸 = 题头行 + 一排 128 缩略图 + 内边(16/18/14)。
    /// 与 PreviewPanelView 的 .frame(previewContentSize) 同源。
    /// 带参数的版本给"本会期尺寸上限"用:它要量**所有组**里最宽的那个,而不是当前选中组。
    /// T88:卡宽随窗比例,尺寸按每张卡的实际宽算(不再有 count × 定尺的省事)
    func previewContentSize(for group: AppGroup?) -> NSSize {
        guard let group, !group.windows.isEmpty else { return .zero }
        let sizes = Self.cardSizes(group.windows)
        // 一行里的卡**按各自的真实宽**(形状随窗,ADR-0014)⇒ 尺寸账/排布/命中是同一把尺子
        let widths = sizes.map(\.width)
        let (rows, cols) = trayLayout(widths: widths)
        // 高度 = 各行最大卡高之和 + 行距(卡片大小不一 ⇒ 不能用"行数 × 常量" ✗)
        let rowH = Self.rowHeights(sizes, rows: rows, cols: cols)
        return NSSize(
            width: Self.maxRowWidth(widths, rows: rows, cols: cols) + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop
                + rowH.reduce(0, +) + max(CGFloat(max(rows, 1)) - 1, 0) * PanelMetrics.trayRowGap
                + PanelMetrics.trayPadBottom
        )
    }

    /// 启动行(方案 E v2)的托盘尺寸:**主环的图标节距**(icon + iconGap),不是窗口卡的壳 ——
    /// v1 借窗口卡壳被用户实评否决(「丑的要死」:一枚小图标浮在大灰卡上,空得难受)。
    /// v2 = 第二条主环,尺寸数学与主环同源
    func previewContentSize(launchCount n: Int) -> NSSize {
        guard n > 0 else { return .zero }
        let (rows, cols) = launchLayout(count: n)
        let c = CGFloat(cols)
        let r = CGFloat(max(rows, 1))
        return NSSize(
            width: c * PanelMetrics.pitch - PanelMetrics.iconGap
                + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop + r * PanelMetrics.icon
                + max(r - 1, 0) * PanelMetrics.trayRowGap + PanelMetrics.trayPadBottom
        )
    }

    /// 启动行的行 × 列:与 `trayLayout` 同一套"放得下的最少行数"逻辑,只是格距换成图标节距。
    /// (数学同源,不许各算各的 —— 同 trayLayout 头上的那条规矩)
    func launchLayout(count n: Int) -> (rows: Int, cols: Int) {
        TrayGrid.fitRows(count: n,
                         cellPitch: PanelMetrics.pitch,
                         padW: PanelMetrics.trayPadX * 2 - PanelMetrics.iconGap,
                         roomW: trayRoomW,
                         maxRows: PanelMetrics.trayMaxRows)
    }

    /// 当前托盘该显示的内容的尺寸(窗口卡 / 启动行,随选中格切换)
    func previewContentSize() -> NSSize {
        return entrySelected ? previewContentSize(launchCount: launchables.count) : previewContentSize(for: currentGroup)
    }

    /// 托盘窗几何的**唯一来源**(P0-2):尺寸与原点都在 `TrayGeometry` 里算,这里只负责喂输入。
    /// 原来这里有一份"窗口尺寸"的算法 —— 它与 `previewFrame()` 的 x、与视图的内容尺寸是三本账,
    /// 只要取整规则或取数来源差一点就互相改(实机:一局 100+ / 104 / 335 次重排)⇒ 已并入 TrayGeometry ✓。
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
        // 入口槽选中时托盘显示启动行,与"当前组有窗"互斥地撑起托盘 T91:换环后环里就是那些 App,托盘**收起**(它们没有窗可预览)。
        // ⚠️ 2026-09-17:说话时**不要**让托盘出现 —— 用户实拍「先出现了 2 个芯片」,
        // 而且托盘那本尺寸账与面板不同源 ⇒ 紧接着就是 Update Constraints 崩溃。
        // 芯片只由面板那一扇窗承担。
        //
        // ★ 守卫必须住在**这里**(2026-09-17 修「预览窗岿然不动」):说话局的 orderOut
        // 曾经写在 finishBegin 里,而 showPanel 末尾的 updatePreview() 会把它**再拉起来**
        // (托盘上屏的唯一入口就是 updatePreview → 这里)。补丁打在调用方 = 每个新调用点
        // 都会让 bug 复活;打在门口 = 谁来都出不去。
        // 🔬 调试键 debug.hideTray:整个托盘不出现(用来**单测纯环上浮**是否掉帧)。
        //   放在门口(与下面那批守卫同一处)—— 打在这里,任何调用方都绕不过去。
        //   `defaults write com.cheney12138.macswitcher debug.hideTray -bool true` / delete 即装回
        guard !DebugFlags.hideTray else { return nil }
        guard hintText == nil, !entrySelected, expandedCount > 0, let panel,
              let area = contextScreen?.visibleFrame else { return nil }
        // ★ P0-2:几何**只问一处**(TrayGeometry)。这里不再算尺寸/位置,也不做取整 ——
        //   取整规则(尺寸向上、原点向下)住在那个类型里,别处改了也不会分叉 ✓。
        let maxContent = trayMaxContentSize.width > 0 ? trayMaxContentSize : previewContentSize()
        let geo = TrayGeometry(maxContentSize: maxContent, panelFrame: panel.frame, screenArea: area)
        if maxContent.width > area.width - PanelMetrics.screenMargin * 2, !trayOverflowLogged {
            trayOverflowLogged = true
            glog("[尺寸] 托盘玻璃 \(Int(maxContent.width))pt > 可用 \(Int(area.width - PanelMetrics.screenMargin * 2))pt,已居中(两端会被切)")
        }
        return geo.frame
    }


    private func updatePreview() {
        // 🔬 分段计时(2026-09-21):"指针换选中 13–30ms"到底花在哪一段 —— 只在总量 >3ms 时打一行。
        //   病例:托盘更新平时 0.30ms ✓,但 176 个样本里 13 个 ≥10ms ✗;两个图像缓存都没干掉它 ⇒ 拆段量。
        let __t0 = CFAbsoluteTimeGetCurrent()
        var __prev = __t0
        var __segs: [String] = []
        func __mark(_ s: String) {
            let n = CFAbsoluteTimeGetCurrent()
            __segs.append(String(format: "%@ %.1fms", s, (n - __prev) * 1000))
            __prev = n
        }
        // ★ S1 接线:把"当前该活的窗口"交给流池(它只管起流收帧,不参与绘制)。
        //   选这里是因为 updatePreview 是**唤起 + 每次换 app/换窗**的唯一公共出口。
        // ★ 2026-09-21:「座」的模糊**预热门**。面板一开就把全环的窗在后台算一遍
        //   ⇒ 指针 hover 换 app 时一次都不用算(原来每换一次重算高斯模糊 ⇒ 主线程 12–24ms ✗)。
        //   注:缓存以"第一次拿到的快照"为准 —— 它只是一层**模糊**过的底,内容略有更新看不出来。
        // 卡片底图同样预缩放到"卡片像素尺寸"⇒ 托盘重建时不再 decode/缩放(见 CardImageCache)
        // 目标尺寸 = 卡片那套"不放大"的口径(与视图里的 imageBox 同一算法,免得预热出的图与绘制不一致)
        let shots = groups.flatMap { $0.windows }.compactMap { w -> (wid: CGWindowID, source: NSImage, target: CGSize)? in
            guard let img = Snapshotter.shared.cache[w.wid] else { return nil }
            let cardW = PanelMetrics.thumbWidth(aspect: w.aspect)
            let win = w.bounds.size
            let s = (win.width > 1 && win.height > 1)
                ? min(1, max(cardW / win.width, PanelMetrics.shotH / win.height)) : 1
            return (wid: w.wid, source: img,
                    target: CGSize(width: max(1, win.width * s), height: max(1, win.height * s)))
        }
        CardImageCache.shared.prewarm(shots)
        SeatImageCache.shared.prewarm(
            groups.flatMap { $0.windows }.compactMap { w in
                Snapshotter.shared.cache[w.wid].map { (wid: w.wid, source: $0) }
            }
        )
        __mark("预热")
        if !entrySelected {
            // ★★ 2026-09-21 修正(S1.2 → S1.3):**只预热"当前这一组"的窗口**,不再预热整个环。
            // 病历(用户实报「卡的,要死,不仅唤起切换不流畅,选中之后打开也会卡半秒」):
            //   预热整个环 ⇒ 一局起 **13 条**捕获会话 ✗ ⇒
            //     ① 开场:13×40ms 错峰起流 ≈ 520ms(唤起不流畅)
            //     ② 收场:13 条会话一起拆(系统级工作)⇒ **确认后卡半秒**(日志 `全部停流 … 共 13 条`)
            //     ③ 稳态:13 条在采 ⇒ 切换不流畅
            //   ⇒ 换来的只是"hover 到任意 app 都零延迟";而池本来就有 **5s keepAlive** ✓ ⇒
            //     在同一批 app 之间来回 hover 根本不会重启流 ✓ —— 那个收益**不需要**全环预热 ✓。
            //   代价:第一次进某个 app,卡片会先显示静默态(实测首帧 36–74ms)✓ 可接受。
            let items = (currentGroup?.windows ?? []).map { (wid: $0.wid, aspect: $0.aspect) }
            if items.isEmpty {
                LivePreviewPool.shared.stopAll(reason: "环里没有窗口")
            } else {
                // 选中的那一扇按用户档位,其余 5fps(成本 = 1×档位 + (N-1)×5fps)
            let sel = currentGroup?.windows.indices.contains(winIndex) == true
                ? currentGroup?.windows[winIndex].wid : nil
            LivePreviewPool.shared.sync(items, selected: sel)
            }
        } else {
            LivePreviewPool.shared.stopAll(reason: "入口槽选中(启停生活动)")
        }
        __mark("池")
        let __tf = CFAbsoluteTimeGetCurrent()
        guard let frame = previewFrame() else {
            // ★★ 2026-09-21 定版:**没内容也不要 orderOut**。
            //   病例(分段计时):`orderFront` 在 hover 途中被调用 **27/33 次** ✗,托盘窗重排 157 次 ✗
            //   —— 因为"没内容"(hover 到无窗应用 / 说话局)时我 orderOut 了它,下一个 app 又 orderFront ✗
            //   每次窗口排序 4–24ms,且都落在滑块弹簧正在跑的那一帧 ⇒ 掉帧。
            //   ⇒ 改用 **alpha 0 + 忽略鼠标**:窗口留在台上,显/隐只是图层属性(微秒级 ✓)。
            //   真正的 orderOut 只留在**整局收场**那一处(现在由 ChromeWindow 的 teardown 承担)。
            trayChrome?.setContentHidden(true)      // 内容隐藏 = 只改图层属性(不再收窗,见 ChromeWindow)
            return
        }
        __segs.append(String(format: "previewFrame %.1fms", (CFAbsoluteTimeGetCurrent() - __tf) * 1000))
        __prev = CFAbsoluteTimeGetCurrent()
        let __tb = CFAbsoluteTimeGetCurrent()
        buildPreviewPanelIfNeeded()
        __segs.append(String(format: "buildPanel %.1fms", (CFAbsoluteTimeGetCurrent() - __tb) * 1000))
        __prev = CFAbsoluteTimeGetCurrent()
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
        __mark("setFrame")
        // ★★ 2026-09-21 真凶(分段计时抓到):`orderFrontRegardless()` 在**每次 hover 更新**都被调用 ✗
        //   ⇒ AppKit 窗口排序 4–35ms/次 ✗(日志:[工] 托盘分段 … **orderFront 34.8**)。
        //   病因:用 `previewPanel.isVisible` 当"已经在台上"的判据 —— 在这套
        //   borderless + nonactivatingPanel + level=.popUpMenu 的组合上它**不可靠**(常常报 false),
        //   于是每次更新都重排一次窗口。⇒ 改为**自己记账**:上屏一次就记下,只有 orderOut 才清掉。
        trayChrome?.place()                          // 一整局只 orderFront 一次(其余靠 alpha)
        __mark("orderFront")
        // 帧变了 = 卡片在指针底下挪了位,必须自己重判一次(见 resyncSelectionUnderPointer 的病例)
        let __tr = CFAbsoluteTimeGetCurrent()
        if previewPanel.frame != before { resyncSelectionUnderPointer() }
        __segs.append(String(format: "resync %.1fms(调用了: %@)",
                             (CFAbsoluteTimeGetCurrent() - __tr) * 1000,
                             previewPanel.frame != before ? "是" : "否"))
        __prev = CFAbsoluteTimeGetCurrent()
        __mark("尾")
        let __total = (CFAbsoluteTimeGetCurrent() - __t0) * 1000
        if __total > 3 {
            glog(String(format: "[工] 托盘分段 共 %.1fms | %@", __total, __segs.joined(separator: " · ")))
        }
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
    ///
    /// ⚠️ 驱动方有**两处**(2026-09-18 起):① `updatePreview` 里窗框变化时补判一次(原有);
    /// ② PreviewPanelView thumbGrid 的**帧拍兜底**(与 pollLaunchHover 同一套 —— 托盘换内容后
    /// tracking area 哑掉、hover 事件丢失,正是用户实报「鼠标接管窗口选择慢半拍」的主因)。
    ///
    /// ⚠️ 2026-09-18 修**多行盲区**:原来 `y <= thumbH` 只认得第一行 —— 托盘两行以上时
    /// 第 2 行永远命不中。它以前只在窗框变化时被调一次、而 hover 事件平时兜着,所以没炸;
    /// 升级成每帧兜底后必须自己会走多行网格(行距 = 卡高 + 行隙,行内左对齐,
    /// 与 thumbGrid 的 VStack/HStack 同一分布)。
    private func resyncSelectionUnderPointer() {
        guard isVisible else { return }
        samplePointer()                                        // 托盘帧拍每帧路过:顺手采样指针位移
        guard pointerMayTakeOver() else { return }             // 键盘后动中,指针停着不许抢(与 hover 同一道闸)
        // 托盘两种内容(窗口卡 / 启动图标行)共用同一套卡壳几何,只有名单不同 —— 几何算一份
        let count: Int; let names: [String]
        if entrySelected {
            count = launchables.count; names = launchables.map(\.name)
        } else if let g = currentGroup {
            count = g.windows.count; names = g.windows.map(\.title)
        } else { return }
        // 同上:只有一格时也要能选中它(循环才需要 > 1)
        guard count > 0 else { return }
        let p = NSEvent.mouseLocation
        // 窗框 ≠ 玻璃(窗口按整局最大布局开,内容底部居中)→ 必须用内容矩形
        guard let glass = previewContentRect(), glass.contains(p) else { return }
        // 玻璃 → 内容:视图是 .padding(top: trayPadTop, horizontal: trayPadX, bottom: trayPadBottom),
        // 卡片那一横条因此从玻璃下沿 + trayPadBottom 起算
        let x = p.x - glass.minX - PanelMetrics.trayPadX
        let yUp = p.y - glass.minY - PanelMetrics.trayPadBottom
        guard x >= 0, yUp >= 0 else { return }
        if entrySelected {
            // 启动行:格距 = icon + iconGap,行距 = icon + trayRowGap(与 pollLaunchHover 同一套数学)
            let (rows, cols) = launchLayout(count: count)
            let r = min(max(rows, 1) - 1, Int(yUp / (PanelMetrics.icon + PanelMetrics.trayRowGap)))
            let i = r * cols + min(cols - 1, RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap))
            guard launchables.indices.contains(i), i != launchIndex else { return }
            bumpIdle()   // 帧拍选中了新格子 = 用户在动它(hover 事件哑掉时,这是"活着"的唯一证据)
            launchIndex = i
            // ★ 悬停触感(2026-09-22 用户实报「预览容器的 hover 没做震感吗」):
            //   托盘**实际走的是帧拍这条路**(逐格 `.onHover` 早就"实测会哑" ⇒ 见 hoverWindow 的注释),
            //   第一版把触感挂在 `hoverWindow` 里 ⇒ 等于挂在了用不到的那条路上 ✗
            //   托盘两种内容(窗口卡 / 启动图标行)都算"预览容器" ⇒ 同一个事件 ✓
            Haptics.fire(.hoverPreviewThumb)
            trace("[T6] 视图挪位后指针重定位(启动区): [\(i + 1)/\(count)] \(names[i])")
        } else {
            // 窗口卡:T88 卡宽随窗比例,按**每张卡的实际宽**走查命中;
            // 行的分布与 thumbGrid 的 VStack/HStack 完全一致(按数量均分、末行左对齐)
            guard let g = currentGroup else { return }
            let sizes = Self.cardSizes(g.windows)
            let widths = sizes.map(\.width)            // 与视图/尺寸账同一把尺子(不再走槽宽)
            let (rows, cols) = trayLayout(widths: widths)
            // 行高是"逐行最大卡高"(卡片大小不一)⇒ 不能用常量行距去整除 y ✗
            var r = 0
            var rowTop: CGFloat = 0
            let rowH = Self.rowHeights(sizes, rows: rows, cols: cols)
            for k in 0..<max(rows, 1) where yUp >= rowTop + rowH[k] + PanelMetrics.trayRowGap {
                rowTop += rowH[k] + PanelMetrics.trayRowGap
                r = k + 1
            }
            r = min(max(rows, 1) - 1, r)
            let start = r * cols
            let end = min(start + cols, widths.count)
            guard start < end else { return }
            var cursor: CGFloat = 0
            var hit: Int?
            for j in start..<end {
                let w = widths[j]
                if x < cursor + w { hit = j; break }
                cursor += w + PanelMetrics.thumbGap
            }
            guard let i = hit else {
                // 玻璃内但没命中卡片(点在 padding/行间隙):节流打一行,给"点击吞没"定位用
                if CFAbsoluteTimeGetCurrent() - Self.lastCardMissLog > 0.5 {
                    Self.lastCardMissLog = CFAbsoluteTimeGetCurrent()
                    trace("[T6] 卡片未命中 (x=\(Int(x)) yUp=\(Int(yUp)) 行=\(r) start=\(start) end=\(end))")
                }
                return
            }
            guard i != winIndex else { return }
            Haptics.fire(.hoverPreviewThumb)     // ★ 见上面启动行那一支的注释(托盘真正的 hover 路在这里 ✓)
            bumpIdle()   // 同上
            winIndex = i
            trace("[T6] 视图挪位后指针重定位(卡片): [\(i + 1)/\(count)] \(names[i])")
        }
    }

    nonisolated(unsafe) static var lastCardMissLog: CFAbsoluteTime = 0

    /// 帧拍兜底入口(与 `pollLaunchHover` 并排):窗口卡网格的**每帧**指针重定位。
    /// 为什么只做异步一跳:本函数跑在 Canvas 的绘制闭包里(视图更新中)——
    /// **不许在这里直接写 @Published**,否则 Runtime 警告 + `-layoutSubtreeIfNeeded`
    /// 布局递归(2026-09-16 实机两连的病例,见 pollLaunchHover 头上的注释)。
    /// 落账在 `resyncSelectionUnderPointer`,它自己带全部门卫(在台上 / 指针挪过窝 / 等值守卫)。
    func pollWindowHover() {
        Task { @MainActor in self.resyncSelectionUnderPointer() }
    }

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    /// 滚轮 / 双指滑动 = 面板里的「Tab」。事件由 **navTap** 转来(会话期才存在的那个 tap,
    /// 它把滚动吞掉,所以底下的 App 收不到),动作仍走 Tab 那条路(`handle(.next/.prev)`)。
    private var lastScrollAt: TimeInterval = 0
    /// 节流间隔**由设置里的"速度(次/秒)"算出**:interval = 1 / speed。
    /// 滑杆线性映射的是**速度**而不是间隔 —— 否则慢端几乎不动(两者是倒数关系)。
    /// 默认 10 次/秒 = 原来的 0.10s,升级后手感不变。
    private var scrollInterval: TimeInterval {
        let speed = UserDefaults.standard.object(forKey: Keys.panelScrollSpeed) as? Double ?? 10
        return 1.0 / max(3, min(20, speed))
    }

    /// 两条细节照抄 LumaRing 实测经验:惯性滚动不算一次操作;节流(一次滑动会送几十个事件)。
    /// 吞事件的部分在 navTap —— 这里只管"要不要动选中"。
    func handleScrollEvent(_ e: NSEvent) {
        bumpIdle()
        guard panel?.isVisible == true else { return }   // 双保险:面板不在就什么都不做
        // 设置开关(默认开)。用 object(forKey:) 取,而不是 bool(forKey:) —— 后者的
        // "没写过"和"写成 false"是同一个值,默认值就没法表达(与 switch.advanceOnOpen 同一处理)。
        guard UserDefaults.standard.object(forKey: Keys.switchScrollMovesSelection) as? Bool ?? true else { return }
        guard e.momentumPhase == [] else { return }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let d = abs(dy) >= abs(dx) ? dy : dx
        guard abs(d) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollAt > scrollInterval else { return }
        lastScrollAt = now
        trace("[T6] 选中(滚轮/双指滑): dx=\(Int(dx)) dy=\(Int(dy)) → \(d < 0 ? "下一组" : "上一组")")
        handle(d < 0 ? .next : .prev)
    }

    private func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        // ★ 键盘换选中也要打"选中变更"点(2026-09-21 修):原来只有指针 hover 会打 ⇒
        //   用户实报的复现是**「tab 切到大象那一拍掉帧」**,而这条路径**从不打点** ✗
        //   ⇒ 我们前几轮量到的长帧全是指针那一路的,压根没量到用户报的那一下 ✗✗
        FrameProbe.lastHoverMark = CACurrentMediaTime()
        traceCost("键盘换选中") {
            // 模型 C(ADR-0013):**逻辑上只有一条环** —— 主环走完 `Tab` 自然进入未启动段,
            // 未启动段走完接回主环;`⇧Tab` 反向对称。两条旧裁定(2026-09-16「不经 Tab 到达」、
            // spec 落地清单 #4)已随入口槽的死一起翻案,全程见 ADR-0013。
            // 段切换 = entrySelected 翻转 + applyRingSwap(尺寸/内容同一拍,实验台 ⑤);
            // 段内移动不碰窗框(与主环同一条纪律)。
            let backward = delta < 0
            if entrySelected {
                let n = launchables.count
                guard n > 0 else {              // 局中名单清空(最后一个也启动完了):段没了
                    appIndex = min(appIndex, groups.count - 1); winIndex = 0
                    setSegment(false, travel: .backward, launchIndex: nil)  // ↑ = 向上一环(反向滑)
                    trace("[T91] 段切换: 未启动名单已空 → 主环 [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
                    return
                }
                // launchIndex == nil(↓/四指刚进段还没选)时,nil 的语义是"站在段门口":
                // 正向 Tab 从第一格进,反向 ⇧Tab 从最后一格进 —— 而不是从段尾绕回主环!
                // 病例(2026-09-19):↓ 进段后按 Tab 被 cur = n-1 的兜底直接推出段,
                // 白名单 App 用键盘永远选不中 ⇒「没办法启动」。
                let cur = launchIndex ?? (backward ? n : -1)
                let next = cur + delta
                if next < 0 {                   // 段头反向
                    if tabEntersLaunchSection { // 设置开着 ⇒ 跨回主环最后一格 ✓
                        appIndex = groups.count - 1; winIndex = 0
                        setSegment(false, travel: .backward, launchIndex: nil)
                        trace("[T91] 段切换(⇧Tab): 未启动 → 主环 [\(groups.count)/\(groups.count)] \(groups[appIndex].appName)")
                    } else {                    // ★ 设置关着 ⇒ 不跨段,在**段内绕回**末格(与主环绕回同一种手感 ✓)
                        launchIndex = n - 1
                        trace("[T6] 选中(键盘 Tab): 未启动 [\(n)/\(n)] \(launchables[n - 1].name)(段内绕回)")
                    }
                } else if next >= n {           // 段尾正向
                    if tabEntersLaunchSection { // 设置开着 ⇒ 跨回主环第一格(绕环不断)✓
                        appIndex = 0; winIndex = 0
                        setSegment(false, travel: .forward, launchIndex: nil)
                        trace("[T91] 段切换(Tab): 未启动 → 主环 [1/\(groups.count)] \(groups[appIndex].appName)")
                    } else {                    // ★ 设置关着 ⇒ 段内绕回首格 ✓
                        launchIndex = 0
                        trace("[T6] 选中(键盘 Tab): 未启动 [1/\(n)] \(launchables[0].name)(段内绕回)")
                    }
                } else {
                    launchIndex = next
                    trace("[T6] 选中(键盘 Tab): 未启动 [\(next + 1)/\(n)] \(launchables[next].name)")
                }
            // ★ 2026-09-22 修「回得来、去不了」:门禁要**对称** ——
            //   用户口径:设置关着时 Tab **两个方向都不该跨段**(进出口交给 ↑/↓ 与四指 ✓)。
            //   而当时只有这一边挂了门禁、另一边从来没挂 ⇒ 才出现"去不了、回得来" ✗
            } else if !backward, appIndex == groups.count - 1, launchSectionEnabled, tabEntersLaunchSection {
                setSegment(true, travel: .forward, launchIndex: 0)
                trace("[T91] 段切换(Tab): 主环 → 未启动(选中 [1/\(launchables.count)] \(launchables[0].name))")
            } else if backward, appIndex == 0, launchSectionEnabled, tabEntersLaunchSection {
                setSegment(true, travel: .backward, launchIndex: launchables.count - 1)
                trace("[T91] 段切换(⇧Tab): 主环 → 未启动(选中 [\(launchables.count)/\(launchables.count)] \(launchables[launchables.count - 1].name))")
            } else {
                appIndex = (appIndex + delta + groups.count) % groups.count
                winIndex = 0
                // 不动窗框:面板尺寸只跟 App 数量有关,选中移动不改尺寸(旧病见 setFrameIfNeeded)
                trace("[T6] 选中(键盘 Tab): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
                traceCost("  ↳拍图") { refreshSnapshotForSelection() }
                traceCost("  ↳托盘更新") { updatePreview() }
            }
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
    /// 计时括号。**认父子关系**(2026-09-15 修):子账由父账自己汇总在一行里打出来。
    ///
    /// 为什么必须这样:上一版靠"日志里谁挨着谁"来配对父子 —— 而同一个标签(`指针换选中`)
    /// 在**三条路径**里都用了,于是解析时把 Tab 的子账配到了 hover 的外账上,得出"外层 12ms、
    /// 三笔子账加起来 0.2ms"这种自相矛盾的结论 ✗。现在子账挂在父账身上,顺序无关。
    private final class CostNode {
        let label: String
        let t0 = CFAbsoluteTimeGetCurrent()
        var children: [(String, Double)] = []
        init(_ label: String) { self.label = label }
    }
    nonisolated(unsafe) private static var costStack: [CostNode] = []   // 只在主线程用

    private func traceCost(_ label: String, _ body: () -> Void) {
        let node = CostNode(label)
        Self.costStack.append(node)
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - node.t0) * 1000
        Self.costStack.removeLast()
        if let parent = Self.costStack.indices.last {
            Self.costStack[parent].children.append((label.trimmingCharacters(in: .whitespaces), ms))
        }
        let isSub = label.hasPrefix("  ↳")
        if isSub { guard isTraceEnabled, !node.children.isEmpty || ms > 2 else { return } }
        else { guard ms > (Self.traceOn ? 2.0 : 16.0) else { return } }
        // 子账**并进父账同一行** —— 一次选中只占一行日志,而不是四行
        let kids = node.children.isEmpty ? ""
            : "(" + node.children.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: " · ") + ")"
        glog(String(format: "[工] %@ 主线程 %.1fms%@", label.trimmingCharacters(in: .whitespaces), ms, kids))
    }


    /// ←/→ = **跳到当前段最左 / 最右的一格**(用户 2026-09-15 重新设计,2026-09-18 推广到两段)。
    /// 为什么改:原来的 ←/→ 是"在当前 App 的窗口间移动",而这正是 ` 的职责 —— 功能重复;
    /// 走组的职责在 Tab。把 ←/→ 换成"跳到两端",是最便宜的一条效率提升(H/M/L 的心智)。
    private func jumpToGroupEdge(_ target: Int) {
        // ★ ←/→ 的语义对两段一视同仁(用户 2026-09-18:「左右的语义不要只服务启动环」):
        //   跳的就是**当前正在看的那一段**的两端 —— 主环里跳最左/最右 App,
        //   未启动段里跳行内最左/最右。曾经的实现让段内的 ←/→ 出段回主环,已经推翻。
        if entrySelected {
            // 段内跳:只挪高亮、不换窗框(与段内 Tab 同一条纪律)。
            //   ⚠️ 不能像旧版那样直接写 entrySelected = false 出段 —— 内容当帧换回主环、
            //   窗框还停在段的短尺寸上,整条环被挤在半截窗里(2026-09-18 用户实报)。
            let n = launchables.count
            guard n > 0 else { return }
            let targetIndex = target == 0 ? 0 : n - 1
            guard launchIndex != targetIndex else { return }   // 已在那一端 = 夹住,不环绕
            launchIndex = targetIndex
            trace("[T6] 选中(键盘 " + (target == 0 ? "←=最左" : "→=最右") + "): 未启动 [\(targetIndex + 1)/\(n)] \(launchables[targetIndex].name)")
            return
        }
        guard groups.indices.contains(target), target != appIndex else { return }   // 两端 = 夹住,不环绕
        launchIndex = nil
        appIndex = target
        winIndex = 0                       // 落到目标 App 的第一扇窗,可预测
        trace("[T6] 选中(键盘 " + (target == 0 ? "←=最左" : "→=最右") + "): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
    }

    private func moveWindow(_ delta: Int) {
        // 权责冻结(用户拍板):App 移动归 Tab 与指针,←→ 只管展开层的窗;
        // 组内 ≤1 窗时 ←→ 无语义,静默吞掉
        let n = expandedCount
        // 启动行有它自己的"窗"序列:` = 行内循环(与主环的 ` 同一个心智:在当前位置前后挪一格)。
        // 用户实报「未启动的app不能用`切换选中」—— 启动行的成员本来就是**它自己的内容**,
        // 拿"它不是窗"把它挡掉是把代码的分类当成了用户的分类。
        if entrySelected {
            let m = launchables.count
            // ⚠️ 不能写 m > 1:只剩一个待启动 App 时(用户实报),` 会被直接 return 掉,
            // launchIndex 永远停在 nil ⇒ 那一格**无法被选中**。循环需要 2 个以上,
            // 但"选中"只需要 1 个 —— 这两件事不是同一件。
            guard m > 0 else { return }
            if m == 1 { launchIndex = 0; trace("[T6] 启动行选中(`): [1/1] \(launchables[0].name)"); return }
            // launchIndex == nil(只在入口槽、还没进到行里)时,第一下 ` 落到第一格;
            // 否则按 delta 在行内循环,两个方向都取正模
            let cur = launchIndex
            let next = cur == nil ? 0 : (((cur! + delta) % m) + m) % m
            launchIndex = next
            trace("[T6] 启动行选中(`): [\(next + 1)/\(m)] \(launchables[next].name)")
            return
        }
        guard n > 1 else { return }
        // 补记账(2026-09-15):日志里出现过一局 `长帧 4(6%)`,全部落在连按 ←→ 的那 3 秒里 ——
        // 而这条路径一直没有括号,是个黑盒。和 `键盘换选中` 同一口径,方便直接比。
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // 同"键盘换选中":选中一变就打点
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

    /// **谁后动听谁**的仲裁账本(2026-09-18 用户口径:「就看谁在活跃」):
    ///   · `lastKeyAt` = 键盘最近一次发言(唤起 + 每个导航动作);
    ///   · `lastPointerMoveAt` = 指针最近一次**真实位移**;
    ///   · `lastPointerSample` = 上一帧指针位(采位移用)。
    /// 指针可否接管 = 指针比键盘后动。曾经口径是"指针自面板出现起挪没挪过窝"
    /// (panelOpenPoint + 1pt 阈值),有两个结构性缺陷,都被实机咬到:
    ///   ① 阈值太脆,亚像素抖动就能把闸**永久**打开 —— 之后键盘连按 Tab,指针杵着
    ///      照样抢选中(实测:Tab 后 11ms 帧拍把选中抢回指针压着的格子);
    ///   ② 只有"开/关"两态,表达不了"指针动过、又停下、键盘接着操作"的交替 ——
    ///      键盘操作完,指针想接管还得靠"它恰好没在面板出现时压在玻璃上"这个运气。
    /// 位移阈值 2pt:手搭在鼠标上的传感器抖动远低于此,真实的"动一下"远高于此
    private var lastKeyAt: CFAbsoluteTime = 0
    private var lastPointerMoveAt: CFAbsoluteTime = 0
    private var lastPointerSample: CGPoint?
    private static let pointerMoveThreshold: CGFloat = 2
    /// "hover 被闸掉"这行账每局只打一次(见 hoverAllowedByGate)
    private var gateBlockedLogged = false

    /// 每帧采一次指针位移,返回当前位置。位移过门槛 = 指针"发言"了(拿到接管权)。
    /// 采样点:主环帧拍 + 托盘指针重定位 —— 两条帧拍路各 60Hz,足够密
    @discardableResult
    private func samplePointer() -> CGPoint {
        let p = NSEvent.mouseLocation
        if let s = lastPointerSample,
           abs(p.x - s.x) > Self.pointerMoveThreshold || abs(p.y - s.y) > Self.pointerMoveThreshold {
            lastPointerMoveAt = CFAbsoluteTimeGetCurrent()
            if isTraceEnabled {
                glog(String(format: "[闸] 指针位移 → 发言(%.0f,%.0f)", p.x, p.y))
            }
        }
        lastPointerSample = p
        return p
    }

    /// 键盘发言:唤起与每个导航动作都算。键盘刚动过 ⇒ 指针此前的位移不再有优先权
    private func noteKeyboardAction() {
        lastKeyAt = CFAbsoluteTimeGetCurrent()
    }

    /// 鼠标**点击**也是指针发言(点格选中/确认不走位移采样 —— 点击本身没有位移)
    private func notePointerClick() {
        lastPointerMoveAt = CFAbsoluteTimeGetCurrent()
    }

    /// 指针此刻可否接管选中 = **指针比键盘后动**。
    /// 面板开在停着的指针下方:键盘(唤起)必然后动 ⇒ 闸关着,指针不许抢(⌘Tab 移得动);
    /// 指针一动 ⇒ 指针后动 ⇒ 当帧接管 ——「但凡鼠标动了,就必须要立马响应」
    private func pointerMayTakeOver() -> Bool {
        lastPointerMoveAt >= lastKeyAt
    }

    /// 同一道闸,但**被闸掉时记一笔**(每局一次)。
    ///
    /// 2026-09-14 病例:用户报"多窗口 App 的卡片,指针移上去焦点不跟随、点不动,得等一会"。
    /// 那种描述有两种完全不同的病因,而日志里当时只有"没反应"——
    ///   · hover 事件**根本没到**(窗口/层级/事件投递问题);
    ///   · 事件到了但**被这道闸吃了**(面板恰好开在指针下方)。
    /// 有了这一行,下次一看就知道是哪一种,不用猜(本仓库的老规矩:先让它可观测,再改)。
    private func hoverAllowedByGate() -> Bool {
        if pointerMayTakeOver() { return true }
        if !gateBlockedLogged {
            gateBlockedLogged = true
            trace("[T6] 指针 hover 被闸掉(键盘比指针后动 —— 指针停着,不许抢选中)")
        }
        return false
    }

    /// hover 从 SwiftUI 直接进来;与键盘共写 appIndex/winIndex,天然"谁后动听谁的"。
    /// `source` 区分来路(事件 / 帧拍)—— 两条路在这行账里长得一样就永远查不清"刚才谁选的"
    /// 指针是否落在第 i 格的 **hover 热区**(格子内缩后的中心区,见 PanelMetrics.hoverInset*)
    /// 几何与 iconStrip 同源:首格左缘 = 玻璃左 + rowPadX − iconGap/2,格宽 = icon + iconGap
    private func pointerInRingHotZone(_ i: Int) -> Bool {
        guard let glass = panelContentRect() else { return false }
        let pitch = PanelMetrics.pitch
        let tileLeft = glass.minX + ringContentLeftInset + PanelMetrics.rowPadX - PanelMetrics.iconGap / 2 + CGFloat(i) * pitch
        let rect = CGRect(
            x: tileLeft + PanelMetrics.hoverInsetX,
            y: glass.minY + PanelMetrics.rowPadY + PanelMetrics.hoverInsetY,
            width: pitch - PanelMetrics.hoverInsetX * 2,
            height: PanelMetrics.icon - PanelMetrics.hoverInsetY * 2)
        return rect.contains(NSEvent.mouseLocation)
    }

    func hoverApp(_ i: Int, source: String = "指针 hover", strict: Bool = true) {
        DispatchQueue.main.async { [weak self] in self?.logRowAlignment("换组") }
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // ★ 换 app 打点
        // ★ 热区内缩:指针只蹭到格子边缘 = "路过",不算选中(2026-09-19 用户裁定)。
        //   点按路径传 strict:false —— 点击目标仍是整格,精度要求不同
        if strict && !pointerInRingHotZone(i) { return }
        bumpIdle()
        // T91:换环后 strip 里装的是"未启动的 App" —— 同一格上的 hover 归 launchIndex,
        // 不能落到主环的 appIndex 上(那会把一套看不见的选中改掉)
        if entrySelected {
            guard hoverAllowedByGate(), launchables.indices.contains(i), i != launchIndex else { return }
            launchIndex = i
            Haptics.fire(.hoverAppRow)       // ★ 悬停触感(设置里可关;策略层已把"只保留 hover"写死 ✓)
            trace("[T91] 启动选中(\(source)): [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
            return
        }
        // 选中没变 = 同块地砖上挪指针,免工——onHover 每像素都发声,不设闸就是现拍风暴
        // (实机现形:日志被系统 QUARANTINED 截流)
        // entrySelected 也要放行:指针从启动区挪回主环,等于选回主环
        guard hoverAllowedByGate(), groups.indices.contains(i), i != appIndex || entrySelected else { return }
        // ★ 悬停触感:指针**换到另一个 App 格**上时震一下(用户 2026-09-22 要求 ✓)
        //   放在这道闸之后 ⇒ 每像素发声的 onHover 不会变成震动风暴 ✓(同格重复不进账 ✓)
        Haptics.fire(.hoverAppRow)
        traceCost("指针换选中") {
            // App 层原来没有这行账(窗口层一直有),于是"指针选中"和"键盘 Tab"在日志里长得一样——
            // 查"指针到底有没有动"时只能猜。口径与窗口层拉齐:括号里写明来源
            trace("[T6] 选中(\(source)): [\(i + 1)/\(groups.count)] \(groups[i].appName)"
                  + "(共 \(groups[i].windows.count) 窗)")
            // 拆账(2026-09-15):`指针换选中` 中位 12ms × 123 次,是现在最大的主线程开销 ✗。
            // 第一轮只拆了"拍图 / 托盘更新",结果**两笔都没超过 2ms** —— 说明钱不在这两处 ✗,
            // 于是把仅剩的候选(两个 @Published 写入,会同步惊动整棵观察者)也单独记一笔。
            traceCost("  ↳写状态") { entrySelected = false; launchIndex = nil; appIndex = i; winIndex = 0 }
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        }
    }

    // MARK: - T91 换环(↓ / ↑)
    
    /// ↓:环里换成"未启动的 App"。
    ///
    /// 为什么复用 `entrySelected`:它本来就表达"这一局在看未启动的 App"(托盘切启动行、
    /// 确认即启动、`` ` `` 在启动项里循环 —— 下游全挂在它身上)。换的只是**画在哪**:
    /// 旧形态画在环尾那枚记号 + 托盘里;新形态把**环本身**换掉(用户:完全覆盖掉)。
    ///
    /// `launchIndex` 故意留 nil:只按一下 ↓ 就松手 = 没有可生效之物 ⇒ 什么都不启动,
    /// 面板照常散场(与旧的"只选中入口槽"同一个语义)。
    /// **触发层专用入口**(四指轻点)。
    ///
    /// 病例(2026-09-17,用户实报「四指没生效」——日志给出了铁证):
    /// ```
    /// [ 85309ms] [T91] 换环 → 未启动的 App(共 2 个)      ← 触发了
    /// [ 85354ms] [T6] 落点顺序 [Ghostty | 大象 | …]      ← 45ms 后新一局开始,把它抹掉
    /// ```
    /// 根因:`onFireFour` 在 `beginPinnedSession()` 之后**立刻**调 `enterLaunchRing()`,
    /// 而那一刻 `launchables` 里装的还是**上一局留下的名单**(非空)⇒ 守卫放行、当场换环;
    /// 紧接着新一局的 `finishBegin` 才跑,一句 `entrySelected = false` 把环换了回去。
    ///
    /// 所以触发层的入口**只记意图**:等本局的名单装好(finishBegin)再兑现 ——
    /// 与"四指那一发比枚举先到"是同一个道理,那条路本来就存在(pendingLaunchRing)。
    func requestLaunchRing() {
        guard !entrySelected else { return }
        pendingLaunchRing = true
        pendingLaunchAt = CFAbsoluteTimeGetCurrent()
        trace("[T91] 换环意图已记下(触发层:等本局的名单)")
    }

    func enterLaunchRing() {
        guard !entrySelected else { return }
        // ★ 病例(2026-09-17,用户实报「唤起的还是启动的环, 不是未启动的」):四指轻点那一发
        // 到得**比枚举早** —— `begin()` 把枚举丢进后台 Task(见那里的注释),名单是在
        // `finishBegin` 里才装上的。那时这里 isEmpty ⇒ 静默 return ⇒ 面板照常显示主环,
        // 用户读到的是"四指没生效"。症状像没接线,其实是**时序**。
        guard !launchables.isEmpty else {
            // ⚠️ 2026-09-17 修(用户实报「倒是展示了, 但是别给启动环同时唤起来了呀」)。
            // 这里**绝不能**再把意图置成 true —— 日志原样:
            //   兑现换环意图(等了 72ms,未启动的 App 共 0 个)
            //   换环意图已记下(名单还没到:枚举在后台跑)   ← 又武装一次 ⇒ 每局都会再来换环
            // 没有可换之物 ⇒ 意图到此为止:**消费掉**就走。
            pendingLaunchRing = false
            showHint("没有未启动的 App")
            trace("[T91] 没有未启动的 App ⇒ 不换环,芯片说一句就散场")
            return
        }
        // 名单连名字一起打:一句话分清"到底换没换、换成了谁"(用户报"还是唤起来了"时,
        // 只有"共 N 个"是分不清的 —— 这条让报告能对号入座)
        trace("[T91] 换环 → 未启动的 App(共 \(launchables.count) 个): \(launchables.map(\.name).joined(separator: " · "))")
        setSegment(true, travel: .forward, launchIndex: nil)   // ↓ = 向下一环(滑动方向:新内容从右进)
    }

    /// ↑:换回"已启动的 App 组"
    func leaveLaunchRing() {
        guard entrySelected else { return }
        trace("[T91] 换环 → 已启动的 App 组(共 \(groups.count) 个)")
        setSegment(false, travel: .direct, launchIndex: nil)
    }
    
    /// 尺寸与内容**同一拍**(实验台 ⑤)。
    ///
    /// 老病(T76 之前)是"内容先变、尺寸后到"—— 屏幕会闪一帧"内容在旧尺寸里"。所以顺序钉死:
    /// 算尺寸(此时 entrySelected 已改,`paddedSize()` 自然给出那一套)→ 同一拍 setFrame。
    /// 瞬时改尺寸(不补间):与"关闭要已经没了"同一条纪律,而且**不可能掉帧**。
    /// 将来若实测觉得"跳",再改 `animate: true`,并且**用 [帧] 探针量 P95 与长帧占比**,不靠感觉。
    ///
    /// 指针重定位:面板宽度变了 ⇒ 指针底下那块地砖可能已不是原来那一格,自己补判一次
    /// (SwiftUI 只在指针移动时发 hover)。
    /// 段切换的**行进方向**(PanelView 靠它选过渡的方向):
    /// `forward`/`backward` = Tab/⇧Tab 沿环走(内容横滑,行进感);`direct` = ↓/↑ 跳段(淡切)。
    enum SegmentTravel { case forward, backward, direct }

    /// 跨段过渡的时长。窗口(AppKit)与内容(SwiftUI)用**同一根曲线同一段时长**,
    /// 两边才会读成一次变形而不是两层各动各的。系统"减弱动态效果"时 MotionPolicy 给 nil ⇒ 双边都瞬时。
    /// (0.22 → 0.18:双系统相位差的表现随帧数走,短一点抖动窗口就小 —— 2026-09-18 抖动病例)
    private static var segmentAnimation: Animation? {
        // 🔬 消元开关:确认"换段动画"是不是那个把托盘卡片动画着挪位置的元凶。
        //   `defaults write com.cheney12138.macswitcher debug.noSegmentAnim -bool true`
        if DebugFlags.noSegmentAnim { return nil }
        return MotionPolicy.animation(.easeInOut(duration: 0.18))
    }

    /// 段切换的唯一入口(模型 C):状态翻转走 withAnimation(SwiftUI 侧玻璃/内容跟着变形),
    /// 窗框走 applyRingSwap(animated:) 同一根曲线 —— 内容与玻璃一次变形完成。
    private func setSegment(_ toLaunch: Bool, travel: SegmentTravel, launchIndex target: Int?) {
        segmentTravel = travel
        ringSwapUntil = CFAbsoluteTimeGetCurrent() + 0.35   // 这一拍托盘内容当拍换(见 isRingSwapInFlight)
        // ★★ 2026-09-22 用户实报:「上下切换的时候, 环有抖动。应该是变形导致的, 直接 3/4 唤起打开是没问题的」
        //   —— 说的就是**双动画系统的相位差**(见 applyRingSwap 里那段"已知成本"的注释):
        //      AppKit 动窗框(0.18s easeInOut)+ SwiftUI 动内容,两条时间线不可能逐帧对齐 ⇒ 抖 ✗。
        //   既然用户早定过「任何场景都不要的动效 = 直接毙掉」(换段横向位移就是这么砍的),这里同办:
        //   **换环不补间、当拍到位** —— 窗框瞬时改尺寸(与"关闭要已经没了"同一纪律 ✓)、内容瞬时换 ✓
        //   ⇒ 相位差这个东西**从构造上就不存在了** ✓(不是"压小",是"没有" ✓)
        //   注:入场(唤起那一刻)的上浮照旧(carried by contentEntryRise ✓),换环不是入场 ✓
        withAnimation(Self.segmentAnimation) {   // 内容滑(单系统 ✓)
            entrySelected = toLaunch
            launchIndex = target
        }
        applyRingSwap(animated: false)           // 窗框当拍改尺寸(不补间 ⇒ 没有相位差 ⇒ 不抖 ✓)
    }

    private func applyRingSwap(animated: Bool = false) {
        // ★★ 铁律(用户 2026-09-17 明确):**不管在哪个环,面板一律相对当前屏幕居中** ——
        // 上下居中 + 左右居中。左缘**不许**钉偏移。
        //
        // 走错的弯路(记在这里,别再走):上一版为了"环不要右移"把左缘钉住了 —— 结果更糟:
        // ① 托盘是按面板 `midX` 定位的 ⇒ 面板一左偏,托盘跟着偏;
        // ② 屏幕上出现了"两套锚点"(面板看左缘、托盘看中线),对齐关系当场崩。
        // 环宽窄变化时的平移是**居中该有的样子**:向中线收缩,左右对称。
        //
        // 尺寸与内容同一拍(实验台 ⑤):算尺寸(此时 entrySelected 已改)→ 同一拍 setFrame。
        // 瞬时改尺寸(不补间):与"关闭要已经没了"同一条纪律,而且不可能掉帧。
        guard let panel else { updatePreview(); return }
        if let target = centerFrame(for: paddedSize()) {
            // ★★ 2026-09-22:这里原本是"AppKit 动窗框 + SwiftUI 动内容"**两个动画系统** ✗ ——
            //   双系统的相位差就是用户实报的"换环抖一下"。现在窗框**当拍**(而且它的尺寸本就是
            //   一局的不变量,见 `ringWindowWidth`)⇒ 只剩内容一个动画系统 ⇒ 抖从构造上不存在 ✓
            //   旧路留档,别再走:union 外框窗口(玻璃左锚定、从第一格向右长)/ 根部弹性 frame
            //   (Update Constraints 递归 FAULT,实机崩溃)。`animated` 形参只为调用点可读,窗框不补间 ✓
            _ = animated
            setFrameIfNeeded(panel, target)
        }
        resyncSelectionUnderPointer()
        updatePreview()
    }
    
    /// 启动行内 hover:只挪高亮(内容已在托盘里),不重排窗框
    /// 指针在启动行内的位置 → 格子下标。**由位置推导,不依赖 hover 事件**。
    ///
    /// 病例(2026-09-16 实机日志):hover 到网易云后再把指针移向微信,`[T6] 启动区 hover` 再也没有输出
    /// —— 事件根本没送达。这是本仓库记过的一类病(见 `resyncSelectionUnderPointer`):SwiftUI 的
    /// tracking area 在**视图于指针底下改变外观/重排**之后就哑了,不补发 hover。
    /// 当初那份补丁只覆盖了窗口卡,启动行是新代码、没继承到。
    ///
    /// `onContinuousHover` 不走 tracking area:指针只要在行内移动就持续回调**位置**,我们自己算格子,
    /// 因此不存在"事件丢失"。位置 → 下标是纯几何:x 按格距分列,y 按行高分行。
    func hoverLaunchAt(x: CGFloat, y: CGFloat, count: Int, cols: Int, rows: Int) {
        let pitch = PanelMetrics.pitch
        let rowH = PanelMetrics.icon + PanelMetrics.trayRowGap
        let c = max(0, min(cols - 1, Int(floor(x / pitch))))
        let r = max(0, min(max(rows - 1, 0), Int(floor(y / rowH))))
        let i = r * cols + c
        guard launchables.indices.contains(i) else { return }
        if !entrySelected { entrySelected = true }
        launchIndex = i
        trace("[T6] 启动区选中(位置推导): [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
    }

    func hoverLaunch(_ i: Int) {
        // hover 到启动行某一格,**本身就意味着**入口槽是选中的 —— 不能再要求 entrySelected 为真:
        // 指针从入口槽(面板)走到托盘是跨窗口的一段路,状态可能已被清掉,于是"鼠标再移动也选不中"
        // (用户实报)。这里直接把它补回来,而不是让 hover 去依赖一段可能丢失的记忆。
        guard hoverAllowedByGate(), launchables.indices.contains(i) else { return }
        entrySelected = true
        guard launchIndex != i else { return }
        trace("[T6] 启动区 hover: [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
        launchIndex = i
    }

    func hoverWindow(_ i: Int) {
        bumpIdle()
        guard i != winIndex else { return } // 同一格的重复 hover(指针每像素都发声)不进账
        // **到达**与**接受**分两行记:这一行证明"hover 事件到了",下一行证明"我们认了"。
        // 两行之间的时间差 = 我们这边的处理耗时;两行都晚 = 事件本身就投递晚了(窗口/层级/系统侧)
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] hover 到窗 [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)(闸:\(pointerMayTakeOver() ? "开" : "关"))")
        }
        guard hoverAllowedByGate() else { return }
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // ★ 悬停打点(量"含悬停那几拍")
        winIndex = i
        Haptics.fire(.hoverPreviewThumb)     // ★ 悬停触感:指针换到托盘里另一扇窗 ✓
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] 窗口选中(指针): [\(i + 1)/\(g.windows.count)] \(g.appName) — \(g.windows[i].title)")
        }
    }

    /// **卡片行点击**(2026-09-19):行内任何位置都归属最近的一张卡(含卡片之间的空隙)。
    /// `localX` = 行坐标系横向位置(行原点 = 首卡左缘,宽度口径与 resync 完全同源)。
    /// 曾经行内空隙是命中空洞,点击穿透托盘落到长条上,什么都不发生
    /// (用户实报「多窗口 App 的第二张卡要点两遍」)。
    func cardTapped(localX: CGFloat) {
        guard let g = currentGroup, !g.windows.isEmpty else { return }
        var cum: CGFloat = 0
        var hit: Int?
        let sizes = Self.cardSizes(g.windows)
        for i in g.windows.indices {
            let cw = sizes[i].width                     // 卡有多宽就命中多宽(与视图同源)
            if localX < cum + cw { hit = i; break }
            cum += cw + PanelMetrics.thumbGap
        }
        guard let i = hit ?? g.windows.indices.last else { return }   // 行尾空隙 = 归最后一张
        bumpIdle()
        if winIndex != i {
            trace("[T6] 卡片点击(行级): [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)")
            winIndex = i
        }
        confirmSelection()
    }

    // MARK: - 确认与放弃

    /// 松手不合面板(T10 毕业为设置面板正式项,UserDefaults key 不变):松手语义在
    /// 触发层处理(那边保持导航态、不发确认),这里只剩一件事——面板外点击是否免死
    /// ⚠️ 2026-09-22 修:这里原来读 `DebugFlags.pinPanelOnRelease`(**淘汰的调试键**)✗
    /// ⇒ 设置/菜单里打开的「保持面板打开」,到这一句就断了:面板外点击照样关面板 ✗
    /// 现在两个读取点都走 `Keys.pinOnRelease`(唯一来源 ✓)
    private var pinPanel: Bool { Keys.pinOnRelease }

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
                // 关掉 / 最小化的那扇窗离开列表(最小化窗我们本来就不列)。
                // ★ 组空了**不再摘组**(2026-09-20 用户:「cmd w 只是关闭窗口,不需要从环里
                //   杀掉」):进程还在 = 无窗应用(T15),原地保留、只清窗卡 —— 与 H 的
                //   "位置不变,只是窗口消失"同一语义。App 若因关末窗自动退出,下一次
                //   重枚举自然摘它(进程不在了)
                let keep = group.windows.enumerated().filter { $0.offset != winIndex }.map(\.element)
                if !keep.isEmpty {
                    next.append(AppGroup(pid: group.pid, appName: group.appName,
                                         bundleID: group.bundleID, windows: keep))
                } else if NSRunningApplication(processIdentifier: group.pid)?.isTerminated == false {
                    next.append(AppGroup(pid: group.pid, appName: group.appName,
                                         bundleID: group.bundleID, windows: []))
                }
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
        // 启动区里处决键无对象:appIndex 停在上一个活跃 App,动它 = 误杀,静默吞掉
        guard !entrySelected, groups.indices.contains(appIndex) else { return }
        let g = groups[appIndex]
        // **自保**(2026-09-18 用户裁定):Q(退出)与 H(隐藏)对 Glance 本体 = **按了没反应**。
        // 杀了切换器当场陪葬;H 更糟 —— LSUIElement 没有 Dock 图标,藏了就无处可捞。
        // 不弹提示不说话(v2 裁定:「应该是 cmd q 按了没反应而已」),日志记一笔即可
        if (op == .quit || op == .hide), g.pid == ProcessInfo.processInfo.processIdentifier {
            glog("[T12] 自保:\(g.appName) 不接受 \(op == .quit ? "Q(退出)" : "H(隐藏)"),静默忽略")
            return
        }
        switch op {
        case .quit:
            glog("[T12] 退出应用: \(g.appName)")
            quitPIDs.insert(g.pid) // 先记后杀:0.18s 后那次重枚举不许把它捞回来(见 quitPIDs 的病例)
            WindowFocuser.quitApp(pid: g.pid)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
            verifyQuit(pid: g.pid, name: g.appName, group: g, restoreAt: appIndex) // 0.9s 后问进程:真死了没?
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
            purgedWIDs.insert(w.wid) // 先记后摘:复核之前不许它"诈尸"回来
            verifyPurged(wid: w.wid, name: g.appName, group: g)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 最小化: \(g.appName) — \(w.title)")
            // ★★ **先记后做**(与 purgedWIDs/quitPIDs 同一套 ✓)——
            //    用户 2026-09-22:「遗照灰的渲染有点延迟. 是在确认窗口真的缩小了吗」
            //    ⇒ **是**,原来就是:我把"记下已收纳"写在 AX 调用**之后** ✗,而
            //      `AXUIElementSetAttributeValue` 是**同步跨进程调用**(要等 App 真缩下去才返回 ✓)
            //      ⇒ 图只能等 App 缩完才变灰 ✓(实测那点延迟就是目标 App 自己的最小化耗时 ✓)
            //    ⇒ 改成乐观:图**当帧**就变灰 ✓;AX 被拒了再回滚 ✓(不许留假状态 ✓)
            purgedWIDs.insert(w.wid)          // 先记后摘:复核之前不许它"诈尸"回来
            minimizedWIDs[w.wid] = g.pid      // 常驻:环上的"已收纳"记号 ✓
            sessionMinimizedPIDs.insert(g.pid) // 本局:松开时不许唤醒它 ✓
            marksRevision &+= 1               // ⇒ 当帧重绘(不等 AX ✓)
            glog("[记号] 记下已收纳(先记后做):窗 \(w.wid) @ \(g.appName)")
            let accepted = WindowFocuser.minimize(window: w)
            if !accepted {
                // 系统没受理(取不到 AX 窗 / 被拒)⇒ **把乐观记的账全撤掉** ✓ 不许留假灰 ✗
                minimizedWIDs.removeValue(forKey: w.wid)
                sessionMinimizedPIDs.remove(g.pid)
                purgedWIDs.remove(w.wid)   // 窗还在屏幕上 ⇒ 别让"复核期"把它按掉 ✗(0.18s 后它会自己回来 ✓)
                marksRevision &+= 1
                glog("[记号] 回滚已收纳:窗 \(w.wid) 最小化未被受理")
            }
            verifyPurged(wid: w.wid, name: g.appName, group: g)
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

    /// 退出的**复核**(2026-09-17 初版"放回被拒者"的语义已被 09-18 三修取代 ——
    /// 终案「Q 过的本局不回」与完整三轮弯路记录见函数体内的注释):
    /// 0.9s 后问一次进程死活,只打日志、不再放回;`quitPIDs` 压住本局直到散场。
    ///
    /// 关窗/最小化的**复核**(2026-09-17,与 `verifyQuit` 成对但语义**不同**——
    /// 关窗没有"慢死"问题:窗关就是关,`optionOnScreenOnly` 里报的窗就是真还在的窗;
    /// App 的确认框(modal alert)根本关不掉,摘了会变成"消失又回来"的来回跳。
    /// 0.9s 后重枚举一次:真没了 ⇒ 摘除成立;还在 ⇒ 撤回(放回**原位**,并且保持选中)。
    private func verifyPurged(wid: CGWindowID, name: String, group: AppGroup) {
        let generation = beginGeneration
        let restoreAt = appIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.beginGeneration == generation else { return }
            guard self.purgedWIDs.contains(wid) else { return }
            self.purgedWIDs.remove(wid)   // 复核这次之后,真相由系统说了算
            guard self.isVisible, let screen = self.contextScreen else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.isVisible, self.beginGeneration == generation else { return }
                    let stillThere = raw.contains { $0.windows.contains { $0.wid == wid } }
                    if stillThere {
                        glog("[T12] 关闭被拒(窗还在): \(name) → 放回列表")
                        var next = self.groups
                        if !next.contains(where: { $0.pid == group.pid }) {
                            next.insert(group, at: min(max(0, restoreAt), next.count))
                            self.applyList(next, keepPID: group.pid, keepWin: 0)
                        } else {
                            self.applyRefreshed(raw, keepPID: group.pid, keepWin: 0)
                        }
                    }
                }
            }
        }
    }

    private func verifyQuit(pid: pid_t, name: String, group: AppGroup, restoreAt index: Int) {
        // ★ 2026-09-18 三修(用户拍板「**Q 过的本局不回**」)—— 三轮修到这里才对,把两条弯路记全:
        //   · 一修(quitPIDs,09-17)治了"尾部复活" ✓,但放回逻辑还在;
        //   · 二修(「有窗才放回」,今天上午)被 zoom 实锤误伤 —— 日志:`[510178ms] 退出被拒(窗还在)
        //     → 放回列表` + `[T5] 预截 要拍 1 窗`(连它那扇正在关的窗的图都拍到了)。
        //     **正在关闭动画里的窗**与**确认框**在单一时点的窗口表里长得一模一样,
        //     任何固定时限的复核都是在赌 zoom 们窗消失的时机 —— 赌输一次症状就回来一次。
        //   · 终案语义(用户裁定):**面板反映用户的意图,屏幕反映现实** ——
        //     Q 过的 App 本局绝不自动放回;真被拒的确认框用户在屏幕上自己看得见,
        //     新一局 begin 重枚举,真相自然恢复。zoom 窗拖 1s 还是 10s 都不再有变量。
        //   (放回逻辑随二修撤销;`group`/`index` 参数保留以免动调用方,已无用处。
        //    本函数此后只负责打日志;记忆的最终清账交给 begin —— 下一局以系统真实状态为准。)
        let generation = beginGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.beginGeneration == generation else { return }
            let app = NSRunningApplication(processIdentifier: pid)
            guard app != nil, app?.isTerminated == false else {
                glog("[T12] 退出完成: \(name)")
                self.quitPIDs.remove(pid) // 死透了;撤掉只是账面干净(下一局 begin 反正会清)
                return
            }
            // 还活着:本局绝不放回。再问一句窗口表,把"正在死"与"疑似被拒"在日志里分清 ——
            // 今天的误伤就是靠这一行定位的,复盘时对得上账
            guard let screen = self.contextScreen else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.beginGeneration == generation else { return }
                    let windows = raw.first { $0.pid == pid }?.windows ?? []
                    if windows.isEmpty {
                        glog("[T12] 退出中(进程在、窗已空): \(name) → 本局不放回")
                    } else {
                        glog("[T12] 疑似被拒(窗还在,可能是确认框): \(name) → 本局不放回,弹窗由用户处理")
                    }
                    // quitPIDs **故意不撤**:本局后续任何重枚举都不许它回来(「Q 过的本局不回」)
                }
            }
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

    /// "已收纳"记号的自愈(每次重枚举后跑一遍,很便宜 ✓):
    ///   · 那扇窗**回到屏幕上了**(从 Dock 点回来 / 别的路还原了)⇒ 它不再"在 Dock 里" ⇒ 剪掉 ✓
    ///   · 它的 App 已经不在了 ⇒ 剪掉 ✓(wid 会被系统复用,必须靠 pid 判断,不能只认 wid ✓)
    /// 隐藏标记同理:现读 `isHidden` ⇒ 只有"还藏着"的才留 ✓
    private func reconcileMinimizedMarks(_ raw: [AppGroup]) {
        let before = minimizedWIDs.count
        var onScreen = Set<CGWindowID>()
        for g in raw { for w in g.windows { onScreen.insert(w.wid) } }
        // 每个被标记的 App 问一次 AX 真相(只有 1–2 个 App ✓;问不到就 nil ⇒ 不据此下结论 ✓)
        var axTucked: [pid_t: Bool?] = [:]
        for pid in Set(minimizedWIDs.values) where axTucked[pid] == nil {
            axTucked[pid] = WindowFocuser.hasMinimizedWindow(ofPID: pid)
        }
        minimizedWIDs = minimizedWIDs.filter { wid, pid in
            // ⚠️ **不许拿 purgedWIDs 里的窗当"回来了"** ✗
            //    病例(2026-09-22 用户实报:「没有常驻, 只出现了一下就消失了」):
            //    缩下去之后 0.18s 那次重枚举**还会把它报回来**(本仓早就记过这个"诈尸" ✓
            //    见 purgedWIDs 的注释 ✓),我这里却当场把记号剪掉了 ✗ ⇒ 记号一闪就没 ✓
            //    ⇒ 按 purgedWIDs 的老规矩:复核期(0.9s)内**不算数** ✓
            guard !purgedWIDs.contains(wid) else { return true }              // 复核期内:不动它 ✓
            if onScreen.contains(wid) {                                       // ① 真的回到屏上了 ✓
                glog("[记号] 摘掉已收纳:窗 \(wid) 回到屏上了")
                return false
            }
            // ② AX 说这个 App 已经一扇缩着的窗都没有了 ⇒ 记号失效 ✓
            //    ★ 这条才治得住"还原之后 window id 变了"的 App(见 hasMinimizedWindow 的注释 ✓)
            if let stillTucked = axTucked[pid], stillTucked == false {
                glog("[记号] 摘掉已收纳:App \(pid) 已经没有缩着的窗了")
                return false
            }
            return NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        }
        refreshHidingMarks()
        if minimizedWIDs.count != before { marksRevision &+= 1 }   // 表变了 ⇒ 保证重绘一次 ✓
    }

    /// 重算"哪些 App 现在藏着" —— 角标 `eye.slash` 的唯一数据源 ✓
    ///
    /// ⚠️ 2026-09-22 用户问:「刚才怎么还偶然看到了一个闭眼不可见的角标…是写在哪了, 什么状态下会出现」
    ///   —— 他之所以是"偶然看到",就是因为这里**原来只在**重枚举时才算(唤起 / 我们自己动作之后)
    ///   ⇒ 面板**开着**的时候,别处把 App 藏了/放出来了,角标都要等到下一次刷才跟上 ✗
    /// ⇒ 现在多两个触发源:`NSWorkspace` 的 hide / unhide 通知(见 `observeHidingChanges`)✓
    private func refreshHidingMarks() {
        // ★★ 2026-09-22 修正:`isHidden == true` **不等于**"用户按过 ⌘H" ✗
        //   用户实报:「还是有啊, 是不是之前的状态还在, 所以有残留」⇒ 当场量了系统(只读):
        //   ```
        //   常规 App 共 14 个;其中 isHidden=true 的只有: 文枢(com.meituan.EncryptionBox)
        //   ```
        //   ⇒ 他的截图里那枚角标**不是残留** ✓ —— 是那个 App**自己**报的 hidden ✓
        //      (窗口关掉的工具类 App / 常驻辅助型,没有可见窗口时就会这样 ✗)
        //   ⇒ 上一轮我写的"口径是系统事实"是**错的** ✗ ⇒ 现在:只认**我们按过 ⌘H 的** App ✓
        //      再与系统对一次账 ⇒ "只要还是 hide 就一直有"仍然成立 ✓,但不再给局外 App 乱打 ✓
        //   代价(说清楚):用别的工具隐藏的 App(⌥⌘H"隐藏其他"等)不会有角标 ✓
        let stillHidden = hiddenPIDs.filter {
            NSRunningApplication(processIdentifier: $0)?.isHidden == true
        }
        // 自己从 Dock / 别处放回来了 ⇒ 记号的依据没了 ⇒ 顺手把这笔账也清了 ✓(自愈 ✓)
        if Set(stillHidden) != hiddenPIDs { hiddenPIDs = Set(stillHidden) }
        var hiding = Set<pid_t>()
        for g in groups where hiddenPIDs.contains(g.pid) {
            hiding.insert(g.pid)
        }
        if hiding != hidingPIDs {
            if isTraceEnabled {
                // 谁被判定成 hidden —— 2026-09-22 病例(⌘M 之后冒出"隐藏"角标 ✗)需要这行才能定案:
                // 到底是系统把"窗都收走的 App"报成了 hidden,还是别处动了它 ✓
                let names = hiding.subtracting(hidingPIDs).map {
                    NSRunningApplication(processIdentifier: $0)?.localizedName ?? "\($0)"
                }
                let gone = hidingPIDs.subtracting(hiding).map {
                    NSRunningApplication(processIdentifier: $0)?.localizedName ?? "\($0)"
                }
                if !names.isEmpty { glog("[记号] 系统报告这些 App 变成隐藏: \(names.joined(separator: " · "))") }
                if !gone.isEmpty { glog("[记号] 这些 App 不再隐藏: \(gone.joined(separator: " · "))") }
            }
            hidingPIDs = hiding
        }
    }

    /// 系统的"某个 App 被藏了 / 被放出来了"通知 ⇒ 立刻跟上(全局只装一次 ✓)
    ///
    /// 注意口径:这里认的是**系统事实**(`isHidden`),不是"我们按过 ⌘H" ✓
    /// ⇒ 别的工具 / "隐藏其他(⌥⌘H)" / App 自己藏的,都会让这枚角标出现 ✓ 这是有意的 ✓
    private func observeHidingChanges() {
        guard !didObserveHiding else { return }
        didObserveHiding = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` 是**我们的事实**,但编译器不认 ⇒ 显式说明它 ✓
                // (不写它会有三条 warning:读 isVisible / 调 refreshAfterAction 都算跨隔离 ✗
                //   —— 别用"消音"绕过:那会把真正的主线程假设藏起来 ✓)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 在台上就顺手重枚举一次:被藏起来的 App,它的窗**还在列表里**(枚举要到下一次
                    // 重枚举才把它们除掉)⇒ 光改角标会留下几张"已经看不见的卡" ✗
                    if self.isVisible { self.refreshAfterAction() } else { self.refreshHidingMarks() }
                }
            }
        }
    }

    private func applyRefreshed(_ raw: [AppGroup], keepPID: pid_t?, keepWin: Int) {
        reconcileMinimizedMarks(raw)
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
        // 只用来决定"本局中途新冒出来的 App"排哪 ⇒ 同样按本局的屏 ✓
        let fresh = WindowEnumerator.orderByMRU(raw, on: contextScreen ?? NSScreen.main ?? NSScreen.screens[0])
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
                // 位置不动,只换内容(窗多了少了都还在这格)。但**我们刚摘掉的窗**要按住,
                // 否则 0.2s 后它诈尸回来一次(见 purgedWIDs 的病例)
                let kept = f.windows.filter { !purgedWIDs.contains($0.wid) }
                if kept.isEmpty {
                    // ★ **窗全没了 ≠ App 没了**(2026-09-20 用户:「cmd w 只是关闭窗口,
                    //    不需要从环里杀掉」):W 关掉最后一扇窗后,进程还活着 —— 它是
                    //    无窗应用(T15),**原地保留**(顺序冻结,不挪窝),只清空窗卡。
                    //    App 真死了的话(有的 App 关末窗即退出),下一次重枚举自然摘它
                    if NSRunningApplication(processIdentifier: old.pid)?.isTerminated == false {
                        merged.append(AppGroup(pid: old.pid, appName: old.appName,
                                               bundleID: old.bundleID, windows: []))
                    }
                } else {
                    merged.append(kept.count == f.windows.count ? f
                                  : AppGroup(pid: f.pid, appName: f.appName,
                                             bundleID: f.bundleID, windows: kept))
                }
            }
            // 不在 fresh 里 = 这个 App 真的没了(退出)→ 丢掉
        }
        for g in fresh where !seen.contains(g.pid)
            && !hiddenPIDs.contains(g.pid) && !quitPIDs.contains(g.pid) {
            // ★ 无窗条目(T15)照样收 —— 原来的 `guard !kept.isEmpty` 把它拦掉了,
            //   W 之后 0.18s 的重枚举明明带回了它,却没请回环里(用户实报"被杀")
            let kept = g.windows.filter { !purgedWIDs.contains($0.wid) }
            guard !kept.isEmpty || g.windows.isEmpty else { continue }
            // 本局中途新出现的 App 挂到**尾部**:不插队,免得又跳一次
            merged.append(kept.count == g.windows.count ? g
                          : AppGroup(pid: g.pid, appName: g.appName, bundleID: g.bundleID, windows: kept))
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
        // (T87 v3 起交给 `reapAlive()`:后台全量保活,被处决的窗在系统清单里消失即被 reap)
        Snapshotter.shared.reapAlive()
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
    /// 点启动行某一格 = 启动它并散场。
    ///
    /// **刻意不走 hoverLaunch/confirmSelection**:指针要从面板的入口槽挪到托盘(另一个窗口),
    /// 中间会经过"离开面板"的一段,`entrySelected` 可能已被复位 ⇒ `hoverLaunch` 的
    /// `guard entrySelected` 挡下 ⇒ `launchIndex` 留不下来 ⇒ `confirmSelection` 静默 no-op。
    /// 用户实报「那俩 app 也点不了」就是这么来的 —— 点击必须自带它的对象,不靠 hover 的记忆。
    func launchAt(_ i: Int) {
        guard launchables.indices.contains(i) else { return }
        let app = launchables[i]
        glog("[T83] 启动未启动 App: \(app.name)(\(app.path))")
        dismiss(reason: "确认(启动 \(app.name))")                  // ★ 先收面板 ✓
        DockAppsProvider.launch(at: app.path)
    }

    /// ## ⚡ 关闭顺序:**先收面板,再聚焦**(2026-09-22 用户实报「关闭不干脆, 慢一拍 / 像有残留」)
    ///
    /// 旧顺序是 `WindowFocuser.focus(...)` 然后 `dismiss(...)` ✗ —— 而聚焦要等一次**激活往返**
    /// (实测 30–51ms:`→ emit confirm` 到 `[T7] 已聚焦`),这期间面板还挂在屏幕上 ✗
    /// ⇒ 观感就是"松手了, 面板还赖着" ✓(而且目标 App 已经在往前台动画,面板浮在上面更像残留 ✓)
    /// 新顺序:先 `orderOut`(啪一下就没 —— 与"取消淡出"那次的用户口径一致 ✓),**之后再聚焦** ✓
    /// 代价:旧 App 会露出来几十毫秒 —— 那正是原生切换器的观感,也是用户要的"跟手" ✓
    func confirmSelection() {
        // 启动区(方案 E):入口槽选中 = 没有可生效之物(它在等用户进到某格),no-op;
        // 启动图标选中 = **启动并激活**,面板即关(与「确认」的"生效即散场"同款)。
        // 启动失败的兜底在 DockAppsProvider.launch 的日志里 —— 面板已经关了,不回头等
        if entrySelected {
            // ⚠️ 这里**不能**裸 return:用户实报「选中这个之后, 松手, 不消失了」。
            // 松开触发键 = 本局结束 ⇒ **所有**确认路径都必须散场(生效即散场)。
            // 只选中入口槽、还没进到某格 = 没有可生效之物,但面板照样要关。
            guard let j = launchIndex, launchables.indices.contains(j) else {
                dismiss(reason: "确认(入口槽,未进到某格)")
                return
            }
            let app = launchables[j]
            glog("[T83] 启动未启动 App: \(app.name)(\(app.path))")
            dismiss(reason: "确认(启动 \(app.name))")              // ★ 先收面板 ✓(启动要等几百 ms ✗)
            DockAppsProvider.launch(at: app.path)
            return
        }
        guard listReady else {
            // 名单还在后台枚举 ⇒ **记下意图**,等 finishBegin 兑现 ✓
            confirmBeforeList = true
            let gen = beginGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.beginGeneration, self.confirmBeforeList else { return }
                self.confirmBeforeList = false
                self.dismiss(reason: "确认(等名单超时 0.6s)")
            }
            confirmWaitWork?.cancel()
            confirmWaitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            trace("[T6] 确认(名单未到 ⇒ 记下意图,等枚举落地就兑现)")
            return
        }
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
        // ★ 本局**被我们缩小过的** App:松开时**什么都不做**(照 H 的先例 ✓)
        //   病例(2026-09-22 用户实报):「cmd m 会缩小…松开之后会立马把缩小的窗口又换起来」✗
        //   ⇒ 它此刻是"无窗应用"(窗都收进 Dock 了 ✓),而下面那条会把 App 激活 ⇒ 系统把窗抬回来 ✗
        //   判据:该 App **在本局**被我们缩小过 ∧ 它在本屏已经没有可选的窗 ✓(还有别的窗就照常切 ✓)
        //   ⚠️ 必须用**会话账**(`sessionMinimizedPIDs`)而不是常驻的记号表 ✗ ——
        //     2026-09-22 用户第二条实报:「关闭再唤起之后, 选中 app 拉不起窗口了」✗
        //     就是拿常驻表当守卫的后果:另起一局再确认也什么都不做 ✗
        //     ⇒ **本局不唤醒**(那次缩小不算白按 ✓)、**下一局能唤醒**(用户的手已离开键盘 ✓)
        if sessionMinimizedPIDs.contains(g.pid), g.windows.isEmpty {
            dismiss(reason: "确认(刚被缩小收纳 ⇒ 不唤醒它)")
            return
        }
        // 无窗应用(T15)不是"空列表"——确认 = 激活(App 自己处理开窗与还原)
        if !g.windows.indices.contains(winIndex) {
            dismiss(reason: "确认(无窗应用)")                       // ★ 先收面板 ✓
            WindowFocuser.focusWindowlessApp(pid: g.pid, contextScreen: contextScreen)
            return
        }
        let w = g.windows[winIndex]
        dismiss(reason: "确认")                                     // ★ 先收面板 ✓
        WindowFocuser.focus(window: w)
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
        // 本地:自己窗口的点击(**能吞**)——点空白就是关面板,不该顺手把下层那个 App 也点开。
        // 同时它也是仲裁账本的采样点:**点击 = 指针发言**(点格选中/点红绿灯必须能立即接管,
        // 哪怕之前一直是键盘在操作)。同步记账 —— 手势处理在同一轮事件里紧随其后,异步就输了
        // ⚠️ 2026-09-19:长条→托盘的点击矛盾不用事件转交解(试过 `sendEvent` 重投 —— 合成事件
        // 进了托盘但 SwiftUI 手势不认,down/up 双双无声)。改用**合成器闸**(见 updateStripClickGate):
        // 指针进托盘玻璃时长条对 WindowServer 隐身,点击由系统直接送托盘 —— 全程真实事件。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if isTraceEnabled {
                let inTray = self.previewContentRect()?.contains(NSEvent.mouseLocation) ?? false
                let inStrip = self.panelContentRect()?.contains(NSEvent.mouseLocation) ?? false
                let m = NSEvent.mouseLocation
                let pf = self.previewPanel?.frame ?? .zero
                glog("[T6] 本地点击 全局=(\(Int(m.x)),\(Int(m.y))) win=\(event.windowNumber) [长=\(self.panel?.windowNumber ?? -1) 托=\(self.previewPanel?.windowNumber ?? -1) 托可见=\(self.previewPanel?.isVisible ?? false) 托框=\(Int(pf.minX)),\(Int(pf.minY)),\(Int(pf.maxX)),\(Int(pf.maxY))] 托盘内=\(inTray ? "是" : "否") 长条内=\(inStrip ? "是" : "否") 长闸=\(self.panel?.ignoresMouseEvents ?? false)")
            }
            self.notePointerClick()
            return self.dismissIfClickOutside() ? nil : event
        }
        if pinPanel { return }

        // 全局:别人的点击,吞不掉(全局监听没有返回值的权力)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dismissIfClickOutside()
            }
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

    /// **长条→托盘的合成器闸**(2026-09-19,Bug2 终审):
    /// 托盘被故意压一层(popUpMenu - 1,demo 让长条盖住托盘的阴影尾 —— 黑影防线),而长条
    /// 整窗框带 108pt 呼吸区、与托盘玻璃大幅重叠(实测盖进下排卡片 ~185pt)。落在这条带里的
    /// 点击被 WindowServer 送给长条;长条 hitTest 在呼吸区返回 nil,**事件就地落地** ——
    /// 一锤定音账:`z序=长前托后 长hit=nil 托hit=ClickThroughHostingView`。
    /// 单行托盘的卡片在带外(一直好使),多窗口 App 撑出两行 → 下排整排在死区
    /// —— 用户实报「多窗口 App 的第二张卡要点两遍」,实为**永远点不着**。
    ///
    /// 修法:指针进托盘玻璃时把长条 `ignoresMouseEvents = true`(WindowServer 整窗跳过,
    /// 点击落到下层唯一的自家窗 = 托盘,**真实事件原路进 SwiftUI**);离开玻璃就还回来。
    /// 两扇窗的视觉 z 序一字不动,黑影防线保留。副作用审视:
    ///   · 闸开期间长条收不到任何鼠标事件 —— 指针在托盘玻璃里,本来就轮不到长条,无损;
    ///   · 翻闸有 ≤16ms 帧拍延迟 —— 极快的"划出即点"可能吞一下长条点击,点击先要有
    ///     位移、位移先被帧拍看到,实测窗口足够大;
    ///   · hover 不受影响(长条/托盘的选中都是帧拍几何算的,不靠事件)。
    /// 事件转交方案(重建 NSEvent 重投 `sendEvent`)实测无效 —— 合成事件进了托盘但
    /// SwiftUI 手势不认,down/up 双双无声 —— 别再走回头路。
    private var stripClickGateOn = false

    private func updateStripClickGate() {
        let shouldGate = isVisible
            && previewPanel?.isVisible == true
            && (previewContentRect()?.contains(NSEvent.mouseLocation) ?? false)
        guard shouldGate != stripClickGateOn else { return }
        stripClickGateOn = shouldGate
        panel?.ignoresMouseEvents = shouldGate
        if isTraceEnabled {
            glog("[T6] 长条点击闸 \(shouldGate ? "开(指针在托盘玻璃,点击让给托盘)" : "关")")
        }
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

// MARK: - 面板窗口

/// **必须能成为 key 的面板**(2026-09-16 定案,实机证据)。
///
/// 病(用户实报两条,实为同一个根因):
///   ① 托盘里的启动格点不动 —— Xcode 控制台连续三行
///      `-[NSWindow makeKeyWindow] … returned NO from -[NSWindow canBecomeKeyWindow]`,
///      而 `[T84]` 的诊断日志**一行都没有** ⇒ 点击到了 AppKit,却没到 SwiftUI 的手势;
///   ② 指针在启动行/托盘上移动后要**等好几秒**才换选中 ——
///      AppKit 只把 `mouseMoved` 派发给 **key window**。
///
/// 根因:面板用 `.borderless` 造型,而无边框窗口的 `canBecomeKey` 默认就是 **false** ✗。
/// `.nonactivatingPanel` 的正确用法恰恰相反:**能成为 key,但点它不激活 App**
/// (AltTab / DockDoor 等先例都是这么配的)。所以这里显式打开 `canBecomeKey`,
/// 同时把 `canBecomeMain` 关掉 —— 它是一个浮在别人上面的工具面板,不是主窗口。
/// 一扇 chrome 窗(主面板 / 托盘窗)的**显隐状态机** —— 显隐只有一个入口。
///
/// 为什么要有它(2026-09-21 两天的账):
///   · `NSPanel.isVisible` 在 borderless + nonactivatingPanel + level=.popUpMenu 上**不可靠** ✗
///     ⇒ 拿它当"已经在台上"的判据 ⇒ 每次 hover 都重排一次窗口(4–35ms ✗);
///   · "没内容"时 orderOut ✗ ⇒ 下一个 app 又 orderFront ✗ ⇒ 一局 27 次窗口排序(收/放风暴);
///   · 两件都在热路径上 ⇒ 把滑块的弹簧动画砸掉帧。
/// ⇒ 约定:**上屏一次就记住**(placed);没内容只改图层属性(不进/出窗口栈);只有整局收场才真 orderOut。
///   **落位(几何)不归它管** —— 那是 setFrameIfNeeded 的唯一职责。
@MainActor
final class ChromeWindow {
    private let panel: NSPanel
    private var placed = false              // 本局"已经在台上"(自己记账,不信 isVisible)
    private var hidden = false              // 内容隐藏(用户看不见 ≠ 窗口不在台上)
    /// 这一局是否已经收场(收场后禁止 place ✓ —— 见 `place()` 的病例)
    private var sessionEnded = true

    init(_ panel: NSPanel) { self.panel = panel }

    /// 确保在台上 + 内容可见。**幂等**:重复调用不产生任何窗口排序 ✓
    ///
    /// ★★ 2026-09-22 用户实报(「有时候环消失了, 预览容器还在。都松手回到 app 了, 容器还在」)——
    ///   真因:原来是"没在台上就上屏"✗,而它的调用点在 **`updatePreview()`** = **每次 hover 更新**都跑 ✗。
    ///   收场(`teardown()` 把 `placed` 清成 false ✓)之后,只要**再来一次迟到的更新**
    ///   (视图重渲染 / 延迟的布局 pass ✓)⇒ 托盘又被 `orderFrontRegardless` ✗;
    ///   而主面板那次没人再上屏 ⇒ 症状正是"**环没了、托盘还在**" ✓
    ///   ⇒ 加**会话闸**:收场之后、下一局 `beginSession()` 之前,`place()` 一律 no-op ✓
    ///   (连 `hidden` 都不碰:会话结束后它就该保持隐藏 ✓)
    func place() {
        guard !sessionEnded else { return }
        if hidden { setContentHidden(false) }
        guard !placed else { return }
        placed = true
        panel.orderFrontRegardless()
    }

    /// 新一局开始:重新允许上屏 ✓(与 `teardown()` 配对 —— 见 `place()` 的病例)
    func beginSession() { sessionEnded = false }

    /// 内容显隐:只改图层属性(微秒级 ✓)
    func setContentHidden(_ on: Bool) {
        guard on != hidden else { return }
        hidden = on
        panel.alphaValue = on ? 0 : 1
        panel.ignoresMouseEvents = on
    }

    /// 整局收场:真的腾出窗口 + 清账(与 place 严格配对)
    func teardown() {
        sessionEnded = true          // ★ 收场 ⇒ 迟到的 place() 不许再上屏(见 place 的病例 ✓)
        placed = false
        hidden = false
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        // ★ 2026-09-22 用户实报「预览容器会在环之后才消失, 看着跟有残留一样」:
        //   环与托盘是**两扇窗**,两次 `orderOut` = **两次独立提交** ⇒ 合成器可能有一帧
        //   只收走了环 ✗(16ms 的残留,肉眼刚好看得见)。
        //   `disableScreenUpdatesUntilFlush()` 把这次改动**并进下一次 flush** ⇒ 与环同批消失 ✓
        panel.disableScreenUpdatesUntilFlush()
        panel.orderOut(nil)
    }
}

final class GlancePanel: NSPanel {
    /// nil = 默认可 key;托盘设 false(2026-09-19):托盘若可 key,真鼠标第一击会被
    /// AppKit 拿去"设为 key"而不派发给视图(SwiftUI 内部视图不回 acceptsFirstMouse)
    /// —— 用户实报「第二张卡要点两遍」。托盘没有任何需要 key 的交互。
    var keyable: Bool = true
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}