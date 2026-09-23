import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GlanceCore

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
    static let defaultsKey = Keys.pointerThreeFingerTapPanel
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? KeyDefaults.threeFingerTapPanel
    }

    /// 四指轻点(T91)= **直接进未启动环**。与三指那条同一条纪律:**默认关**
    /// (默认对齐 macOS:macOS 没有这个功能),而且**区分"没写过"与"写成 false"** ——
    /// `object(forKey:) as? Bool ?? false`:取不到 = 没写过 = 关,取到 false = 用户关掉了。
    /// (本机实测:系统没有占用"四指轻点"—— `TrackpadFourFingerTapGesture` 这个键根本不存在;
    ///  四指只有横扫/竖扫/捏合。见 design/入口槽-底部形态实验台.html 的记账。)
    static let defaultsKeyFour = Keys.pointerFourFingerTapLaunchRing
    private var enabledFour: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKeyFour) as? Bool ?? KeyDefaults.fourFingerTapLaunchRing
    }

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
    /// 阈值**只有一处**(`TapRound.Policy`)✓ —— App 侧不再抄第二份 ✗
    static var maxMove: Float { TapRound.Policy.standard.maxMove }
    static var maxDuration: Double { TapRound.Policy.standard.maxDuration }

    private var started = false
    /// 一次按压的账本(记账 + 判卷都在 `Press`,回调只喂数据 —— 2026-09-18 重构:
    /// 判卷逻辑越来越长,再跟"读 C 结构体 + 回调线程纪律"搅在一起,每次动都会伤到别的)
    private var press = Press()
    /// 上一次成功判卷的时刻。**0.35s 防抖**(LumaRing 同款):连击的第二发不重复动作 ——
    /// 用户连着试几次的时候,面板被反复拆建,读起来就是"闪"
    private var lastTapAt: CFAbsoluteTime = 0

    /// **一次按压**的账本 —— 判卷本身已经搬到 `GlanceCore.TapRound` ✓。
    ///
    /// ## 为什么搬（2026-09-22）
    ///
    /// 同一个"**账本生命周期没写清楚**"的病犯了**四次**:11 指 · 幽灵触点 · 单指数成三指 · 拖拽误判。
    /// 每次只能靠用户"用手指数"/事后翻日志来发现 ✗ —— 因为判卷是**纯逻辑**,
    /// 却被埋在 `dlopen` 回调的 `mutating` 字段里,没有一处能断言 ✓。
    /// ⇒ 照 ADR-0015 的三条判据(纯 + 常改 + 曾经错过,全占)抽成 `TapRound` + 单测 ✓
    ///
    /// 这里只留**基础设施**该干的事:
    /// 把 `MultitouchSupport` 的原始 struct 解码成 `TapRound.Contact`、把"卡死自愈"翻译成一行日志。
    /// **一行判断都不做** ✓
    struct Press {
        typealias Outcome = TapRound.Outcome
        /// 阈值唯一来源(`TapRound.Policy`)✓
        static var policy: TapRound.Policy { .standard }
        static var maxMove: Float { policy.maxMove }
        static var maxDuration: Double { policy.maxDuration }

        private var tracker: TapRound.Tracker = {
            var t = TapRound.Tracker()
            // 点按时长下限的**真机档位**(默认 30ms = 原行为 ✓)
            // 病例(2026-09-22):一次"三指静置 60ms 后抬起"被判成点按 ⇒ 面板自己弹出来 ✗
            // (用户:「就在回复的时候, 三指误触又出现了」✓ 日志 `三指 60ms 位移 abs=0.3 → 唤起`)
            // 判卷没写错 —— 那个形状**就是**一记标准点按;要治的是"这种形状也可能是无意的一搭" ✓
            // ⇒ 抬下限的代价是"更快的轻点会被挡" ⇒ 只能由用户在真机上定 ⇒ 做成档位 ✓
            t.policy.minDuration = Double(DebugFlags.tapMinDurationMs) / 1000
            // 重量门(默认 0.6):"很轻地搭一下"不是点按(见 Policy.minContactSize 的病例 ✓)
            t.policy.minContactSize = DebugFlags.tapMinContactSize
            return t
        }()
        private var lastSnapshot = TapRound.Snapshot()

        /// 量尺(进日志):本轮见过的 state 档
        var statesSeen: [Int32] { lastSnapshot.statesSeen }
        var pressFired: Bool { tracker.hasFired }

        /// 喂一帧,返回"此刻在板上的真手指数"(0 = 全部离开 ⇒ 调用方去判卷 ✓)
        mutating func feed(nFingers: Int, data: UnsafeMutableRawPointer?) -> Int {
            let now = CFAbsoluteTimeGetCurrent()
            let stale = tracker.resetIfStuck(now: now)
            if stale > 0 {
                glog(String(format: "[指点按] 账本 %.1fs 未收口 ⇒ 强制重置(丢帧/幽灵触点自愈)", stale))
            }
            var contacts: [TapRound.Contact] = []
            if let data, nFingers > 0 {
                for i in 0..<nFingers {
                    let f = data.assumingMemoryBound(to: Finger.self)[i]
                    contacts.append(TapRound.Contact(
                        id: f.identifier,
                        normalized: TapRound.Point(Double(f.normalized.pos.x), Double(f.normalized.pos.y)),
                        absolute: TapRound.Point(Double(f.absolute.pos.x), Double(f.absolute.pos.y)),
                        size: f.size, majorAxis: f.majorAxis, state: f.state))
                }
            }
            let n = tracker.feed(TapRound.Frame(contacts: contacts, time: now))
            lastSnapshot = tracker.snapshot(now: now)
            return n
        }

        /// 判卷(**先判卷,再 `endRound()`** —— 顺序反了就是拿空账本判 ✗)
        func judge() -> Outcome { tracker.judge(now: CFAbsoluteTimeGetCurrent()) }

        mutating func endRound() {
            tracker.endRound()
            lastSnapshot = TapRound.Snapshot()
        }

        /// 标记"本轮已生效"(按压触发那条路用;抬手不再按点按重复计)
        mutating func markFired() { tracker.markFired() }
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

    /// **起拖就撤销这次唤起**(2026-09-22 用户实报「我三指拖拽窗口边框, 也唤起了面板。
    /// 已经是拖拽了, 怎么还能唤起呢」)。
    ///
    /// ★ 为什么不再调阈值(这是同类病的**第三次** ⇒ 按"修到第三次就怀疑设计"的规矩停手):
    ///   前两次都在收 `maxMove`(0.08 → 0.03 ✓),因为真实的**长拖**位移大、拒得掉 ✓;
    ///   但这次这条在手指数据上**与轻点完全一致** ✗ ——
    ///   `TrackpadThreeFingerDrag = 1`(三指拖移开着 ✓)时,**起拖那一拍本身就是一次干净的三指轻点** ✓
    ///   (带动移锁定时更是如此:轻点起拖、拖完再轻点放下 ⇒ 两次都是"完美轻点" ✗)。
    ///   手指分不出来 ⇒ 换个**手指之外**的证据:系统真在拖东西时,**鼠标键是按下状态** ✓
    ///   (三指拖移在系统里就是"按住左键移动指针" ✓)。
    ///
    /// 口径:生效之后 0.3s 内只要看到按键按下 ⇒ **撤销这次唤起**(面板收起 ✓)。
    ///   ⇒ 观感从"拖窗时面板一直挂着"✗ 变成"闪一下"✓(用户原话:点按误触我能理解 ✓);
    ///     代价诚实说:真轻点唤起后 0.3s 内如果**恰好**有拖拽在进行,这次唤起会被收掉 ✗。
    @MainActor
    static func cancelIfDragStarted(reason: String) {
        // 判据演进(2026-09-22,用户三次实报"拖拽误触"):
        //   ① `pressedMouseButtons != 0` —— **错的信号** ✗(物理按键;三指拖移是系统**合成**的拖动 ⇒ 恒为 0)
        //   ② 250ms 内指针位移 > 15pt —— 抓到了一部分 ✓,但**窗口太短** ✗:
        //      带"拖移锁定"的用法是「轻点起拖 → 停一下 → 再拖」⇒ 移动发生在 250ms **之后** ✗
        //   ③ 现在:**直接盯"系统在拖"这件事** —— 装一个短命全局监听收 `leftMouseDragged` ✓
        //      (三指拖移在系统里就是拖动 ⇒ 一定有 dragged 事件 ✓),窗口给 1.2s ✓;
        //      同时保留指针位移这条当兜底(便宜 ✓,窗口也拉长到 0.8s ✓)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        var monitor: Any?
        var fired = false
        func cancelOnce(how: String) {
            guard !fired else { return }
            fired = true
            glog("[指点按] ⚠️ \(reason) 之后系统在拖拽(\(how)) ⇒ **撤销这次唤起(拖拽误触)**")
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            onDragMisfire?()
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            DispatchQueue.main.async { cancelOnce(how: "收到拖拽事件") }
        }
        // ⚠️ 2026-09-22 **删掉两条"指针位移"兜底** ✗ —— 它们误伤了**钉住的一局**:
        //   病例(用户实报):「三指唤起之后, 怎么 hover 选择 app 面板就会消失啊。不是说此局维持吗」✓
        //   hover 选 App 就是**挪指针**(动辄几百 pt ✗),与拖拽在"指针"这个量上完全分不出来 ✗
        //   ⇒ 真信号只能是"**系统在拖东西**"(= `*MouseDragged` 事件 ✓,hover 不会产生它 ✓),
        //     而不是"指针动了" ✗。位移那两条留在 `logPostFirePointerDrift`(只记日志 ✓)以便继续取证 ✓
        // 1.2s 后收工(不留监听 ✓)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if !fired, let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    /// 撤销唤起(由 App 层装配到面板:收面板 ✓)
    static var onDragMisfire: (() -> Void)?

    /// **生效后的事后归因**(2026-09-22 用户实报「三指划词的时候好像又误触了」)——
    /// 生效之后 250ms 再看一眼指针有没有**继续移动**:
    ///   · 几乎没动 ⇒ 真是一次轻点 ✓
    ///   · 又挪了 8pt 以上 ⇒ 这一发其实是**划词/拖选的开头** ✗(手指还在板上滑,人是在选文字)
    /// 它**只记日志、不改行为** ✓ —— 先把"哪些生效其实是误触"变成可数的数,
    /// 再决定要不要"发现拖选就撤掉面板"(那是行为改动,得先问用户 ✓)。
    @MainActor
    static func logPostFirePointerDrift(_ what: String) {
        let p0 = NSEvent.mouseLocation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let p1 = NSEvent.mouseLocation
            let dist = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()
            if dist > 8 {
                glog(String(format: "[指点按] ⚠️ %@ 生效后 250ms 指针又移动 %.0fpt ⇒ 这一发**像是划词/拖选的开头**",
                            what, dist))
            }
        }
    }

    /// **截图会话里,手势也要让权**(2026-09-22 用户实报后加)。
    ///
    /// 病例:用户「我刚才截图, 然后好像误触唤起启动环了」—— 日志铁证:
    ///   `[指点按] 四指 75ms 位移 norm=0.0028 abs=0.3 → 唤起并直接进未启动环(钉住)` ✗
    ///   手指/掌缘压在触控板上,被读成"干净的四指轻点"(位移 0.3pt ✓ 时长 75ms ✓ 全都过闸)。
    /// 结构缺口:键盘那条早就让权了(`captureSessionTookOver(keyCode:)` ⇒ 截图时放行导航键 ✓),
    ///   而**手势这条(MultitouchSupport)从来没问过截图会话** ✗ ⇒ 截图时照样唤起 ✓
    /// ⇒ 这里把同一套判据接到手势的两个生效点上(点按 + 四指按压)✓
    @MainActor
    private static func gestureBlockedByCapture(_ what: String) -> Bool {
        let capture = CaptureSessionProbe.verdict()
        guard capture.isCapture else { return false }
        glog("[T32] 截图会话里忽略手势(\(what)):\(capture.reason)")
        return true
    }

    /// C 回调:主线程之外也可能被调 ⇒ 只喂数据、只在抬手帧判卷,回主线程才动作。
    private static let contactFrame: ContactCallback = { _, data, nFingers, _, _ in
        let tap = ThreeFingerTap.shared
        if tap.press.feed(nFingers: Int(nFingers), data: data) > 0 {
            // ⚠️ 2026-09-22 这里原本有一条"**中途开火**":四指齐压满 0.25s 就当场生效(不必抬手)✗
            //   四指下滑的前 0.25s 与"四指按住"完全一样 ⇒ 拖/滑被误判(用户实报三次 ✓)。
            //   照 LumaRing 的做法:**只在全部手指离开那一帧判**(见下面的 `judge()` ✓)——
            //   "按住"这个意图改由时长窗口 `pressHoldRange` 在抬手时认领 ✓
            //   (LumaRing 的原文只剩一句:`if (!activeCount) { fire = matched && ... }` ✓)
            return 0
        }
        // ★ **抬手帧**(全部手指都离开)⇒ 判卷 —— 照 LumaRing:只有这一帧才可能 fire ✓
        //   ⚠️ 恢复记录(2026-09-22):我删"中途开火"那一块时,**把这一段一起切掉了** ✗
        //      ⇒ `judge()` 一夜之间没有任何调用点 ⇒ 三指点按彻底不生效 ✗
        //      (只靠"构建通过"发现不了 —— 教训:**删块之后必须回读调用点** ✓)
        // ⚠️ 2026-09-22 撤掉"确认静默 70ms 候选"✗(它建立在**错前提**上):
        //   那版以为"抬手后会有 70ms 安静" ✓,实测这台触控板**几乎每帧都有触点**
        //   (休息的手指/幽灵触点)⇒ 候选**永远**被作废 ⇒ 判卷一次都没跑 ⇒ 手势全灭 ✗
        //   (用户实报「你治好什么了, 手势不生效了... 确实不会误触了」——
        //    "不误触"是因为**什么都不触发** ✗,日志:开火 0 / 不动作 0 / 账本 1.0s 未收口)
        //   ⇒ 恢复"抬手帧当场判" ✓;单指误触由**起点清 id**那条真修复挡着 ✓
        let states = tap.press.statesSeen.sorted().map(String.init).joined(separator: "/")
        let outcome = tap.press.judge()          // 先判卷(要用账本 ✓)
        tap.press.endRound()                     // 再清账(id 跨轮累计 ⇒ 手指数算成 11 ✗)
        DispatchQueue.main.async {
            let tap = ThreeFingerTap.shared
            let now = CFAbsoluteTimeGetCurrent()
            switch outcome {
            case let .fireThree(held, norm, absMove, maxSize, maxMajor):
                guard now - tap.lastTapAt > 0.35 else {
                    glog(String(format: "[指点按] 三指 %.0fms → 防抖(距上次 %.2fs),不重复动作", held, now - tap.lastTapAt))
                    return
                }
                tap.lastTapAt = now
                if ThreeFingerTap.gestureBlockedByCapture("三指点按") { return }
                glog(String(format: "[指点按] 三指 %.0fms[state %@] 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 唤起(钉住)",
                            held, states, norm, absMove, maxSize, maxMajor))
                if tap.enabled { tap.onFire?() }
                Haptics.fire(.summonThreeFinger)
                ThreeFingerTap.logPostFirePointerDrift("三指点按")
                ThreeFingerTap.cancelIfDragStarted(reason: "三指点按")
            case let .fireFour(held, norm, absMove, maxSize, maxMajor):
                guard now - tap.lastTapAt > 0.35 else {
                    glog(String(format: "[指点按] 四指 %.0fms → 防抖(距上次 %.2fs),不重复动作", held, now - tap.lastTapAt))
                    return
                }
                tap.lastTapAt = now
                if ThreeFingerTap.gestureBlockedByCapture("四指点按") { return }
                glog(String(format: "[指点按] 四指 %.0fms[state %@] 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 唤起并直接进未启动环(钉住)",
                            held, states, norm, absMove, maxSize, maxMajor))
                if tap.enabledFour { tap.onFireFour?() }
                Haptics.fire(.summonFourFinger)
                ThreeFingerTap.logPostFirePointerDrift("四指点按")
                // (四指**轻点**不挂"拖拽撤销":轻点之后拖东西是正当用法 ✓ 见上面的长注 ✓)
            case let .slide(norm):
                glog(String(format: "[指点按] 滑动(位移 norm=%.3f > %.2f)→ 让给系统,不动作",
                            norm, ThreeFingerTap.maxMove))
            case let .rejected(reason):
                if !reason.isEmpty { glog("[指点按] \(reason)") }
            }
        }
        return 0
    }
}
