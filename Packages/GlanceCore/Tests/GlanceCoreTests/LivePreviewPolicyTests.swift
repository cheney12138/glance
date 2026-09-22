import CoreGraphics
import Testing
@testable import GlanceCore

/// 每条对着一次真事故 / 一次实测数字(先写事故,再写断言 ✓)
@Suite("实时预览策略")
struct LivePreviewPolicyTests {
    let items: [(wid: UInt32, aspect: CGFloat)] = [(1, 1.6), (2, 1.6), (3, 1.6)]

    private func plan(now: Double = 100, selected: UInt32? = 1,
                      running: [UInt32: Int] = [:], pending: Set<UInt32> = [],
                      idleSince: [UInt32: Double] = [:], allowStart: Bool = true,
                      maxStreams: Int = 24, keepAlive: Double = 5) -> LivePreviewPolicy.Plan {
        LivePreviewPolicy.plan(now: now, items: items, selected: selected, running: running,
                               pending: pending, idleSince: idleSince, tierFps: 10, lowFps: 5,
                               maxStreams: maxStreams, keepAlive: keepAlive, allowStart: allowStart)
    }

    /// 实测:13 条流全按用户档位 = ~26% CPU ✗,而鼠标只看得到一张卡在动。
    /// 断言:选中那条用用户档位,其余一律 lowFps。
    @Test("分档:选中 = 用户档位,其余 = lowFps")
    func tiers() {
        let p = plan()
        #expect(p.start == [.init(wid: 1, fps: 10), .init(wid: 2, fps: 5), .init(wid: 3, fps: 5)])
    }

    /// 事故(S4):全跑用户档位 ⇒ CPU 26%。改成"档不对就重启那一条"(帧保留 ⇒ 不闪 ✓)。
    @Test("档不对 ⇒ 先停再按新档重建(帧保留)")
    func retierRestarts() {
        let p = plan(running: [1: 5, 2: 5, 3: 5])
        #expect(p.stop == [.init(wid: 1, reason: .retier(from: 5, to: 10))], "只有 1 号档不对")
        #expect(p.start == [.init(wid: 1, fps: 10)], "停掉之后必须按新档重建,不然选中那张就没画面了 ✗")
    }

    /// 事故:hover 到"没起过流的窗口"时,SCStream 创建压在 hover 那拍 ⇒ 丢 1 拍 ✗。
    /// 修法:起流挪出那一拍 ⇒ 但**停**必须立刻做 ✓
    @Test("allowStart=false 时只停不启(把起流挪出 hover 那一拍)")
    func deferredStartStillStops() {
        let p = plan(running: [1: 5], idleSince: [9: 0], allowStart: false)
        #expect(p.stop.contains(.init(wid: 1, reason: .retier(from: 5, to: 10))), "换档的停要立刻做 ✓")
        #expect(p.stop.contains { $0.wid == 9 }, "养够 5s 的也要立刻回收 ✓")
        #expect(p.start.isEmpty, "这一轮不起流 ✓")
    }

    /// 事故类:换组之后旧的那几条流**还在跑**(keepAlive=5s,为了换回来是热的 ✓)。
    /// 断言:刚离开环 ⇒ 只**记闲置**、不停;养够 5s 才停。
    @Test("离开环:先记闲置,养够 keepAlive 才停")
    func keepAliveThenStop() {
        let justLeft = plan(running: [7: 5], idleSince: [:])
        #expect(justLeft.markIdle == [7], "要记下'从这一刻起闲置' ✓")
        #expect(justLeft.stop.isEmpty, "刚离开就停 ⇒ 换回来要重新起流(冷)✗")

        let tooLong = plan(now: 100, running: [7: 5], idleSince: [7: 94])   // 养了 6s
        #expect(tooLong.stop == [.init(wid: 7, reason: .idleOutside(seconds: 6))])
        #expect(!tooLong.start.contains { $0.wid == 7 }, "它已经不在名单里 ⇒ 被回收后不该被重新起 ✓")
        #expect(tooLong.start.map(\.wid) == [1, 2, 3], "名单里的这三张照常起 ✓")
    }

    /// 事故:用户 hover 扫过 5 个 app 后停手 ⇒ 若只在 sync 里扫,那几条流会一直出帧 ✗
    @Test("定时清扫不等下一次 sync")
    func sweepReclaims() {
        let s = LivePreviewPolicy.sweepPlan(now: 100, running: [7: 5], idleSince: [7: 90], keepAlive: 5)
        #expect(s == [.init(wid: 7, reason: .idleSwept(seconds: 10))])
        #expect(LivePreviewPolicy.sweepPlan(now: 100, running: [7: 5], idleSince: [7: 99], keepAlive: 5).isEmpty)
    }

    /// 上限只是**防呆**(不是节流阀):超出的既不参与起流,也不被换档 ✗
    @Test("超过 maxStreams 的不参与起流")
    func maxStreamsCaps() {
        let p = plan(maxStreams: 2)
        #expect(p.start.map(\.wid) == [1, 2])
        #expect(!p.stop.contains { $0.wid == 3 }, "3 号只是没被起,不该被当成'换档'去停 ✗")
    }

    /// 已经在跑、档也对 ⇒ 什么都不做(同组里换窗口/重复调用都不许碰流 ✓)
    @Test("已经正确在跑的不动它")
    func steadyStateIsQuiet() {
        let p = plan(running: [1: 10, 2: 5, 3: 5])
        #expect(p.stop.isEmpty && p.start.isEmpty && p.markIdle.isEmpty)
    }

    /// 在排队的窗口不许重复起(一扇窗一条流 ✓ ADR-0007)
    @Test("正在排队的不重复起")
    func pendingIsNotRestarted() {
        #expect(plan(pending: [2]).start.map(\.wid) == [1, 3])
    }
}
