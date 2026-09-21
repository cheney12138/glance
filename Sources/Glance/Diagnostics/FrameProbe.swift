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
    /// 本轮探针开跑时的进程时刻(ms)—— 长帧直方图的事件对时锚点
    private var startUptimeMs: Double = 0

    private var enabled: Bool { isTraceEnabled }

    func start(on view: NSView, label: String) {
        guard enabled, link == nil, #available(macOS 14.0, *) else { return }
        self.label = label
        startUptimeMs = glanceUptimeMs()
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
        // **长帧落在进程时间的哪些秒**(2026-09-19 改直方图):只报"有几帧"没法判断它是不是
        // 落在入场那 0.2s 里、还是均匀铺在整个滚动期 —— 前者是开场布局的账,后者是滚动路径
        // 的账。按秒聚堆,并给出探针起点的进程时刻(glanceUptimeMs 口径),可与
        // `[保温]` / `[T5]` 等事件流水逐秒对时
        var elapsed: TimeInterval = 0
        var bySecond: [Int: (count: Int, worst: Double)] = [:]
        for interval in intervals {
            if interval > longFrame {
                let sec = Int(elapsed)
                let old = bySecond[sec] ?? (0, 0)
                bySecond[sec] = (old.count + 1, max(old.worst, interval * 1000))
            }
            elapsed += interval
        }
        let where_ = bySecond.isEmpty ? "" : " @" + bySecond.sorted { $0.key < $1.key }
            .map { pair -> String in
                String(format: "%d-%ds×%d(max %.0fms)", pair.key, pair.key + 1, pair.value.count, pair.value.worst)
            }
            .joined(separator: " ")
        // 判定基准非 60Hz 时标出来 —— 否则读日志的人会拿 25ms 的口径去理解 120Hz 屏的数据
        let judge = fps == 60 ? "" : String(format: " [按 %.0fHz 判定:>%.1fms]", fps, longFrame * 1000)
        print(String(format: "[帧] %@ 共 %d 帧 | P50 %.1fms · P95 %.1fms · max %.1fms | 长帧 %d(%.0f%%) %@| 探针起点=%.0fms%@",
                     label, sorted.count, pick(0.5), pick(0.95), (sorted.last ?? 0) * 1000,
                     long, Double(long) / Double(sorted.count) * 100, where_, startUptimeMs, judge))
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

// MARK: - 120Hz 调查:A/B 对比(临时诊断,2026-09-21)

/// **同一个 App、同一块屏**,只差"窗口是谁":
///   A. 我们面板(NSHostingView,SwiftUI)
///   B. 同一 App 里临时开的一扇普通 NSView 窗口(同样的 borderless+nonactivating+.popUpMenu 配置)
/// 背景(实验结论,见对话记录):同样的窗口配置在**独立测试 App** 里能拿到 **120Hz** ✓,
///   而我们面板的 display link 只有 **60Hz** ✗ ⇒ 差别在本 App 内部 ⇒ 这个 A/B 用来定性:
///   · A=60,B=120 ⇒ 问题在"面板这扇窗 / 这个视图" ✓;
///   · A=60,B=60  ⇒ 问题是 **App 级**的(某个全局设置 / 某个东西压着帧率)✓。
@MainActor
final class HzCompare {
    static let shared = HzCompare()
    private var window: NSWindow?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var a: [Double] = []      // A:面板
    private var b: [Double] = []      // B:临时普通窗口
    private var started = false

    /// 只在调试键打开时做一次:`defaults write com.cheney12138.macswitcher debug.hzProbe -bool true`
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.hzProbe") }

    /// 面板上屏后调一次。`panelView` = 面板的内容视图(hosting view)
    func run(panelView: NSView) {
        guard Self.enabled, !started, #available(macOS 14.0, *) else { return }
        started = true
        let screen = panelView.window?.screen ?? NSScreen.main
        glog("[Hz] A/B 开始:面板屏 maxFps=\(screen?.maximumFramesPerSecond ?? -1)"
             + " 本地化名=\(screen?.localizedName ?? "?") 共 \(NSScreen.screens.count) 块屏")

        // A:面板自己的 display link
        let la = panelView.displayLink(target: self, selector: #selector(tickA(_:)))
        la.add(to: .main, forMode: .common)
        aLink = la

        // B:同 App 里临时开一扇"普通 NSView"窗口(配置与面板一致)
        let r = NSRect(x: (screen?.frame.minX ?? 0) + 80, y: (screen?.frame.minY ?? 0) + 80,
                       width: 420, height: 300)
        let w = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .popUpMenu
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        let lb = v.displayLink(target: self, selector: #selector(tickB(_:)))
        lb.add(to: .main, forMode: .common)
        bLink = lb

        // 1.6s 后收摊 + 打印
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.report() }
    }

    private var aLink: CADisplayLink?
    private var bLink: CADisplayLink?

    @objc private func tickA(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { a.append((now - last) * 1000) }
        last = now
    }
    @objc private func tickB(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if bLast > 0 { b.append((now - bLast) * 1000) }
        bLast = now
    }
    private var bLast: CFTimeInterval = 0

    private func report() {
        aLink?.invalidate(); bLink?.invalidate()
        aLink = nil; bLink = nil
        window?.orderOut(nil); window = nil
        func s(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "无回调" }
            let x = v.sorted(); let p50 = x[x.count / 2]
            return String(format: "n=%d P50 %.1fms(≈%.0fHz) min %.1f max %.1f",
                          x.count, p50, p50 > 0 ? 1000 / p50 : 0, x.first!, x.last!)
        }
        glog("[Hz] A 面板(hostingView): \(s(a))")
        glog("[Hz] B 同 App 普通 NSView 窗: \(s(b))")
        glog("[Hz] 结论: \(a.isEmpty || b.isEmpty ? "样本不足" : "见上两行")")
    }
}
