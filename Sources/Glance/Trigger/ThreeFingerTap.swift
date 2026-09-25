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

    // MARK: 拖移证据(2026-09-23 实锤后加,规格文档表二"一票否决"✓)
    //
    // 三指拖移被系统消费时会**合成 leftMouseDown**("按住左键移动" —— 这正是文字能被
    // 选中的机制),而真轻点不合成任何鼠标事件。误触实锤(日志 `[27900ms] 三指 237ms
    // 位移 norm=0.0251 size=0.6 → 唤起`):快速选词在**接触期间**就完成了拖移,抬手后
    // 没有 dragged 事件 ⇒ 事后撤销(`cancelIfDragStarted`)抓不到 ✗
    // ⇒ 判卷这一刻必须问:**这轮按压期间系统按下过鼠标没有**。
    // 采集口 = HotkeyTapCenter **已有的** `mouseTap`(`.listenOnly` + leftMouseDown,
    // 全天候在线)⇒ 零新框架 ✓。窗口 1.5s 的取舍记账见规格文档表二 ✓。
    private let dragEvidenceLock = NSLock()
    private var lastDragEvidenceAt: CFAbsoluteTime = 0
    static let dragEvidenceWindow: CFAbsoluteTime = 1.5

    /// HotkeyTapCenter 的 mouseTap(主线程)调:**≥2 指在板时**看到鼠标按下 ⇒ 记一笔证据。
    /// 物理点按(拇指按键)时若 ≥2 指搭在板上也会记 —— 那种时刻本就不该唤起面板,方向一致 ✓
    func noteMouseDownWhileTouching() {
        guard press.lastTouching >= 2 else { return }
        dragEvidenceLock.lock(); defer { dragEvidenceLock.unlock() }
        lastDragEvidenceAt = CFAbsoluteTimeGetCurrent()
    }

    /// contactFrame(MT 回调线程)判卷前取证据。写在主线程、读在回调线程 ⇒ 锁保护 ✓
    private func dragEvidencePending() -> Bool {
        dragEvidenceLock.lock(); defer { dragEvidenceLock.unlock() }
        guard lastDragEvidenceAt > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - lastDragEvidenceAt < Self.dragEvidenceWindow
    }

    // MARK: 拖后宽限(2026-09-25,用户裁定「任何时候三指都应该是唤起手势」)
    //
    // 刚拖完(鼠标刚抬起)的一小窗里,系统会抢着把下一发三指认成拖移 —— 那一下"点击/小拖"
    // 反正收不回来,面板照给(判卷见 `TapRound.judge` 的 postDragGrace)。
    // 与"快速选词"的区分点:**前序拖拽** —— 选词的按压开始前没有刚抬起的鼠标,
    // 拖完边框再点的那一发有 ✓。所以记的是**鼠标抬起**时刻,不是按下。
    private var lastSystemMouseUpAt: CFAbsoluteTime = 0
    /// 拖后宽限的窗口:鼠标抬起多久之内的下一发按压算"刚拖完"
    static let postDragGraceWindow: CFAbsoluteTime = 0.8

    /// HotkeyTapCenter 的 mouseTap(主线程)调:左键抬起 ⇒ 记一笔(不设手指数门禁,
    /// 拖边框/拖窗口都是单指操作,抬起时板上根本没有第二根手指 ✓)
    func noteMouseUp() {
        dragEvidenceLock.lock(); defer { dragEvidenceLock.unlock() }
        lastSystemMouseUpAt = CFAbsoluteTimeGetCurrent()
    }

    /// contactFrame(回调线程)判卷前问:这轮按压是不是"刚拖完"开始的
    /// (鼠标抬起 < 按压起点 < +0.8s;`pressStart` = now − 整轮时长 ✓)
    private func postDragGracePending(pressStart: Double) -> Bool {
        dragEvidenceLock.lock(); defer { dragEvidenceLock.unlock() }
        guard lastSystemMouseUpAt > 0 else { return false }
        let gap = pressStart - lastSystemMouseUpAt
        return gap > 0 && gap < Self.postDragGraceWindow
    }

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
    /// 睡醒/屏变化的重挂只装一次 ✓
    private var observing = false
    /// 上次挂设备的时刻(久闲后的第一次唤起会用它做自愈判据 ✓)
    private var lastAttachAt: CFAbsoluteTime = 0
    /// 上一个**触点帧**的时刻 —— "久闲后自愈"的判据 ✓(回调线程写、主线程读,只当一个时间戳用 ✓)
    private var lastFrameAt: CFAbsoluteTime = 0

    /// **久闲之后第一次按触发键 ⇒ 把设备重挂一遍**(不依赖"有帧进来" ✓)。
    ///
    /// 病例(2026-09-25 用户实报):合盖一夜后**三指/四指全哑**,而 ⌘Tab 照常 ✓
    /// 自愈为什么没生效:原来那条"账本 1.0s 未收口"的补丁住在**喂帧路径**里 ✗
    /// ⇒ 回调死了 ⇒ **一帧都不来** ⇒ 它永远不会被触发 ✓(他记的"卡 40 多小时"是账本卡住,
    ///   那是另一半;这一半是"根本没帧" ✓)
    /// 判据:距上一帧 > `debug.tapReattachIdleMin` 分钟(默认 30 ✓ 设 0 = 关 ✓)
    ///   —— 正常使用中永不成立(滑动/打字时帧一直在 ✓),只有"长时间没碰触控板"才会 ✓
    func recoverIfStale() {
        let idleMin = DebugFlags.tapReattachIdleMin
        guard idleMin > 0 else { return }
        // ⚠️ 判据只看"距上次**挂载**多久" ✗ 不要看"距上一帧":
        //   第一次实现用 lastFrameAt —— 实机一测**不触发** ✗ 因为**鼠标设备也在吐帧**
        //   (设备列表里不只有触控板 ✓)⇒ 时间戳被一路刷新 ⇒ 永远不到 30 分钟 ✓
        //   改成只看挂载时刻:久闲后的第一发触发键重挂一次(注册是亚毫秒级 ✓ 很便宜 ✓)
        let age = CFAbsoluteTimeGetCurrent() - lastAttachAt
        guard age > Double(idleMin) * 60 else { return }
        attachDevices(reason: String(format: "久闲 %.0f 分钟后自愈", age / 60))
    }
    /// 一次按压的账本(记账 + 判卷都在 `Press`,回调只喂数据 —— 2026-09-18 重构:
    /// 判卷逻辑越来越长,再跟"读 C 结构体 + 回调线程纪律"搅在一起,每次动都会伤到别的)
    private var press = Press()
    /// MT 回调的**串行闸**(2026-09-25 病例:进程 297% CPU 卡死):
    /// MultitouchSupport **每个设备一条回调线程**(`mt_ThreadedMTEntry`)—— 设备列表里
    /// 不只有内建板(鼠标设备也在 ✓ 外接板/睡醒后重建的设备同理)⇒ 同一时刻**两条线程**
    /// 同时进 `contactFrame`,`press`(值类型账本,内嵌 Array/Set)被并发读写 ⇒
    /// Swift 的并发变更断言在 `statesSeen.sorted()` 里炸开,两条线程在断言里打转 ⇒
    /// 整机卡死(采样铁证:两条 MT 线程 100% 栈都是
    /// `Press.feed → Tracker.snapshot → sorted → _assertionFailure`)。
    /// ⇒ 回调整段进锁:喂帧、判卷 + 清账必须同一临界区(两张抬手帧交错 = 拿空账判 ✗)
    let feedLock = NSLock()
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
            // ⚠️ 三个档位(时长下限 / 重量门 / 位移上限)由 `DebugFlags.tapPolicy` **一处拼装** ✓
            //   —— 这里**不要**再逐条赋值 ✗:我先写的是"先设 minDuration、再整体覆盖 policy",
            //   顺序一颠倒就把时长档位冲掉了(自己刚踩过 ✓);一处拼装从构造上没这个坑 ✓
            // 各自的病例:
            //   · 时长下限(默认 30ms):「三指静置 60ms 后抬起」被判成点按 ⇒ 面板自己弹出来 ✗
            //   · 重量门(默认 0.6):很轻地搭一下不是点按(见 Policy.minContactSize 的病例 ✓)
            //   · 位移上限(默认 0.05,2026-09-24 从 0.03 放宽):手指自然漂移不算滑动 ✓
            t.policy = DebugFlags.tapPolicy
            return t
        }()
        private var lastSnapshot = TapRound.Snapshot()
        /// 此刻在板上的真手指数(最近一帧的 feed 结果)。给**拖移证据**的采集口用:
        /// mouseTap(主线程)问"现在板上有没有 ≥2 指" ⇒ 有才记证据 ✓
        /// (MT 回调线程写、主线程读 —— 与本结构其它标量同一条纪律:单字读写,不拆不绕 ✓)
        private(set) var lastTouching = 0

        /// 量尺(进日志):本轮见过的 state 档
        var statesSeen: [Int32] { lastSnapshot.statesSeen }
        /// 整轮时长(给"按压起点 = now − heldTotal"用,拖后宽限的判据之一 ✓)
        var heldTotal: Double { lastSnapshot.heldTotal }
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
            lastTouching = n
            lastSnapshot = tracker.snapshot(now: now)
            return n
        }

        /// 判卷(**先判卷,再 `endRound()`** —— 顺序反了就是拿空账本判 ✗)。
        /// `dragEvidence` = 这轮按压期间系统按下过鼠标(见 ThreeFingerTap 拖移证据那段 ✓)
        /// `postDragGrace` = 按压开始前刚拖完(拖后宽限,见 ThreeFingerTap 同名牌段 ✓)
        func judge(dragEvidence: Bool = false, postDragGrace: Bool = false) -> Outcome {
            tracker.judge(now: CFAbsoluteTimeGetCurrent(),
                          dragEvidence: dragEvidence, postDragGrace: postDragGrace)
        }

        mutating func endRound() {
            tracker.endRound()
            lastSnapshot = TapRound.Snapshot()
        }

        /// 标记"本轮已生效"(按压触发那条路用;抬手不再按点按重复计)
        mutating func markFired() { tracker.markFired() }
    }
    func start() {
        guard !started else { return }   // 幂等:载库只做一次 ✓
        started = true
        guard Self.loadFramework() else { return }
        attachDevices(reason: "启动")
        observeWakeAndScreenChanges()
    }

    /// 载 MultitouchSupport 并把三个符号拿好(只做一次 ✓;拿不到就永久降级 ✓)
    /// MultitouchSupport 的四个函数类型(类型作用域 ✓ —— 属性要用到它们,不能留在函数里 ✗)
    private typealias CreateList = @convention(c) () -> CFMutableArray?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static var symbols: (list: CreateList, register: Register, start: StartDevice, stop: StopDevice?)?

    private static func loadFramework() -> Bool {
        guard symbols == nil else { return true }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW),
              let symList = dlsym(lib, "MTDeviceCreateList"),
              let symRegister = dlsym(lib, "MTRegisterContactFrameCallback"),
              let symStart = dlsym(lib, "MTDeviceStart") else {
            glog("[指点按] 取不到 MultitouchSupport ⇒ 该手势不可用(其余照常)")
            return false
        }
        symbols = (unsafeBitCast(symList, to: CreateList.self),
                   unsafeBitCast(symRegister, to: Register.self),
                   unsafeBitCast(symStart, to: StartDevice.self),
                   dlsym(lib, "MTDeviceStop").map { unsafeBitCast($0, to: StopDevice.self) })
        return true
    }

    /// **把当前设备重新挂一遍**(可重复调用 ✓)。
    ///
    /// 病例(2026-09-25 用户实报):**另一台机器合盖一夜**,早上打开 ⇒ 三指/四指都唤不起来,
    /// 而 ⌘Tab 照常响 ✓ 他说"以前修过、当时卡了 40 多小时"⇒ 那是**账本**卡住(自愈住在喂帧路径里 ✓)。
    /// 这一早的是**另一半**:`start()` 里有 `guard !started` ⇒ 整个进程**只挂一次设备** ✗
    /// ⇒ 睡醒后 Multitouch 的回调常常就死了 ⇒ **一帧都不来** ⇒ 账本自愈**永远不会触发** ✗
    /// ⇒ 三指/四指彻底静默,而 ⌘Tab 走 Carbon 热键(另一套机制)⇒ 照常 ✓ 现象与之一字不差 ✓
    /// 所以:睡醒 / 屏参数变化 / **久闲后的第一次唤起** 都重挂一遍 ✓(重挂幂等、很便宜 ✓)
    private func attachDevices(reason: String) {
        guard let sym = Self.symbols, let devices = sym.list() else { return }
        let count = CFArrayGetCount(devices)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(devices, i) else { continue }
            let p = UnsafeMutableRawPointer(mutating: raw)
            sym.stop?(p)                              // 先停(若符号在)—— 避免重复注册后帧送两遍 ✗
            sym.register(p, Self.contactFrame)
            sym.start(p, 0)
        }
        lastAttachAt = CFAbsoluteTimeGetCurrent()
        glog("[指点按] 已挂载 \(count) 个设备(\(reason))· 三指=\(enabled ? "开" : "关")"
             + " · 四指=\(enabledFour ? "开" : "关")")
    }

    /// 睡醒 / 屏参数变化 ⇒ 重挂(这两件正是"设备回调会死"的时刻 ✓)
    private func observeWakeAndScreenChanges() {
        guard !observing else { return }
        observing = true
        let c = NSWorkspace.shared.notificationCenter
        c.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            ThreeFingerTap.shared.attachDevices(reason: "睡醒")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { _ in
            ThreeFingerTap.shared.attachDevices(reason: "屏参数变化")
        }
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
        // ★ 提前到 **250ms 这一拍**(2026-09-23 用户「又复现误触了」):
        //   拖移在接触期间就开始了,但系统合成的拖拽事件要 1s 后才交出来 ✗
        //   那段"面板已经弹出来"的空窗,正是用户看到的东西 ✓
        //   判据在 `GlanceCore.TapUndoPolicy`(纯函数 + 单测 ✓):位移够大 **且 手指还在板上** ✓
        //   ⇒ hover 选 App(手已离板)不会被误撤 —— 那正是这条逻辑以前被否掉的原因 ✓
        let p0 = NSEvent.mouseLocation
        let policy = DebugFlags.tapUndoPolicy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let p1 = NSEvent.mouseLocation
            let drift = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()
            let fingers = ThreeFingerTap.shared.press.lastTouching
            switch policy.verdict(drift: drift, sinceFire: 0.25, fingersDown: fingers) {
            case .undo(let why):
                cancelOnce(how: why)
            case .keep(let why):
                if isTraceEnabled, drift >= 8 {
                    glog("[指点按] 生效后 250ms 指针动了 \(Int(drift))pt,但**不撤**:\(why)")
                }
            }
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
    /// ⚠️ "主线程之外"不是一条线程,是**每个设备一条**(见 `feedLock` 的病例)⇒ 整段进锁 ✓
    private static let contactFrame: ContactCallback = { _, data, nFingers, _, _ in
        let tap = ThreeFingerTap.shared
        tap.feedLock.lock()
        defer { tap.feedLock.unlock() }
        tap.lastFrameAt = CFAbsoluteTimeGetCurrent()   // 给"久闲后自愈"当判据 ✓
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
        let evidence = tap.dragEvidencePending()
        // 拖后宽限:按压起点 = 此刻 − 整轮时长;鼠标刚抬起 + 本轮被系统抢过(证据)⇒ 宽门 ✓
        let now0 = CFAbsoluteTimeGetCurrent()
        let grace = evidence && tap.postDragGracePending(pressStart: now0 - tap.press.heldTotal)
        let outcome = tap.press.judge(dragEvidence: evidence, postDragGrace: grace)   // 先判卷(要用账本 ✓)
        tap.press.endRound()                     // 再清账(id 跨轮累计 ⇒ 手指数算成 11 ✗)
        let graceNote = grace ? "(拖后宽限)" : ""
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
                glog(String(format: "[指点按] 三指 %.0fms[state %@] 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 唤起(钉住)%@",
                            held, states, norm, absMove, maxSize, maxMajor, graceNote))
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
                glog(String(format: "[指点按] 四指 %.0fms[state %@] 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 唤起并直接进未启动环(钉住)%@",
                            held, states, norm, absMove, maxSize, maxMajor, graceNote))
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
