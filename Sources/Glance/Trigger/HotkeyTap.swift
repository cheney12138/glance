import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GlanceCore

/// 触发层(v1.13 架构,**不再靠吞键防原生切换器**)。
///
/// 四个部件,各司其职,越往下越有特权:
/// 1. **Carbon `RegisterEventHotKey`** —— 触发键(⌘Tab)与反向(⌘⇧Tab)的收键口。系统直接把和弦交给我们,
///    前台 App 收不到,所以**不需要吞**;原生那条已由 `NativeSwitcherHotkeys` 从系统注册表上关掉。
/// 2. **`flagsTap`**(`.cgSessionEventTap` + `.listenOnly` + `flagsChanged`)—— 只听修饰键的按下/释放,
///    撑起 hold 语义(按下 = 待命,松开 = 确认)。只读 tap 从根上不碰输入法:参考实现 #5766 的血案是
///    "一个常开的 HID keyDown tap 把第三方输入法搞坏了(越南语 EVKey)",之后他们就把主 tap 改成这个配置。
/// 3. **`mouseTap`**(`.listenOnly` + `leftMouseDown`)—— ⌘+点击补焦(T7.5)的耳朵,同样只听不吞。
/// 4. **`navTap`**(`.cghidEventTap` + `.defaultTap` + `keyDown`)—— **唯一有吞键权的那个**,而且
///    创建时是禁用的,只在导航态里打开(吞 Esc/←→/Q/W/M)。参考实现同一手法(`updateEscapeAbsorptionTap`):
///    能吞的窗口缩到最小,而且它被系统停用也不影响触发(触发走 Carbon,与它无关)。
///
/// 状态机不变:`idle ─触发→ navigating ─松修饰键→(确认)idle`,`Esc` = 放弃,
/// 导航期 Q/W/M = 破坏性操作(处决即散场)。
@MainActor
final class HotkeyTapCenter {

    /// ⌘` 接管:参数 = 是否向前(⇧ = 反向 ✓)。**由 App 层装配**(Trigger 不许反向依赖 App 层 ✗,
    /// 见 `Sources/Glance/App/SameAppScreenCycler.swift` 的头注 ✓)
    var onSameAppScreenCycle: ((Bool) -> Void)?


    enum State { case idle, armed, navigating }

    /// 导航期间的一次动作。T6 面板、T7 聚焦以后订阅这个出口,不直接碰事件层。
    enum Action {
        case begin            // 首次 ⌥+Tab:进入导航态(面板应出现)
        case beginReverse     // 首次 ⇧⌥+Tab:同上,但方向相反(落点判断要用,见 PanelController)
        case next             // Tab:图标层后移
        case prev             // ⇧Tab:图标层前移
        case firstGroup      // ←:跳到**最左**的 App
        case lastGroup       // →:跳到**最右**的 App
        /// ↓:把**整个环**换成"未启动的 App"(T91)。是**内容替换**,不是多长一行 ——
        /// 用户口径:「我想的是完全覆盖掉诶, 不是 2 行的概念」。
        case enterLaunchRing
        /// ↑:换回"已启动的 App 组"。与 ↓ 成对(有进有出,不用 Esc 也能回来)
        case leaveLaunchRing
        /// ` 循环窗口:在**当前 App 的窗口之间**循环 —— 与 ←/→ 是两件事
        /// (2026-09-15 分家:原先是同一个 case,导致两个键做同一件事)
        case cycleWindowPrev
        case cycleWindowNext
        /// 数字键:直接选中当前 App 的第 N 扇窗(1-based 在这里转成 0-based)
        case pickWindow(Int)
        case confirm          // ⌥ 释放:确认(聚焦选中窗)
        case cancel           // Esc:放弃
        case yieldToCapture   // 截图中按回车:关面板、不聚焦(回车的第一所有权在截图工具,见 CaptureSessionRule)
        case quitApp          // Q:退出选中 App(T12)
        case closeWindow      // W:关闭选中窗(T12)
        case minimizeWindow   // M:最小化选中窗(T12)
        case toggleFullscreen // F:选中窗进出全屏(T29,AltTab 同键)
        case hideApp          // H:隐藏选中 App(T29,AltTab 同键)
        /// T:把选中的窗**搬到下一块屏**(2026-09-22 用户点名的 P2)。
        /// 单屏时什么都不做(会记一行日志说明 ✓);两块屏以上**循环** ⇒ 再按一次就搬回来 ✓
        case moveToNextScreen
    }

    private(set) var state: State = .idle
    /// T6 起由面板控制器赋值;T3 阶段默认为打印。
    var onAction: ((Action) -> Void)?
    /// 会话期间的滚动(由 navTap 转来)。面板是浮层 ⇒ 滚动**只该服务于面板**,
    /// 所以 navTap 那一发被吞掉,底下的 App 收不到。
    var onScroll: ((NSEvent) -> Void)?
    /// T91 表一 ⑤:导航期里出现"**不是我们键**"的那一发 = 用户开始做别的事。
    /// 面板那边据此收掉钉住的那一局(治"牛皮糖")。**只旁观,不吞键** —— 与 onScroll 同一纪律。
    var onElsewhereInput: (() -> Void)?
    /// T7.5:⌘+左键点击(Quartz 全局坐标)。导航态里挂起(Q9-④)
    var onCmdClick: ((CGPoint) -> Void)?

    private var flagsTap: CFMachPort?
    private var mouseTap: CFMachPort?
    private var navTap: CFMachPort?
    private var hotKeyRef: EventHotKeyRef?
    private var reverseHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var appliedTrigger: TriggerConfig?
    private var appliedTakeover = false
    private var defaultsObserver: NSObjectProtocol?

    /// 自家 Carbon 热键的签名与 id(签名用来挡住别人的热键事件串门)
    private static let hotKeySignature = OSType(0x676C6E63) // 'glnc'
    private enum HotKeyId: UInt32 { case forward = 1, reverse = 2 }

    /// 1…9:直接跳到**当前 App 的第 N 扇窗**(数字 = 跳,与 ` 的"走"并存,CONTEXT.md「走 / 跳」)。
    /// **主键盘与小键盘都收**:用户原话"有时候不想用小数字键盘选窗口"——
    /// 两种到达方式都要可用,别把口子封死(2026-09-15 的教训)。
    /// 只在会话内生效:navTap 只在导航态挂着,平时数字键照旧打字。
    private static let digitKeys: [Int64: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,  // 主键盘
        0x53: 1, 0x54: 2, 0x55: 3, 0x56: 4, 0x57: 5, 0x58: 6, 0x59: 7, 0x5B: 8, 0x5C: 9,  // 小键盘
    ]

    private static let keyLeft: Int64 = 0x7B
    private static let keyRight: Int64 = 0x7C

    /// ↓ / ↑(T91):**换环**。环里装的东西整体换掉 —— 下 = 未启动的 App,上 = 已启动的 App 组。
    /// 这两个键在导航期本来是空档(`←/→` 是首/末 App)。放进 navKeys = 会话期被我们吞掉,
    /// 底下的 App 收不到 —— 与其它导航键同一个约定。
    private static let keyDown: Int64 = 0x7D
    private static let keyUp: Int64 = 0x7E
    private static let keyEsc: Int64 = 0x35
    private static let keyReturn: Int64 = 0x24
    /// 空格(0x31)—— **确认**,与回车同一支(2026-09-22 用户要求:「有时候回车确认太麻烦了,
    /// 手还要移动到右边,新增一个空格确认的功能吧」)。
    /// ⚠️ 两条边界,写在这里免得以后被"优化"掉:
    ///   · **按住触发键(⌘)的那一局**,空格会组成 ⌘Space —— 那是系统 Spotlight 的热键,
    ///     可能**先于**我们的 tap 被系统收走 ⇒ 那一局空格不一定到得了我们手里(松 ⌘ 确认照旧有效 ✓);
    ///   · 三指唤起是**钉住**局(没有 ⌘),空格就是纯空格 ⇒ 一定会走到我们这里 ✓ 也正是用户的主用法 ✓。
    /// 既已进 `navKeys` ⇒ 导航期会被**吞掉**(底下的 App 收不到空格、不会翻页)✓ 与其它导航键同一约定 ✓。
    private static let keySpace: Int64 = 0x31
    private static let keyQ: Int64 = 0x0C
    private static let keyW: Int64 = 0x0D
    private static let keyM: Int64 = 0x2E
    private static let keyF: Int64 = 0x03
    private static let keyH: Int64 = 0x04
    /// `T`(0x11)—— **搬到下一块屏**(P2)。选它是因为:字母区空着的位置 ✓、
    /// 且 `T` 与既有动作键(Q/W/M/F/H)不冲突 ✓
    private static let keyT: Int64 = 0x11
    /// 导航期被吞的固定键:方向/Esc/Enter + Q/W/M 破坏性键盘操作(CONTEXT.md)+ 数字 1…9
    /// ⚠️ 唯一的例外是**截图会话里的回车**:那一发不吞(它是截图工具的"完成"),见 `handleReturn()`
    ///
    /// ⚠️ 数字**必须在这里登记**:`handleNavKey` 第一句就是
    /// `guard Self.navKeys.contains(keyCode) else { return false }` —— 这是一道**前置闸门**,
    /// 没登记就走不到后面的 switch(第一次加数字键时漏了这步,功能会**静默失效**:
    /// 按 2 不选中,还把 "2" 放行给底下的 App)。
    /// `Set([...])` 必须显式写:直接写数组字面量再 `.union` 会被推成 `[Int64]`(实测编译错)。
    private static let navKeys: Set<Int64> =
        Set([keyLeft, keyRight, keyDown, keyUp, keyEsc, keyReturn, keySpace,
             keyQ, keyW, keyM, keyF, keyH, keyT, keyGrave])
            .union(digitKeys.keys)
    /// **⌘ + 动作键**(全匹配)⇒ 作用在"选中的那个 App / 那一扇窗"上。
    ///
    /// 病例(2026-09-21 用户实报「三指唤起后按 q/w/f/m/h 只会关面板」):用户按的是 **⌘Q/⌘W/⌘M/⌘H/⌘F**
    /// ⇒ 那一发带 ⌘ ⇒ 撞上"修饰键门禁"(`pinnedSession ? [] : config.modifierMask`)被当成"不是我们的键"放行 ✗
    /// ⇒ 而放行的副作用正是 `onElsewhereInput()` ⇒ **关面板,动作一个都没做** ✓。
    /// 为什么 ⌘Tab 唤起时正常:那是**按住触发键**的局(⌘ 本来就在 `config.modifierMask` 里,门禁放行它)✓;
    /// 三指唤起是"钉住"局(允许集为空)✗ ⇒ 差别就在这里。
    /// 用户口径:「那肯定是**全匹配**啊。快捷键还能模糊匹配吗。」⇒
    /// 判据 = 修饰键**恰好**是 ⌘(多一个 ⇧/⌃/⌥ 都不算):⌘⇧Q 是注销、⌃⌘W/⌥⌘W 是用户自己的热键 ✓
    /// ⇒ 一律放行,绝不动用户选中的窗(守住 2026-09-17「⌃⌘W 误杀」那次病例)✓。
    private static let cmdActionKeys: [Int64: Action] = [
        keyQ: .quitApp, keyW: .closeWindow, keyM: .minimizeWindow,
        keyF: .toggleFullscreen, keyH: .hideApp,
        keyT: .moveToNextScreen,
    ]
    
    /// `(kVK_ANSI_Grave = 0x32):会话期可选地接管"当前 App 的窗口循环"。
    ///
    /// 为什么这个键值得单独说:它同时是 macOS **全局**的"同 App 窗口循环"(⌘`) ——
    /// 我们**不去关系统热键**(DockDoor 的做法,源码实证):靠 navTap 会话期吞键即可,
    /// 系统那条热键在 WindowServer 层是更晚的环节,吞掉就收不到。
    /// 代价与 Tab 循环同一条:tap 若被系统停用那一瞬,这一发会漏给系统(见 ADR-0005 的取舍)。
    /// 默认**关**:它动的是系统级快捷键的肌肉记忆,只能用户显式开(与接管 ⌘Tab 同一纪律)。
    private static let keyGrave: Int64 = 0x32
    /// 接管系统 ⌘` 的开关(opt-in;`object(forKey:)` 区分"没写过"与"写成 false" ✓ —— 同 `Keys` 其它开关)
    private static var graveTakeoverEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.triggerTakeoverGraveCyclesWindows) as? Bool
            ?? KeyDefaults.takeoverGraveCyclesWindows
    }

    /// 「唤起即切换」(默认开 ✓;与设置面板同一个键、现读 ✓)
    private static var advanceOnOpen: Bool {
        UserDefaults.standard.object(forKey: Keys.switchAdvanceOnOpen) as? Bool ?? KeyDefaults.advanceOnOpen
    }

    private static var graveCyclesWindows: Bool {
        UserDefaults.standard.object(forKey: Keys.switchGraveCyclesWindows) as? Bool ?? KeyDefaults.graveCyclesWindows
    }
    /// 面板出现期间是否接管滚动(设置里的「双指滑动换组」,默认开)。
    /// 关掉时必须**放行**:设置里的说明写着"关闭后…照常交给底下的应用"。
    private static var scrollMovesSelection: Bool {
        UserDefaults.standard.object(forKey: Keys.switchScrollMovesSelection) as? Bool ?? true
    }

    /// 钉住开关:松 ⌥ 不关面板,状态机保持导航态,Enter 接手确认权(用户实评"还挺实用")
    // ★ 2026-09-22:从 `DebugFlags.pinPanelOnRelease`(调试键,每次启动被清 ✗)提升为**用户设置** ✓
    //   优先看启动参数(自动化测试用 ✓),否则看设置里那一行 ✓
    private var pinPanel: Bool { Keys.pinOnRelease }   // 唯一读取点(见 Keys.pinOnRelease)✓

    /// **三指点按起来的那一局**:没有键可松 ⇒ 松手语义整个不适用。
    /// 与上面的调试旋钮分开:`pinPanel` 是"按住也钉住"(调试),这个是"本来就没握住"。
    private var pinnedSession = false


    // MARK: - 生命周期

    func start() {
        guard flagsTap == nil else { return }
        // 启动自愈:上一次运行如果被 SIGKILL(谁也拦不住的那种),原生 ⌘Tab 会一直死着 —— 先全恢复。
        // 标记文件还在 = 上次确实是被强杀带走的(见 `NativeHotkeys` 的"脏退出标记"):明说一句,
        // 否则"⌘Tab 死了"这件事在日志里完全不可见,只能靠猜。
        if NativeHotkeys.consumeTakeoverMarker() {
            print("[T13] 上次退出没来得及归还原生热键(强杀)——本次启动已自愈")
        }
        NativeHotkeys.restoreAll()
        normalizeLegacyTakeoverState()

        installEventHandler()
        flagsTap = makeTap(at: .cgSessionEventTap, options: .listenOnly, types: [.flagsChanged])
        mouseTap = makeTap(at: .cgSessionEventTap, options: .listenOnly, types: [.leftMouseDown])
        navTap = makeTap(at: .cghidEventTap, options: .defaultTap, types: [.keyDown, .scrollWheel])
        guard flagsTap != nil else {
            print("[Glance] 触发层创建失败——辅助功能权限未就绪,触发层不工作")
            return
        }
        registerTrigger(TriggerConfig.load())
        NativeHotkeys.apply(trigger: TriggerConfig.load(), takeover: TriggerConfig.takeoverEnabled)
        observeTriggerChanges()
        print("[Glance] 触发层上线(Carbon 热键 + 3 tap;只有会话期的 navTap 有吞键权)")
    }

    /// 归一历史状态:老版本把"接管"记在触发键上(键写成 ⌘Tab 就算接管),而现在的口径是
    /// **必须用户显式开过那个开关**。于是:没开过开关、却留着一条与系统热键重叠的触发键
    /// → 清掉它、回到 ⌥Tab,并把系统热键还回去。想接管,去设置里开那一个开关(它会同时把键写成 ⌘Tab)。
    private func normalizeLegacyTakeoverState() {
        guard !TriggerConfig.takeoverEnabled,
              NativeHotkeys.overlapsNativeHotkey(TriggerConfig.load()) else { return }
        UserDefaults.standard.removeObject(forKey: Keys.triggerKeyCode)
        UserDefaults.standard.removeObject(forKey: Keys.triggerModifier)
        print("[T13] 未开启「接管系统切换器」:触发键已归位到 ⌥Tab,系统热键一行没动")
    }

    /// 预留(设置面板录制改键、二期补焦):整体停/启输入管线
    func suspend() {
        for tap in [flagsTap, mouseTap, navTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    func resume() {
        for tap in [flagsTap, mouseTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        updateNavTap()
    }

    /// 键盘路径之外的会话终结(鼠标点卡片确认/面板外点击放弃等):面板控制器每次
    /// dismiss 必须调这个,否则钉住模式下状态机永远卡在 navigating,⌥Tab 再也唤不醒
    /// ——实机现形:鼠标确认后 switcher 永久失能
    func endSession() { pinnedSession = false; setState(.idle) }

    /// 三指点按的入口:没有触发键的按下,所以直接进导航态。
    /// 已在跑就不重开(手势抖动不产生第二局;面板窗口复用,重开只会把状态搅乱)。
    func beginPinnedSession() {
        guard state == .idle else { return }
        pinnedSession = true
        setState(.navigating)
        emit(.begin)
    }

    // MARK: - Carbon 热键(触发键)

    private func installEventHandler() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // GetEventDispatcherTarget:不需要辅助功能权限(AltTab 的注释:GetEventMonitorTarget /
        // GetApplicationEventTarget 也行,但那两个要权限)
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func registerTrigger(_ config: TriggerConfig) {
        unregisterHotKeys()
        hotKeyRef = registerHotKey(config, extras: [], id: .forward)
        reverseHotKeyRef = registerHotKey(config, extras: [.maskShift], id: .reverse)
        appliedTrigger = config
        appliedTakeover = TriggerConfig.takeoverEnabled
        let take = NativeHotkeys.plan(for: config, takeover: appliedTakeover).disable.isEmpty ? "否" : "是"
        print("[T13] 触发键注册:\(config.display)(+ ⇧ 反向);接管原生 = \(take)")
        // ★ 2026-09-22 加:这条原来只 print 到 stdout ⇒ trace.log 里**看不到** ✗
        //   病例:「单指单击怎么也唤起了」—— 我先要能确认"到底注册的是哪个和弦" ✓
        glog("[热键] 触发键注册 = \(config.display)(+⇧ 反向) · 接管原生 = \(take)")
    }

    private func registerHotKey(_ config: TriggerConfig, extras: CGEventFlags, id: HotKeyId) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id.rawValue)
        let status = RegisterEventHotKey(UInt32(config.keyCode),
                                        Self.carbonModifiers(config.modifierMask.union(extras)),
                                        hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            print("[T13] RegisterEventHotKey 失败 id=\(id.rawValue) status=\(status)(多半是这个组合已被系统/别的 App 占用)")
            return nil
        }
        return ref
    }

    private func unregisterHotKeys() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let reverseHotKeyRef { UnregisterEventHotKey(reverseHotKeyRef) }
        hotKeyRef = nil
        reverseHotKeyRef = nil
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        return mods
    }

    /// Carbon 热键事件回调(主线程,由主 runLoop 的事件分发器投递)
    fileprivate func handleHotKey(_ id: UInt32, pressed: Bool) {
        // 释放不参与语义:确认由"修饰键释放"决定(hold 语义)
        guard pressed, let hotKey = HotKeyId(rawValue: id) else { return }
        trace("hotkey \(hotKey) pressed state=\(state)")
        // ★ 热键开面板会**大声报一行**(手势那条另有日志);两条互斥出现 ⇒ 一眼知道是谁按的 ✓
        //   (Carbon 回调只给 id,给不出"物理上是哪颗键"—— 但注册的和弦启动时已报 ✓)
        glog("[热键] \(hotKey == .reverse ? "⌘⇧Tab(反向)" : "⌘Tab(接管)") 开面板 — 进之前的状态=\(state)")
        // **只在"开局"这一发用它**。实机病:同一个和弦按住期间,系统不会重复投递 `kEventHotKeyPressed`
        // (按住 ⌘ 连按 Tab,只来第一发)→ 于是"继续按 Tab 移动"在旧版里彻底不动(用户实机反馈)。
        // 循环移动改回 navTap 接(会话期它本来就在收 keyDown),这里会话已在跑就什么都不做,
        // 也顺手避免了"Carbon 重复投递 + navTap 各动一次"的双跳。
        guard state != .navigating else { return }
        setState(.navigating)
        // 方向要传下去:「唤起即切换」开着时,正向落"上一个 App"、反向落"最后一个"
        let forward = hotKey != .reverse
        // ★ 2026-09-22 用户裁定:**放弃"轻点不弹面板"那条**(试过两版阈值,延迟都影响使用 ✗)——
        //   原生 macOS 就是"按下即弹" ✓,我们照它 ✓。**切换逻辑的正确性**另有保障:
        //   落点会跳过当前 App(`LandingRule.landingIndex(count:from:reverse:)` ✓)、
        //   顺序按"这块屏的最近用过"排(`ScreenRecency` ✓)✓
        emit(forward ? .begin : .beginReverse)
    }

    // MARK: - 事件 tap

    private func makeTap(at place: CGEventTapLocation, options: CGEventTapOptions, types: [CGEventType]) -> CFMachPort? {
        var mask: CGEventMask = 0
        for type in types { mask |= CGEventMask(1 << type.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: place,
            place: .headInsertEventTap,
            options: options,            // `.listenOnly` = 只读,永不吞键
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // navTap 是唯一有吞键权的那个:**创建后立刻禁用**,只在导航态打开
        CGEvent.tapEnable(tap: tap, enable: options == .listenOnly)
        return tap
    }

    /// 唯一有吞键权的 tap 的开/关。参考实现 `updateEscapeAbsorptionTap` 同一手法:
    /// 先对账"系统说它开着没有",再决定要不要动 —— 盲目 enable 会让日志失去可信度。
    private func updateNavTap() {
        guard let navTap else { return }
        // ⚠️ 开了"接管 ⌘`"之后,这个 tap 要**常开** —— 否则面板没开的时候收不到那颗键 ✗。
        //   代价诚实说:从此每个 keyDown 都要过一遍 `handleNavKey`,所以那里面**先判状态与键码**、
        //   不匹配立刻 return false(放行)✓;真正耗时的聚焦动作挪到 async(见上面那条分支)✓
        let shouldEnable = state == .navigating || Self.graveTakeoverEnabled
        if CGEvent.tapIsEnabled(tap: navTap) != shouldEnable {
            CGEvent.tapEnable(tap: navTap, enable: shouldEnable)
            // 每局开关各一条,是常态而非事件 —— 收进 trace(要看纪律是否守住时再开)
            trace("[T13] 导航吞键 tap:\(shouldEnable ? "开" : "关")")
        }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        updateNavTap()
    }

    /// 事件处理入口(主线程,source 挂在主 runLoop 上)。返回值 = 是否吞掉该事件。
    fileprivate func handle(_ event: CGEvent) -> Bool {
        switch event.type {
        case .flagsChanged: return handleFlags(event)
        case .leftMouseDown: return handleMouse(event)
        case .keyDown: return handleNavKey(event)
        case .scrollWheel:
            // ★★ 2026-09-22 事故(用户实报「触摸板双指滑动怎么失效了」,他正在工作 ✗):
            //   这一支原先**靠隐含前提**——"navTap 只在会话期开着" ⇒ 于是没写状态判断 ✗。
            //   给 ⌘` 接管让 navTap **常开**之后,它就变成**全系统吞滚动** ⇒ 双指滑动到处失效 ✗
            //   (用户设置里「滚动切换应用」是开的 ⇒ 正好踩中)。
            //   教训:凡"只有我能吞键"的 tap,**每一支都要自己带状态判断**,不许依赖 tap 的开合 ✗
            guard state == .navigating else { return false }   // 非会话期:滚动一律放行 ✓
            // 用户实报:「我滑动的时候, ghostty 的滚轮也跟着动了」——
            // 全局 NSEvent 监听只能旁观、不能拦,所以交给 navTap。
            // 返回 true = 吞掉。惯性事件也一并吞:只吞非惯性的话,甩动的尾巴会继续滚底下的 App。
            if let nse = NSEvent(cgEvent: event) { onScroll?(nse) }
            // ⚠️ 必须先看开关:设置里写的是"关闭后,滚轮与双指滑动照常交给底下的应用",
            // 无条件吞就会让那句说明变成假话(关掉后底下 App 依然滚不动)。
            // 设置项一旦承诺了行为,代码就得兑现 —— 否则不如不写那句说明。
            guard Self.scrollMovesSelection else { return false }   // false = 放行,不吞
            return true
        default: return false
        }
    }

    /// 只听修饰键:撑起 hold 语义。**这个 tap 永不吞键**(`.listenOnly`),返回 false
    private func handleFlags(_ event: CGEvent) -> Bool {
        let config = TriggerConfig.load()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard config.modifierKeyCodes.contains(keyCode) else { return false }
        let modifierDown = event.flags.contains(config.modifierMask)
        trace("flagsChanged kc=\(keyCode) down=\(modifierDown) state=\(state)")
        switch (state, modifierDown) {
        case (.idle, true):
            setState(.armed) // 裸按触发修饰键只待命,什么都不发生
        case (.armed, false):
            setState(.idle)  // 待命期放手:恢复原状
        case (.navigating, false):
            // 钉住:松手不确认、不退出导航态——面板与它的"脑子"一起钉住,
            // 否则面板还在台上、状态机已经下班,Tabs/Esc 全漏给前台 App(实机现形)
            if pinPanel || pinnedSession { break }
            setState(.idle)
            emit(.confirm)
        default:
            break
        }
        return false
    }

    /// ⌘+点击补焦的耳朵。**只听不吞**:事件本身照常送到前台 App
    private func handleMouse(_ event: CGEvent) -> Bool {
        if event.flags.contains(.maskCommand), state != .navigating {
            onCmdClick?(event.location)
        }
        return false
    }

    /// 导航期的固定键(唯一会吞键的地方)。触发键本身不在这里 —— 它走 Carbon,前台 App 本来就收不到
    private func handleNavKey(_ event: CGEvent) -> Bool {
        // 🔬 键账(2026-09-21 用户实报「三指唤起后按 q/w/f/m/h 只会关面板,而 cmd-tab 唤起时正常」):
        //   把 tap 看见的**每一颗会话期按键**都记下来(带状态与修饰键)⇒ 一眼能分清是
        //   ① 键根本没被看见(navTap 没开/会话已结束)还是 ② 看见了但下游没做事。
        let __kc = event.getIntegerValueField(.keyboardEventKeycode)
        // ★ 2026-09-22:面板没开时若 tap 看见 ⌘Tab ⇒ 记一行。配合上面的 `[热键]` 日志可判定:
        //   两行都有 = 真的有人按了 ⌘Tab ✓;只有 `[热键]` 那行 = **Carbon 幽灵事件**(要另查)✗
        if __kc == 48, state != .navigating,
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskCommand] {
            glog("[热键] tap 看见 ⌘Tab(面板没开)")
        }
        // ★★ 接管系统 ⌘`(2026-09-22 用户要求:「能拦截系统的 cmd+`(只在当前屏幕内容的同类型app跳转)」)
        //   口径:**只在面板没开**的时候接管 —— 面板开着时 ⌘` / ` 照旧走"会话内窗口循环" ✓
        //   修饰键**精确匹配** {⌘} 或 {⌘,⇧}:多一个(⌃/⌥)都是别人的快捷键 ⇒ 放行 ✗(见下面那把门禁的病例)
        //   ⚠️ 回调必须**立刻返回**:tap 回调超时会被系统摘掉 ⇒ 真正的活挪到 async ✓
        //   ⚠️ 这一支必须在**下面那道 `guard state == .navigating` 之前** —— 第一版写在它后面 ⇒
        //      面板没开时永远到不了这里(实机:注入 ⌘` 日志里一行都没有)✗
        if Self.graveTakeoverEnabled, __kc == Self.keyGrave, state != .navigating {
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if mods == [.maskCommand] || mods == [.maskCommand, .maskShift] {
                let forward = !event.flags.contains(.maskShift)
                // ★ 不直接调 App 层的循环器(Trigger 不许反向依赖 ✗ 架构脚本会报 ✓)
                //   ⇒ 走**闭包钩子**,由 GlanceApp 装配 ✓(输入管线的既有约定:onFire / onScroll 同一套 ✓)
                onSameAppScreenCycle?(forward)
                return true                                    // 吞掉:系统那条 ⌘` 不再执行 ✓
            }
            return false       // 夹了别的修饰键 ⇒ 别人的快捷键,放行 ✓
        }
        // ⚠️ 开了"接管 ⌘`"之后这个 tap **常开** ⇒ 这行不能无条件打 ✗
        //    (否则全系统每一次按键都写一行日志 —— 正是之前刚修过的"刷屏"病 ✓)
        if isTraceEnabled, state == .navigating {
            glog("[键账] kc=\(__kc) state=\(state) pinned=\(pinnedSession) mods=\(event.flags.rawValue)")
        }
        guard state == .navigating else { return false } // 理论上不会(会话期才开),守一道
        let keyCode = __kc
        let config = TriggerConfig.load()
        // 触发键在导航期 = **循环移动**(开头那一发由 Carbon 负责,见 `handleHotKey`)
        if keyCode == config.keyCode {
            trace("trigger repeat kc=\(keyCode) shift=\(event.flags.contains(.maskShift))")
            emit(event.flags.contains(.maskShift) ? .prev : .next)
            return true
        }
        // ★★ 修饰键门禁(2026-09-17 病例,严重):导航键原来**只看 keycode** ——
        // 于是用户在自己 App 里按 ⌃⌘W(他自己的热键)被我们当成「W = 关窗」,
        // **把选中的那个窗杀了**;⌘W / ⌘Q / ⌘H / ⌘1… 同理,全会被抢。
        // 用户原话:「qwer fh 都得是全匹配的快捷键才能生效」—— 说的就是这件事。
        //
        // 判据:除了**触发键本身那个修饰键**(只在"按住触发键"的那一局里才该出现)之外,
        // 不许再夹 ⌘/⌃/⌥(⇧ 始终允许:我们自己的 ⇧` / ⇧Tab 要用它)。
        // 夹了 ⇒ 这不是我们的键 ⇒ 原样交给 App;钉住的那一局还算"用户在做别的事"(表一 ⑤)。
        // ★ 全匹配的 ⌘ 动作键(见 cmdActionKeys 的病例):先于"修饰键门禁"判定。
        //   修饰键集合**必须恰好等于** {⌘} —— 多一个都算别人的快捷键 ⇒ 放行走下面的门禁。
        let modSet = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if modSet == [.maskCommand], let act = Self.cmdActionKeys[keyCode] {
            trace("navKey(cmd) kc=\(keyCode)")
            emit(act)
            return true
        }
        let allowedMods: CGEventFlags = pinnedSession ? [] : config.modifierMask
        let extraMods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !extraMods.subtracting(allowedMods).isEmpty {
            if pinnedSession { onElsewhereInput?() }
            return false   // 不吞:让 App 收到它自己的快捷键
        }
        guard Self.navKeys.contains(keyCode) else {
            // T91 表一 ⑤:别的键 ⇒ 用户在做别的事。**只认钉住的局**:
            // 按住触发键的那一局,松手本来就会结束(不该被一个无关键打断)。
            if pinnedSession { onElsewhereInput?() }
            return false   // 照旧放行,不吞
        }
        // ★ 截图会话:整套导航键让权(T32)。放在 trace 之前 —— 这一支的整条路都与面板无关了
        if captureSessionTookOver(keyCode: keyCode) { return false }
        trace("navKey kc=\(keyCode)")
        switch keyCode {
        case Self.keyReturn: setState(.idle); emit(.confirm) // 钉住模式的确认键
        case Self.keySpace: setState(.idle); emit(.confirm)  // 空格 = 同一个动作(见 keySpace 的两条边界)
        case Self.keyEsc: setState(.idle); emit(.cancel)
        case Self.keyQ: emit(.quitApp)
        case Self.keyW: emit(.closeWindow)
        case Self.keyM: emit(.minimizeWindow)
        case Self.keyF: emit(.toggleFullscreen)
        case Self.keyH: emit(.hideApp)
        case Self.keyT: emit(.moveToNextScreen)
        case Self.keyLeft: emit(.firstGroup)
        case Self.keyRight: emit(.lastGroup)
        case Self.keyDown: emit(.enterLaunchRing)   // ↓ 换环:未启动的 App
        case Self.keyUp: emit(.leaveLaunchRing)    // ↑ 换回:已启动的 App 组
        case Self.keyGrave:
            // 开关关着就**放行**(return false = 不吞),让系统那条 ⌘` 照旧工作
            guard Self.graveCyclesWindows else { return false }
            // ⇧` = 反向,与触发键的 ⇧ 反向约定一致
            emit(event.flags.contains(.maskShift) ? .cycleWindowPrev : .cycleWindowNext)
        default:
            if let n = Self.digitKeys[keyCode] { emit(.pickWindow(n - 1)); return true }
            break
        }
        return true
    }

    /// 截图会话里的**让权**(T32)。返回 true = "这一颗已经被截图会话接管",调用方直接放行(不吞)。
    ///
    /// 病例(2026-09-14 用户实报):「在截图的情况下,我按回车会同时触发截图的复制和选中的逻辑」。
    /// 一次击键被两个主人收下:截图工具的取景框自己也在收回车(Return = 完成/复制),
    /// 而 navTap 是**后装**的 tap,排在同一颗事件的后半段 —— 它照样看见、照样确认了一次,
    /// 于是用户眼里就是"截图拷走了,App 也被拉起来了"。
    ///
    /// 裁决只有一条:**屏幕上正等着"完成"的那一刻,键盘归截图工具**。于是:
    ///   · **一律不吞** —— 吞了,截图工具的"完成/复制"(Esc 取消、方向键微调选区)就都没了;
    ///   · **一律不动选中** —— 此刻方向键是"微调选区",不是"换一扇窗";Q/W/M 更是不能乱动;
    ///   · **只有回车多走一步:把面板关掉**(用户口径:"如果是截图,按回车之后不要触发打开某一个 APP,
    ///     glance 面板应该直接关闭")。它也**不聚焦** —— 打开 App 是副作用,用户要的是把区域拷走。
    ///
    /// 判据在核里(`GlanceCore.CaptureSessionRule`,可单测),证据由 `CaptureSessionProbe` 采集。
    private func captureSessionTookOver(keyCode: Int64) -> Bool {
        let capture = CaptureSessionProbe.verdict()
        guard capture.isCapture else { return false }
        if keyCode == Self.keyReturn {
            print("[T32] 回车落在截图会话里:\(capture.reason)→ 只关面板、不聚焦,这一颗放行给截图工具")
            setState(.idle)
            emit(.yieldToCapture)
        } else {
            trace("截图会话里放行 kc=\(keyCode):\(capture.reason)")
        }
        return true
    }

    private func emit(_ action: Action) {
        trace("  → emit \(action)")
        if let onAction { onAction(action) } else { print("[T3] \(Self.describe(action))") }
    }

    // MARK: - tap 被系统停用时

    /// 返回 true = 吞掉这一颗。**我们吞不吞都不影响"⌘Tab 归谁"** —— 触发走 Carbon,
    /// 与这个 tap 的生死无关(v1.13 之前不是这样:那时吞键就是防线本身)。所以照参考实现
    /// 原样放行,只把状态说清楚,免得日志引发误判。
    fileprivate func handleTapDisabled(_ type: CGEventType) -> Bool {
        let byTimeout = type == .tapDisabledByTimeout
        // 措辞要准:这里只重开**只读**两个 tap;navTap 的生死由会话状态管(见 `updateNavTap`)。
        // 上一版写"→ 重开"会读成"吞键 tap 又回来了",把人和诊断都带偏(2026-09-15 我自己先中了一次)。
        // 常态不打扰:**会话结束后我们自己关 navTap,系统会把这条"禁用"回显给我们**
        // (实测每局必来一条,导航中:false)—— 它没有信息量,却占了日志里很大一块。
        // 只有"会话进行中"被停用才值得说话:那才是 ADR-0005 说的"这一发可能漏给系统"。
        if state == .navigating {
            print("[T13] ⚠️ 导航中 tap 被系统停用(\(byTimeout ? "超时" : "用户输入")) → 只读 tap 重开(navTap 按会话开关)")
        } else {
            trace("[T13] tap 停用回显(常态,已忽略)")
        }
        reEnableTapIfNeeded()
        return false
    }

    fileprivate func reEnableTapIfNeeded() {
        for tap in [flagsTap, mouseTap].compactMap({ $0 }) where !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[T13] 只读 tap 已重新启用")
        }
        updateNavTap()
    }

    // MARK: - 配置热更新

    /// 触发键/接管开关变化时:重注册 Carbon 热键 + 重算原生热键的开/关。
    /// 走 UserDefaults 变化通知而不是让设置面板反向持有触发层:单一入口,谁写 keys 都生效。
    private func observeTriggerChanges() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadTriggerIfChanged()
                self?.updateNavTap()      // ★ ⌘` 接管开关是"现读"的 ⇒ tap 开/关要跟着设置走 ✓
            }
        }
    }

    func reloadTriggerIfChanged() {
        let config = TriggerConfig.load()
        let takeover = TriggerConfig.takeoverEnabled
        guard config != appliedTrigger || takeover != appliedTakeover else { return }
        registerTrigger(config)
        NativeHotkeys.apply(trigger: config, takeover: takeover)
    }

    // MARK: - 事件级 trace(设 GLANCE_TRACE=1 才输出)

    /// 开关缓存在 static let:`ProcessInfo.environment` 每次调用都要建字典,不能放在每颗事件的热路径上。
    /// (stdout 的行缓冲在 `Stdout.swift` 里设,那里比这里更早。)
    private static let traceEnabled = isTraceEnabled

    private func trace(_ line: String) {
        guard Self.traceEnabled else { return }
        glog("[tap] \(line)")
    }

    private static func describe(_ action: Action) -> String {
        switch action {
        case .begin: return "首次 ⌥+Tab → 导航开始(面板应出现)"
        case .beginReverse: return "首次 ⇧⌥+Tab → 导航开始(反向)"
        case .next: return "Tab → 后移"
        case .prev: return "⇧Tab → 前移"
        case .firstGroup: return "← → 跳到最左的 App"
        case .lastGroup: return "→ → 跳到最右的 App"
        case .cycleWindowPrev: return "⇧` → 当前 App 上一个窗口"
        case .cycleWindowNext: return "` → 当前 App 下一个窗口"
        case .pickWindow(let n): return "\(n + 1) → 直接选中第 \(n + 1) 扇窗"
        case .confirm: return "⌥ 释放 → 确认(T7 聚焦此处)"
        case .cancel: return "Esc → 放弃(面板关闭,不聚焦)"
        case .yieldToCapture: return "回车落在截图会话 → 只关面板、不聚焦(T32;这一颗不吞)"
        case .quitApp: return "Q → 退出选中 App(T12)"
        case .closeWindow: return "W → 关闭选中窗(T12)"
        case .minimizeWindow: return "M → 最小化选中窗(T12)"
        case .toggleFullscreen: return "F → 全屏切换(T29)"
        case .hideApp: return "H → 隐藏 App(T29)"
        case .moveToNextScreen: return "T → 把选中窗搬到下一块屏(P2)"
        case .enterLaunchRing: return "↓ → 换环:把环换成未启动的 App(T91)"
        case .leaveLaunchRing: return "↑ → 换环:换回已启动的 App 组(T91)"
        }
    }
}

/// C 回调桥。三个 tap 共用:靠事件类型分流(订阅的类型互不重叠)。
/// tap 的 runLoop source 挂主 runLoop,所以回调在主线程,可以安全动 @MainActor 状态。
private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let center = Unmanaged<HotkeyTapCenter>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return center.handleTapDisabled(type) ? nil : Unmanaged.passUnretained(event)
        }
        return center.handle(event) ? nil : Unmanaged.passUnretained(event)
    }
}

/// Carbon 热键事件回调
private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?, event: EventRef?, userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x676C6E63 else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotkeyTapCenter>.fromOpaque(userInfo).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { center.handleHotKey(hotKeyID.id, pressed: pressed) }
    return noErr
}

