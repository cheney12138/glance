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
    private static let keyQ: Int64 = 0x0C
    private static let keyW: Int64 = 0x0D
    private static let keyM: Int64 = 0x2E
    private static let keyF: Int64 = 0x03
    private static let keyH: Int64 = 0x04
    /// 导航期被吞的固定键:方向/Esc/Enter + Q/W/M 破坏性键盘操作(CONTEXT.md)+ 数字 1…9
    /// ⚠️ 唯一的例外是**截图会话里的回车**:那一发不吞(它是截图工具的"完成"),见 `handleReturn()`
    ///
    /// ⚠️ 数字**必须在这里登记**:`handleNavKey` 第一句就是
    /// `guard Self.navKeys.contains(keyCode) else { return false }` —— 这是一道**前置闸门**,
    /// 没登记就走不到后面的 switch(第一次加数字键时漏了这步,功能会**静默失效**:
    /// 按 2 不选中,还把 "2" 放行给底下的 App)。
    /// `Set([...])` 必须显式写:直接写数组字面量再 `.union` 会被推成 `[Int64]`(实测编译错)。
    private static let navKeys: Set<Int64> =
        Set([keyLeft, keyRight, keyDown, keyUp, keyEsc, keyReturn, keyQ, keyW, keyM, keyF, keyH, keyGrave])
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
    ]
    
    /// `(kVK_ANSI_Grave = 0x32):会话期可选地接管"当前 App 的窗口循环"。
    ///
    /// 为什么这个键值得单独说:它同时是 macOS **全局**的"同 App 窗口循环"(⌘`) ——
    /// 我们**不去关系统热键**(DockDoor 的做法,源码实证):靠 navTap 会话期吞键即可,
    /// 系统那条热键在 WindowServer 层是更晚的环节,吞掉就收不到。
    /// 代价与 Tab 循环同一条:tap 若被系统停用那一瞬,这一发会漏给系统(见 ADR-0005 的取舍)。
    /// 默认**关**:它动的是系统级快捷键的肌肉记忆,只能用户显式开(与接管 ⌘Tab 同一纪律)。
    private static let keyGrave: Int64 = 0x32
    private static var graveCyclesWindows: Bool {
        UserDefaults.standard.object(forKey: Keys.switchGraveCyclesWindows) as? Bool ?? false
    }
    /// 面板出现期间是否接管滚动(设置里的「双指滑动换组」,默认开)。
    /// 关掉时必须**放行**:设置里的说明写着"关闭后…照常交给底下的应用"。
    private static var scrollMovesSelection: Bool {
        UserDefaults.standard.object(forKey: Keys.switchScrollMovesSelection) as? Bool ?? true
    }

    /// 钉住开关:松 ⌥ 不关面板,状态机保持导航态,Enter 接手确认权(用户实评"还挺实用")
    private var pinPanel: Bool { UserDefaults.standard.bool(forKey: Keys.debugPinPanelOnRelease) }

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
        // **只在"开局"这一发用它**。实机病:同一个和弦按住期间,系统不会重复投递 `kEventHotKeyPressed`
        // (按住 ⌘ 连按 Tab,只来第一发)→ 于是"继续按 Tab 移动"在旧版里彻底不动(用户实机反馈)。
        // 循环移动改回 navTap 接(会话期它本来就在收 keyDown),这里会话已在跑就什么都不做,
        // 也顺手避免了"Carbon 重复投递 + navTap 各动一次"的双跳。
        guard state != .navigating else { return }
        setState(.navigating)
        // 方向要传下去:「唤起即切换」开着时,正向落"上一个 App"、反向落"最后一个"
        emit(hotKey == .reverse ? .beginReverse : .begin)
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
        let shouldEnable = state == .navigating
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
            // 用户实报:「我滑动的时候, ghostty 的滚轮也跟着动了」——
            // 全局 NSEvent 监听只能旁观、不能拦,所以交给 navTap(会话期才有、唯一有吞键权的那个)。
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
        glog("[键账] kc=\(__kc) state=\(state) pinned=\(pinnedSession) mods=\(event.flags.rawValue)")
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
        case Self.keyEsc: setState(.idle); emit(.cancel)
        case Self.keyQ: emit(.quitApp)
        case Self.keyW: emit(.closeWindow)
        case Self.keyM: emit(.minimizeWindow)
        case Self.keyF: emit(.toggleFullscreen)
        case Self.keyH: emit(.hideApp)
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
            MainActor.assumeIsolated { self?.reloadTriggerIfChanged() }
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

// MARK: - 三指点按唤起面板(钉住,不散场)

/// 三指点按 = 唤起面板,并且**这一局不散场**(没有键可松 ⇒ 一直留着,直到选一个/Esc/点外面)。
///
/// 为什么必须借私有框架:触控板的**原始触摸**不在 CGEvent 里 —— 三指点按既不是 `.gesture`,
/// 也不是鼠标事件;系统把它当"查词/拖移"的手势自己消费掉了。能看到"现在几根手指、按了多久"的
/// 唯一地方是 `/System/Library/PrivateFrameworks/MultitouchSupport.framework`
/// (MiddleClick 一类工具同一条路)。
///
/// ⚠️ 本机**三指拖移是开着的**(`TrackpadThreeFingerDrag = 1`,2026-09-17 实测),所以判据必须
/// 和拖移分得开。这里只用两条:**恰好三指** + **按下到抬起 ≤ 0.30s** —— 拖移天然要按住一段时间,
/// 点按天然是一碰就走。
/// 刻意**不看触摸坐标**:那个结构体的字段布局是反推来的,一旦猜错,位移永远算成离谱的大值,
/// 结果是"这个功能永远不触发" ✗。少一个判据,换来一个不会因为布局猜错而死掉的探针。
/// 代价:三指**快速**甩一下(拖移起手,<0.3s)会误开面板 —— 代价只是面板开了一下,点外面就散。
///
/// **失败即关门**:框架/符号/设备任一取不到 ⇒ 记一行日志、功能静默不可用,绝不拖垮 App。
/// 历史名字:它最早只认三指;T91 起 **3 与 4 指都归它判卷** ——
/// 按 maxTouches(这一整次按压里出现过的最大手指数)分派:3 = 唤起,4 = 唤起并直接进未启动环。
/// (改名的收益抵不过这轮的风险 ⇒ 名字保留,但这里写明它的真实职责。)
final class ThreeFingerTap {
    static let shared = ThreeFingerTap()
    private init() {}

    /// 设置项。**默认关**(新开关一律默认对齐 macOS:macOS 没有这个功能)。
    /// UserDefaults 直读 ⇒ 设置里一改立刻生效,不用重启(与 DoubleOptionTap 同一套约定)。
    static let defaultsKey = "pointer.threeFingerTapPanel"
    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? false }

    /// 四指轻点(T91)= **直接进未启动环**。与三指那条同一条纪律:**默认关**
    /// (默认对齐 macOS:macOS 没有这个功能),而且**区分"没写过"与"写成 false"** ——
    /// `object(forKey:) as? Bool ?? false`:取不到 = 没写过 = 关,取到 false = 用户关掉了。
    /// (本机实测:系统没有占用"四指轻点"—— `TrackpadFourFingerTapGesture` 这个键根本不存在;
    ///  四指只有横扫/竖扫/捏合。见 design/入口槽-底部形态实验台.html 的记账。)
    static let defaultsKeyFour = "pointer.fourFingerTapLaunchRing"
    private var enabledFour: Bool { UserDefaults.standard.object(forKey: Self.defaultsKeyFour) as? Bool ?? false }

    var onFire: (() -> Void)?
    /// 四指的落点:唤起 + 直接切到未启动环。接线在 GlanceApp,与 onFire 并排
    var onFireFour: (() -> Void)?

    // MARK: 私有框架的接口(反推布局,只读 state 一个字段)

    private struct MTPoint { var x: Float = 0; var y: Float = 0 }
    private struct MTVector { var pos = MTPoint(); var vel = MTPoint() }
    private struct Finger {
        var frame: Int32 = 0
        var timestamp: Double = 0
        var identifier: Int32 = 0
        var state: Int32 = 0        // 4 = 正在触摸
        var fingerId: Int32 = 0
        var handId: Int32 = 0
        var normalized = MTVector()
        var size: Float = 0
        var zero1: Int32 = 0
        var angle: Float = 0
        var majorAxis: Float = 0
        var minorAxis: Float = 0
        var absolute = MTVector()
        var zero2: Int32 = 0
        var zero3: Int32 = 0
    }

    private typealias ContactCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    // MARK: T91 表二:手势的**位移**判据(先量后定,规格见 design/gesture-session-spec.md)
    //
    // 为什么要有它:2026-09-17 用户实测「四指**上下滑也会唤出环**」—— 判据里刻意没有坐标
    // (怕反推的结构体布局猜错、整个探针当场死掉),代价就是"滑"和"点"分不开。
    // 现在这个代价已经付过,改用位移判据;**阈值不猜,先量**:这一步只记账,不改行为。
    //
    // 同时量两套坐标(normalized 与 absolute)—— 反推布局若错,其中一套会给出荒唐值,
    // 一眼就能看出来该信哪一套。
    // ⚠️ 第一版量错了(记在这里,别再犯):量的是"所有触摸点的**包围盒**" —— 而轻点也有 3–4 根
    // 手指**张在**触控板上,包围盒天生就大(实测 abs≈50–66 = 手指之间的张开距离),
    // 于是"点"和"滑"分不开。正确的量是:**每根手指离开它落点时走了多远**(按 fingerId 跟踪)。
    /// T91 表二:**3 与 4 指都要过"位移"这一关**。阈值来自实测:
    ///   真轻点   norm≈0.002–0.007(2026-09-18 又量一轮:0.0023–0.0060,口径不变)
    ///   三指拖移 norm≈0.11–0.30(短拖)  0.13–0.55(长拖/滑动)
    /// ★ 2026-09-18 从 0.08 收窄到 0.03(用户实报「操作着操作着就出现了」):
    ///   0.08 时代,"短拖"(拖一下窗、小距离选字,位移 0.05–0.08)会压线判成轻点唤起面板
    ///   —— 正是"容易误触"的真身。0.03 对真轻点仍有 **4 倍**余量,0.05+ 的拖动全拒。
    ///   (LumaRing 的 TapRecognizer 用 0.025/0.035,同一量级 —— 佐证这个量级是对的。)
    ///
    /// ⚠️ 病例(别再犯):第一版**只给四指**加,理由写的是"三指的横扫/竖扫在系统里都是关的"——
    /// **漏查了一个键**:`TrackpadThreeFingerDrag = 1`(**三指拖移开着**,用户天天在用:拖窗、选字)。
    /// 于是"拖窗"的那种快速三指被我们判成了轻点 ⇒ 用户实报「三指滑动改坏了」。
    /// 教训:查"系统占用了什么手势"时,要把**拖移(Drag)**和**轻扫(Swipe)**两类键都过一遍。
    static let maxMove: Float = 0.03
    static let maxDuration: Double = 0.30

    private var started = false
    /// 一次按压的账本(记账 + 判卷都在 `Press`,回调只喂数据 —— 2026-09-18 重构:
    /// 判卷逻辑越来越长,再跟"读 C 结构体 + 回调线程纪律"搅在一起,每次动都会伤到别的)
    private var press = Press()
    /// 上一次成功判卷的时刻。**0.35s 防抖**(LumaRing 同款):连击的第二发不重复动作 ——
    /// 用户连着试几次的时候,面板被反复拆建,读起来就是"闪"
    private var lastTapAt: CFAbsoluteTime = 0

    /// **一次按压**从第一帧触点到全部抬起的完整账本。
    ///
    /// 2026-09-18 用户实报「三指唤起了未启动, 四指失灵」—— 日志铁证:
    /// ```text
    /// [指点按] 5 指 154ms 位移 norm=0.0035 → 不动作     ← 干净的四指点按,被数成 5
    /// [指点按] 四指 113ms 位移 norm=0.0060 → 进未启动环   ← 三指点按,被数成 4
    /// ```
    /// **每个触点都被多数了 +1**:掌缘/拇指根搭在板上也被 `state == 4` 计进手指数。
    /// T91 把计数从"抬手瞬间的手指数"改成"整轮 maxTouches"(治四指慢落误判)之后,
    /// 这类**搭着的杂触点**就再也躲不掉计数了 —— 三指→4(开错环)、四指→5(不动作)。
    /// 解法用的是这份数据里早就躺着、只是没读的信号:`size` / `majorAxis`(触点面积/长轴)
    /// —— 指尖小、掌大,这是系统手势识别同款的第一道掌缘豁免。
    ///
    /// 阈值纪律照旧:**先量后定**。真值会记进 [指点按] 日志(size=/major= 字段),
    /// 第一版先放很宽(只挡明显是掌的),宁可漏挡也别把真手指挡掉 —— 漏挡 = 病复发,可再调;
    /// 误挡 = 真四指永远唤不醒,更难查。
    struct Press {
        /// 掌缘豁免线(第一版,待真值收紧):长轴 ≥22 或面积 ≥4.5 的触点不计入手指数
        static let palmMajorAxis: Float = 22
        static let palmSize: Float = 4.5

        /// ★ 账本卡死自愈上限(2026-09-20「三指四指又失效了」的病根):
        /// 账本只在"收口帧"判卷,而收口条件一旦满足不了,账本就**无限期撑开** ——
        /// 之后所有触摸全被吸进同一条账本,手指数/时长/位移全爆表,判卷永远失败,
        /// 而且**一条日志都不留**(判卷不跑 = 沉默失效)。实锤:
        /// ```text
        /// [5049394ms] [指点按] 5 指(豁免掌 1) 2941951ms … size=4.6 → 不动作
        /// ```
        /// 一条按压持续 **49 分钟**(size=4.6 = 掌缘):掌搭在板上打字,收口帧永远等不来。
        /// 1.0s = 点按 ≤0.30s、按压触发 ≤0.25s 之后的三倍余量 —— 真手势到不了 1s 还不收口。
        static let stuckLedgerAfter: Double = 1.0

        private(set) var maxTouches = 0
        /// **去重手指 id 数**(2026-09-18 补,治「不灵敏」):极快的轻点(实测 ~50ms)里,
        /// 四根手指可能**从未同帧落齐** —— 按"同帧最大手指数"就数成 2/3,判成不动作。
        /// 每个触点有稳定 fingerId,整轮去重计数兜住"先后落、没同帧"的竞态;
        /// 掌缘豁免的 id 不进这个集合(豁免的本意就是它不算手指)。
        private(set) var distinctIDs: Set<Int32> = []
        private(set) var maxNormMove: Float = 0
        private(set) var maxAbsMove: Float = 0
        private(set) var palmCount = 0           // 被豁免的触点数(记账,不计数)
        private(set) var maxSeenSize: Float = 0  // 量尺:本轮真实触点的最大面积/长轴
        private(set) var maxSeenMajor: Float = 0
        private(set) var statesSeen: Set<Int32> = []   // 本轮见过的 state 档(判"漏在哪档"的量尺)
        private var beganAt: CFAbsoluteTime = 0
        private var pressActive = false
        /// 本轮**真手指**是否已经落板(掌不算)。掌先落时表不掐,真手指落的这帧才掐 ——
        /// 掌缘搭着打字时,"搭着"的时长不该算进点按时长
        private var sawRealTouch = false
        private var firstNorm: [Int32: MTPoint] = [:]
        private var firstAbs: [Int32: MTPoint] = [:]

        /// 判卷结果。
        enum Outcome {
            case fireThree(held: Double, norm: Float, abs: Float)
            case fireFour(held: Double, norm: Float, abs: Float)
            case slide(norm: Float)                  // 位移过大 = 滑动,让给系统
            case rejected(String)                    // 不动作(带原因,进日志)
        }

        /// 喂一帧。返回"当前正在触摸的**真手指**数"(>0 = 这一轮还没结束)。
        /// 线程纪律:只在 MultitouchSupport 的回调线程跑,只碰自己的标量;判卷在抬手帧同步出。
        mutating func feed(nFingers: Int, data: UnsafeMutableRawPointer?) -> Int {
            var touching = 0
            var palmTouching = 0
            // ★ 卡死自愈:账本超过 stuckLedgerAfter 还没收口 ⇒ 整本作废重来。
            //   (丢收口帧/幽灵触点常驻都会把账本撑成毒账本 —— 见 stuckLedgerAfter 的病历)
            if pressActive, CFAbsoluteTimeGetCurrent() - beganAt > Self.stuckLedgerAfter {
                let stale = CFAbsoluteTimeGetCurrent() - beganAt
                pressActive = false
                pressFired = false
                maxTouches = 0; distinctIDs.removeAll()
                maxNormMove = 0; maxAbsMove = 0
                palmCount = 0; maxSeenSize = 0; maxSeenMajor = 0
                statesSeen.removeAll(); sawRealTouch = false
                firstNorm.removeAll(); firstAbs.removeAll()
                DispatchQueue.main.async {
                    glog(String(format: "[指点按] 账本 %.1fs 未收口 ⇒ 强制重置(丢帧/幽灵触点自愈)", stale))
                }
            }
            if let data, nFingers > 0 {
                for i in 0..<nFingers {
                    let f = data.assumingMemoryBound(to: Finger.self)[i]
                    // 1–4 = 在板上(落板全过程),5–7 = 离板。
                    // (state 记账保留:失败日志自答"漏在哪档")
                    guard f.state >= 1 && f.state <= 4 else { continue }
                    statesSeen.insert(f.state)
                    // ★★ 跟踪键必须是 **identifier**(每触点唯一流水号),不是 fingerId!
                    //   fingerId 是手内槽位号(拇指 0/食指 1/中指 2…),四指同点时槽位撞号,
                    //   去重只剩 2–3 个 —— 这就是「四指十次唤不醒七次」的全部真相。
                    //   口径对齐 LumaRing:LRContact.id = touches[j].identifier(MIT)。
                    let id = f.identifier
                    // 掌缘豁免:大触点不计入手指数(位移照记 —— 掌动了就是真滑,该让给系统)
                    let isPalm = f.size >= Self.palmSize || f.majorAxis >= Self.palmMajorAxis
                    if isPalm { palmTouching += 1 } else { touching += 1; distinctIDs.insert(id) }
                    maxSeenSize = max(maxSeenSize, f.size)
                    maxSeenMajor = max(maxSeenMajor, f.majorAxis)
                    if let p0 = firstNorm[id] {
                        let dx = Double(f.normalized.pos.x - p0.x), dy = Double(f.normalized.pos.y - p0.y)
                        maxNormMove = max(maxNormMove, Float((dx * dx + dy * dy).squareRoot()))
                    } else {
                        firstNorm[id] = f.normalized.pos
                    }
                    if let p0 = firstAbs[id] {
                        let dx = Double(f.absolute.pos.x - p0.x), dy = Double(f.absolute.pos.y - p0.y)
                        maxAbsMove = max(maxAbsMove, Float((dx * dx + dy * dy).squareRoot()))
                    } else {
                        firstAbs[id] = f.absolute.pos
                    }
                }
            }
            if touching > 0 || palmTouching > 0 {
                if !pressActive {                    // 按压起点:清上一轮的运动账,掐表
                    pressActive = true
                    beganAt = CFAbsoluteTimeGetCurrent()
                    firstNorm.removeAll(); firstAbs.removeAll()
                    maxNormMove = 0; maxAbsMove = 0
                    palmCount = 0; maxSeenSize = 0; maxSeenMajor = 0
                    statesSeen.removeAll()
                    sawRealTouch = false
                }
                if touching > 0, !sawRealTouch {
                    // ★ 真手指此刻才第一次落板:表从**这一帧**重掐(掌先落的不计时 ——
                    //   2026-09-20 病例:掌搭着打字,掐表从掌落起,0.3s 上限必爆)
                    sawRealTouch = true
                    beganAt = CFAbsoluteTimeGetCurrent()
                    firstNorm.removeAll(); firstAbs.removeAll()
                    maxNormMove = 0; maxAbsMove = 0
                    maxTouches = 0
                }
                maxTouches = max(maxTouches, touching)
                palmCount = max(palmCount, palmTouching)
                // ★ 返回**真手指数**,不是 total:掌还搭着不该挡收口 ——
                //   (2026-09-20 病例:收口条件曾是"total == 0",掌缘搭板 = 账本永不收口,
                //   后续三/四指点按全部被无声吞掉,这正是「三指四指又失效了」的主病根)
                return touching
            }
            pressActive = false
            return 0
        }

        private(set) var pressFired = false   // 本轮已经"按压触发"过(抬手后不再按点按重复生效)

        /// **按压触发**(2026-09-18 用户提议:「给四指加上点按 + 按压」):四根手指齐压
        /// ≥0.25s 且几乎没动 ⇒ **当场生效**,不必抬手。点按失手时的兜底 —— 按住的手指
        /// 有几十帧把 identifier 记全,不存在"没同帧落齐"的竞态。
        /// ★ **必须同帧 4 指**(2026-09-19 修「三指变成未启动环」):曾经只看
        /// distinctIDs ≥ 4 —— 而 id 跨帧累计,手势落指帧相互沾边时(滚动→点按)按压
        /// 被合并、id 累到 4,三指点按就被误当"四指按压"唤起了未启动环。
        /// 同帧 4 指 = 真的"四根手指此刻都在板上",三指点按永远凑不齐这个条件。
        /// 防误触其余双闸:位移 ≤ maxMove(四指滑动/捏合全被拒);0.35s 防抖在生效侧照常拦。
        mutating func pressFireIfDue() -> Bool {
            guard !pressFired, maxTouches >= 4, distinctIDs.count >= 4,
                  CFAbsoluteTimeGetCurrent() - beganAt >= 0.25,
                  maxNormMove <= ThreeFingerTap.maxMove else { return false }
            pressFired = true
            return true
        }

        /// 全部抬起 ⇒ 判卷。
        /// T91:按 **maxTouches**(整轮最大值)而不是抬手瞬间的手指数 —— 四根手指不可能
        /// 同一帧落齐(先落 3 根、第 4 根 40ms 后到是常态),只看当前帧会把"四指慢落"误判成三指。
        func judge() -> Outcome {
            if pressFired { return .rejected("") }   // 按压已生效,抬手不再按点按重复计
            let held = CFAbsoluteTimeGetCurrent() - beganAt
            // 手指数 = max(同帧最大, 去重 id 数) —— 前者管"同帧落齐"的常态,后者兜"极快轻点
            // 从未同帧"的竞态(实测 ~50ms 的四指点按曾被数成 2)
            let n = max(maxTouches, distinctIDs.count)
            // <30ms = 瞬时毛刺(LumaRing 同款下限):一次真实的四指轻点至少也要 30ms+
            guard held >= 0.03 else { return .rejected("") }
            guard (n == 3 || n == 4), held <= ThreeFingerTap.maxDuration else {
                // 不匹配也要留账(要能分辨"0 是干净"还是"0 是没看见");带上豁免账与量尺。
                // states 供"漏在哪一档"对账:真手指若整轮只报了 1/2,这里一眼可见
                if n >= 2 || palmCount > 0 {
                    let st = statesSeen.sorted().map(String.init).joined(separator: "/")
                    return .rejected(String(format: "%d 指(豁免掌 %d)[state %@]%.0fms 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 不动作(只认 3/4 指,且 ≤%.0fms)",
                                            n, palmCount, st, held * 1000, maxNormMove, maxAbsMove,
                                            maxSeenSize, maxSeenMajor, ThreeFingerTap.maxDuration * 1000))
                }
                return .rejected("")   // 一指的普通点按:不进账
            }
            if maxNormMove > ThreeFingerTap.maxMove {
                return .slide(norm: maxNormMove)
            }
            let heldMs = held * 1000
            return n == 4 ? .fireFour(held: heldMs, norm: maxNormMove, abs: maxAbsMove)
                          : .fireThree(held: heldMs, norm: maxNormMove, abs: maxAbsMove)
        }
    }

    func start() {
        guard !started else { return }   // 幂等
        started = true
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW),
              let symList = dlsym(lib, "MTDeviceCreateList"),
              let symRegister = dlsym(lib, "MTRegisterContactFrameCallback"),
              let symStart = dlsym(lib, "MTDeviceStart") else {
            glog("[指点按] 取不到 MultitouchSupport ⇒ 该手势不可用(其余照常)")
            return
        }
        typealias CreateList = @convention(c) () -> CFMutableArray?
        typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
        typealias StartDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        let createList = unsafeBitCast(symList, to: CreateList.self)
        let register = unsafeBitCast(symRegister, to: Register.self)
        let startDevice = unsafeBitCast(symStart, to: StartDevice.self)
        guard let devices = createList() else {
            glog("[指点按] 拿不到触控设备 ⇒ 该手势不可用(其余照常)")
            return
        }
        let count = CFArrayGetCount(devices)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(devices, i) else { continue }
            register(UnsafeMutableRawPointer(mutating: raw), ThreeFingerTap.contactFrame)
            startDevice(UnsafeMutableRawPointer(mutating: raw), 0)
        }
        glog("[指点按] 已上线(\(count) 个设备)· 三指=\(enabled ? "开" : "关")(\(Self.defaultsKey))"
             + " · 四指=\(enabledFour ? "开" : "关")(\(Self.defaultsKeyFour))")
    }

    /// C 回调:主线程之外也可能被调 ⇒ 只喂数据、只在抬手帧判卷,回主线程才动作。
    private static let contactFrame: ContactCallback = { _, data, nFingers, _, _ in
        let tap = ThreeFingerTap.shared
        if tap.press.feed(nFingers: Int(nFingers), data: data) > 0 {
            // 按压路径:四指齐压到时 ⇒ 当场生效(点按失手的兜底,不必抬手)
            if tap.press.pressFireIfDue() {
                DispatchQueue.main.async {
                    let tap = ThreeFingerTap.shared
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - tap.lastTapAt > 0.35 else { return }
                    tap.lastTapAt = now
                    glog("[指点按] 四指按压 0.25s → 唤起并直接进未启动环(钉住)")
                    if tap.enabledFour { tap.onFireFour?() }
                    Haptics.fire(.summonFourFinger)
                }
            }
            return 0   // 按压还没结束
        }
        // 全部抬起 ⇒ 判卷(账本换新,下一轮从零记)
        let outcome = tap.press.judge()
        tap.press = Press()
        switch outcome {
        case .rejected(""):
            break                              // 一指的普通点按:不进账
        case .rejected(let why):
        if !why.isEmpty { Haptics.fire(.gestureRejected, trace: String(why.prefix(48))) }
            DispatchQueue.main.async { glog("[指点按] \(why)") }
        case .slide(let norm):
            DispatchQueue.main.async {
                glog(String(format: "[指点按] 滑动(位移 norm=%.3f > %.2f)→ 让给系统,不动作",
                            norm, ThreeFingerTap.maxMove))
            }
        case .fireThree(let held, let norm, let absMove):
            DispatchQueue.main.async {
                let tap = ThreeFingerTap.shared
                let now = CFAbsoluteTimeGetCurrent()
                guard now - tap.lastTapAt > 0.35 else {
                    glog(String(format: "[指点按] 三指 %.0fms → 防抖(距上次 %.2fs),不重复动作", held, now - tap.lastTapAt))
                    return
                }
                tap.lastTapAt = now
                glog(String(format: "[指点按] 三指 %.0fms 位移 norm=%.4f abs=%.1f → 唤起(钉住)",
                            held, norm, absMove))
                if tap.enabled { tap.onFire?() }
                Haptics.fire(.summonThreeFinger)
            }
        case .fireFour(let held, let norm, let absMove):
            DispatchQueue.main.async {
                let tap = ThreeFingerTap.shared
                let now = CFAbsoluteTimeGetCurrent()
                guard now - tap.lastTapAt > 0.35 else {
                    glog(String(format: "[指点按] 四指 %.0fms → 防抖(距上次 %.2fs),不重复动作", held, now - tap.lastTapAt))
                    return
                }
                tap.lastTapAt = now
                glog(String(format: "[指点按] 四指 %.0fms 位移 norm=%.4f abs=%.1f → 唤起并直接进未启动环(钉住)",
                            held, norm, absMove))
                if tap.enabledFour { tap.onFireFour?() }
                Haptics.fire(.summonFourFinger)
            }
        }
        return 0
    }
}

// MARK: - 双击 ⌥ 把指针送到下一块屏幕

/// 双击 ⌥ 把指针送到**下一块屏幕**（今天双屏场景 = 另一块屏，多屏自动循环 ✓）。
///
/// 为什么不是"注册一个热键"：⌘/⌃/⌥/⇧ 是**修饰键**，系统热键 API 只接受"修饰键 + 一个真实按键"，
/// 单独一个 ⌥ 注册不了。所以换一种做法：**监听事件流**，只看不改 ——
/// 两处监听都把事件**原样返回**（`return e`），一个字节都不吞，因此不可能影响 ⌥Tab、⌥⇧ 等任何既有操作。
///
/// 触发键史:曾是双击 ⌃(2026-09-15)—— 用户实测与 IDEA 的 ⌃ 系快捷键打架,2026-09-17 改 ⌥。
///
/// 要小心的不是"冲突"（双 ⌥ 不是 macOS 的系统快捷键 —— 按住 ⌥ 出音标选单那是"按住",
/// 只有一次 down,凑不出双击），而是**误触发**：
/// 一天要按几百次"⌥ + 别的键"。所以规则是 —— **两次干净的 ⌥ 之间只要夹了任何别的按键，立刻作废**。
/// 于是 ⌥ 组合键、⌥Tab(触发键自己也走 ⌥+键的路,被 dirty 拦住)永不误触发；只有"干干净净连按两下 ⌥"才动。
/// 最坏情况的代价也只是指针跳了一下，再双击一次就回来 —— 自纠正。
///
/// 放在这个文件里而不是新建文件：本工程的 pbxproj 用的是**显式文件引用**，
/// 新建 .swift 必须同时在四处登记（PBXBuildFile / PBXFileReference / group / Sources phase），
/// 漏一处就是 `cannot find 'X' in scope`。同一个 domain 的代码就近放，先避免这类机械风险。
final class DoubleOptionTap {
    static let shared = DoubleOptionTap()
    private init() {}

    /// 设置项。**默认关**：macOS 本身没有这个功能，按"新开关一律默认对齐 macOS"的规则应为关。
    /// UserDefaults 直读 ⇒ 设置里一改立刻生效，不用重启（和 panel.sheen 等既有开关同一套约定）。
    /// key 随触发键换名(⌃→⌥),**不做旧值迁移**:功能默认关,丢一次开关状态无伤
    /// (先例:panel.puckRiseFromBottom → panel.slideFromLastApp 也是不迁移)。
    static let defaultsKey = "pointer.doubleOptionJumps"
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCleanDown: CFAbsoluteTime?   // 上一次"干净地按下 ⌥"的时刻
    private var dirty = false                    // 这一轮按住 ⌥ 期间有没有夹别的键
    private var optionWasDown = false
    private static let minGap: Double = 0.06     // 太快 ⇒ 同一次按住的抖动，不算双击
    private static let maxGap: Double = 0.30     // 超过 ⇒ 不像"有意双击"（苹果 ~500ms 对修饰键太松）

    func start() {
        guard globalMonitor == nil else { return }   // 幂等：重复 start 不会挂两套监听
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e)
        }
        // 我们自己的窗口在最前时，全局监听**看不到**事件（macOS 的设计）⇒ 补一个本地监听。
        // 注意返回 e 而不是 nil：nil 会**吞掉**事件，那正是要绝对避免的事。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            dirty = true                       // 夹了别的按键 ⇒ 这一轮作废
        case .flagsChanged:
            // ⌘/⌃/⇧ 动过也算"夹了别的键"（fn / capsLock 常驻，不算；⌥ 自己是触发键，不算）
            if !e.modifierFlags.intersection([.command, .control, .shift]).isEmpty { dirty = true }
            let optionDown = e.modifierFlags.contains(.option)
            guard optionDown != optionWasDown else { return }   // 只认状态翻转
            optionWasDown = optionDown
            guard optionDown else { return }                     // 抬起：什么都不做
            let now = CFAbsoluteTimeGetCurrent()
            if let prev = lastCleanDown, now - prev >= Self.minGap, now - prev <= Self.maxGap, !dirty {
                lastCleanDown = nil
                dirty = false
                if enabled { jumpToNextDisplay() }
            } else {
                lastCleanDown = now
                dirty = false
            }
        default:
            break
        }
    }

    /// 目标屏上 Z 序最前的那扇窗 = 用户说的"台前第一个 App"。
    /// 为什么落焦到**窗**而不是 App:同一个 App 可能两块屏各有窗,让 App 自己决定键盘给谁
    /// 正是"激活不保证落焦"那个坑(见 CONTEXT.md)。
    private func landingWindow(on displayID: CGDirectDisplayID) -> WindowRecord? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        // ⚠️ 不能直接用 WindowEnumerator.rawGroups(on:).first —— 那个数组是按 pid 分组后的
        // **Dictionary 的值**,而 Swift 里 Dictionary 的顺序是未定义的。实机现形(2026-09-15 用户报):
        // "不是台前第一个…现在是系统自己选的" —— .first 拿到的是哈希序里的某个 App ✗。
        //
        // 所以直接问 CGWindowList:它返回的数组是**前到后**的 Z 序,第一个命中者就是"层级最上面"那扇窗。
        // 过滤规则与 rawGroups 保持一致(layer==0 / 排除自家窗 / 尺寸合理 / 归属屏恰为目标屏)。
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in infos {                       // 顺序遍历 = 从最上面往下,第一个命中即答案
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1,
                  WindowEnumerator.ownsByContextScreen(bounds, contextScreen: screen)
            else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let owner = info[kCGWindowOwnerName as String] as? String ?? "(未知应用)"
            return WindowRecord(wid: wid, pid: pid, ownerName: owner, title: title, bounds: bounds)
        }
        return nil
    }

    /// 移到下一块屏幕，**保持相对位置**（右屏 70% 高处 ⇒ 左屏 70% 高处），
    /// 而不是丢到角落 —— 指针像"平移"过去，这是体感的关键。
    private func jumpToNextDisplay() {
        guard NSEvent.pressedMouseButtons == 0 else { return }   // 拖拽途中不动（别把拖拽目标搞乱）
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

        // 全程用 CoreGraphics 坐标系（原点在主屏**左上**）：指针位置与屏幕矩形同系，
        // 就不需要 y 翻转 —— 少一次换算出错的机会（这类翻转是经典 bug 源）。
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard let from = ids.firstIndex(where: { CGDisplayBounds($0).contains(cursor) }) else { return }
        let b = CGDisplayBounds(ids[(from + 1) % ids.count])
        // **居中落点**(用户 2026-09-15):指针永远落在那块屏的**正中间**。
        // 原先按"相对位置"平移(右屏 70% 高处 → 左屏 70% 高处),思路是"像把指针平推过去";
        // 改动理由是**可预测**:落焦已经把键盘交给目标屏台前的窗之后,
        // 指针的精确位置不再承载意义,而"永远在正中间"是闭着眼也知道的事。
        // 顺带不需要再夹 2%–98% —— 屏幕中心天生远离各条边缘。
        let rx = 0.5
        let ry = 0.5
        CGWarpMouseCursorPosition(CGPoint(x: b.minX + rx * b.width, y: b.minY + ry * b.height))
        CGAssociateMouseAndMouseCursorPosition(1)   // 防止与事件流解耦（否则指针"冻住"直到动一下）
        // 把"工作上下文"一起搬过去:落焦到那块屏台前的那扇窗 ⇒ 过去就能直接打字。
        // **落焦是跳屏的固定语义,没有"只搬指针"模式**(T87 v2 用户裁定:
        // 「移动过去不落焦那移动的意义是什么」—— 子开关废除)。
        // 不算融合操作 —— 落点由那块屏自身决定,没有替用户做选择(ADR-0007 修正)。
        let targetID = ids[(from + 1) % ids.count]
        var landed = ""
        if let w = landingWindow(on: targetID) {
            MainActor.assumeIsolated { WindowFocuser.focus(window: w) }   // 监听器在主线程,无需再跳
            landed = " · 落焦 \(w.ownerName)"
        }
        print(String(format: "[指针] 双击 ⌥ → 屏 %d → 屏 %d (居中)%@",
                     from + 1, (from + 1) % ids.count + 1, landed))
    }
}
