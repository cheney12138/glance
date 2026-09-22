import Foundation

/// **实时预览该跑哪些流、各几 fps、什么时候停** —— 这套*策略*原先长在
/// `LivePreviewPool.reconcile` 里(混着 SCStream 的创建/停止、串行队列、错峰定时器)✗
/// ⇒ 抽成纯函数:入参是账本快照,出参是"该做什么",**执行**留给池 ✓
///
/// 为什么值得抽(不是为好看):
///   · 今天两个 bug 都出在这段策略上 —— ① 给看不见的卡派帧 ② 换环门禁只挡一边;
///     它们都不是"SCStream 用错了",而是**判断写漏了**,而判断没法单测(它长在类里)✗
///   · 分档/回收/上限这些数改一次,现在要在一段 60 行的命令式代码里找位置 ✗
///
/// 规矩:这里**只做决定**,不读时间(now 由调用方给)、不碰系统(不建流)、不写日志 ✓
public enum LivePreviewPolicy {

    /// 为什么要停(字符串与日志里原来的说法逐字一致 —— 那些文案有诊断价值 ✓)
    public enum StopReason: Equatable, Sendable {
        /// 已经不在当前这一组里了,养了 keepAlive 秒
        case idleOutside(seconds: Int)
        /// 定时清扫时确认超时
        case idleSwept(seconds: Int)
        /// 换档(选中 ⇄ 非选中):停掉后用新档重建(帧保留 ⇒ 不闪 ✓)
        case retier(from: Int, to: Int)

        public var logText: String {
            switch self {
            case let .idleOutside(s): return "已不在环内 \(s)s"
            case let .idleSwept(s):   return "闲置 \(s)s"
            case let .retier(f, t):   return "换档 \(f)->\(t)fps"
            }
        }
    }

    public struct StopRequest: Equatable, Sendable {
        public var wid: UInt32
        public var reason: StopReason
    }

    public struct StartRequest: Equatable, Sendable {
        public var wid: UInt32
        public var fps: Int
    }

    /// 一次决策的全部结果。**顺序即语义**:先 `markIdle` ⇒ 再 `stop` ⇒ 最后按数组顺序起 `start` ✓
    public struct Plan: Equatable, Sendable {
        /// ① 刚离开环的窗口:记下"从这一刻起闲置"(不立刻停 —— 见 keepAlive)
        public var markIdle: [UInt32] = []
        /// ②③ 要停的(含换档时的"先停")
        public var stop: [StopRequest] = []
        /// ④ 要起的(数组顺序 = 错峰顺序 ✓)
        public var start: [StartRequest] = []
        public init() {}
    }

    /// - Parameters:
    ///   - items: 当前界面上**该活的窗口**(顺序有意义:托盘从左到右 ✓)
    ///   - selected: 正在 hover 的那扇窗(它用用户档位,其余用 lowFps ✓)
    ///   - allowStart: `false` = **这一轮只停不启**。用于把"起流"挪出 hover 那一拍
    ///     (SCStream 创建是系统级重活 ⇒ 压在 hover 上会丢 1 拍 ✗;见 `LivePreviewPool.sync` 头注)
    public static func plan(now: Double,
                            items: [(wid: UInt32, aspect: CGFloat)],
                            selected: UInt32?,
                            running: [UInt32: Int],
                            pending: Set<UInt32>,
                            idleSince: [UInt32: Double],
                            tierFps: Int,
                            lowFps: Int,
                            maxStreams: Int,
                            keepAlive: Double,
                            allowStart: Bool,
                            swept: Bool = false) -> Plan {
        var out = Plan()

        // ① 记闲置时间:有流、但已不在"该活"名单里 ⇒ 从这一刻起算养着(为了换回来是热的 ✓)
        for wid in running.keys where !items.contains(where: { $0.wid == wid }) {
            if idleSince[wid] == nil { out.markIdle.append(wid) }
        }
        let idleAfter = idleSince.merging(out.markIdle.map { ($0, now) }) { _, new in new }

        // ② 停:养够 keepAlive 就回收。**局内不做上限淘汰** —— 上限只为防呆,不是节流阀 ✗
        for (wid, since) in idleAfter.sorted(by: { $0.key < $1.key }) where now - since > keepAlive {
            out.stop.append(StopRequest(wid: wid, reason: swept ? .idleSwept(seconds: Int(now - since))
                                                                : .idleOutside(seconds: Int(now - since))))
        }

        // ③ 换档:选中 = 用户档位,其余 = lowFps。档不对 ⇒ 停(下面 ④ 会用新档重建 ⇒ 帧保留不闪 ✓)
        //    超过上限的那些**不进名单**:它们不参与起流,也不该被换档
        let live = items.prefix(maxStreams)
        for item in live {
            guard let have = running[item.wid] else { continue }
            let want = (item.wid == selected) ? tierFps : lowFps
            if have != want {
                out.stop.append(StopRequest(wid: item.wid, reason: .retier(from: have, to: want)))
            }
        }
        // ⚠️ ④ 里必须把"刚因换档被停掉"的窗口当成**没在跑**(池里 `stopStream` 真会摘掉 handle ⇒
        //    建流循环看见 `handles[wid] == nil` 就按新档重建 ✓)。
        //    第一版漏了这一步 ⇒ 选中那张换档后就**没有画面**了(单测当场抓住 ✓)。
        //    ⚠️ 只当"换档"这一类:被回收(闲置)的那些本来就不在名单里,不该被重新起 ✗
        let retiring = Set(out.stop.map(\.wid)).intersection(live.map(\.wid))
        guard allowStart else { return out }
        for item in live where (running[item.wid] == nil || retiring.contains(item.wid))
            && !pending.contains(item.wid) {
            out.start.append(StartRequest(wid: item.wid,
                                          fps: item.wid == selected ? tierFps : lowFps))
        }
        return out
    }

    /// 定时清扫(不等下一次 sync):只有"超时回收"这一件事 ✓
    public static func sweepPlan(now: Double, running: [UInt32: Int],
                                 idleSince: [UInt32: Double], keepAlive: Double) -> [StopRequest] {
        idleSince.filter { running[$0.key] != nil && now - $0.value > keepAlive }
            .sorted { $0.key < $1.key }
            .map { StopRequest(wid: $0.key, reason: .idleSwept(seconds: Int(now - $0.value))) }
    }
}
