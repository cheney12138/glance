import AppKit
import GlanceCore
import QuartzCore
import SwiftUI

/// 面板控制器:导航态状态机的唯一权威。
/// 出现(begin)→ 选中移动(next/prev/firstGroup/lastGroup/hover)→ 确认(confirm)/放弃(cancel),
/// 四状态无旁路。确认的真实聚焦在 T7 接 WindowFocuser,现在只打日志。
@MainActor
final class PanelController: ObservableObject {
    /// ★★ 锁屏/睡眠强制收场的接线(2026-10-15 病例:用户锁屏过夜,直播流整夜没停 ✗✗
    ///   「屏幕在监视中」常亮 + 显示器整夜没睡 ✗)—— 流长在面板手里,
    ///   锁屏那一拍必须把面板收掉 ✓(保温侧的暂停闸在 ThumbnailRefresher ✓)
    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.dismissForSystemSleep() } }
        // ★★ 2026-10-28(用户:「设置打开, 按 cmd tab, 环还是有一个伸长的过程, 因为加了一个 app 进来;
        //   接着第二次唤起, app 的位置还变动了」):
        //   唤起先用 `lastSessionGroups`(上一局名单)上屏,而它**只在开局那一刻**写过 ⇒
        //   之后新开的 App 不在里面 ⇒ 真名单一到,环**边长**、位置也**跳** ✗
        //   ⇒ 面板不在屏上时,利用 App 生命周期 / 激活 / 空间切换 / 上一局散场把缓存**续鲜** ✓
        //   · 退出 / 隐藏通知当场同步把该 PID 从陈旧缓存剪除(0ms 生效,绝不闪现已死/已藏 App)✓
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification] {
            workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self?.pruneStaleCache(removingPID: app.processIdentifier)
                    }
                    self?.refreshStaleListSoon()
                }
            }
        }
        // ★ 其中**只有三个**会改变"这块屏上有哪些 App / 哪些窗":新启动、解除隐藏、切 Space
        //   ⇒ 只有它们把缓存标脏(见 `staleCacheDirty`)。
        //   `didActivateApplication` 只是换前台,窗口集合没变;而且它**很频繁**
        //   (面板里每切一格、用户每点一下窗口都会来一发)⇒ 跟着标脏等于常态都走慢路径 ✗
        let dirtyingNotifications: Set<NSNotification.Name> = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let marksDirty = dirtyingNotifications.contains(name)
            workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if marksDirty { self?.markStaleCacheDirty() }
                    self?.refreshStaleListSoon()
                }
            }
        }
        // ★★ 2026-11-22(用户:「点开引导页面, 按照提示唤起 cmd tab … 显示全是 glance 设置面板的帧内容,
        //   但实际已经切换到 cat paw ide 了」):
        //   自家普通窗(设置 / 快速上手 / 速查)打开或关闭时进程早已在跑,不触发 `didLaunchApplication`,
        //   导致 `lastSessionGroups`(陈旧名单)没有及时续鲜 ⇒ 用户刚开或刚关引导窗就按 ⌘Tab 时,
        //   陈旧名单与真名单的 Glance 条目不一致,首帧先落在旧的 Glance 窗上、80ms 后真名单到达又跳到 CatPaw IDE ✗
        //   ⇒ 自家非面板窗开/关时同样触发 `refreshStaleListSoon()` 后台续鲜 ✓
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let w = note.object as? NSWindow, !(w is GlancePanel) else { return }
                    self?.refreshStaleListSoon()
                }
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.dismissForSystemSleep() } }
        }
        // ★ 2026-11-19 病例:「三指唤起延迟巨大」—— 根因是面板首次画到新启动 App 时,
        //   主线程同步等 IconServices XPC 14.7s(sample 铁证)。修后图标改后台解析,
        //   未命中时先上占位 → 这里监听落账通知,触发一次重画 + 清 sheenTint 备忘
        //   (备忘里可能记着占位图标推导的颜色,不落清会错一局)。
        NotificationCenter.default.addObserver(
            forName: IconProvider.iconCacheDidFill, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.sheenTintMemo = nil
                // ★★ 2026-11-25 根因 C(用户:「程序坞/环里新 App 先白纸,要等一会(甚至很久)才有 logo」):
                //   光发 `objectWillChange` **不够** —— `IconCell` / `DockRunningIconCell` 都是吃值参数的
                //   纯子视图,父视图重算时传给它们的参数一比特没变 ⇒ SwiftUI 跳过子视图 `body` ⇒
                //   后台 20ms 就拿到的真 logo 迟迟画不上屏,要等 hover / 重开面板才突然变出来 ✗
                //   ⇒ 递增这个 token 并作为参数传给子视图,让它们**一定能重算一次**(0 成本)✓
                self?.iconRevision &+= 1
                self?.objectWillChange.send()
            }
        }
    }
    @Published var groups: [AppGroup] = []
    /// **图标版本号**(2026-11-25 根因 C):后台图标落账时 +1,作为 token 传给 `IconCell`。
    /// 存在的理由只有一条:纯值参数子视图不会因为"图标磁层变了"而重绘(见上面观察者里的病例)✓
    @Published private(set) var iconRevision: Int = 0
    /// 上一局的名单**副本** + 它属于哪块屏(用于"陈旧名单先上屏" ✓)
    ///
    /// ⚠️ 为什么不能直接拿 `groups`:散场时有一句 `groups = []`(第 1195 行 ✓,拆窗的一部分)
    /// ⇒ 第二局唤起时它是空的 ✗ —— 第一版就是这么写的,实机一验:`[打卡] … 枚举 39.6` 照旧等枚举 ✓
    /// 所以另存一份副本(只有一份源:由 `finishBegin` / `applyList` 在"名单成为事实"那两处写 ✓)
    var lastSessionGroups: [AppGroup] = []
    private var lastSessionScreenID: CGDirectDisplayID?
    @Published var appIndex = 0 {
        didSet {
            // ★★ 2026-10-19:换组(无论走 ↓↑/Tab、⌘Tab、还是**指针悬停换组**)都在这里过账。
            //   卡片要在这短暂窗口里**完全不做选中动画** —— 否则换组那一拍整行重排会被动画化,
            //   视觉上就是"新组的卡片从左边浮出来"(用户稳定复现:Sublime 第二窗 → IDEA/DataGrip)✗
            if appIndex != oldValue {
                contentSwapUntil = CFAbsoluteTimeGetCurrent() + Self.contentSwapSeconds
                // ★★ 2026-10-20 病例(用户:「直接跳过去就闪,一个一个切就正常」):
                //   自拍量到整块托盘**掉暗一帧**:187.16 → 133.83 → 187.16,
                //   而 0.72 × 187 = 134.6 ⇒ 那一帧所有卡片都被判成"**未选中**"✗
                //   病根:调用方写的是 `appIndex = i; winIndex = 0` —— `appIndex` 的 didSet
                //   **同步**重建托盘,那一刻 `winIndex` 还是**上一组的旧值**(比如 1,新组只有 1 窗)
                //   ⇒ 新组的卡片一张都不匹配 ⇒ 整块按 0.72 画一帧 ⇒ 闪 ✗
                //   ⇒ didSet 里先**夹住** winIndex 再重建(调用方的顺序也就无所谓了)✓
                if let g = currentGroup, !g.windows.isEmpty, winIndex >= g.windows.count {
                    winIndex = max(0, g.windows.count - 1)
                }
                // ★★ 2026-11-20 性能修复:
                //   ① 撤掉已废弃的 `startEntryFloat()`(视图层早已在 2026-10-27 删掉对 `entryFloat.progress`
                //      的读取,留下 60Hz 定时器每切一次 App 白推 16 帧全托盘重算 ✗);
                //   ② 撤掉这里的 `updatePreview()`:所有写 `appIndex` 的同步调用方
                //      (moveApp / hoverApp / jumpToGroupEdge / pickApp / showPanel / applyList)
                //      在同一轮 runloop 内紧接着就会调 `updatePreview()`(同样早于 SwiftUI body 求值),
                //      放在 didSet 里导致每次换 App 重复跑两遍,且在 finishBegin/applyList 里还会拿着
                //      尚未重算 cap 与窗框的旧几何抢跑一次 ✗
                // ★★ 2026-11-22 残帧排查修正:
                //   不在高频换组(`appIndex.didSet`)里递增 `glassEpoch` ✗ ——
                //   每次 hover/Tab 换组都把 `NSGlassEffectView` 与整棵 `PreviewPanelView` 拆掉重建,
                //   再在同帧强行 `CATransaction.flush()`,反而会导致 SwiftUI 异步 `ViewGraph` 尚未重建完成时
                //   把半拆状态的玻璃/空帧刷进 WindowServer ✓。`glassEpoch` 只在每局开局 `showPanel` 递增一次 ✓。
                if let panel {
                    panel.invalidateShadow()
                    panel.contentView?.needsDisplay = true
                }
            }
        }
    }
    // MARK: - 托盘尺寸暂缓(删窗重排用)

    /// 删掉一扇窗后,卡片要做 FLIP 滑位(见 `PreviewPanelView.handleCardFrames`)——
    /// 那 0.34s 里卡片仍画在**旧位置**上,而托盘窗已经会按新内容收窄 ⇒ 会被窗缘裁掉 ✗
    /// ⇒ 这一段暂时把托盘窗留大一点(窗口本身透明,留大不可见 ✓)
    var trayFrameHoldUntil: CFAbsoluteTime = 0
    /// 上一次给托盘渲染的组(2026-10-26,换组残帧的判据)
    var lastPreviewBundleID: String?
    /// ⌘` 的"只有窗口"会话(2026-10-27):不显示环(长条),只上屏托盘;
    /// 组名单只留**当前前台 App** 那一组 ⇒ 托盘里就是这个 App 的窗口(轨道或卡片行)✓
    var windowsOnly = false
    /// 窗口局托盘的"允许上屏"时刻(CD 时间)。在那之前托盘一律 alpha 0 ——
    /// 因为毛玻璃那一层是**窗口自己的材质**,SwiftUI 的 opacity 管不到它 ⇒
    /// 窗口一上屏就先看见一层浅灰玻璃、内容后到 = 用户看到的闪 ✗
    /// 托盘**允许上屏**的时刻:开局后这段时间内保持 alpha 0 ——
    /// 否则会先看到"上一局那一帧"(托盘窗复用,后备存储里还是旧画面)✓
    var trayRevealAt: CFAbsoluteTime = 0
    /// 本局"托盘等图"的起算时刻(用于 0.4s 上限,防止永远等不到图)✓
    var trayGateStartAt: CFAbsoluteTime = 0
    var heldTrayFrame: NSRect?

    /// **冻结托盘窗框** `seconds` 秒(删窗重排那一拍用)。
    /// ⚠️ 2026-10-19 第一次实现是"把内容尺寸临时加大 220pt",结果 `TrayGeometry` 会按新的
    ///    maxContentSize 重算位置/比例 ⇒ 内容整体被推上去 ✗(用户:「删除一个窗口之后,位置上移了」)。
    ///    冻结帧 = 什么都不算、什么都不改 ⇒ 动画期间托盘的几何是死的,只有卡片在动 ✓
    func holdTrayFrame(seconds: Double) {
        if let f = previewPanel?.frame { heldTrayFrame = f }
        trayFrameHoldUntil = CFAbsoluteTimeGetCurrent() + seconds
    }

    /// 换组后"内容正在互换"的窗口(见 `appIndex.didSet`)
    var contentSwapUntil: CFAbsoluteTime = 0
    static let contentSwapSeconds: CFAbsoluteTime = 0.25
    var isContentSwapInFlight: Bool { CFAbsoluteTimeGetCurrent() < contentSwapUntil }
    @Published var winIndex = 0
    @Published private(set) var isVisible = false
    /// **入场令牌**:每开一局 +1(2026-10-26)。
    /// 为什么需要它(用户:「一样的操作, 入场动画不是稳定出现」):入场动效原来挂在
    /// `onAppear` / `onChange(bundleID)` 上 —— 面板窗口是常驻的,同一个 App 组再唤起时
    /// 视图实例没变、`onAppear` 不再触发;`bundleID` 也没变 ⇒ 动画就"有时播有时不播" ✗
    /// ⇒ 入场统一认这个令牌 ✓
    @Published private(set) var entryTick = 0
    /// **本局的名单还在路上**(陈旧名单已上屏、真名单未到)——
    /// 这期间 `groups.count` 的变化不许播"环变长/变短"的动画 ✗
    /// 病例(2026-10-27,用户):新开一个 App、再 ⌘Tab ⇒ 先上屏的是陈旧名单(没它),
    /// 真名单到了才把它加进来 ⇒ 环**中途形变**长出来,读起来像"卡在变" ✗
    @Published private(set) var listSettling = false
    /// 一局的不变量基线(开局时存;`SessionInvariants` 只读只报,不改行为 ✓)
    private var sessionBaseline: SessionSnapshot?
    /// 本局查过几次(防呆:不变量一旦违反会**每拍都报** ⇒ 只报第一次,免得刷屏 ✗)
    private var sessionFrameChecks = 0
    /// 本局开局时刻(开局 0.6s 内是"开门过程":窗口要经过 0x0 → 芯片 → 全量 两次布局 ⇒ 不比较 ✓)
    private var sessionOpenedAt: CFAbsoluteTime = 0
    /// 托盘窗的显隐状态机(懒建:窗口是 buildPreviewPanelIfNeeded 时才有的)
    var trayChrome: ChromeWindow?
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
    var trayMaxContentSize: NSSize = .zero

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
    /// 玻璃世代(残帧对策,2026-11-09):每局递增,SwiftUI 侧 `.id(glassEpoch)` ⇒
    /// 每局都是全新的 NSGlassEffectView(新视图 = 重新采样身后的画面,不吐旧快照 ✓)
    @Published private(set) var glassEpoch = 0
    /// 确认涟漪的令牌(demo .ripple):每次确认 +1,`PanelView` 靠它的变化重挂涟漪视图重播一遍

    var panel: NSPanel?
    private var hostingView: ClickThroughHostingView<PanelView>?
    var previewPanel: NSPanel?
    var previewHostingView: ClickThroughHostingView<PreviewPanelView>?

    // MARK: - 首帧显影门(2026-11-26)
    //
    // ★★ 病例(用户实拍,⌘Tab / 三指唤起瞬间偶发闪现 1~2 帧纯灰/黑"坦克矩形"):
    //   旧链路把新建冷窗 `setFrame(display: false)` 扩容后以 `alphaValue = 0` 上屏 ——
    //   WindowServer 对 **alpha == 0** 的窗口会跳过/推迟 macOS 26 `.glassEffect(.clear)`
    //   与 Metal 首帧合成;而显影只等了 1 次 `CFRunLoopBeforeWaiting` + `DispatchQueue.main.async`
    //   (**不等 GPU / VSync**),回调里还调 `flushPanelBackingStores` 主动标脏刚排好的树 ✗
    //   ⇒ 同一毫秒拉起 alpha,暴露出未渲染/刚扩容的纯灰矩形 ✓
    //   对策见 `FirstFrameRevealGate`:等真实 CA 提交 + 越过一个 VSync 边界再显影,
    //   显影之前窗口保持 **肉眼不可见但非零** 的 alpha(`preRevealAlpha`)。

    /// 显影前的"预显 alpha":肉眼 0/255 不可见,且 `< 0.01` 仍被 `previewContentRect()` /
    /// `ThreeFingerTap` 视作未上屏(不参与指针与点击),但 **`> 0`** 能让 WindowServer
    /// 照常合成 `.glassEffect` 与 Metal 首帧(零透明窗口会被裁掉/推迟)✓
    static let preRevealAlpha: CGFloat = 0.0005
    /// 本局"首帧还没显影"(从 `showPanel` 上屏到显影门兑现之间为 true)。
    /// 托盘(`PanelTrayWindow.updatePreview`)据此绝不允许提前把 `alpha` 拉到 1 ✓
    var awaitingFirstReveal = false
    /// 托盘正在 `fadeInWindow` 渐入途中 ⇒ alpha 由渐入曲线独家驱动,
    /// `updatePreview` 不许覆盖(否则渐入定时器会把刚顶到 1 的 alpha 又砸回 0.3~0.5 ✗)
    var isFadingInPreview = false
    /// 首帧显影门(等 CA 提交 + 一个真实 VSync 边界再显影)
    private let firstFrameRevealGate = FirstFrameRevealGate()

    var contextScreen: NSScreen?
    var outsideClickMonitor: Any?
    /// Esc 监听(2026-10-26,见 `installEscapeMonitor`:tap 没接管时 Esc 也要能关面板)
    var escGlobal: Any?
    var escLocal: Any?
    /// 自己窗口的点击(全局监听看不见自己家的事件,见 `installOutsideClickMonitor`)
    var localClickMonitor: Any?
    /// 退场演出期间的窗口拆迁单(见 `dismiss`):淡出/涟漪播完才 orderOut,
    /// 新一轮 `begin` 会把它撤掉
    private var teardown: DispatchWorkItem?
    /// 导航期间的 App Nap 豁免票:菜单栏型 App 在"用户没在动它"时会被系统降优先级,
    /// 表现就是动画掉帧、动效发涩。一局切换器只活几百毫秒,全程按住不放,代价可忽略
    private var activityToken: NSObjectProtocol?
    /// begin 的世代号:后台枚举回来时,若已开了新一局就丢掉旧结果(连按 ⌘Tab 的竞态)
    var beginGeneration = 0
    /// 延迟上屏阈值状态（超快 ⌘Tab 直切不建窗、不上屏，杜绝闪切残帧）
    private var revealDeferred = false
    private var revealWork: DispatchWorkItem?
    private var staleFallbackWork: DispatchWorkItem?
    private var pendingShowParams: (beganAt: CFAbsoluteTime, enumerateMs: Double)?
    private var deferredStaleFallbackArgs: (beganAt: CFAbsoluteTime, reverse: Bool, generation: Int)?
    private var sessionAppliedStale = false
    private var sessionShowedPanel = false
    /// 面板**不在屏上**时那份"后台续鲜"(`refreshStaleListSoon`)是否已经有一次
    /// `WindowEnumerator.rawGroups` 在途。
    /// ★ 为什么要有这道闸:App 生命周期 / 激活 / 空间切换 / 自家窗开合,**每一个**都会来敲一次
    /// `refreshStaleListSoon`(0.15s 防抖只是把它们并成一发,并挡不住"上一发刚跑起来、下一发又到")
    /// ⇒ 不设闸的话会有多个后台枚举同时压在 WindowServer / AX IPC 上,
    /// 而**三指唤起那一次枚举正好排在它们后面** = 用户体感的"偶发延迟" ✗
    private var isRefreshingStaleCache = false
    /// `lastSessionGroups`(陈旧名单)是否**可能已经过时**。
    /// · 只在本机"可能引入新 App / 改变这块屏窗口集合"的通知里置 true
    ///   (`didLaunchApplication` / `didUnhideApplication` / `activeSpaceDidChange`);
    /// · 退出 / 隐藏**不标脏** —— 它们已经走 `pruneStaleCache(removingPID:)` 同步剪掉了 ✓
    /// · 真实枚举把这份缓存写新的那两处(`finishBegin` / 续鲜回调落地)复位 false ✓
    /// 消费方只有一个:`begin` 的 `else if canStale` 分支 —— 干净就当拍回落(0ms 上屏),
    /// 脏才让位给真实枚举一小会儿(30ms)✓
    private var staleCacheDirty = false
    /// 标脏次数。后台枚举**开始那一刻**记下它,落地时只有次数没变才允许把 `staleCacheDirty` 复位:
    /// 否则"枚举正跑着的时候用户又启动了一个 App"会被这发**旧结果**洗成"干净" ✗
    /// ⇒ 下一次唤起就敢当拍回落到**缺那个 App** 的名单上 ⇒ 环边长一节(与 2026-10-28 那个病例同类)
    private var staleDirtySeq = 0
    /// 本局 `begin` 发起枚举那一刻的 `staleDirtySeq`(给 `finishBegin` 判"这发结果是否已过期"用)✓
    private var beginDirtySeq = 0

    /// 把陈旧名单标脏(可能已有新 App / 本屏窗口集合变了)。统一从这里过账:
    /// `staleDirtySeq` 与 `staleCacheDirty` 必须同时变,漏一个就是上面那个"旧结果洗成干净" ✗
    private func markStaleCacheDirty() {
        staleCacheDirty = true
        staleDirtySeq &+= 1
    }

    /// 预截补拍的推迟量 = 入场弹簧的沉降时间。T86 起**整单都挪**:唤起零拍,所有补拍
    /// (显示组 force + 其余组 TTL)都发生在沉降之后 —— 见 `finishBegin` 的那段注释
    private static let recaptureDelay: Double = 0.45

    /// dismiss 时通知触发层收尸(见 HotkeyTapCenter.endSession)。App 装配时接线
    var onSessionEnd: (() -> Void)?

    /// 查询触发层当前是否处于钉住会话（如三指点按）。App 装配时接线，避免 Panel 反向持有 HotkeyTapCenter 实例
    var isPinnedSession: (() -> Bool)?

    // (2026-09-24 深夜:这里曾有一个"快照落账 ⇒ 预热座"的 Combine 常驻订阅,治"冷启动遮罩
    //  后浮"。当晚用户拍板把遮罩改成容器自己的静态雾檐(PanelColors.thumbHaze)——不再有
    //  任何图像派生的座 ⇒ 订阅与 SeatImageCache 一并退役,后浮从根上不存在 ✓。)

    /// **光晕的圆心 = 选中那一格的中心**(面板内容坐标 —— 与视图里那个 `Canvas` 同一个坐标系 ✓)。
    ///
    /// ★ 2026-10-08 用户裁定:「高光不该跟着指针跑 —— 只按取色算法晕染**当前选中的 App**,
    ///   指针怎么移动都不影响它」✓(实拍:那团光出现在指针所在的空格子里,而不是选中图标周围 ✗)
    ///   ⇒ 位置与颜色由此**同源**:都取自"当前选中"这一件事 ✓
    ///   (原来位置走 `NSEvent.mouseLocation`、颜色走 `sheenTint` —— 两个源,所以会各跑各的 ✗)
    ///
    /// X 与托盘锚点/确认涟漪同源(`PanelLayout.iconCenterX`)—— 三处各算一遍必然有一处歪着 ✓;
    /// y = 选中图标(含 14pt 上浮)的中心,与涟漪那条口径一字不差 ✓
    /// 视图每 30Hz 问一次 ⇒ 必须便宜:这里只有一次算术(没有事件、没有查询 ✓)
    func sheenCenterInContent() -> CGPoint? {
        guard isVisible, !entrySelected, groups.indices.contains(appIndex) else { return nil }
        guard ringFlipAngle == 0 else { return nil }      // 翻牌期间不画:圆心正在变宽,画了会飘 ✗
        let x = PanelLayout.iconCenterX(appIndex: appIndex, appCount: groups.count,
                                        contentWidth: contentSize().width)
        return CGPoint(x: x, y: PanelMetrics.rowPadY + PanelMetrics.icon / 2 - PanelMetrics.iconLift)
    }

    var currentGroup: AppGroup? { groups.indices.contains(appIndex) ? groups[appIndex] : nil }
    var expandedCount: Int { currentGroup?.windows.count ?? 0 }

    /// 导航态按 `?` / `/` 时由 GlanceApp 唤出独立速查窗（避免 Panel 反向依赖 Settings）
    var onOpenCheatSheet: (() -> Void)?

    // MARK: - 触发层入口

    func handle(_ action: HotkeyTapCenter.Action) {
        bumpIdle()
        noteKeyboardAction()   // 键盘发言:此后指针的旧位移不再有优先权(谁后动听谁)
        finishRingFlip()       // ★ 翻牌还没落地就来新输入 ⇒ 先把这一发收尾,动作再照常执行 ✓
        // 阈值窗口内若又收到连续导航键（而非 begin/confirm/cancel/yieldToCapture），
        // 立刻取消延迟并准备上屏，保证连续 Tab/方向键零等待、不卡手 ✓
        let revealAfterMove: Bool
        switch action {
        case .begin, .beginReverse, .confirm, .cancel, .yieldToCapture:
            revealAfterMove = false
        default:
            if revealDeferred {
                if listReady {
                    revealAfterMove = true
                } else {
                    revealPendingPanel(generation: beginGeneration)
                    revealAfterMove = false
                }
            } else {
                revealAfterMove = false
            }
        }
        switch action {
        case .begin:
            DiagnosticRingBuffer.shared.recordSessionOpen()
            NotificationCenter.default.post(name: .glancePanelDidSummon, object: nil)
            begin(reverse: false)
        case .beginReverse:
            DiagnosticRingBuffer.shared.recordSessionOpen()
            NotificationCenter.default.post(name: .glancePanelDidSummon, object: nil)
            begin(reverse: true)
        case .next: moveApp(1)
        case .prev: moveApp(-1)
        case .firstGroup: jumpToGroupEdge(0)
        case .lastGroup: jumpToGroupEdge(groups.count - 1)
        case .enterLaunchRing: enterLaunchRing()
        case .leaveLaunchRing: leaveLaunchRing()
        case .cycleWindowPrev: moveWindow(-1)   // ` 循环窗口(与 ←/→ 分家)
        case .cycleWindowNext: moveWindow(1)
        case .pickApp(let n):
            // ★ 2026-11-12(用户:「按数字键选中的app"):数字 = 跳到环上第 N 个 App。
            //   两个段一视同仁(与 ←→ 的口径同源 ✓):主环选第 N 个组,启动环选第 N 个未启动 App;
            //   越界/已选中 = 夹住不动,不做环绕(与「两端夹住、不环绕」同一条纪律 ✓)
            if entrySelected {
                guard launchables.indices.contains(n), launchIndex != n else { return }
                launchIndex = n
                trace("[T6] 选中(键盘数字 \(n + 1)): 未启动 [\(n + 1)/\(launchables.count)] \(launchables[n].name)")
                return
            }
            guard groups.indices.contains(n), n != appIndex else { return }
            launchIndex = nil
            // ★ 选中一变必打帧探针点(2026-11-14 审查发现数字键路径漏了):与 moveApp 同款
            FrameProbe.lastHoverMark = CACurrentMediaTime()
            winIndex = 0                       // 先落:落到目标 App 的第一扇窗,可预测(moveApp/hoverApp 同款 ✓)
            appIndex = n
            trace("[T6] 选中(键盘数字 \(n + 1)): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
            // ★★ 2026-10-08 病例(←→ 那条欠的账,新选中路径必须照抄):选中一变必跟两笔,
            //   否则静图不换、Live 流不起 ⇒ "左右到头尾的 App 没有 live"同款病 ✗
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        case .pickWindow(let n):
            // 只在"当前 App 的窗口范围"内生效:越界 = 什么都不做
            // (跳到不存在的地方不该有副作用 —— 与"两端夹住、不环绕"同一个道理)
            // 启动区里数字键无语义(没有窗可选),静默吞掉
            guard !entrySelected,
                  groups.indices.contains(appIndex),
                  groups[appIndex].windows.indices.contains(n) else { return }
            winIndex = n
            trace("[T6] 窗口选中(键盘数字 \(n + 1)): \(groups[appIndex].windows[n].title)")
        case .confirm:
            DiagnosticRingBuffer.shared.recordSessionConfirm()
            confirmSelection()
        case .cancel:
            DiagnosticRingBuffer.shared.recordSessionCancel()
            dismiss(reason: "放弃")
        // 截图会话里的回车(T32):面板退场、**不聚焦任何窗**。
        // 语义上它就是"放弃"(不生效),但理由不同 —— 用户不是不要了,是那一发回车归截图工具,
        // 所以日志里必须分得清这两件事(否则复盘时会把"截图让权"读成"用户反悔")
        case .yieldToCapture: dismiss(reason: "截图会话让权")
        case .quitApp: destructive(.quit)
        case .closeWindow: destructive(.close)
        case .minimizeWindow: destructive(.minimize)
        case .toggleFullscreen: destructive(.fullscreen)
        case .hideApp: destructive(.hide)
        case .openCheatSheet:
            dismiss(reason: "打开快捷键速查")
            onOpenCheatSheet?()
        }
        if revealAfterMove, revealDeferred {
            revealPendingPanel(generation: beginGeneration)
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

    func showHint(_ text: String) {
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
    func bumpIdle() {
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

    /// **这块屏上最前面那扇窗**属于哪个 App(按 CG 的 z 序:列表就是前→后)✓
    /// 为什么不用 `NSWorkspace.frontmostApplication`:那是**全局键盘焦点**,
    /// 焦点在另一块屏/另一个 App 时它不代表这块屏的台前 App ✗(用户实报过)
    private static func frontPID(on screen: NSScreen) -> pid_t? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd),
                  b.width > 50, b.height > 50 else { continue }
            if WindowEnumerator.ownsByContextScreen(b, contextScreen: screen) { return pid }
        }
        return nil
    }

    /// ⌘` 新语义的入口:唤醒"只有窗口"的一局(没有环)
    /// · 默认**先切一扇**(预览下一次切换),松手才真正切窗(确认在触发层:松 ⌘ ⇒ `.confirm`)
    /// · Esc / 点空白 ⇒ 放弃(既有路径)
    @discardableResult
    func beginWindows(reverse: Bool) -> Bool {
        // 窗口局:托盘要多等一会儿(卡片图到齐)✓
        trayRevealAt = CFAbsoluteTimeGetCurrent() + 0.14
        trayGateStartAt = CFAbsoluteTimeGetCurrent()
        // ★★★ 2026-10-27 用户:「焦点不在内键屏也能唤起整个面板,但 ⌘` 唤不起窗口 —— 应该跟面板
        //   保持一样的唤起逻辑:**鼠标在哪就唤起哪个屏幕、台前的第一个应用**,不管它有没有焦点」
        //   上一版错在拿**全局前台 App**(`frontmostApplication`):内键屏上 IDEA 在最前面、
        //   而键盘焦点在别的屏(或别的 App)时,这个全局值不是 IDEA ⇒ 直接被门禁挡掉 ✗
        //   ⇒ 判据改成和面板**同一个源**:`lastSessionGroups`(已按**光标所在屏**排序)的第一组 ✓
        //   —— 只有"这份名单确实属于这块屏"时才用它做廉价预检;对不上就放行,
        //      由 `finishBegin` 拿到真实名单后再判(见那里 `<2 扇窗 ⇒ 整局作废`)
        if let screen = CursorScreenAnchor.cursorScreen,
           DisplayOrder.displayID(of: screen) == lastSessionScreenID,
           lastSessionGroups.map(\.windows.count).max() ?? 0 < 2 {
            if isTraceEnabled { glog("[窗口局] 这块屏上没有任何多窗口 App ⇒ 不唤起") }
            return false
        }
        windowsOnly = true
        // 没有环 ⇒ 卡片放大,**但比"一倍"收 20%**(用户:「相对屏幕居中, 缩小 20%」)✓
        PanelMetrics.trayZoom = 1.28
        begin(reverse: reverse)
        return true
    }


    private func begin(reverse: Bool) {
        // ★ 后台续鲜与热唤起枚举**不许打架**(三指唤起"偶发延迟"的一条真因):
        //   面板外那一发 `refreshStaleListSoon` 若正好在唤起这一拍落地,它会和本局的
        //   `WindowEnumerator.rawGroups` 抢同一份 WindowServer / AX IPC(实测单个 App 的 AX 调用
        //   就能慢到几十毫秒)⇒ 本该 15–40ms 的枚举被拖到 65ms+ ⇒ 用户就是"偶尔顿一下" ✗
        //   ⇒ 新一局开始先把**还没执行**的那张单子撤掉 ✓
        //   (已经在途的那个撤不掉 —— 但它落地时 `isVisible` 已是 true,会自己放弃,见那里 ✓)
        staleRefreshWork?.cancel()
        staleRefreshWork = nil
        // 新一局:上一局还没兑现的首帧显影作废(旧回调拿着旧 showGen,本就不会再显影)
        firstFrameRevealGate.cancel()
        awaitingFirstReveal = false
        isFadingInPreview = false
        // ⚠️ 2026-10-27 撤回:常规会话(⌘Tab)加 140ms 闸 ⇒ 用户实评「迟钝了, 且没修复, 还有白光」
        //   ⇒ 说明 ⌘Tab 那一下白光**不是托盘的空玻璃**(窗口局才是),
        //     加延迟只是让面板更晚出现,白挨一次体感 ✗
        //   ⇒ 常规会话恢复**当拍显示**(0);窗口局仍然是 140ms(那条已验证有效 ✓)
        trayRevealAt = 0
        trayGateStartAt = CFAbsoluteTimeGetCurrent()
        entryTick &+= 1
        // ★★ 2026-10-26 病例(用户:「切换几次之后, 再重新唤起面板, 芯片跑到下面去了」):
        //   上一局散场时,轨道样式会 `holdTrayFrame(0.5)`(冻住窗框,免得"先缩小再消失")✗
        //   若用户在 0.5s 内又唤起,`trayFrame()` 仍返回**上一局那个冻住的框** ⇒
        //   新一局的内容按新尺寸排、窗框却是旧尺寸 ⇒ 芯片被挤到玻璃外/下面 ✓
        //   ⇒ 新一局开始 = 冻结作废(上一局已经散场,没有任何东西还需要那个框)✓
        trayFrameHoldUntil = 0
        heldTrayFrame = nil
        lastPreviewBundleID = nil      // 新一局第一拍也整窗重绘一次(窗是复用的)✓
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
        listSettling = true
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
        optimisticMinimizedWIDs.removeAll() // 上一局原地挪尾的最小化守卫
        // ★ "已收纳"的账**跨局保留**(用户 2026-09-22:「角标要常驻」✓)—— 只靠下面的自愈剪枝 ✓
        hidingPIDs.removeAll()          // 隐藏标记是现读系统的 ✓ 这里只是清掉上一帧的缓存
        sessionMinimizedPIDs.removeAll() // "不许唤醒"只活一局 ✓(记号常驻,守卫不常驻)
        // T91:换环意图只活一局。**只在它真的挂着时留账**(日志预算:常态两行,这里是例外才出声)
        if pendingLaunchRing { trace("[T91] 新一局:上一局的换环意图没兑现,丢掉") }
        pendingLaunchRing = false
        trayChrome?.beginSession()      // 新一局 ⇒ 重新允许托盘上屏(见 ChromeWindow.place 的病例 ✓)
        beginGeneration &+= 1
        let generation = beginGeneration
        // 阈值延迟上屏策略（默认 130ms，可用 debug.summonRevealDelayMs 实机微调；0 = 立即上屏）：
        // · 按键→立即在后台枚举（~30ms 就位），面板窗口先不创建、不上屏；
        // · 若在阈值内松开修饰键（<130ms 超快切换）⇒ 直接静默切焦，零弹窗、零残帧；
        // · 若长按超过阈值，或途中再按一次 Tab/方向键 ⇒ 立即用已就位的最新名单上屏（不卡手）✓
        let revealDelayMs = DebugFlags.summonRevealDelayMs
        let advanceOnOpen = UserDefaults.standard.object(forKey: Keys.switchAdvanceOnOpen) as? Bool ?? KeyDefaults.advanceOnOpen
        let modHeld = !NSEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty
        // ★ 三指(**钉住的**)会话不吃这条阈值延迟:用户刚按完 ⌘C / ⌘V,拇指很可能还搭在 ⌘ 上,
        //   紧接着三指点按唤起 —— 那一拍 `modHeld` 恰好为 true ⇒ 莫名触发 130ms 阈值上屏 ✗
        //   ⇒ 钉住会话(三指)一律当拍上屏;⌘Tab 会话(isPinnedSession == false)保持原样 ✓
        let useRevealDelay = revealDelayMs > 0 && advanceOnOpen && modHeld
            && !(isPinnedSession?() ?? false)
        cancelPendingReveal()
        sessionAppliedStale = false
        sessionShowedPanel = false
        revealDeferred = useRevealDelay
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
        let canStale = canUseStaleList(on: screen)
        // 本局枚举的"起点脏度":落地时用它判"这发结果是不是已经旧了"(见 `finishBegin`)✓
        beginDirtySeq = staleDirtySeq
        if useRevealDelay {
            deferredStaleFallbackArgs = (beganAt: beganAt, reverse: reverse, generation: generation)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.beginGeneration == generation,
                      self.revealDeferred, !self.confirmBeforeList else { return }
                self.revealPendingPanel(generation: generation)
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(revealDelayMs), execute: work)
        } else if canStale {
            // 无延迟唤起(三指轻点 / revealDelayMs == 0)的陈旧缓存回落。
            // ★★ 口径修正(治"三指唤起偶发延迟"):
            //   上一版**统一**推迟 65ms ⇒ 每一次三指唤起都白等 20–65ms(正常枚举 15~40ms 就到了,
            //   那 65ms 只是把它挡在门外);遇到单个 App 的 AX IPC 慢,直接吃满 65ms ✗
            //   ⇒ 分两档:
            //   · 缓存干净(`!staleCacheDirty`,常态 95% 场景:退出/隐藏已同步剪枝、后台续鲜也已落地)
            //     ⇒ **下一轮 runloop 就上屏**(≈0ms:面板本来也得等本轮结束后才能提交首帧 ✓)
            //     ⚠️ 这里**不能**就地同步跑完 `finishBegin`(两个硬约束):
            //       ① 四指点按的换环意图是 `begin` 返回**之后**才记下的
            //          (`onFireFour`: `beginPinnedSession()` → `requestLaunchRing()`)
            //          ⇒ 同步跑先把面板开成主环、那个意图就再没人消费了 ✗(会变成"先闪一下主环再变形")
            //       ② ⌘Tab 的零延迟 debug 路径(`summonRevealDelayMs == 0`)**仍在事件 tap 回调里**,
            //          回调里跑整轮建窗 = 系统判超时停 tap 那条老病(见下面枚举搬后台那段)✗
            //   · 缓存刚被标脏(刚启动新 App / 刚切 Space,续鲜还没跑完)
            //     ⇒ 让位 30ms 给真实枚举(原来 65ms),兼顾新鲜度与低延迟 ✓
            if !staleCacheDirty {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.beginGeneration == generation,
                          !self.listReady, !self.confirmBeforeList, !self.sessionAppliedStale else { return }
                    self.staleFallbackWork = nil
                    self.presentStaleListFallback(generation: generation, beganAt: beganAt, reverse: reverse)
                }
                staleFallbackWork = work
                DispatchQueue.main.async(execute: work)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.beginGeneration == generation,
                          !self.listReady, !self.confirmBeforeList, !self.sessionAppliedStale else { return }
                    self.staleFallbackWork = nil
                    self.presentStaleListFallback(generation: generation, beganAt: beganAt, reverse: reverse)
                }
                staleFallbackWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30), execute: work)
            }
        }
        Task.detached(priority: .userInitiated) {
            let raw = WindowEnumerator.rawGroups(on: screen)
            await MainActor.run {
                guard generation == self.beginGeneration else { return }
                self.staleFallbackWork?.cancel()
                self.staleFallbackWork = nil
                if self.sessionAppliedStale {
                    // ★★ 2026-11-22 残帧与幽灵驻留根治:
                    //   快速 ⌘Tab(按下→松开 < 80–130ms)时,面板已在后台枚举完成前通过 `confirmSelection() -> dismiss()` 收场;
                    //   旧版 `if stale` 分支未校验 `generation == self.beginGeneration && self.isVisible`,
                    //   导致面板已关闭、甚至已聚焦目标 App 后,迟到的枚举仍进入 `applyRefreshed -> applyList -> updatePreview`,
                    //   在 `isVisible == false` 下把 `groups` 重新填满并把 `previewPanel.alphaValue` 重新拉回 1 ✗!
                    guard self.isVisible else { return }
                    // 已经用陈旧名单上屏了 ⇒ **不能**再走 `finishBegin`(那会重演一次入场 ✗)
                    // ⇒ 走现成的刷新路径:顺序冻结、按 pid 认住选中(与"处决后刷新"同一条路 ✓)
                    let ms = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
                    self.trace(String(format: "[T8] 枚举到达 +%.0fms(上屏用的是陈旧名单,这里只刷新内容)", ms))
                    let keepPID = self.groups.indices.contains(self.appIndex) ? self.groups[self.appIndex].pid : nil
                    self.applyRefreshed(raw, keepPID: keepPID, keepWin: self.winIndex, forceReshoot: false)
                    // ★ 这一拍**就是**"新开的 App 被加进环里"的那一帧 —— 名单动画要闭嘴:
                    //   本拍渲染时 `listSettling` 仍为 true(叠加替换不加动画),下一拍才放开 ✓
                    self.settleListSoon()
                } else {
                    self.finishBegin(raw, generation: generation, beganAt: beganAt, reverse: reverse)
                }
            }
        }
    }

    private func revealPendingPanel(generation: Int) {
        guard generation == beginGeneration, revealDeferred else { return }
        revealWork?.cancel()
        revealWork = nil
        revealDeferred = false
        if let params = pendingShowParams {
            pendingShowParams = nil
            deferredStaleFallbackArgs = nil
            scheduleSessionPrecapture(generation: generation, stale: sessionAppliedStale)
            showPanel(beganAt: params.beganAt, enumerateMs: params.enumerateMs)
        } else if let fallback = deferredStaleFallbackArgs, !listReady {
            deferredStaleFallbackArgs = nil
            if canUseStaleList(on: contextScreen) {
                presentStaleListFallback(generation: fallback.generation, beganAt: fallback.beganAt,
                                         reverse: fallback.reverse, tag: "阈值/连按接力")
            }
        }
    }

    private func canUseStaleList(on screen: NSScreen?) -> Bool {
        guard !windowsOnly, let screen else { return false }
        return StaleListPolicy.canShowStale(
            enabled: DebugFlags.staleListFirst,
            listCount: lastSessionGroups.count,
            windowCount: lastSessionGroups.reduce(0) { $0 + $1.windows.count },
            sameScreen: DisplayOrder.displayID(of: screen) == lastSessionScreenID
        )
    }

    private func presentStaleListFallback(generation: Int, beganAt: CFAbsoluteTime,
                                          reverse: Bool, tag: String = "不等枚举") {
        let staleList = lastSessionGroups
        let wins = staleList.reduce(0) { $0 + $1.windows.count }
        trace("[T8] 陈旧名单先上屏:\(staleList.count) 个 App · \(wins) 扇窗(\(tag))")
        finishBegin(staleList, generation: generation, beganAt: beganAt,
                    reverse: reverse, stale: true)
    }

    func cancelPendingReveal() {
        revealWork?.cancel()
        revealWork = nil
        staleFallbackWork?.cancel()
        staleFallbackWork = nil
        revealDeferred = false
        pendingShowParams = nil
        deferredStaleFallbackArgs = nil
    }

    private func scheduleSessionPrecapture(generation: Int, stale: Bool) {
        let allWindows = groups.flatMap { $0.windows }
        Snapshotter.shared.reapAlive()
        let shown = groups.indices.contains(appIndex) ? groups[appIndex].windows : []
        let shownIDs = Set(shown.map(\.wid))
        Snapshotter.shared.precapture(shown, maxAge: .infinity)
        Snapshotter.shared.precapture(allWindows.filter { !shownIDs.contains($0.wid) }, maxAge: .infinity)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recaptureDelay) { [weak self] in
            guard !stale, let self, generation == self.beginGeneration, self.isVisible else { return }
            Snapshotter.shared.precapture(allWindows.filter { !shownIDs.contains($0.wid) })
            Snapshotter.shared.precapture(shown, force: true)
        }
    }

    /// 名单落地的那一拍过后,才允许"环变长/变短"的动画(本拍必须闭嘴)✓
    private func settleListSoon() {
        DispatchQueue.main.async { [weak self] in self?.listSettling = false }
    }

    private var staleRefreshWork: DispatchWorkItem?
    private var didObserveLifecycle = false

    /// App 退出或隐藏时从陈旧缓存同步移除该 PID（0ms 生效），避免随后立即唤起时闪现已死/已藏 App ✓
    private func pruneStaleCache(removingPID pid: pid_t) {
        lastSessionGroups.removeAll { $0.pid == pid }
        // ★ **只递增序号,不标脏**。两件事分开看:
        //   · `staleCacheDirty` 不动 —— 同步剪枝本身就让当前这份缓存是干净的,
        //     标脏只会让下一次唤起白白多等 30ms ✗
        //   · `staleDirtySeq` 必须 `&+= 1` —— 剪枝这一拍可能**正有一发**
        //     `refreshStaleListSoon` 的枚举在途,而它的起点**早于**这次退出/隐藏:
        //     它落地时若照样写回,就会把刚剪掉的已死 PID **重新写回** `lastSessionGroups`
        //     (现象:退出一个 App 后 0.1s 内按 ⌘Tab,环里闪出那个刚退出的 App ✗),
        //     而 `seq == staleDirtySeq` 还会把 `staleCacheDirty` 洗成 false(缓存假干净 ✗)
        //   ⇒ 递增后那发旧快照看见序号变了就整份丢弃,见 `refreshStaleListSoon` ✓
        staleDirtySeq &+= 1
    }

    /// 面板**不在屏上**时,把"上一局名单"这份缓存续鲜(见 init 里的病例)✓
    func refreshStaleListSoon() {
        guard !isVisible else { return }        // 局中由 `applyRefreshed` 负责,这里不许插嘴 ✗
        // 已经有一次后台枚举在途 ⇒ **不再叠一个**:两份 `WindowEnumerator.rawGroups` 会同时压在
        // WindowServer / AX IPC 上,把紧接着那次唤起自己的枚举挤慢(见 `isRefreshingStaleCache`)✓
        // 这一发丢掉不会让缓存"假新鲜":在途那发的起点早于这次通知 ⇒ 它很可能没看见新变化,
        // 而 `staleCacheDirty` 仍是 true ⇒ 下一次唤起走 30ms 那条路,安全 ✓
        guard !isRefreshingStaleCache else { return }
        staleRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            guard let screen = CursorScreenAnchor.cursorScreen else { return }
            self.isRefreshingStaleCache = true
            // 这发枚举的"起点脏度":落地时若已变 = 跑着的时候又有新变化 ⇒ 不许洗成"干净" ✓
            let seq = self.staleDirtySeq
            Task.detached(priority: .utility) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    // ★ 无论这一发的结果**采不采用**,闸都要复位 —— 否则面板一下屏就再也续不了鲜 ✗
                    self.isRefreshingStaleCache = false
                    guard !self.isVisible else { return }
                    if seq == self.staleDirtySeq {
                        // 起点脏度没变 ⇒ 这发枚举看见了全部变化,快照照单收下 ✓
                        self.lastSessionGroups = WindowEnumerator.orderByMRU(raw, on: screen)
                        self.lastSessionScreenID = DisplayOrder.displayID(of: screen)
                        self.staleCacheDirty = false   // 缓存刚被真实枚举写新 ✓
                    } else {
                        // ★ 起点脏度已变 ⇒ 这发快照是**过期**的,**一个字都不许写回**:
                        //   它可能还带着刚剪枝掉的已死 PID(见 `pruneStaleCache` 起头那段 ——
                        //   写回就是「退出后立刻 ⌘Tab 闪出已退出 App」),
                        //   也可能缺了刚启动的 App。写回还会顺手把 `staleCacheDirty` 洗成干净 ✗
                        //   ⇒ 整份丢弃,再续一次,让缓存自己追上来 ✓
                        //   (不会自旋:只有真的又来了通知才会再排一发,且仍受 0.15s 防抖)
                        self.refreshStaleListSoon()
                    }
                }
            }
        }
        staleRefreshWork = work
        // 0.15s 防抖:兼顾快速连开/关窗口去抖与高时效续鲜 ✓
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 启动区名单(候选 + 在跑)的**后台刷新**(病例与实测账见 `DockAppsProvider.candidateCache`
    /// 与 `runningCache` 两段):这两块实测在"后台枚举并发跑着"的那一拍要 15–22ms ✗,
    /// 而单独量每个调用只要 ~1.5ms ✓ ⇒ 不猜谁对,直接让它们**让开关键路径** ✓
    /// (唤起那拍只读缓存;重活在后台做、下一局生效 —— "在跑的"另有工作区通知 ⇒ 及时 ✓)
    private var launchCandidatesRefreshing = false
    private func refreshLaunchCandidatesSoon() {
        guard !launchCandidatesRefreshing else { return }
        launchCandidatesRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let list = DockAppsProvider.computeCandidates()
            let running = DockAppsProvider.computeRunningSet()
            await MainActor.run {
                DockAppsProvider.storeCandidates(list)
                DockAppsProvider.storeRunningSet(running)
                self?.launchCandidatesRefreshing = false
            }
        }
    }

    /// - Parameter stale: true = 这一趟画的是**上一局的名单**(枚举还没回来)
    private func finishBegin(_ raw: [AppGroup], generation: Int, beganAt: CFAbsoluteTime,
                             reverse: Bool, stale: Bool = false) {
        // 打卡器上的名字要说实话:陈旧那一趟不能记成"枚举" ✗(否则 A/B 看不出省了多少)
        SessionMarks.step(stale ? "陈旧上屏" : "枚举")
        // 上一局已被新一局取代(连按 ⌘Tab):旧结果直接丢,别把面板闪回旧内容
        guard generation == beginGeneration else { return }
        staleFallbackWork?.cancel()
        staleFallbackWork = nil
        sessionAppliedStale = stale
        let screen = contextScreen
        // ★ 落点排序要认**这块屏**(2026-09-22 病例:全局 MRU 会把另一块屏的"最近用过"
        //   带过来 ⇒ 落点跳到错误的 App ✗)。`contextScreen` 就是本局的屏(ADR-0001 ✓)
        let fullGroups = WindowEnumerator.orderByMRU(raw, on: screen ?? NSScreen.main ?? NSScreen.screens[0])
        groups = fullGroups
        // ★★ 2026-11-25:顺手把"还没命中图标"的新 App 派给后台预热(兜住没产生 `didLaunch` 通知的
        //   那些进程)+ bundleID 二级缓存命中时 0ms 回填 ⇒ 本局第一帧就有真 logo ✓
        IconProvider.prewarmMissing(for: raw.map { (pid: $0.pid, bundleID: $0.bundleID) })
        if windowsOnly {
            // ★ 2026-10-27:口径改成"**这块屏**台前的第一个 App"(与面板同一个源):
            //   `groups` 已经是 `orderByMRU(raw, on: screen)` 的结果 ⇒ 第一组就是它 ✓
            //   (上一版用全局 `recentlyActivePID`,焦点在别的屏时会选错人 ✗)
            // ★★ 2026-10-27 第三次修正(用户:「cmd ` 没有窗口了」):
            //   `groups` 是按 **MRU(激活序)** 排的;而用户要的是"**台前**那个 App" ——
            //   例如焦点刚回到 IDEA、但 Ghostty 是上一次激活过的 ⇒ MRU 第一格是 Ghostty,
            //   它只有 1 扇窗 ⇒ 整局被判定"没得切" ✗
            //   ⇒ 改成按 **窗口 z 序**:`raw` 是前→后排列的,取**这块屏上第一扇窗**的 pid ✓
            let frontPID = screen.flatMap { Self.frontPID(on: $0) }
            let matched = frontPID.flatMap { pid in groups.first(where: { $0.pid == pid }) }
            if let first = matched ?? groups.first {
                groups = [first]
                if isTraceEnabled {
                    glog("[窗口局] 只留台前 App: \(first.appName) · \(first.windows.count) 扇窗")
                }
            }
        }
        SessionMarks.step("顺序")     // 🔬 细账(2026-10-09):拆"落点"这一段
        // ★ 2026-10-27 用户:「单窗口不唤起卡片」⇒ 廉价预检只能"宁松勿紧",
        //   真正的判据放在这里(枚举已经拿到**真实名单**):
        //   前台 App 不足 2 扇窗 ⇒ 这一局**根本不开**,连面板都不上屏 ✓
        if windowsOnly, (groups.first?.windows.count ?? 0) < 2 {
            if isTraceEnabled {
                glog("[窗口局] 实际只有 \(groups.first?.windows.count ?? 0) 扇窗 ⇒ 不唤起")
            }
            windowsOnly = false
            dismiss(reason: "单窗口 ⇒ 不开面板")
            return
        }
        // 记下这份名单(和它属于哪块屏):下一局唤起要靠它先上屏 ✓
        // ⚠️ 2026-10-27 病例(用户:「没有窗口了」):⌘` 的窗口局会把 `groups` 过滤成**一组**,
        //   而这里存进去的是过滤后的 ⇒ 下一局 ⌘Tab 的"陈旧名单先上屏"只显示那**一个 App**
        //   ⇒ 用户看到"没有窗口了" ✗ ⇒ 必须存**完整名单** ✓
        lastSessionGroups = fullGroups
        lastSessionScreenID = screen.flatMap { DisplayOrder.displayID(of: $0) }
        // 「真实枚举写新 ⇒ 记账复位」—— 两个前置:
        //   ① 本局拿的**不是**陈旧名单(陈旧回落的 `finishBegin` 写回去的还是同一份内容,零新信息);
        //   ② 枚举开始之后没有新的标脏事件(否则这发旧结果会把"刚启动的 App"洗成不存在 ✗)
        if !stale, beginDirtySeq == staleDirtySeq { staleCacheDirty = false }
        // ★ 唤起**也要**剪一次记号(2026-09-22 用户实报「已经从缩率态回来了, 图标没有消失」的真因 ✓):
        //   剪枝原本只挂在 `applyRefreshed` 上 —— 而它只在我们**自己的动作后**才跑(⌘M/W/H ✓)。
        //   "从 Dock 把窗点回来"**不产生我们的任何动作** ✗ ⇒ 那条路根本没人剪 ✗
        //   ⇒ 局面重设的这一刻就是最好的机会(而且这里最便宜:一局一次 ✓)
        reconcileMinimizedMarks(raw)
        SessionMarks.step("剪枝")     // 🔬 细账
        listReady = true
        // 名单定稿:本拍渲染仍按 `listSettling = true`(不加动画),下一拍才放开 ✓
        settleListSoon()
        // 启动区(方案 E):Dock 常驻 − 在跑的。**同步取** —— 长条宽度与托盘最大布局都依赖它,
        // 晚到 = 面板中途改尺寸(中途 setFrame 是 T76 之前那条老病,别回来)。
        // CFPreferences 读 + 解析是 1ms 级;图标首局逐个加载(几十 ms,一次性),之后走进程级缓存。
        // 新一局回到"主环第一格"的语义:上一局若停在启动区,这一局不带过去(主环才是本产品的主世界)
        entrySelected = false
        launchIndex = nil
        SessionMarks.step("状态三笔")   // 🔬 细账(2026-10-09):@Published 赋值本身要不要钱
        // ★ 2026-10-19:原来这里外面套着 `if Keys.panelShowLaunchables`(设置里那个
        //   「展示 Dock 常驻应用」开关)。用户实报「这是个废配置,也不起作用」—— 拨了没有可感知变化,
        //   因为默认一直是开,而关掉的效果(整条未启动环消失)并不是用户会去用的东西 ✗
        //   ⇒ 开关撤掉,行为**固定成原来的默认值(开)**:未启动环一直在 ✓
        do {
            // ⚠️ 2026-09-17 病例:除了 bundle id,**把 bundle 的路径也放进"在跑"的集合**。
            // 有些 Dock 常驻项取不到 bundleID(`DockApps.launchables` 里会退化成用 **path** 当 id),
            // 那时"在跑"的集合里只有 id ⇒ 两边**永远对不上** ⇒ 明明在跑的 App 也被列成"未启动"。
            // 用户实报:「app 全启动了, 但四指没有文案提示」—— 日志里正是 `未启动的 App(共 2 个)`。
            // ★ 2026-10-09:整块(含下面那个集合)现在**只吃缓存** ⇒ 亚毫秒;重活全在后台刷 ✓
            //   细账点名它 15–22ms ✗ ⇒ 见 `DockAppsProvider.runningCache` 的病例 ✓
            let running = DockAppsProvider.runningSet()
            SessionMarks.step("在跑集合")   // 🔬 细账
            launchables = DockAppsProvider.launchables(excluding: running)
            SessionMarks.step("名单")       // 🔬 细账
            // ★ 2026-10-09:这一拍只吃**缓存**(上面那行现在是一次 filter ✓ 亚毫秒);
            //   真正的重活(Dock plist + N 次 LaunchServices 查询 + 图标元数据)挪到后台算,
            //   **下一局生效** ✓ —— 病例与实测账见 `DockAppsProvider.candidateCache` ✓
            refreshLaunchCandidatesSoon()
            // 诊断(只在真有名单时出声):把名字与 id 都打出来 —— 一眼能看出是谁、以及 id 退化没退化
            if isTraceEnabled, !launchables.isEmpty {
                trace("[T91] 未启动名单: " + launchables.map { "\($0.name)[\($0.id)]" }.joined(separator: " · "))
            }
        }
        SessionMarks.step("T91")        // 🔬 细账
        SessionMarks.step("Dock")     // 🔬 细账:启动区名单(自 2026-10-09 起只吃缓存 ⇒ 应该降到亚毫秒 ✓)
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
        // ⚠️ 2026-10-19:用**最近被激活**的 App(激活序列),不是窗口堆叠序 ——
        //   后者会被常驻浮窗带歪 ⇒ 落点落到自己身上(按 ⌘Tab 等于没切换)✗(病例见 `recentlyActivePID`)
        let currentIdx = WindowEnumerator.recentlyActivePID(of: Set(groups.map(\.pid)))
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
        if windowsOnly, let g = groups.first, g.windows.count > 1 {
            // 默认**先切一扇**:正向 = 第 2 扇(MRU 里第 1 扇是当前窗),反向 = 最后一扇 ✓
            winIndex = reverse ? g.windows.count - 1 : 1
            trace("[窗口局] 默认落点 [\(winIndex + 1)/\(g.windows.count)] \(g.windows[winIndex].title)")
        }
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
        if !revealDeferred {
            scheduleSessionPrecapture(generation: generation, stale: stale)
        } else {
            Snapshotter.shared.reapAlive()
        }
        let ms = (CFAbsoluteTimeGetCurrent() - beganAt) * 1000
        if !stale {
            trace(String(format: "[T8] 按键→枚举就位 %.0fms(后台枚举,不卡按键)", ms))
        }
        guard !groups.isEmpty else {
            print("[T6] 本屏无窗,面板不出现(语境屏 = \(screen?.localizedName ?? "?"))")
            endActivity() // 同上:早退要还
            return
        }
        // 面板出现那行并入 `showPanel` 的"唤起结算"(那里才有"按键→上屏"的读数)
        recomputeSessionFit(on: screen)
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
        if revealDeferred && generation == beginGeneration && !pendingLaunchRing && hintText == nil {
            pendingShowParams = (beganAt: beganAt, enumerateMs: ms)
        } else {
            cancelPendingReveal()
            showPanel(beganAt: beganAt, enumerateMs: ms)
        }
    }

    /// 本局的"放得下"账:**收紧 cap + 托盘最大布局**,同一份数学两个调用点 ——
    /// 开局(finishBegin)与局中名单变化(applyList 的"只收紧"守卫)。
    /// **收紧之后**再算托盘窗口的最大布局:所有度量都随 sessionCap 变,算早了就是上一局的尺寸
    /// (与 `[尺寸]` 那行注释里同一条教训:行/列要在收紧之后算)
    func recomputeSessionFit(on screen: NSScreen?) {
        applySessionScaleCap(on: screen)
        // ⚠️ 2026-10-10 我在这里试过"只增不减"(想让托盘窗成为一局的不变量 ✗)—— **错的,已回退** ✓
        //   用户实拍:窗框尺寸是保住了,可**内容布局(几行几列)是从同一个 max 推出来的** ✗
        //   ⇒ 5 扇窗仍按 2 行 × 3 列画 ⇒ 托盘变高、第二排被面板压住 ⇒ 「更是离谱」✓
        //   ⇒ 正解是把两件事拆开:**窗框尺寸**(一局不变量 ✓)与**内容布局**(当前组 ✓),
        //     现在它们共用 `trayMaxContentSize` 一个输入 ✗ —— 那是一次"托盘几何"的设计改动,
        //     要重读 `TrayGeometry`/视图那条链,不能在连轴转的深夜顺手改 ✗(见下条注释 ✓)
        // ★★ 2026-10-10 定案（用户:「6-1 的时候还是没好」+ `[托]` 探针一锤定音）:
        //   探针把病灶定死了:
        //   ```
        //   68753526ms  窗=1226x537  内容= 978x344  网格=2x3  组窗数=6  max=1033x344  ✓
        //   68755188ms  窗=1226x537  内容=**1560x184** 网格=1x5  组窗数=5  max=1033x344  ✗✗
        //                           ↑ 内容比窗框宽 334pt ⇒ 溢出 ⇒ 用户看到的"错位"
        //   ```
        //   机理:窗框按"本局开局那一刻的**最坏网格**"定(6 窗 ⇒ 2行×3列 = 1033 ✓);
        //   关掉一扇后,布局器取"放得下的**最少行数**" ⇒ 5 张排成一行 ⇒ 而**在本局那把尺**下
        //   每张卡 ≈312pt ⇒ 一行要 1560 ✗ ⇒ 比窗框宽 ⇒ 溢出 ✓
        //   (另一块屏上没这毛病,就因为那边开局时的最坏情况**碰巧**覆盖了"一行"这个形状 ✓)
        //
        //   ⇒ 口径（用户选 A）:**本局最大内容 = 各组"最坏一行"与"最坏网格"的较大者** ✓
        //     窗框从此一定装得下"这一组排成一行"的形状 ⇒ 关一扇之后是一行居中 ✓
        //     代价照实说:一行算得更宽 ⇒ 窗框更宽、本局比例可能更早收紧(长条/图标略小 ✓)
        //     ⚠️ 这是一局**开局算一次**的数(ADR-0006 ✓),局中一律不重算 ✓
        // ══════════════════════════════════════════════════════════════════════════
        trayMaxContentSize = groups.reduce(NSSize.zero) { acc, g in
            let natural = previewContentSize(for: g)
            let oneRow = Self.oneRowContentSize(for: g)
            let c = NSSize(width: max(natural.width, oneRow.width), height: max(natural.height, oneRow.height))
            return NSSize(width: max(acc.width, c.width), height: max(acc.height, c.height))
        }

        // 启动行(方案 E)也是托盘的一种内容:它可能是本局**最大**的托盘(未启动比某组的窗多),
        // 不进 max 的话,选中入口槽那一下就会把托盘窗口撑到中途改尺寸
        if launchSectionEnabled {
            let c = previewContentSize(launchCount: launchables.count)
            trayMaxContentSize = NSSize(width: max(trayMaxContentSize.width, c.width),
                                        height: max(trayMaxContentSize.height, c.height))
        }
    }

    /// 本会期托盘可用的**玻璃**空间(2026-09-14 换行那轮引入)。
    /// 宽 = 可视宽 − 两侧安全边;高 = 长条**头顶**那一半 —— 长条是垂直居中的,
    /// 托盘挂在它上沿之上,所以只有 (可视高 − 长条高) / 2 可用,不是整个屏高。
    var trayRoomW: CGFloat = 1440
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
        // ★★ 2026-10-13 用户裁定「环和容器两边自己控制」——
        //   **这条 `cap = min(cap, fit)` 就是病灶**(用户实拍「怎么把环给我缩小了」✓):
        //   托盘一装不下就把整局比例(长条/玻璃/圆角都在用)一起收紧 ⇒ 环被托盘拖着缩 ✗
        //   ⇒ 现在 `fit` 只写进 `PanelMetrics.trayCap`(只管卡片 ✓),环只由 `availW / stripBase` 定 ✓
        var trayCap = CGFloat.greatestFiniteMagnitude
        for g in groups where !g.windows.isEmpty {
            let fit = trayFitScale(aspects: g.windows.map(\.aspect)).scale
            trayCap = min(trayCap, fit)
            if fit < worstScale {
                worstScale = fit
                worstN = g.windows.count
                worstAspects = g.windows.map(\.aspect)
            }
        }
        PanelMetrics.trayCap = trayCap
        PanelMetrics.sessionCap = cap
        // 行/列要在**收紧之后**再算:列数取的是当前尺寸下能放几张,
        // 收紧前算出来的会是上一局的尺寸(日志里就会看到对不上的行 × 列)
        let worstLayout = trayLayout(widths: worstAspects.map { PanelMetrics.thumbWidth(aspect: $0) })
        // **只在档位变化时打**:同一台机器上它几乎每局一样,重印就是噪音;变了一定要看
        if Self.lastScaleLine == String(format: "%.3f/%.3f", s, cap) { return }
        Self.lastScaleLine = String(format: "%.3f/%.3f", s, cap)        // ⚠️ 这里原来用 `print`(走 stdout)⇒ **块缓冲** ⇒ 落盘能延迟几分钟 ✗
        //   (2026-09-24 查"面板比屏还宽"时被它坑了一次:明明打了,日志里半天看不见 ✓)
        trace(String(format: "[尺寸] 净距 %.0fpt(%@) · 固定 %.0f%% · 环 %.0f%%(长条 %.0fpt 基准 · 玻璃 %.0f/%.0fpt%@) · 托盘 %.0f%%(只剩它自己管卡片 · 最挤 %d 窗 → %d 行 × %d 列)",
                     PanelMetrics.trayRingGap,
                     DebugFlags.trayRingGap == nil ? "默认" : "用户键①",
                     s * 100, cap * 100, stripBase, cap * stripBase, availW,
                     cap < s - 0.001 ? " → 已收紧" : "",
                     min(trayCap, s) * 100, worstN, worstLayout.rows, worstLayout.cols))
        // (托盘窗口尺寸那行撤了:它是"整局只 setFrame 一次"的验证账,已验证完;
        //  要复核时看 `[工] 托盘改尺寸` 是否只在开局出现即可)
        if cap < 0.6 {
            trace("[尺寸] 提示:本局 < 60%,面板会明显偏小 —— 是 App 数太多(长条压尺寸),不是托盘")
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
        let savedTrayCap = PanelMetrics.trayCap          // ★ 两把尺子都要在 ∞ 窗口内(否则基准宽会带着上一局的缩放 ✗)
        PanelMetrics.sessionCap = .greatestFiniteMagnitude
        PanelMetrics.trayCap = .greatestFiniteMagnitude
        let s = PanelMetrics.trayScale
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
        PanelMetrics.trayCap = savedTrayCap

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

    /// 某一组**排成一行**时的内容尺寸(2026-10-10:给"本局最大内容"多算一种形状 ✓)
    /// 数学与 `previewContentSize(for:)` 同源:同一把 `cardSizes` ✓、同一套 `TrayGrid` ✓、同一组内边 ✓
    static func oneRowContentSize(for group: AppGroup) -> NSSize {
        let sizes = cardSizes(group.windows)
        guard !sizes.isEmpty else { return .zero }
        let widths = sizes.map(\.width)
        let rows = 1, cols = sizes.count
        let h = rowHeights(sizes, rows: rows, cols: cols).reduce(0, +)
        return NSSize(width: maxRowWidth(widths, rows: rows, cols: cols) + PanelMetrics.trayPadX * 2,
                      height: PanelMetrics.trayPadTop + h + PanelMetrics.trayPadBottom)
    }

    static func cardSizes(_ windows: [WindowRecord]) -> [CGSize] {
        windows.map { PanelMetrics.thumbSize(real: $0.bounds.size, aspect: $0.aspect) }
    }
    
    /// 分行后**每行的最大高度**(内容尺寸 / 命中判定 / 视图三处共用同一套数)
    /// 算式在 `GlanceCore.TrayGrid`(可单测);这里只把"这一局的尺子"喂进去。
    static func rowHeights(_ sizes: [CGSize], rows: Int, cols: Int) -> [CGFloat] {
        // ★★ 2026-10-13 病例(用户实拍:访达 8 窗 2 排 ⇒「访达距离环太近了」/第二排芯片消失 ✗):
        //   视图里每张卡是 `VStack(卡片, 芯片)` ⇒ **渲染高 = 卡片高 + (thumbH − shotH)** ✓
        //   而这里只按**卡片**高算行高 ✗ ⇒ 每行少算约 36pt(芯片那一段)
        //   ⇒ 1 排:内容矮一截 ⇒ 芯片勉强还在框内(所以一直没暴露 ✗)
        //   ⇒ 2 排:矮两截 ⇒ 内容实际比窗框高 ⇒ 贴底后**往下溢** ⇒
        //      最后一排芯片钻到环的玻璃底下(用户截图:第一排芯片在、第二排没了 ✓)
        //   ⇒ 行高 = 行内最高的卡 + 芯片那一段(与视图**同一个来源** ✓,不许各算各的 ✗)
        let chipSegment = PanelMetrics.thumbH - PanelMetrics.shotH
        return TrayGrid.rowHeights(sizes.map { CGSize(width: $0.width, height: $0.height + chipSegment) },
                                   rows: rows, cols: cols)
    }

    static func maxRowWidth(_ widths: [CGFloat], rows: Int, cols: Int) -> CGFloat {
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
        sessionShowedPanel = true
        isVisible = true
        ThumbnailRefresher.shared.setPanelVisible(true)
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
        trace("[T6] 入场:渐入 \(DebugFlags.summonPopMs)ms(弹簧档 \(PanelMotion.entranceGearName))" + (willSlide
            ? " + 从上一格滑过来(托底 \(lastLandedIndex! + 1) → \(appIndex + 1))"
            : ""))

        // 入场动效在 SwiftUI 层(demo .switcher-wrap 的 scale .90→1 + 渐入),窗口只负责就位
        // ★★ 残帧根治(2026-11-21 用户实拍:快速切换 / App 卡顿 / CPU 负载高时,
        //   环 + 托盘组成的整个"坦克形"面板区域透穿显示上一个 App 对应位置的真内容):
        //   559a295 加了 `glassEpoch` + 主面板 `alpha=0` 一拍门,但留下三条漏路:
        //     ① `updatePreview()` 在同一拍把 `previewPanel.alphaValue = 1` 并立即 `orderFront`,
        //        托盘窗完全没走 `alpha=0` 首帧门;
        //     ② 改 `@Published glassEpoch` 只将 `NSHostingView` 标为 dirty,在高负载/掉帧下
        //        `layoutSubtreeIfNeeded() + displayIfNeeded()` 并不能保证 SwiftUI 的 Metal/CA
        //        事务已提交到 WindowServer 的窗口 backing store,下一拍 `DispatchQueue.main.async`
        //        直接拉回 `alpha=1` 时新帧可能仍未落入 backing,合成器直接把上一局烘焙的旧帧吐出;
        //     ③ `appIndex.didSet` 此前撤掉了 `updatePreview()`,导致 `showPanel` 里先拿旧组的
        //        托盘几何画了一遍,末尾才调 `updatePreview()`。
        //   对策:
        //     · 唤起/换组时同步递增 `glassEpoch`,并在窗口显示前对两扇窗的 `hostingView` 强制执行
        //       `CATransaction.begin() -> layoutSubtreeIfNeeded() -> displayIfNeeded() -> CATransaction.commit() -> CATransaction.flush()`,
        //       把 SwiftUI 新树与新 `NSGlassEffectView` 的 CA 提交同步推入 WindowServer;
        //     · 主面板与托盘窗(常规局)**同拍**先以 `alphaValue = 0` 就位并同步 flush,
        //       下一拍再一并拉回可见(恢复渐入或 `alpha = 1`);
        //     · 收场 `orderOut` 前先把两扇窗 `alphaValue = 0`,确保 WindowServer 侧残存的最后一帧也是全透明。
        // ★ `glassEpoch` 已在上一局 `teardownPanel` 退场 flush 后递增并完成离屏重置，
        //   开局 `showPanel` 不再同步拆建 `.id(glassEpoch)` 视图树，避免与首帧 `fadeInWindow` 抢拍。
        let showGen = beginGeneration
        LivePreviewPool.shared.setAccepting(true)

        // 新一局:上一局的显影门会作废,本局重新等首帧 ✓
        firstFrameRevealGate.cancel()
        awaitingFirstReveal = true
        isFadingInPreview = false

        // ★★ 2026-11-26:非零但肉眼不可见的预显 alpha(见 `preRevealAlpha`)——
        //   零透明窗会被 WindowServer 推迟 `.glassEffect` / Metal 首帧合成 ⇒ 显影瞬间露灰底 ✗
        panel.alphaValue = windowsOnly ? 0 : Self.preRevealAlpha
        setFrameIfNeeded(panel, target)
        SessionMarks.step("置框")     // 🔬 细账(2026-10-09):拆"开窗"这一段

        // ★ 入场淡入统一只走窗口 `alphaValue`（`fadeInWindow`），不再叠加 SwiftUI 内容 `.opacity(entryFade)`，
        //   避免 `PreviewPanelView` 在首帧把内容置成全透明、与首帧显影门(`FirstFrameRevealGate`)抢拍露出空壳。
        var popInstant = Transaction()
        popInstant.disablesAnimations = true
        trayShownOnce = false        // 新一局:托盘"首次上屏"这一笔重新记(见上面那行日志 ✓)
        withTransaction(popInstant) { entryFadeProgress = 1 }
        updatePreview(initialSummon: true)
        if isTraceEnabled { probeContentReady(panel) }   // 🔬 白光排查:上屏前量一次内容
        if windowsOnly {
            // ⌘` 窗口局不显示主环，根本不把主面板排进 WindowServer 在屏列表，避免空玻璃层占屏。
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        } else {
            panel.orderFrontRegardless()
        }
        SessionMarks.step("上屏")     // 🔬 细账:orderFront + 首轮布局

        // ★★ 2026-11-26:首帧前只做一次**无重脏**的轻量布局收口 ——
        //   绝不写 `needsLayout = true` / `needsDisplay = true`(那是把刚排好的 `NSHostingView`
        //   反向标脏,显影那一帧反而还没渲染完 ⇒ 纯灰/黑坦克矩形 ✗)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !windowsOnly { panel.layoutIfNeeded() }
        if let previewPanel, !(trayChrome?.isContentHidden ?? true) {
            previewPanel.layoutIfNeeded()
        }
        CATransaction.commit()

        // ★★ 2026-11-26 首帧显影门(见 `FirstFrameRevealGate`):
        //   等本轮 `NSDisplayCycle` + CA 事务提交,再越过一个**真实 VSync 边界**才显影，
        //   不再用 `DispatchQueue.main.async` 抢跑在 GPU 提交之前 ✓
        let syncView = windowsOnly ? previewPanel?.contentView : panel.contentView
        firstFrameRevealGate.schedule(on: syncView) { [weak self, weak panel] in
            guard let self, let panel, panel === self.panel,
                  self.isVisible, self.beginGeneration == showGen, !self.groups.isEmpty else { return }
            // 首帧已显影:托盘从此可以自由上屏(见 `PanelTrayWindow.updatePreview` 的 `holdPreReveal`)
            self.awaitingFirstReveal = false
            // ★ 入场渐入 = **窗口 alpha**(不是内容 opacity,见 PanelView 那条病例)
            //   ⚠️ 不要用 `NSAnimationContext + animator()`:对这扇无边框窗口**根本不跑**
            //      (实测:加完就"闪现"出来,没有任何渐入 ✗)⇒ 自己按 ~8ms 一步推过去 ✓
            if self.windowsOnly {
                // ⌘` 的"只有窗口"那一局:**不上屏环**(长条整块不出现)⇒ 一直 alpha 0 ✓
                // 托盘照常上屏(它是另一个窗口,位置本来就按环的几何算 ⇒ 不会跳)✓
                panel.alphaValue = 0
                panel.ignoresMouseEvents = true
                self.updatePreview()
            } else if self.summonFadeEnabled {
                self.fadeInWindow(panel)
                if let previewPanel = self.previewPanel, !(self.trayChrome?.isContentHidden ?? true) {
                    // 托盘同步渐入:渐入期间 alpha 归 `fadeInWindow` 独家驱动
                    self.isFadingInPreview = true
                    self.fadeInWindow(previewPanel)
                }
            } else {
                panel.alphaValue = 1
                if let previewPanel = self.previewPanel, !(self.trayChrome?.isContentHidden ?? true) {
                    previewPanel.alphaValue = 1
                }
            }
            self.bumpIdle()          // 表一 ④:从"看得见"那一刻开始计时
            // 🔬 连拍放在这里:拍的是"第一次被看见的那几帧",不是 alpha 0 的那几帧
            // ⚠️ 2026-09-21:重型探针**单独门禁**(原来只挂 `isTraceEnabled`)。
            // 病例:为了白光排查,这里一次唤起连抓 12 帧 `CGWindowListCreateImage`(单次 10–50ms ✗),
            // 而 debug.trace 一开它就一直在跑 ⇒ 唤起/早期交互的卡顿有它一份,还污染所有测量。
            // 纪律:重型诊断必须有自己的开关 + 默认关(见 AGENTS.md「诊断开关」)。
            if isTraceEnabled, DebugFlags.screenProbe {
                self.probeShownFrames(panel)
            }
            // 🔬 120Hz 调查:面板上屏后做一次 A/B(只在 debug.hzProbe 打开时,一次性)
            if let hv = panel.contentView { HzCompare.shared.run(panelView: hv) }
            PanelScreen.update(self.contextScreen)
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
        installEscapeMonitor()

        // 起点已就位:首帧提交后把上浮归零 —— "通用"那一层,任何时候都发生
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.entryDelay) { [weak self] in
            guard let self, self.isVisible, self.beginGeneration == showGen else { return }
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
    func logRowAlignment(_ reason: String) {
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

    func setFrameIfNeeded(_ panel: NSPanel, _ rawFrame: NSRect?, caller: String = #function) {
        // ★★ 2026-10-19 病例(日志量出来的,不是猜):
        //   每次唤起都在重设主面板窗框,而两个值只差 0.1~0.6pt:
        //   ```
        //   1884.0x375.0  →  1883.9x374.4
        //   1884.0x375.0  →  1883.9x374.4      ← 每次都"变了",所以每次都真的 setFrame
        //   ```
        //   ⇒ `nearlyEquals` 的 eps = 0.5 卡在中间,永远判"不等" ⇒ 每次唤起白付一次
        //     **同步窗口布局 + 后备存储重分配**(实测 13–60ms,占唤起 34–72ms 的一半)✗
        //   ⇒ 先把目标帧**取整**再比较/设置:1883.9x374.4 → 1884x374,两次一致 ⇒ 直接跳过 ✓
        //     (取整也顺带消除亚像素窗口边界,那本来就会让内容画糊)
        guard let rawFrame else { return }
        let frame = rawFrame.integral
        guard !panel.frame.nearlyEquals(frame) else { return }
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

    /// ★★ 锁屏/睡眠强制收场(2026-10-15 病例:用户锁屏过夜,「屏幕在监视中」整夜 ✗✗
    ///   + 显示器整夜没睡 ✗✗)—— 直播流长在面板手里,面板不收流就不停 ✗
    ///   由组装根(GlanceApp)在锁屏/睡眠那一拍调用 ✓
    func dismissForSystemSleep() {
        guard PanelStageProbe.isVisible() else { return }
        dismiss(reason: "锁屏/睡眠")
    }

    func dismiss(reason: String) {
        cancelPendingReveal()
        // 散场:未兑现的显影门作废 + 门禁复位(下一局 `showPanel` 重新拉起)
        firstFrameRevealGate.cancel()
        awaitingFirstReveal = false
        isFadingInPreview = false
        hintWork?.cancel(); hintWork = nil; hintText = nil
        // ⌘` 的"只有窗口"会话结束 ⇒ 复位(下一局按常规档位)✓
        windowsOnly = false
        PanelMetrics.trayZoom = 1
        idleWork?.cancel()   // 散场就把表撤掉(免得迟到的那一发对着已关的面板说话)
        idleWork = nil
        // 先把在途的 begin 作废:枚举搬后台之后,"括键比枚举先到"是能发生的 ——
        // 不拦的话枚举回来会把面板在放弃之后又冒出来
        beginGeneration &+= 1
        // 换环翻牌:散场时作废"侧立那一拍"的回调并把角度归零
        // (不作废 ⇒ 它会在下一局开始后突然把环换掉 ✗;角度不归零 ⇒ 下次唤起是歪的 ✗)
        ringFlipToken += 1
        ringFlipAngle = 0
        ringWidthBlend = 0
        removeOutsideClickMonitor()
        removeEscapeMonitor()
        entrySelected = false
        launchIndex = nil
        isVisible = false
        // 散场后名单会变(MRU 改了顺序 / 刚才处决了谁)⇒ 缓存在后台续鲜,
        // 下一局唤起才不会"先按旧顺序上屏、真名单一到位置全跳"✗
        refreshStaleListSoon()
        sessionBaseline = nil
        LivePreviewPool.shared.stopAll(reason: "面板关闭")
        // ★★ 2026-10-25(用户实报「按 ` 切窗口,面板看着缩小了一下」):
        //   散场这一拍,托盘还要被重算/重排一次(换组那一瞬的名单/尺寸),而 orderOut
        //   要等到后面 teardown 才发生 ⇒ 用户看到面板**先缩小、再消失** ✗
        //   ⇒ 轨道样式下散场就**当拍收窗**(硬切):冻结帧 + 立刻 alpha 0 + orderOut,
        //     中间的重新布局一帧都不许上屏 ✓
        if WindowLayout.current == .rail {
            holdTrayFrame(seconds: 0.5)
            previewPanel?.alphaValue = 0
            previewPanel?.orderOut(nil)
        }
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
        // 收场:未兑现的显影门作废(它拿着旧 showGen,本就不会再显影)✓
        firstFrameRevealGate.cancel()
        awaitingFirstReveal = false
        isFadingInPreview = false
        endActivity()
        PanelMetrics.sessionCap = .greatestFiniteMagnitude // 会期结束,限额随之失效(不留给设置页读到旧值)
        PanelMetrics.trayCap = .greatestFiniteMagnitude    // 托盘那把尺子同样收掉 ✓
        let didShow = sessionShowedPanel || panel?.isVisible == true || previewPanel?.isVisible == true
        sessionShowedPanel = false
        if didShow {
            FrameProbe.shared.stop() // 面板退场 = 本轮采样结束,直接打一行帧间隔结论
            // ★ 取证:收窗**之前**两扇窗各是什么状态(下次再看到"残留"时,这一行能分清
            //   是"有一扇本来就没收"还是"合成器把两次提交拆开了" ✓)
            trace("[T6] 收场:环 visible=\(panel?.isVisible ?? false) · 托 visible=\(previewPanel?.isVisible ?? false)")
            // ★ 残帧根治(2026-11-22):复用窗的 WindowServer 后备存储与 NSGlassEffectView backdrop 会跨会话保留上一局像素。
            //   收场时同步压 alpha=0 + orderOut + close() + CATransaction.flush()，彻底销毁本局两扇 NSPanel，
            //   下局使用全新未上屏过的 NSPanel / NSHostingView，物理杜绝 WindowServer 吐旧像素 ✓
            let retiredPanel = panel
            let retiredPreview = previewPanel
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            retiredPanel?.alphaValue = 0
            retiredPanel?.ignoresMouseEvents = true
            retiredPanel?.orderOut(nil)
            retiredPanel?.close()
            glog("[窗口] 收场后 环 isVisible=\(retiredPanel?.isVisible ?? false) alpha=\(retiredPanel?.alphaValue ?? -1)")
            trayChrome?.teardown()                       // 真的收窗 + 清账(与 place 配对)
            retiredPreview?.close()
            CATransaction.commit()
            CATransaction.flush()
            panel = nil
            hostingView = nil
            previewPanel = nil
            previewHostingView = nil
            trayChrome = nil
            // ★ 兜底:0.25s 后再确认一次已退役的两扇窗真从 WindowServer 撤下 ✓
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak retiredPanel, weak retiredPreview] in
                if let retiredPreview, retiredPreview.isVisible {
                    glog("[T6] ⚠️ 收场后托盘窗还在台上 ⇒ 强制收掉(兜底)")
                    retiredPreview.alphaValue = 0
                    retiredPreview.orderOut(nil)
                    retiredPreview.close()
                    CATransaction.flush()
                }
                if let retiredPanel, retiredPanel.isVisible {
                    glog("[T6] ⚠️ 收场后主面板还在台上 ⇒ 强制收掉(兜底)")
                    retiredPanel.alphaValue = 0
                    retiredPanel.orderOut(nil)
                    retiredPanel.close()
                    CATransaction.flush()
                }
            }
        } else {
            trace("[T6] 快切静默收场:面板未曾上屏(零窗体开销)")
        }
        var resetFade = Transaction()
        resetFade.disablesAnimations = true
        withTransaction(resetFade) { entryFadeProgress = 1 }
        lastPreviewBundleID = nil
        groups = []
        glassEpoch &+= 1
        lastPointerSample = nil   // 结束采样:下一局第一帧不把跨局位移当成"指针动了"
        stopHoverPolling()
        ThumbnailRefresher.shared.setPanelVisible(false)
        teardown = nil
        onSessionEnd?()
        if didShow {
            // 空闲预建下一局的洁净空窗（只建 SwiftUI 宿主，绝不 orderFront —— 不采样任何屏幕像素 ✓）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, !self.isVisible else { return }
                self.buildPanelIfNeeded()
                self.buildPreviewPanelIfNeeded()
            }
        }
        // **关面板预拍**(T86):窗一拆完,把当前屏幕状态全量拍一遍(TTL 过滤,谁新谁不拍)。
        // 此刻屏幕上就是用户刚看到的内容,拍的图对下一次唤起 100% 新鲜 —— 下次唤起第一帧
        // 全走缓存。延 0.25s 让拆窗收尾先落地;面板若已重开(快速连按)则跳过,新一局有自己的节奏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isVisible else { return }
            ThumbnailRefresher.shared.sweepAllScreens(reason: "关面板预拍")
        }
    }

    /// contextScreen 可视区正中出现(自家窗口的锚定纪律与引导窗一致)
    func centerFrame(for size: NSSize) -> NSRect? {
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
        // ★ 2026-10-08:翻牌期间玻璃长度按 `ringWidthBlend` 在"两环"之间**平滑插值**
        //   (用户实报「直接缩短了,没有动画」✗)⇒ 长度差由翻转自己交代 ✓
        //   静止时一律以 `entrySelected` 为准(唯一真源 ✓ 漏同步也自愈 ✓)
        let w: CGFloat
        if ringFlipAngle != 0 {
            let wm = ringContentWidth(launch: false), wl = ringContentWidth(launch: true)
            w = wm + (wl - wm) * CGFloat(ringWidthBlend)
        } else {
            w = ringContentWidth(launch: entrySelected)
        }
        // 尾格(分割线 + 点阵)已随 T91 撤掉:入口靠键(↓),不再靠显眼的占位 ⇒ 不再留位
        return NSSize(width: w, height: PanelMetrics.rowPadY * 2 + PanelMetrics.icon)
    }

    /// 环内容在**玻璃**里的左缘(2026-09-22)。
    ///
    /// 病例:窗框宽度改成"两环更宽者"之后(为了换环不抖 ✓),**未启动环**比窗框窄 ⇒ 内容居中 ✓,
    ///   而命中区/帧拍仍在按"内容从玻璃左缘开始"算 ✗ ⇒ 整排选中**右移**,
    ///   用户实报:「目前未启动环指针 hover 选中的位置, 跟 app 是对不齐的」✓
    /// ⇒ 命中的横坐标必须**同时**扣掉这个居中偏移(主环偏移为 0 ⇒ 只有未启动环看得出 ✓)。
    var ringContentLeftInset: CGFloat {
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

    /// 窗口**自己**的渐入(0 → 1,130ms,easeOut)。
    ///
    /// 为什么不用 `NSAnimationContext`/`animator()`:实测在那扇无边框面板上不生效
    /// (用户实报「没有淡入的效果了,像是闪现出来的」✗)⇒ 按帧推,8ms 一步 ✓
    /// 为什么不用内容 `.opacity`:内容一透明,图标背后的托底就透出来(见 PanelView 那条病例)✗
    private func fadeInWindow(_ w: NSPanel, duration: Double = 0.13) {
        let gen = beginGeneration
        let isPreview = (w === previewPanel)
        // ★★ 2026-11-26:起点**不退回 0** —— 零透明窗会被 WindowServer 推迟/裁掉
        //   `.glassEffect` 与 Metal 首帧合成 ⇒ 显影第一帧露纯灰/黑 ✗(见 `preRevealAlpha`)
        w.alphaValue = max(Self.preRevealAlpha, w.alphaValue)
        let t0 = CACurrentMediaTime()
        func step() {
            // ★★ 2026-11-22 残帧与幽灵驻留修复:
            //   ① 绝不用 `w.isVisible` 当判据(在 borderless + nonactivatingPanel + level=.popUpMenu
            //      的托盘窗上常常误报 false ✗);
            //   ② 绝不在 `!isVisible`(本局已在 130ms 内提前松手收场)时写 `w.alphaValue = 1`!
            //   ③ 同时校验 `w` 仍是当前会话的在任面板，绝不触碰已退役关闭的旧窗 ✓
            guard isVisible, gen == beginGeneration,
                  (w === panel || w === previewPanel) else { return }
            // ★★ 2026-11-26:渐入途中用户切到无窗 App ⇒ 托盘被 `setContentHidden(true)` 压回 alpha 0,
            //   这里必须当场收手(否则 8ms 后会反向把**隐藏着的**托盘又拉高 ✗)
            if isPreview, (trayChrome?.isContentHidden ?? false) {
                isFadingInPreview = false
                return
            }
            let t = min(1, (CACurrentMediaTime() - t0) / duration)
            w.alphaValue = max(Self.preRevealAlpha, CGFloat(1 - pow(1 - t, 3)))     // easeOut
            if t < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self, weak w] in
                    guard let self, let w, self.isVisible, gen == self.beginGeneration,
                          (w === self.panel || w === self.previewPanel) else { return }
                    step()
                }
            } else {
                w.alphaValue = 1
                if isPreview { isFadingInPreview = false }
            }
        }
        step()
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
    func paddedSize() -> NSSize {
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
        // ⚠️ 2026-11-14 审查发现:这里原本不判面板是否已在台上。保温的目的地是"冷窗"——
        //   若用户在预热时机(+0.15s)前已经唤起了面板,这段会把**正在使用的面板**压黑、
        //   orderOut 再收回 —— 一局当场消失。保温只对"还没上过屏的窗"有意义。
        if panel.isVisible || previewPanel?.isVisible == true {
            glog("[保温] 跳过:面板已在台上(用户已唤起),不可拆台")
            // 图标解码仍要做 —— 它与窗口可见性无关,是"首次画到屏幕"的另一半成本。
            warmIconsInBackground()
            return
        }
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
            w.close()
        }
        // 启动预热窗已完成首帧着色器/布局预热，立即销毁并重建从未上屏过的洁净空窗 ✓
        self.panel = nil
        self.hostingView = nil
        self.previewPanel = nil
        self.previewHostingView = nil
        self.trayChrome = nil
        buildPanelIfNeeded()
        buildPreviewPanelIfNeeded()
        glog("[保温] 首帧合成已预热(屏幕内 + 全透明，已替换为洁净未上屏窗口)")
        warmIconsInBackground()
    }

    /// 图标的首次解码 —— "白光"的另一半。列一份名单画一遍,解码就发生了。
    /// 从 warmFirstFrame 拆出来:图标解码与窗口可见性无关,面板已在台上时也要做。
    private func warmIconsInBackground() {
        // ⚠️ 2026-11-13 病例:这段原先在主线程同步跑,某次启动后主线程在这里卡死 6.5h。
        // ★ 2026-11-20 进一步挪干净:旧版切后台前仍在主线程同步跑 `DockAppsProvider.launchables`
        //   (冷启动会同步解析 Dock plist + LaunchServices)和全系统 `runningApplications.compactMap(\.icon)`
        //   (包含上百个后台守护进程,同步触发 IconServices XPC)。
        //   现在全部移入后台 utility 队列:顺手预热 Dock 候选/在跑缓存与常规 App 的 `IconProvider`,
        //   主线程零阻塞 ✓
        DispatchQueue.global(qos: .utility).async {
            let candidates = DockAppsProvider.computeCandidates()
            let runningSet = DockAppsProvider.computeRunningSet()
            let launchableIcons = candidates
                .filter { !runningSet.contains($0.id) && !runningSet.contains($0.path) }
                .map(\.icon)
            for icon in launchableIcons { Self.decodeIcon(icon) }
            // 只预热常规 GUI 应用(`.regular`),不碰上百个后台 daemon 进程
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let icon = app.icon else { continue }
                Self.decodeIcon(icon)
                IconProvider.prewarm(pid: app.processIdentifier, bundleID: app.bundleIdentifier, image: icon)
            }
            DispatchQueue.main.async {
                DockAppsProvider.storeCandidates(candidates)
                DockAppsProvider.storeRunningSet(runningSet)
            }
            glog("[保温] 首帧已预热(布局 + 图标解码)—— 冷启动的第一次唤起不再交这笔钱")
        }
    }

    /// 把 NSImage 真正解码一次:画进一张 1pt 的离屏位图。
    /// 预热必须花在**启动时**,不能花在唤起那一帧 —— 这是这个仓库对"唤起要快"的一贯口径。
    /// nonisolated:只碰离屏位图与 NSGraphicsContext 的线程本地状态,不碰任何主线程语义 ✓
    private nonisolated static func decodeIcon(_ image: NSImage) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
    }

    private var didInstallKeyLogging = false

    /// key 状态变化账(2026-09-19):验证「点托盘 → 长条丢 key → 玻璃变浅 + 首击被吞」的理论
    private func installKeyTransitionLogging() {
        guard !didInstallKeyLogging else { return }
        didInstallKeyLogging = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // `queue: .main` 只保证"送到主队列";闭包本身是 @Sendable ⇒
                // 读主线程隔离状态必须**显式**声明(否则两条 warning ✗)
                MainActor.assumeIsolated {
                    guard let self, let w = note.object as? NSWindow, w is GlancePanel else { return }
                    let role = w == self.panel ? "长条" : w == self.previewPanel ? "托盘" : "其它"
                    glog("[T6] key 变化: \(name == NSWindow.didBecomeKeyNotification ? "获得" : "失去") → \(role)(win=\(w.windowNumber))")
                }
            }
        }
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        installKeyTransitionLogging()
        panel = makeChromePanel(keyable: false)
        let hosting = ClickThroughHostingView(rootView: PanelView(controller: self))
        hosting.pad = PanelMetrics.shadowPadStrip // 透明呼吸区不吃点击
        hosting.autoresizingMask = [.width, .height]
        panel!.contentView = hosting
        panel!.contentMinSize = .zero
        self.hostingView = hosting
    }

    func makeChromePanel(keyable: Bool = true) -> NSPanel {
        let p = GlancePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isReleasedWhenClosed = false
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

    // MARK: - 确认与放弃

    /// 松手不合面板(T10 毕业为设置面板正式项,UserDefaults key 不变):松手语义在
    /// 触发层处理(那边保持导航态、不发确认),这里只剩一件事——面板外点击是否免死
    /// ⚠️ 2026-09-22 修:这里原来读 `DebugFlags.pinPanelOnRelease`(**淘汰的调试键**)✗
    /// ⇒ 设置/菜单里打开的「保持面板打开」,到这一句就断了:面板外点击照样关面板 ✗
    /// 现在两个读取点都走 `Keys.pinOnRelease`(唯一来源 ✓)
    var pinPanel: Bool { Keys.pinOnRelease }
    /// 长条点击闸(2026-10-16 平移到 PanelDestructiveKeys ✗ 存储属性不能进 extension ⇒ 留在主类 ✓)
    var stripClickGateOn = false

    // MARK: 平移回迁的存储属性(2026-10-16 重构:extension 不能有存储属性 ✗)
    /// 滚轮 / 双指滑动 = 面板里的「Tab」。事件由 **navTap** 转来(会话期才存在的那个 tap,
    /// 它把滚动吞掉,所以底下的 App 收不到),动作仍走 Tab 那条路(`handle(.next/.prev)`)。
    var lastScrollAt: TimeInterval = 0
    /// T11 选中项现拍:选中移到哪个组,就把那组窗重截一遍——触发瞬间的截图在
    /// 钉住浏览几秒后已是旧图。异步不阻塞导航;同 wid 后到覆盖先到,天然取新。
    /// 防抖:同一组 0.5s 内不重复拍(横扫面板时边缘组会被扫过多次)
    var lastRefreshAt: [pid_t: CFAbsoluteTime] = [:]
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
    var lastKeyAt: CFAbsoluteTime = 0
    var lastPointerMoveAt: CFAbsoluteTime = 0
    var lastPointerSample: CGPoint?
    /// "hover 被闸掉"这行账每局只打一次(见 hoverAllowedByGate)
    var gateBlockedLogged = false

    /// 托盘出屏的兜底日志:一个会期只喊一次(见 `previewFrame`)
    var trayOverflowLogged = false
    /// 托盘本局是否已经上屏过(只为上面那行日志:区分"首次渐入"与"后续更新" ✓)
    var trayShownOnce = false

    // MARK: 启动区(方案 E「入口槽」,T83;设计稿 design/启动区实验台.html,用户 2026-09-16 拍板)
    //
    // 未启动 App = Dock 常驻且没在跑的(「无窗应用」是**在跑没窗**,这是两个概念,别混)。
    // 它们不进主环 —— 主环是"切换的世界",一格 = 一个活跃 App;它们住在**入口槽后面的托盘里**:
    // 托盘本来就承载"选中格的内容"(活跃格 → 窗口卡,入口槽 → 启动图标行),零新增语法。
    // 常态下面板与今天一个像素不差(没有第二行);Tab 走到主环末尾再按一次 = 选中入口槽。
    /// Dock 常驻且未在跑的 App(每局 begin 时取一次,按 Dock 顺序)
    @Published var launchables: [DockAppsProvider.LaunchableApp] = []
    /// 入口槽被选中(托盘切到启动行)
    @Published var entrySelected = false
    /// 启动行内的选中下标(nil = 入口槽选中但还没进到行内某格)
    @Published var launchIndex: Int?
    /// T91:"换环到未启动"的意图(四指轻点专用)。
    /// 触发层那一发比后台枚举**先到**,名单还没装好 ⇒ 先记在这里,`finishBegin` 里兑现。
    var pendingLaunchRing = false
    /// 意图的**出生时刻**。给意图加寿命是结构性兜底:它只可能活在"触发层比枚举先到"的那一瞬。
    /// 病例(2026-09-17,用户实报「启动之后唤起了一次, 后面就变成启动环了」)—— 症状=意图活了不止一瞬。
    /// 与其猜是哪条路漏了清,不如让**过期本身就等于丢弃**:这样无论漏清在哪,幽灵都活不过 1.5s。
    var pendingLaunchAt: CFAbsoluteTime = 0
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
    var confirmBeforeList = false
    /// 本局名单是否已落地(区分"还没到"与"真的空")✓
    var listReady = false
    /// 等名单的兜底闹钟(见 `confirmBeforeList`)
    var confirmWaitWork: DispatchWorkItem?
    /// 段切换的行进方向(见 `SegmentTravel`)。PanelView 靠它挑过渡:
    /// 沿环走 = 内容横滑,↓/↑ 跳段 = 淡切
    @Published var segmentTravel: SegmentTravel = .direct
    /// **整条环的翻牌角度**(0 = 正对;±`PanelMetrics.ringFlipLimit` = 侧立)。
    ///
    /// ★ 2026-10-08 用户口径:「换环要**整条环**翻(玻璃 + 图标一起),不是只翻图标」+「先做 88°」。
    ///   为什么自己做而不用 `.transition`:系统「减弱动态效果」开着时 SwiftUI 会**自己**把过渡
    ///   降级成淡入淡出,而 `\.accessibilityReduceMotion` 是**只读**的、覆盖不了 ✗
    ///   ⇒ 用户实报「Glance 里开了强制完整动效,换环的翻牌还是只剩环变形」✗
    ///   ⇒ 改成参数驱动(与托底 PuckView 同一套哲学):**设置说什么就是什么** ✓
    @Published var ringFlipAngle: Double = 0
    /// 换环的**目标**环(连按时的意图)。与 `entrySelected` 分开存:
    /// "内容什么时候换"只看目标 ⇒ 翻牌中途改主意也不会半路换错 ✓
    @Published var ringFlipTarget = false
    /// **入场渐入的进度**(0 = 还没出现,1 = 落定)。
    ///
    /// ★ 2026-10-08:用户提「Spotlight 唤起有个 Q 弹的动效」⇒ 按 Apple 录屏**逐帧量**出来的参数实现:
    ///   起始比最终宽 ~7%、130ms 内 ease-out 收位、并快速淡入 ✓(与我第一版"从小涨大"的方向相反 ✓)
    /// ⚠️ 只作用于**环里那块内容**,不动玻璃 —— 原生玻璃不能被变换(材质会掉 ✗)
    /// ⚠️ 起跳**延后一拍**(见 showPanel):提前起跳会踩 AppKit 的"Update Constraints in Window pass"
    ///   递归 ⇒ 一唤起就 SIGABRT ✗(缩放/位移两版都验过;延后一拍是唯一活路 ✓)
    ///   渐入虽不动几何,这条**照旧保留** —— 它保护的是"上屏那一拍的布局",与动什么无关 ✓
    @Published private(set) var entryFadeProgress: Double = 1
    /// **入场渐入的进度**(0 = 还没出现 · 1 = 落定)。视图拿它当 `.opacity` —— **不动任何几何** ✓
    ///
    /// 史(2026-10-08 一天之内):这里先后是「整块横向 1.04→1.00 的拉伸」→「带 duang 的弹簧」
    /// →「纯 transform 的横向橡皮筋」;用户三评之后定为**渐入**:
    ///   「要 fade 吧, 看起来是一个**渐入**的效果。**没有任何的弹动**呢, 比之前的两段弹簧要好」
    /// 换掉的**硬理由**(不是审美):动几何 ⇒ 命中区(用落定尺寸)与画面(被拉伸)**不一致** ✗
    ///   —— 9 个 App 那局最外侧那颗被推离 ≈22pt,而格距才 68pt ⇒ 想点的那颗可能正好在缝里 ✓
    ///   渐入没有这个病:从第一帧起"看到的就是点得到的" ✓
    var entryFade: Double { entryFadeProgress }
    /// **玻璃长度的插值**(0 = 主环那份宽,1 = 未启动环那份宽),与翻牌同拍。
    ///
    /// 用户口径(2026-10-08):「环长度变化那一下没有动画,直接缩短了」⇒ 要**平滑**过去 ✓
    /// ⚠️ 曾经以为"逐帧改玻璃宽度会掉材质" ✗ —— 那是**假结论**:当时容器层还挂着
    ///   `rotation3DEffect`,玻璃一直在被转 ✗(见 PanelView 尾部那段注释)。
    ///   残留删掉之后,逐帧改宽度是安全的 ✓
    /// ⚠️ 它只在翻牌期间有意义:`contentSize()` 在"角度为 0"时一律以 `entrySelected` 为准
    ///   (唯一真源 ⇒ 万一哪里漏了同步,静止态也自愈 ✓)
    @Published var ringWidthBlend: Double = 0
    /// 每次换环 +1;收尾回调靠它判过期(又按了一次 ⇒ 旧回调丢弃 ✓)
    var ringFlipToken = 0
    /// 已经走完"侧立那一拍"的 token(兜底定时与完成回调谁先到都只算一次 ✓)
    var ringFlipMidDone = -1
    /// "换环进行中"的窗口(2026-09-22):托盘内容在换环那一拍要**当拍**换(与环的翻牌同步 ✓),
    /// 而 hover 换组时要**滑**(用户实报「hover app 托盘只会闪现, 没有滑动了」✓)。
    /// 用时间窗而不是开关:换环是同步一瞬间的事,没有"结束"回调可挂 ✓
    var ringSwapUntil: CFAbsoluteTime = 0
    var isRingSwapInFlight: Bool { CFAbsoluteTimeGetCurrent() < ringSwapUntil }
    /// **指针帧拍的心跳**(2026-09-18 实测翻案):TimelineView(.animation) 在**静态窗口上不跳帧**
    /// —— macOS 不给静止的窗口排帧,所谓"每帧兜底"实际只在"有视图更新的那几拍"生效。
    /// 实测账:warp 挪指针后 300ms 内一次采样都没发生,直到下一次键盘动作触发重绘才补上
    /// —— 这就是"键盘操作完、鼠标接管慢半拍"的真身:兜底只在界面刚动过时活着,
    /// 而恰恰是"界面静止、指针开始动"的那一刻最需要它。
    /// 现在面板在台期间挂 60Hz 定时器,统一驱动主环与托盘的指针重定位;散场即停。
    var hoverPollTimer: DispatchSourceTimer?
    /// 启动区这局关了(设置开关/名单为空)—— 视图与键盘路径都靠它短路
    var launchSectionEnabled: Bool { !launchables.isEmpty }
    // (2026-09-19)「悬停回退单」机制整段退役 —— 病例:四指/键盘进段后,指针不在面板上,
    // 0.12s 后段被它静默收掉,白名单 App 还没确认就回到主环(用户实报「白名单的 App 没办法启动」,
    // 日志:段内选中 → 半分钟后主环选中 → 确认,中间无任何段操作)。回退单是"入口槽 +
    // 悬停预览"时代的语义(指针离开启动区 = 用户不要了);模型 C 里段只能由 ↓/四指/Tab
    // **主动**进入,指针在不在面板上与段的生死无关 —— 段保持粘性,由 ↑/Tab/Esc/闲置超时收场。
    /// 本局内被 H 隐藏的 App。为什么要记:
    /// 隐藏是**异步**的(0.2–0.3s 动画),这期间重枚举**还看得见它的窗** ——
    /// 不记住的话,卡片会在 0.18s 后闪回来(用户实报:「先是消失了,然后又出现了」)。
    var hiddenPIDs: Set<pid_t> = []
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
    var quitPIDs: Set<pid_t> = []
    /// 本局已被我们**关掉/最小化**的窗(CGWindowID),等着复核。
    ///
    /// 病例(2026-09-17,用户实报):"点击关闭之后, 面板没关闭, 就又出现了."
    /// 日志一字不差:`[T12] 关闭窗口: DataGrip — Confirm Exit` → `本地先摘 17 窗 → 16 窗`
    /// → 0.2s 后 `[处决后顺序]` 它又回来了,来回三次。
    /// **那扇窗是 App 自己的确认框**(modal alert),AX 的 close 对它无效 —— 它压根关不掉。
    /// 所以"先摘"必须像 `verifyQuit` 一样**复核**:真没了才留摘除的样子,还在就**放回原位**。
    var purgedWIDs: Set<CGWindowID> = []
    /// 开启「显示最小化窗口」时，按 M 后短时（0.9s）锁住该窗为 `isMinimized = true` 且排在尾部，
    /// 防止 0.18s 重枚举撞上 macOS 最小化动画尚未播完而把它弹回队首。
    var optimisticMinimizedWIDs: Set<CGWindowID> = []
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
    var minimizedWIDs: [CGWindowID: pid_t] = [:]
    /// 环上要打"已收纳"记号的 App(由上面那张表推出来 ✓ —— 单一源 ✓)
    var minimizedPIDs: Set<pid_t> { Set(minimizedWIDs.values) }
    /// 让 `minimizedWIDs` 的变化**一定会**触发重绘(它是普通字典,不会自己 publish ✗)
    @Published var marksRevision = 0
    /// **本局**被我们缩小过的 App —— 只给"松开时不许唤醒它"这条守卫用 ✓
    ///
    /// ⚠️ 它与上面那张**常驻**表是**两种寿命**,别混(2026-09-22 用户两条实报互相约束):
    ///   · ① 「cmd m 会缩小…松开之后会立马把缩小的窗口又换起来」✗ ⇒ 本局不许唤醒 ✓(否则那次缩小等于白按)
    ///   · ② 「关闭再唤起之后, 选中 app 拉不起窗口了」✗ ⇒ **另起一局**的确认必须能把它拉回来 ✓
    /// ⇒ 记号(视觉)常驻 ✓;守卫只活一局 ✓ —— 用户的手离开键盘之后再确认,就是"我要它回来" ✓
    var sessionMinimizedPIDs: Set<pid_t> = []
    var didObserveHiding = false
    /// 环上要打"已隐藏"记号的 App(**现读系统真实状态** ✓ ⇒ 只要还是 hide 就有记号 ✓,
    /// 自己从 Dock 点回来 ⇒ 记号自动消失 ✓ 不需要谁去清 ✗)
    @Published var hidingPIDs: Set<pid_t> = []

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
    private(set) var hidden = false         // 内容隐藏(用户看不见 ≠ 窗口不在台上)
    /// ★★ 2026-10-08 加(用户实报「未启动环里指针在面板之外 hover 也能改选中」):
    ///   "窗口在台上" ≠ "内容看得见" —— 2026-09-21 起,托盘"没内容"时不再 `orderOut`,
    ///   而是 **alpha 0 + 忽略鼠标**(为了省掉每次 hover 的窗口排序 4–35ms ✓)。
    ///   于是 `isVisible == true` 却什么都看不见 ⇒ 谁拿 `previewContentRect()` 算几何都会算到
    ///   **一块看不见的地板**上 ✗(指针/点击落进那片区域照样生效 ✗)。
    ///   ⇒ 判"在不在台上"必须问**这个**(唯一真源),不要再拿 isVisible 猜 ✓
    var isContentHidden: Bool { hidden }
    /// 这一局是否已经收场(收场后禁止 place ✓ —— 见 `place()` 的病例)
    private var sessionEnded = true

    /// 角色名(只给日志/判据用):"环" / "托"
    private let role: String

    init(_ panel: NSPanel, role: String = "窗") {
        self.panel = panel
        self.role = role
    }

    /// 确保在台上 + 内容可见。**幂等**:重复调用不产生任何窗口排序 ✓
    ///
    /// ★★ 2026-09-22 用户实报(「有时候环消失了, 预览容器还在。都松手回到 app 了, 容器还在」)——
    ///   真因:原来是"没在台上就上屏"✗,而它的调用点在 **`updatePreview()`** = **每次 hover 更新**都跑 ✗。
    ///   收场(`teardown()` 把 `placed` 清成 false ✓)之后,只要**再来一次迟到的更新**
    ///   (视图重渲染 / 延迟的布局 pass ✓)⇒ 托盘又被 `orderFrontRegardless` ✗;
    ///   而主面板那次没人再上屏 ⇒ 症状正是"**环没了、托盘还在**" ✓
    ///   ⇒ 加**会话闸**:收场之后、下一局 `beginSession()` 之前,`place()` 一律 no-op ✓
    ///   (连 `hidden` 都不碰:会话结束后它就该保持隐藏 ✓)
    /// - Parameter holdAlpha: 上屏时窗口该先停在哪个 alpha(默认 `nil` = 可见)。
    ///   开局首拍传 `PanelController.preRevealAlpha`（肉眼不可见的非零值):既不提前把未提交首帧的
    ///   托盘亮出来,又不会让 WindowServer 把零透明窗当成"没东西"而推迟首帧合成 ✓
    func place(holdAlpha: CGFloat? = nil) {
        guard !sessionEnded else { return }
        if hidden {
            hidden = false
            panel.ignoresMouseEvents = false
            if holdAlpha == nil { panel.alphaValue = 1 }
        }
        if let holdAlpha {
            panel.alphaValue = holdAlpha
        }
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
        // 只打"转场"那一行(调用点每帧都来,但这里被 `on != hidden` 挡着 ⇒ 一条消息只响一次 ✓)
        // ⚠️ ChromeWindow 不是 PanelController ⇒ 用不了那边的 `trace`(那是它的私有方法)⇒
        //    这里判同一个开关 `isTraceEnabled` 再用 glog ✓(口径一致,不多立一个开关 ✓)
        if isTraceEnabled {
            glog(on ? "[托盘] 内容隐藏(alpha 0 + 忽略鼠标)⇒ 从此不参与指针与点击 ✓"
                    : "[托盘] 内容恢复可见 ⇒ 重新参与指针与点击 ✓")
        }
        panel.alphaValue = on ? 0 : 1
        panel.ignoresMouseEvents = on
    }

    /// 整局收场:真的腾出窗口 + 清账(与 place 严格配对)
    func teardown() {
        sessionEnded = true          // ★ 收场 ⇒ 迟到的 place() 不许再上屏(见 place 的病例 ✓)
        placed = false
        hidden = false
        // ★ 2026-11-21 残帧修复:收场时把 alpha 置 0 再 orderOut(旧版置 1 导致带旧像素入库,
        //   下一局 orderFront 时一旦主线程高负载没及时刷完新帧,WindowServer 就会直接把旧帧亮出来 ✗)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderOut(nil)   // ⚠️ 不再 disableScreenUpdatesUntilFlush(见 teardownPanel 的病例 ✓)
        glog("[窗口] 收场后 \(role) isVisible=\(panel.isVisible) alpha=\(panel.alphaValue)")
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

/// 首帧显影门(2026-11-26)
///
/// 为什么不能只等一次 `CFRunLoopBeforeWaiting`(旧 `scheduleAfterDisplayCommit` 的做法):
///   · 那个回调**不代表 GPU 已经画完** —— 同一毫秒把 `alphaValue` 拉到 1 时,
///     WindowServer 手里可能还是"刚扩容、尚未渲染"的空白表面 ⇒ 用户看到 1~2 帧纯灰/黑矩形 ✗
///   · 而被推迟的合成还有第二个原因:窗口以 `alpha == 0` 上屏,macOS 26 会跳过/推迟
///     `.glassEffect(.clear)` 与 Metal 首帧合成 ⇒ 显影那一拍正好露灰底 ✗
/// ⇒ 门的三拍:
///   ① 一次性 `CFRunLoopObserver(beforeWaiting, order: CFIndex.max)`:排在 CA 提交(order 2_000_000)
///      之后,记下 `commitAt`,再挂 `displayLink` + 兜底;
///   ② 每个 VSync 检查 `CACurrentMediaTime() - commitAt >= minCommitWait`(默认 8ms)——
///      120Hz 屏上紧跟提交的那一拍 VSync 只差 1~2ms,属于"提交还没被合成器消费",不算 ✓;
///   ③ `fallbackMs`(默认 45ms)兜底:displayLink 拿不到时也不许把面板卡在隐形 ✓
@MainActor
private final class FirstFrameRevealGate: NSObject {
    private var runLoopObserver: CFRunLoopObserver?
    private var displayLink: CADisplayLink?
    private var fallbackWork: DispatchWorkItem?
    private var action: (@MainActor () -> Void)?
    private var commitAt: CFTimeInterval = 0
    private var minCommitWait: CFTimeInterval = 0.008

    func schedule(on view: NSView?, minCommitWait: CFTimeInterval = 0.008, fallbackMs: Int = 45,
                  _ block: @escaping @MainActor () -> Void) {
        cancel()
        self.minCommitWait = minCommitWait
        action = block
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { [weak self] obs, _ in
            if let obs { CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes) }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runLoopObserver = nil
                self.armAfterCommit(on: view, fallbackMs: fallbackMs)
            }
        }
        if let observer {
            runLoopObserver = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.armAfterCommit(on: view, fallbackMs: fallbackMs) }
            }
        }
    }

    /// CA 事务已提交(或退化路径):从这里开始等 VSync
    private func armAfterCommit(on view: NSView?, fallbackMs: Int) {
        commitAt = CACurrentMediaTime()
        guard action != nil else { return }
        guard let view, view.window != nil else {
            // 没有可挂 VSync 的视图(窗口还没进 WindowServer 列表)⇒ 退化成一次 16ms 的等
            armFallback(after: .milliseconds(16))
            return
        }
        let link = view.displayLink(target: self, selector: #selector(handleTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        armFallback(after: .milliseconds(fallbackMs))
    }

    private func armFallback(after delay: DispatchTimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        fallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private nonisolated func handleTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            // 至少越过 `minCommitWait` 且经过真实 VSync 边界:提交那拍紧邻的早到 VSync 不许抢跑 ✓
            guard CACurrentMediaTime() - commitAt >= minCommitWait else { return }
            fire()
        }
    }

    /// 兑现一次(只有第一次有效;先 `cancel()` 清 observer / link / 兜底定时器,再跑 block)
    private func fire() {
        guard let block = action else { return }
        cancel()
        block()
    }

    func cancel() {
        if let runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        }
        runLoopObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        fallbackWork?.cancel()
        fallbackWork = nil
        action = nil
    }
}
