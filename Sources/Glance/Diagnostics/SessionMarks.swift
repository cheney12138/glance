import Foundation

/// 一局切换器的**打卡器**:按时间轴记下每个环节,结算时把超过一帧的那几步自己喊出来。
///
/// ## 为什么需要它
/// `traceCost` 只能量**一段**代码(还得事先知道该量哪儿);而"掉帧"这类疑难最要命的正是
/// **不知道是哪一段** ✗。打卡器反过来:先把一局的每个环节都记下时间,让账自己浮出来 ——
/// 不预设嫌疑 ✓。
///
/// 形状取自 AltTab 的 `src/debug/MainThreadStall.swift`(阈值同样 16.0ms 起):
/// 扁平的步骤序列、不是树;`step()` 关掉上一步、打开新的一步;结束时把最长的几步打出来。
/// 差别:他们靠 run-loop observer 在空闲前收步(免得把"等"算成一个巨大的步);
/// 我们的环节都在**同一条同步链**上(按键 → 枚举 → 落点 → 开窗 → 首帧),
/// "等"与"帧"由 `FrameProbe` 的帧账单独负责,所以这里不做 observer。
///
/// ## 成本与开关
/// 每步一次 `CFAbsoluteTimeGetCurrent`(约 30ns)× 5 步 —— 常开也无所谓;
/// 但只在**一局之内**记账(所以要先 `begin`)。
/// trace 全开时把整条时间轴打一行;平时**只在有环节超过 16.7ms 时**打一行 ——
/// 守住 `docs/debugging.md` §12 那条"一次唤起 ≤ 2 行"的日志预算。
enum SessionMarks {
    private static var label = ""
    private static var t0: CFAbsoluteTime = 0
    private static var last: CFAbsoluteTime = 0
    private static var steps: [(String, Double)] = []   // (环节, 距上一环节的 ms)
    /// 本局第一张缩略图送达的时刻(相对 t0),trace 模式下单独记一行 ——
    /// "首图什么时候到"是"外接屏窗口多就掉帧"这条线索的直接证人(见 `noteFirstThumb`)
    private static var firstThumbAt: Double?

    static func begin(_ label: String) {
        self.label = label
        t0 = CFAbsoluteTimeGetCurrent()
        last = t0
        steps.removeAll(keepingCapacity: true)
        firstThumbAt = nil
    }

    static func step(_ name: String) {
        guard t0 > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        steps.append((name, (now - last) * 1000))
        last = now
    }

    /// 本局第一张缩略图上屏的时刻。只在 trace 下记(平时不占日志额度)
    static func noteFirstThumb(_ count: Int) {
        guard t0 > 0, firstThumbAt == nil else { return }
        firstThumbAt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if isTraceEnabled {
            glog(String(format: "[打卡] 首图上屏 +%.0fms(本批 %d 张)", firstThumbAt!, count))
        }
    }

    static func finish() {
        guard t0 > 0 else { return }
        let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        defer { t0 = 0 }
        if isTraceEnabled {
            let axis = steps.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: " · ")
            glog(String(format: "[打卡] %@ 共 %.1fms | %@", label, total, axis))
        } else {
            let slow = steps.filter { $0.1 > 16.7 }
            guard !slow.isEmpty else { return }   // 没超就一行都不打(日志预算)
            let s = slow.map { String(format: "%@ %.1fms", $0.0, $0.1) }.joined(separator: " · ")
            glog(String(format: "[打卡] %@ 共 %.1fms,超一帧:%@", label, total, s))
        }
    }
}
