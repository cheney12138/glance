import Foundation

/// 触控板"点按"的**判卷**（纯函数，可单测）。
///
/// ## 为什么它在这儿（ADR-0015）
///
/// 判据三条全占：**纯**（只吃帧、只吐结果；时钟由调用方传）+ **常改**（两周十几轮）+ **曾经错过**
/// —— 同一个"账本生命周期"病**犯了四次**（11 指 / 幽灵触点 / 单指数成三指 / 拖拽误判）。
/// ⇒ 它必须**可断言**，而不是一堆互相依赖的 mutating 字段、事后靠日志猜。
///
/// ## 口径（照 LumaRing 的 `TapRecognizer.c` —— 用户指的那个实现）
///
/// 1. **只在"全部手指离开"那一帧判**（原文只剩一句：`if (!activeCount) { fire = matched && … }`）；
/// 2. 帧间隔 > `maxFrameGap` ⇒ **直接拒**（原文："A missing/reordered frame could hide a swipe"）；
/// 3. 抬手窗口 —— "点按有一个**明确的手指离开过程**"（用户原话 ✓）；拖拽是慢慢松开的 ✗；
/// 4. 位移过大 ⇒ 让给系统。
///
/// ## 相对旧实现只加一条：**按位置续接轨迹**（carry）
///
/// 病例（2026-09-22「我三指拖拽窗口边框, 也唤起了面板」）：
/// ```
/// [指点按] 三指 105ms[state 4] 位移 norm=0.0014 → 唤起(钉住)   ← 判卷以为"轻点"
/// [指点按] ⚠️ 生效后 250ms 指针又移动 33pt                     ← 手一直在板上
/// ```
/// 真因：触点 **id 换号** ⇒ 位移基线被重置成 0 ✗ ⇒ 挪了 30pt 的轨迹看着"没动" ✓。
/// ⇒ 口径：**一根手指的位移，从它整条轨迹的起点算**。新 id 若在 `carryWindow` 内、又落在
///   `carryRadius` 之内，就认作**同一根手指** ✓（顺带让"抬手窗口"不再被 id 抖动骗到 ✓）。
///
/// ## 生命周期（这次要写成契约 —— 四次翻车都是"哪个字段活多久"没说清）
///
/// | 字段 | 活多久 |
/// |---|---|
/// | 轨迹 `live` / `maxLive` / 位移 / state 账 / 掌账 | **一轮**（第一根手指落板 → 全部离开） |
/// | 上次帧时刻 `lastFrameAt` | 跨轮（判"丢帧"要看真实间隔 ✓） |
/// | 已生效 `fired` | 一轮 |
public enum TapRound {

    // MARK: - 输入

    /// 一个坐标（用结构体而不是元组：元组不能合成 `Equatable` ✓，而单测全靠它 ✓）
    public struct Point: Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// 一帧里的一个触点（只留判卷需要的量；解码原始 struct 留给基础设施层）
    public struct Contact: Equatable {
        public var id: Int32
        /// 归一化坐标（判位移尺度的主用值）
        public var normalized: Point
        /// 绝对坐标（进日志对账）
        public var absolute: Point
        public var size: Float
        public var majorAxis: Float
        /// MultitouchSupport 的档：1–4 = 在板上，5–7 = 离板
        public var state: Int32

        public init(id: Int32,
                    normalized: Point,
                    absolute: Point,
                    size: Float, majorAxis: Float, state: Int32) {
            self.id = id
            self.normalized = normalized
            self.absolute = absolute
            self.size = size
            self.majorAxis = majorAxis
            self.state = state
        }
    }

    /// 一帧：触点 + 时刻（时刻由调用方给 ⇒ 判卷可测 ✓）
    public struct Frame {
        public var contacts: [Contact]
        public var time: Double
        public init(contacts: [Contact], time: Double) {
            self.contacts = contacts
            self.time = time
        }
    }

    // MARK: - 窗口（唯一出处；App 侧不再各留一份）

    public struct Policy: Equatable {
        /// 掌缘豁免线：长轴 ≥ 22 或面积 ≥ 4.5 的触点数不算手指
        public var palmMajorAxis: Float = 22
        public var palmSize: Float = 4.5
        /// ① 帧间隔上限：超了直接拒（丢帧 ⇒ 位移不可信）
        public var maxFrameGap: Double = 0.12
        /// ② 抬手窗口（LumaRing：4 指 0.10 / 3 指 0.16）
        public var maxReleaseSpan: Double = 0.12
        /// ④ "按住"窗口（不动的四指按住也算一次意图；再长多半是手搭在板上）
        public var pressHoldRange: ClosedRange<Double> = 0.45...1.2
        /// 账本卡死自愈（掌搭着打字 ⇒ 收口帧永远等不来；实锤见 `resetIfStuck`）
        public var stuckLedgerAfter: Double = 1.0
        /// 点按时长上限（从"手指落齐"起算）
        public var maxDuration: Double = 0.30
        /// 最短时长：< 30ms 算瞬时毛刺（LumaRing 同款下限）
        public var minDuration: Double = 0.03
        /// 位移上限（归一化）：超过就算滑动，让给系统
        public var maxMove: Float = 0.03
        /// 续接窗口：旧轨迹失联多久之内，新 id 可以认领它
        public var carryWindow: Double = 0.06
        /// 续接半径（归一化距离）：新 id 离旧轨迹多近才算同一根手指（≈ 屏宽的 5%）
        public var carryRadius: Double = 0.05

        public static let standard = Policy()
        public init() {}
    }

    // MARK: - 输出

    /// 账本快照（判卷要的量 + 进日志的量尺）
    public struct Snapshot: Equatable {
        public var fingerCount: Int = 0
        public var held: Double = 0
        public var heldTotal: Double = 0
        public var normalizedMove: Float = 0
        public var absoluteMove: Float = 0
        public var palmCount: Int = 0
        public var maxSize: Float = 0
        public var maxMajorAxis: Float = 0
        public var statesSeen: [Int32] = []
        public var sawFrameGap: Bool = false
        public var releaseSpan: Double = 0
        /// 量尺：本轮有几个触点是"续接"来的（id 换过号）—— 正是不续接就会误判的那种局
        public var carriedContacts: Int = 0
        public init() {}
    }

    public enum Outcome: Equatable {
        case fireThree(held: Double, norm: Float, abs: Float)
        case fireFour(held: Double, norm: Float, abs: Float)
        case slide(norm: Float)
        case rejected(String)
    }

    // MARK: - 轨迹

    /// 一根"手指"的轨迹：**id 可以换，轨迹不换** —— 这就是续接的全部意义 ✓
    struct Track: Equatable {
        var id: Int32
        var baseNorm: Point
        var baseAbs: Point
        var lastNorm: Point
        var lastAbs: Point
        var lastSeen: Double
        /// 掌缘轨迹:算位移(掌动了就是真滑 ✓),但**不计入手指数** ✗
        var isPalm: Bool
    }

    // MARK: - 账本

    public struct Tracker {
        public let policy: Policy

        // 一轮的账（见文件头的生命周期表）
        private var live: [Track] = []
        private var maxTracks = 0
        private var beganAt: Double = 0
        private var countedSince: Double = 0
        private var sawRealTouch = false
        private var active = false
        private var fired = false
        private var palmCount = 0
        private var maxSize: Float = 0
        private var maxMajorAxis: Float = 0
        private var statesSeen: Set<Int32> = []
        private var sawFrameGap = false
        private var firstLiftAt: Double = 0
        private var carried = 0
        private var maxNormMove: Float = 0
        private var maxAbsMove: Float = 0
        // 跨轮
        private var lastFrameAt: Double = 0

        public init(policy: Policy = .standard) { self.policy = policy }

        // MARK: 自愈 / 收口

        /// 账本撑开超过 `stuckLedgerAfter` ⇒ 整本作废。返回"卡了多久"（0 = 没卡 ⇒ 调用方不打日志）。
        ///
        /// 实锤（2026-09-20）：掌缘搭在板上打字 ⇒ 收口帧永远等不来 ⇒ 一条按压持续 **49 分钟**
        /// （`[5049394ms] 5 指(豁免掌 1) 2941951ms … size=4.6 → 不动作`）⇒ 之后所有触摸全被吸进同一条账本。
        public mutating func resetIfStuck(now: Double) -> Double {
            guard active, now - beganAt > policy.stuckLedgerAfter else { return 0 }
            let stale = now - beganAt
            clearRound()
            return stale
        }

        /// 一轮结束：清账（**"哪个字段活多久"的唯一出处**）
        public mutating func endRound() {
            clearRound()
            lastFrameAt = 0
        }

        private mutating func clearRound() {
            live.removeAll()
            maxTracks = 0
            beganAt = 0
            countedSince = 0
            sawRealTouch = false
            active = false
            fired = false
            palmCount = 0
            maxSize = 0
            maxMajorAxis = 0
            statesSeen.removeAll()
            sawFrameGap = false
            firstLiftAt = 0
            carried = 0
            maxNormMove = 0
            maxAbsMove = 0
            lastTouching = 0
        }

        // MARK: 喂帧

        /// 喂一帧。返回"此刻在板上的**真手指**数"（0 = 全部离开 ⇒ 调用方去判卷 ✓）
        public mutating func feed(_ frame: Frame) -> Int {
            let now = frame.time
            // ① 帧间隔（照 LumaRing：丢帧 ⇒ 位移不可信 ⇒ 这一轮直接拒）
            if active, lastFrameAt > 0, now - lastFrameAt > policy.maxFrameGap { sawFrameGap = true }
            lastFrameAt = now

            // ② 本帧触点：只认 state 1–4（5–7 = 离板）
            let seen = frame.contacts.filter { $0.state >= 1 && $0.state <= 4 }
            for c in seen { statesSeen.insert(c.state) }
            let palmTouching = seen.filter { isPalm($0) }.count
            let touching = seen.count - palmTouching

            // ③ 板上一点东西都没有（手指与掌都没有）⇒ 这一轮结束（账本**留着**，等调用方判卷 ✓）
            guard !seen.isEmpty else {
                active = false
                return 0
            }

            if !active {                                   // 轮起点：清上一轮的一切 ✓
                clearRound()
                active = true
                beganAt = now
            }

            // ④ 本帧认领轨迹（同 id 优先；否则在 carry 窗口内按最近点续接 ✓）
            // 先按序配对一次(只认同样未被同 id 认领的轨迹;见 carryAssignment 的病历 ✓)
            var claimed = Set<Int>()
            let carryMap = carryAssignment(for: seen, at: now, claimed: claimed)
            for c in seen {
                let palm = isPalm(c)
                // ⚠️ 2026-09-22 单测抓到:原来写成 `else if let (i, _) = carryTarget(...)` ——
                //   那个形式在"最佳目标正好是 `live[0]`"时会**落到 else**(新建轨迹)✗,
                //   于是每帧多出一条轨迹 ⇒ 三指拖拽被数成 5 指 ✗(量到:carried 每帧只 +2 而不是 +3)。
                //   ⇒ 改成显式三步,语义无歧义 ✓
                var idx: Int? = freeIndex(ofTrackWithID: c.id, claimed: claimed)
                if idx == nil, let ti = carryMap[c.id], !claimed.contains(ti) {
                    if live[ti].id != c.id { carried += 1 }         // 量尺:id 换过号 ✓
                    idx = ti
                }
                if idx == nil {
                    live.append(Track(id: c.id, baseNorm: c.normalized, baseAbs: c.absolute,
                                      lastNorm: c.normalized, lastAbs: c.absolute, lastSeen: now,
                                      isPalm: palm))
                    idx = live.count - 1
                }
                let i0 = idx!
                claimed.insert(i0)
                live[i0].id = c.id
                live[i0].lastNorm = c.normalized
                live[i0].lastAbs = c.absolute
                live[i0].lastSeen = now
                live[i0].isPalm = palm
                maxSize = max(maxSize, c.size)
                maxMajorAxis = max(maxMajorAxis, c.majorAxis)
                // ⑤ 位移：**从这条轨迹的起点算**（id 换号不影响 ✓ —— 这条就是那个拖拽 bug 的解药）
                let dn = dist(live[i0].baseNorm, c.normalized)
                let da = dist(live[i0].baseAbs, c.absolute)
                maxNormMove = max(maxNormMove, Float(dn))
                maxAbsMove = max(maxAbsMove, Float(da))
            }

            // ⑤b 剪枝:失联超过 carryWindow ⇒ 这条轨迹**不再算存活** ✓
            //   病例(2026-09-22 单测抓到):不剪枝时,任何一次续接失败都会**新建**一条,
            //   旧的那条还留在 `live` 里 ⇒ 三指拖拽被数成 **5 指** ✗ ⇒ 判成"不动作"(而不是滑动 ✗)
            live.removeAll { now - $0.lastSeen > policy.carryWindow }

            // ⑥ 抬手时刻（照 LumaRing 的 release 窗口）：本帧在板的手指比上帧少 ⇒ 有人抬手了
            if lastTouching > 0, touching < lastTouching, firstLiftAt == 0 { firstLiftAt = now }
            lastTouching = touching

            // ⑦ 真手指第一次落板 ⇒ 表从这一帧重掐（掌先落的不计时 —— 掌搭着打字时那段时间不该算进点按）
            if touching > 0, !sawRealTouch {
                sawRealTouch = true
                beganAt = now
                countedSince = 0
                maxTracks = 0
                for i in claimed {                           // 位移基线也重掐
                    live[i].baseNorm = live[i].lastNorm
                    live[i].baseAbs = live[i].lastAbs
                }
                maxNormMove = 0
                maxAbsMove = 0
            }
            // ⑧ 手指数变多 ⇒ 手势还没"落齐" ⇒ 重掐点按计时（见 maxDuration 那条病历）
            if touching > maxTracks {
                countedSince = now
                maxTracks = touching
            }
            palmCount = max(palmCount, palmTouching)
            return touching
        }

        /// 上一帧的真手指数（判"有人抬手"要跟它比 ✓）
        private var lastTouching = 0

        // MARK: 判卷

        public func judge(now: Double) -> Outcome {
            if fired { return .rejected("") }
            let snap = snapshot(now: now)
            guard snap.held >= policy.minDuration else { return .rejected("") }
            guard (snap.fingerCount == 3 || snap.fingerCount == 4), snap.held <= policy.maxDuration else {
                // 一指的普通点按：不进账（只在可能相关的局里留账，便于对账"漏在哪一档"）
                guard snap.fingerCount >= 2 || snap.palmCount > 0 else { return .rejected("") }
                let st = snap.statesSeen.map(String.init).joined(separator: "/")
                return .rejected(String(format: "%d 指(豁免掌 %d)[state %@]%.0fms 位移 norm=%.4f abs=%.1f size=%.1f major=%.1f → 不动作(只认 3/4 指,且落齐后 ≤%.0fms;整轮 %.0fms)",
                                        snap.fingerCount, snap.palmCount, st, snap.held * 1000,
                                        snap.normalizedMove, snap.absoluteMove, snap.maxSize, snap.maxMajorAxis,
                                        policy.maxDuration * 1000, snap.heldTotal * 1000))
            }
            if snap.sawFrameGap {
                return .rejected(String(format: "%d 指 帧间隔 >%.0fms(丢帧 ⇒ 位移不可信)⇒ 不动作",
                                        snap.fingerCount, policy.maxFrameGap * 1000))
            }
            if snap.releaseSpan > policy.maxReleaseSpan {
                return .rejected(String(format: "%d 指 抬手用了 %.0fms(>%.0fms)⇒ 不是点按",
                                        snap.fingerCount, snap.releaseSpan * 1000, policy.maxReleaseSpan * 1000))
            }
            if snap.normalizedMove > policy.maxMove { return .slide(norm: snap.normalizedMove) }
            if snap.held > policy.maxDuration {
                guard snap.fingerCount == 4, policy.pressHoldRange.contains(snap.held) else {
                    return .rejected(String(format: "%d 指 %.0fms(超出点按 %.0fms 且不在按住的 %.2f–%.2fs 窗口)⇒ 不动作",
                                            snap.fingerCount, snap.held * 1000, policy.maxDuration * 1000,
                                            policy.pressHoldRange.lowerBound, policy.pressHoldRange.upperBound))
                }
                return .fireFour(held: snap.held * 1000, norm: snap.normalizedMove, abs: snap.absoluteMove)
            }
            return snap.fingerCount == 4
                ? .fireFour(held: snap.held * 1000, norm: snap.normalizedMove, abs: snap.absoluteMove)
                : .fireThree(held: snap.held * 1000, norm: snap.normalizedMove, abs: snap.absoluteMove)
        }

        /// 标记"本轮已生效"（按压触发那条路用；抬手不再按点按重复计）
        public mutating func markFired() { fired = true }
        public var hasFired: Bool { fired }

        public func snapshot(now: Double) -> Snapshot {
            var s = Snapshot()
            s.fingerCount = max(maxTracks, live.filter { !$0.isPalm }.count)
            s.held = now - (countedSince > 0 ? countedSince : beganAt)
            s.heldTotal = now - beganAt
            s.normalizedMove = maxNormMove
            s.absoluteMove = maxAbsMove
            s.palmCount = palmCount
            s.maxSize = maxSize
            s.maxMajorAxis = maxMajorAxis
            s.statesSeen = statesSeen.sorted()
            s.sawFrameGap = sawFrameGap
            s.releaseSpan = firstLiftAt > 0 ? now - firstLiftAt : 0
            s.carriedContacts = carried
            return s
        }

        /// 仅供单测/诊断:当前存活轨迹摘要（`internal` ⇒ 不进公开 API ✓）
        var debugTracks: [(id: Int32, x: Double, lastSeen: Double, isPalm: Bool)] {
            live.map { ($0.id, $0.lastNorm.x, $0.lastSeen, $0.isPalm) }
        }

        // MARK: 内部

        private func isPalm(_ c: Contact) -> Bool {
            c.size >= policy.palmSize || c.majorAxis >= policy.palmMajorAxis
        }

        /// 同 id 的、且这一帧还没被别人认领的轨迹
        private func freeIndex(ofTrackWithID id: Int32, claimed: Set<Int>) -> Int? {
            live.indices.first { live[$0].id == id && !claimed.contains($0) }
        }

        /// 续接目标（**按序配对**，不是"最近邻"）。
        ///
        /// ⚠️ 2026-09-22 单测抓到:第一版写成"最近邻 + 并列取先"⇒ 在**并列距离**下会把整批触点**错位配对** ✗
        ///   实测量到(三指拖拽,每帧 id 全换):
        /// ```
        /// [claim] c=140@0.460 -> i=1(旧 id=131)   ← 本该配 i=0(旧 id=130)
        /// [claim] c=141@0.490 -> i=2(旧 id=132)
        /// [claim] c=142@0.520 -> 新建轨迹!        ← 多出幽灵轨迹
        /// ⇒ 三指拖拽被数成 5 指 ✗ ⇒ 判成"不动作"(而不是"滑动")
        /// ```
        /// 真机上新 id 是**按触点顺序**发的(日志:100/101/102 → 110/111/112 → 120… ✓)
        /// ⇒ 口径:剩下的触点与剩下的**未认领轨迹按 id 升序一一配对** ✓,并且只保留
        ///   "落点在 `carryRadius` 内"的那些配对 ✓ —— 距离只当**门禁**,不当排序依据 ✓
        private func carryAssignment(for contacts: [Contact], at now: Double,
                                     claimed: Set<Int>) -> [Int32: Int] {
            let trackIDs = live.indices
                .filter { !claimed.contains($0) && now - live[$0].lastSeen <= policy.carryWindow }
                .sorted { live[$0].id < live[$1].id }
            let sorted = contacts.sorted { $0.id < $1.id }
            var out: [Int32: Int] = [:]        // contact.id → live 下标
            for (c, ti) in zip(sorted, trackIDs) {
                let d = dist(live[ti].lastNorm, c.normalized)
                guard d <= policy.carryRadius else { continue }
                out[c.id] = ti
            }
            return out
        }

        private func dist(_ a: Point, _ b: Point) -> Double {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
    }
}
