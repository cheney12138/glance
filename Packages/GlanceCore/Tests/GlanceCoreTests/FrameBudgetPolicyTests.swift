import Testing
@testable import GlanceCore

/// 每条对着一次实测:阈值算错,量尺就会说谎(而且说得很响 ✗)
@Suite("帧预算(长帧阈值)")
struct FrameBudgetPolicyTests {

    /// 实测翻车:内建 120Hz 标称 + 外接屏在场 ⇒ App 实际只有 60Hz 节拍,
    /// 老阈值(1.5/120 = 12.5ms)把所有 16.7ms 的帧都算成长帧 ⇒ 报「长帧 661(99%)」✗
    @Test("标称 120Hz 但实测 60Hz 节拍:不许把 16.7ms 当长帧")
    func nominalLiesWhenPanelPinnedTo60() {
        let sixty = Array(repeating: 1.0 / 60, count: 120)
        let t = FrameBudgetPolicy.longFrameThreshold(intervals: sixty, nominalFps: 120)
        #expect(abs(t - 0.025) < 0.001, "阈值应当跟着**实测**走(≈25ms),不是标称的 12.5ms")
        #expect(!(1.0 / 60 > t), "16.7ms 不该算长帧 ✓")
    }

    /// 真 120Hz(外接屏拔掉时能拿到 8.3ms):阈值收紧到 12.5ms ⇒ 16.7ms 就该报 ✗
    @Test("真 120Hz 节拍:阈值收紧")
    func true120Hz() {
        let hundredTwenty = Array(repeating: 1.0 / 120, count: 120)
        let t = FrameBudgetPolicy.longFrameThreshold(intervals: hundredTwenty, nominalFps: 120)
        #expect(t > 0.012 && t < 0.013, "1.5 × 8.3ms ≈ 12.5ms")
        #expect(1.0 / 60 > t, "同一帧在 120Hz 上确实算长帧 ✓")
    }

    /// 不取平均:一局长帧多的话,平均值会被抬高 ⇒ 越长越不算长(自欺 ✗)
    @Test("长帧本身不许把阈值抬高")
    func longFramesDoNotRaiseTheBar() {
        var mixed = Array(repeating: 1.0 / 60, count: 100)
        mixed += Array(repeating: 0.05, count: 20)          // 20 条 50ms 的长帧
        let t = FrameBudgetPolicy.longFrameThreshold(intervals: mixed, nominalFps: 60)
        #expect(abs(t - 0.025) < 0.002, "阈值仍该是 25ms(低分位不被长帧带跑 ✓)")
        #expect(0.05 > t, "50ms 那几帧照样算长帧 ✓")
    }

    /// 也不取最小值:偶发一次"一拍回调两次"(8.3ms)不该把节拍算成一半 ⇒ 否则天天报长帧 ✗
    @Test("偶发的快帧不许把节拍带跑")
    func strayFastFrameDoesNotHalveCadence() {
        var v = Array(repeating: 1.0 / 60, count: 100)
        v.append(1.0 / 120)                                  // 一次偶发快帧
        let c = FrameBudgetPolicy.cadence(intervals: v, nominalFps: 60)
        #expect(c > 0.015, "节拍仍认 16.7ms,不是 8.3ms")
    }

    /// 冷启动只有几帧 ⇒ 不敢猜,回落到标称 ✓
    @Test("样本太少时回落到标称")
    func fallsBackWhenCold() {
        let t = FrameBudgetPolicy.longFrameThreshold(intervals: [0.0167, 0.0167], nominalFps: 60)
        #expect(abs(t - 0.025) < 0.001)
    }
}
