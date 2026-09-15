import AppKit
import QuartzCore

/// 帧间隔探针 —— 只在 `GLANCE_TRACE=1` 时挂上。
///
/// 为什么需要它:输入管线的毛病全在毫秒级,肉眼只能说出"有点掉帧";
/// 有 P50/P95/max + 长帧占比,才能分清两件完全不同的事:
///   · **每帧都慢**(P50 就 >16.7ms)→ 渲染/合成重(玻璃、阴影、全屏重绘)
///   · **偶发长帧**(P50 正常、max 大)→ 某一次回调里干了重活(枚举、截图、改窗框)
/// 这两种病的药方相反,先量再治。
final class FrameProbe: NSObject {
    static let shared = FrameProbe()

    /// 判定用的刷新率。**原来写死 60Hz(1.5/60 = 25ms)** ——
    /// 2026-09-15 用户问"跟我外接显示器刷新率有关系吗",顺势发现:在 120Hz 屏(如 ProMotion 的 XDR)上,
    /// 12–25ms 的卡顿会被这阈值**漏掉** ✗。改成按面板所在屏的实际刷新率判定:
    /// 60Hz → 25ms 算长帧;120Hz → 12.5ms 就算。
    private var fps: Double = 60
    private var longFrame: Double { 1.5 / fps }
    private var link: CADisplayLink?
    private var intervals: [Double] = []
    private var last: CFTimeInterval = 0
    private var label = ""

    private var enabled: Bool { isTraceEnabled }

    func start(on view: NSView, label: String) {
        guard enabled, link == nil, #available(macOS 14.0, *) else { return }
        self.label = label
        // 面板在哪块屏上,就按哪块屏的节拍判定(`maximumFramesPerSecond`,macOS 12+)
        fps = Double((view.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
        last = 0
        intervals.removeAll(keepingCapacity: true)
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// 面板退场时收工,直接打一行结论(不给"跑完还得自己翻日志"的负担)
    func stop() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        guard enabled, intervals.count > 5 else { intervals.removeAll(); return }
        let sorted = intervals.sorted()
        let pick = { (q: Double) -> Double in
            sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] * 1000
        }
        let long = intervals.filter { $0 > longFrame }.count
        // **抖动**(2026-09-15 加):`长帧` 只回答"有没有打到一帧",分不清两种完全不同的观感 ——
        //   · 稳定 16.7ms(在高刷屏上"没打到 8.3ms",但节奏均匀 → 看着顺 ✓)
        //   · 忽 8.3 忽 16.7(judder → 肉眼明显抖 ✗)
        // 用户看到的"抖"永远是后者,所以补一个"偏离中位的幅度"(P90),单位 ms。
        let medv = sorted[sorted.count / 2]
        let jitter = intervals.map { abs($0 - medv) }.sorted()[min(Int(Double(intervals.count) * 0.9), intervals.count - 1)] * 1000
        // **长帧发生在什么时候**:只报"有几帧"没法判断它是不是落在入场那 0.2s 里。
        // 偏移量从本轮第一帧算起,最多列 5 个(够看出是否聚集在开头)
        var elapsed: TimeInterval = 0
        var marks: [String] = []
        for interval in intervals {
            if interval > longFrame, marks.count < 5 { marks.append(String(format: "%.2fs", elapsed)) }
            elapsed += interval
        }
        let where_ = marks.isEmpty ? "" : " @" + marks.joined(separator: ",")
        // 判定基准非 60Hz 时标出来 —— 否则读日志的人会拿 25ms 的口径去理解 120Hz 屏的数据
        let judge = fps == 60 ? "" : String(format: " [按 %.0fHz 判定:>%.1fms]", fps, longFrame * 1000)
        print(String(format: "[帧] %@ 共 %d 帧 | P50 %.1fms · P95 %.1fms · max %.1fms | 长帧 %d(%.0f%%)%@%@",
                     label, sorted.count, pick(0.5), pick(0.95), (sorted.last ?? 0) * 1000,
                     long, Double(long) / Double(sorted.count) * 100, where_, judge))
        if jitter > 1.5 { print(String(format: "[帧]   ↳节奏抖动 ±%.1fms(P90,中位 %.1fms)—— 均匀的慢看不出,忽快忽慢才是肉眼里的卡", jitter, medv * 1000)) }
        intervals.removeAll()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last > 0 else { return }
        intervals.append(now - last)
    }
}
