import Foundation

/// **帧预算是多少** —— 长帧阈值的算法(纯函数,可单测)。
///
/// 为什么需要它(2026-09-22 实测翻车):
///   阈值原来是 `1.5 / 屏幕标称刷新率` ⇒ 接外接屏时,内建 120Hz 那块屏仍标称 120,
///   而 App 实际只拿到 60Hz 的节拍(见 §18"已知环境项")⇒ 每一帧 16.7ms 都 > 12.5ms 阈值
///   ⇒ 汇总打出「**长帧 661(99%)**」✗ —— 量尺本身在说谎,而且说得很响 ✗
///
/// 口径:节拍要**量出来**,不能听屏幕的标称 ✓
///   · 不取平均值:长帧会把平均值抬高 ⇒ 阈值跟着涨 ⇒ 越长越不算长(自欺 ✗)
///   · 不取最小值:偶发"一拍回调两次"(8.3ms)会把节拍算成一半 ⇒ 反过来天天报长帧 ✗
///   · 取**低分位**(默认 20%):既不被长帧抬高,也不被偶发快帧带跑 ✓
public enum FrameBudgetPolicy {

    /// 采样窗口:最近这么多帧里估节拍(60Hz 下约 4 秒 ✓ 够稳,又跟得上改刷新率)
    public static let window = 240
    /// 估节拍的百分位(0.2 = 第 20 百分位)
    public static let percentile = 0.2
    /// 样本太少时不敢猜 ⇒ 回落到屏幕标称(冷启动那几帧的事 ✓)
    public static let minSamples = 8

    /// 实测节拍(秒)。样本不足 ⇒ 用标称。
    public static func cadence(intervals: [Double], nominalFps: Double) -> Double {
        let nominal = nominalFps > 1 ? 1.0 / nominalFps : 1.0 / 60
        let recent = Array(intervals.suffix(window)).filter { $0 > 0 }.sorted()
        guard recent.count >= minSamples else { return nominal }
        let idx = min(recent.count - 1, Int(Double(recent.count) * percentile))
        return recent[idx]
    }

    /// 长帧阈值 = 1.5 × 实测节拍(60Hz → 25ms;真 120Hz → 12.5ms ✓)
    public static func longFrameThreshold(intervals: [Double], nominalFps: Double) -> Double {
        cadence(intervals: intervals, nominalFps: nominalFps) * 1.5
    }
}
