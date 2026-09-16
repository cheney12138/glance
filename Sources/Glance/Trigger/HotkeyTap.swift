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
        Set([keyLeft, keyRight, keyEsc, keyReturn, keyQ, keyW, keyM, keyF, keyH, keyGrave])
            .union(digitKeys.keys)
    /// `(kVK_ANSI_Grave = 0x32):会话期可选地接管"当前 App 的窗口循环"。
    ///
    /// 为什么这个键值得单独说:它同时是 macOS **全局**的"同 App 窗口循环"(⌘`) ——
    /// 我们**不去关系统热键**(DockDoor 的做法,源码实证):靠 navTap 会话期吞键即可,
    /// 系统那条热键在 WindowServer 层是更晚的环节,吞掉就收不到。
    /// 代价与 Tab 循环同一条:tap 若被系统停用那一瞬,这一发会漏给系统(见 ADR-0005 的取舍)。
    /// 默认**关**:它动的是系统级快捷键的肌肉记忆,只能用户显式开(与接管 ⌘Tab 同一纪律)。
    private static let keyGrave: Int64 = 0x32
    private static var graveCyclesWindows: Bool {
        UserDefaults.standard.object(forKey: "switch.graveCyclesWindows") as? Bool ?? false
    }

    /// 钉住开关:松 ⌥ 不关面板,状态机保持导航态,Enter 接手确认权(用户实评"还挺实用")
    private var pinPanel: Bool { UserDefaults.standard.bool(forKey: "debug.pinPanelOnRelease") }

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
        navTap = makeTap(at: .cghidEventTap, options: .defaultTap, types: [.keyDown])
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
        UserDefaults.standard.removeObject(forKey: "trigger.keyCode")
        UserDefaults.standard.removeObject(forKey: "trigger.modifier")
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
    func endSession() { setState(.idle) }

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
            if pinPanel { break }
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
        guard state == .navigating else { return false } // 理论上不会(会话期才开),守一道
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let config = TriggerConfig.load()
        // 触发键在导航期 = **循环移动**(开头那一发由 Carbon 负责,见 `handleHotKey`)
        if keyCode == config.keyCode {
            trace("trigger repeat kc=\(keyCode) shift=\(event.flags.contains(.maskShift))")
            emit(event.flags.contains(.maskShift) ? .prev : .next)
            return true
        }
        guard Self.navKeys.contains(keyCode) else { return false }
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

// MARK: - 双击 ⌃ 把指针送到下一块屏幕

/// 双击 ⌃ 把指针送到**下一块屏幕**（今天双屏场景 = 另一块屏，多屏自动循环 ✓）。
///
/// 为什么不是"注册一个热键"：⌘/⌃/⌥/⇧ 是**修饰键**，系统热键 API 只接受"修饰键 + 一个真实按键"，
/// 单独一个 ⌃ 注册不了。所以换一种做法：**监听事件流**，只看不改 ——
/// 两处监听都把事件**原样返回**（`return e`），一个字节都不吞，因此不可能影响 ⌃C、⌃↑、⌥Tab 等任何既有操作。
///
/// 要小心的不是"冲突"（双 ⌃ 不是 macOS 的系统快捷键），而是**误触发**：
/// 一天要按几百次"⌃ + 别的键"。所以规则是 —— **两次干净的 ⌃ 之间只要夹了任何别的按键，立刻作废**。
/// 于是 ⌃C、⌃↑、⌃Tab 永不触发；只有"干干净净连按两下 ⌃"才动。
/// 最坏情况的代价也只是指针跳了一下，再双击一次就回来 —— 自纠正。
///
/// 放在这个文件里而不是新建文件：本工程的 pbxproj 用的是**显式文件引用**，
/// 新建 .swift 必须同时在四处登记（PBXBuildFile / PBXFileReference / group / Sources phase），
/// 漏一处就是 `cannot find 'X' in scope`。同一个 domain 的代码就近放，先避免这类机械风险。
final class DoubleControlTap {
    static let shared = DoubleControlTap()
    private init() {}

    /// 设置项。**默认关**：macOS 本身没有这个功能，按"新开关一律默认对齐 macOS"的规则应为关。
    /// UserDefaults 直读 ⇒ 设置里一改立刻生效，不用重启（和 panel.sheen 等既有开关同一套约定）。
    static let defaultsKey = "pointer.doubleControlJumps"
    /// 移完指针是否**一并落焦**到那块屏台前的那扇窗(默认开:用户明确期望"过去就能打字")
    /// 关掉它 = 只搬指针,不碰键盘(适用于"只是过去点一下"的场景)
    static let landsFocusKey = "pointer.doubleControlLandsFocus"
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCleanDown: CFAbsoluteTime?   // 上一次"干净地按下 ⌃"的时刻
    private var dirty = false                    // 这一轮按住 ⌃ 期间有没有夹别的键
    private var controlWasDown = false
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
            // ⌘/⌥/⇧ 动过也算"夹了别的键"（fn / capsLock 常驻，不算）
            if !e.modifierFlags.intersection([.command, .option, .shift]).isEmpty { dirty = true }
            let controlDown = e.modifierFlags.contains(.control)
            guard controlDown != controlWasDown else { return }   // 只认状态翻转
            controlWasDown = controlDown
            guard controlDown else { return }                     // 抬起：什么都不做
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
        // 不算融合操作 —— 落点由那块屏自身决定,没有替用户做选择(ADR-0007 修正)。
        let targetID = ids[(from + 1) % ids.count]
        var landed = ""
        let wantFocus = UserDefaults.standard.object(forKey: Self.landsFocusKey) as? Bool ?? true
        if wantFocus, let w = landingWindow(on: targetID) {
            MainActor.assumeIsolated { WindowFocuser.focus(window: w) }   // 监听器在主线程,无需再跳
            landed = " · 落焦 \(w.ownerName)"
        }
        print(String(format: "[指针] 双击 ⌃ → 屏 %d → 屏 %d (居中)%@",
                     from + 1, (from + 1) % ids.count + 1, landed))
    }
}
