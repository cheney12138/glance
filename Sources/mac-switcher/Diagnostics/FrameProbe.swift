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

    /// 一帧 16.7ms;超过 1.5 帧算一次"长帧"
    private let longFrame: Double = 1.5 / 60.0
    private var link: CADisplayLink?
    private var intervals: [Double] = []
    private var last: CFTimeInterval = 0
    private var label = ""

    private var enabled: Bool { ProcessInfo.processInfo.environment["GLANCE_TRACE"] == "1" }

    func start(on view: NSView, label: String) {
        guard enabled, link == nil, #available(macOS 14.0, *) else { return }
        self.label = label
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
        print(String(format: "[帧] %@ 共 %d 帧 | P50 %.1fms · P95 %.1fms · max %.1fms | 长帧 %d(%.0f%%)",
                     label, sorted.count, pick(0.5), pick(0.95), (sorted.last ?? 0) * 1000,
                     long, Double(long) / Double(sorted.count) * 100))
        intervals.removeAll()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last > 0 else { return }
        intervals.append(now - last)
    }
}
