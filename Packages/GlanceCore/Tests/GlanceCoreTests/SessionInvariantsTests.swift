import CoreGraphics
import Testing
@testable import GlanceCore

/// 每一条都对着一次**真实事故**(写测试时先写下事故,再写断言 ✓)
@Suite("一局的不变量")
struct SessionInvariantsTests {

    /// 事故:换环时窗框宽度 634 ↔ 1509 当拍跳变 ⇒ 环居中 + 两套动画 ⇒ 用户看到"抖"。
    /// 断言:一局内**宽度**变了就是违反(哪怕只差 1pt)。
    @Test("窗框尺寸在一局内不许变")
    func frameSizeIsSessionInvariant() {
        let baseline = SessionSnapshot(frameSize: CGSize(width: 1383.9, height: 374.4), ringWindowWidth: 1509)
        let same = SessionSnapshot(frameSize: CGSize(width: 1383.9 + 0.3, height: 374.4), ringWindowWidth: 1509)
        #expect(SessionInvariants.violations(baseline: baseline, now: same).isEmpty, "0.3pt 在容差内(浮点累加)")

        // 第一次冒烟实测的噪声:0.6pt(内容取整)⇒ 不许报警 ✓
        let noise = SessionSnapshot(frameSize: CGSize(width: 1258.9, height: 374.4), ringWindowWidth: 1509)
        let base2 = SessionSnapshot(frameSize: CGSize(width: 1259.0, height: 375.0), ringWindowWidth: 1509)
        #expect(SessionInvariants.violations(baseline: base2, now: noise).isEmpty, "0.6pt 是取整噪声,不是违反")

        let changed = SessionSnapshot(frameSize: CGSize(width: 1509, height: 374.4), ringWindowWidth: 1509)
        let v = SessionInvariants.violations(baseline: baseline, now: changed)
        #expect(v == [.frameSizeChanged(from: baseline.frameSize, to: changed.frameSize)])
    }

    /// 事故:环窗口宽度曾经"每拍重算"⇒ 内容宽度一变,窗框跟着变 ⇒ 抖。
    /// 断言:宽度变了 = 违反;而且**只报这一条**(尺寸没变的那些不许跟着报)。
    @Test("环窗口宽度是一局的不变量(两环更宽者)")
    func ringWindowWidthIsSessionInvariant() {
        let baseline = SessionSnapshot(frameSize: CGSize(width: 1383.9, height: 374.4), ringWindowWidth: 1509)
        let now = SessionSnapshot(frameSize: CGSize(width: 1383.9, height: 374.4), ringWindowWidth: 634)
        #expect(SessionInvariants.violations(baseline: baseline, now: now) == [.ringWindowWidthChanged(from: 1509, to: 634)])
    }

    /// 有意不检查的东西:**位置**允许变(ADR-0014 已裁定"保留形状、接受位移")✓
    @Test("位置不属于不变量(它本来就允许动)")
    func originIsNotAnInvariant() {
        let a = SessionSnapshot(frameSize: CGSize(width: 100, height: 50), ringWindowWidth: 200)
        let b = SessionSnapshot(frameSize: CGSize(width: 100, height: 50), ringWindowWidth: 200)
        #expect(SessionInvariants.violations(baseline: a, now: b).isEmpty)
    }

    /// 事故:给**看不见的卡**也派了帧(白帧)⇒ 掉帧。
    /// 断言:有流在跑但不在"该跑"名单里 ⇒ 报出来;被 keepAlive 豁免的不算。
    @Test("在跑的流必须在「该跑」的名单里(keepAlive 豁免)")
    func streamMustBeWanted() {
        let v = SessionInvariants.streamViolations(running: [7, 9, 11], wanted: [9, 13], keepAlive: [11])
        #expect(v == [.streamOutsideWanted(windowID: 7)], "9 该跑 ✓、11 被豁免 ✓、只有 7 是白帧 ✗")

        #expect(SessionInvariants.streamViolations(running: [9], wanted: [9]).isEmpty)
    }

    /// 事故类:账本写坏(ADR-0007 原子操作 ⇒ 一扇窗一条流)
    @Test("同一扇窗不许有两条流")
    func noDuplicateStreams() {
        #expect(SessionInvariants.duplicateStreams([3, 5, 3, 7, 5, 5]) == [3, 5])
        #expect(SessionInvariants.duplicateStreams([1, 2, 3]).isEmpty)
    }
}
