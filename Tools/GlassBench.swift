// GlassBench —— 玻璃"量具台":一块可控背景 + 三个量尺。
//
//   swift Tools/GlassBench.swift bg      [秒=20]                 # 起一块白底(带大字与色块),N 秒后自动退
//   swift Tools/GlassBench.swift sample  <png> x y w h [步长=1]   # 一块区域的平均色/L
//   swift Tools/GlassBench.swift profile <png> y x0 x1            # 横穿一条水平线的亮度剖面
//   swift Tools/GlassBench.swift compare <pngA> <pngB> <y0> <y1> <x0> <x1>   # 两图同一区域对比
//
// 为什么需要它(2026-10-08,用户:「玻璃还是没有 macOS 原生的自然, 背景是白色的时候可见性差一点」):
//   玻璃这件东西,**只能拿数说话** —— 同一块玻璃压在暗底上 L≈0.46、压在白底上 L≈0.96,
//   凭肉眼在"自己的壁纸"上看永远争不出结论。而这套东西需要的其实就三样:
//     ① 一块**确定的**背景(白/黑/带字,而不是随机壁纸)⇒ `bg`
//     ② 一个**两点反解**(同一材质在两种底色上各得多少)⇒ 解出 基色 与 不透明度 ✓
//     ③ 一条**边缘剖面**(背景 → 边缘 → 内部),与 macOS 原生 ⌘Tab 的同口径对比 ✓
//
// 实测得到的两组数(存这里,免得下次重量):
//   原生: 0.27→0.45 · 0.941→0.909 ⇒ 基色 L≈0.84 · α≈0.32
//   我们: 0.227→0.462 · 1.000→0.961 ⇒ 基色 L≈0.89 · α≈0.355  ⇒ 差"偏亮 0.011" ✓
//   ⇒ 浅色补一道灰纱 α=0.04 后:白底 0.952(原生应得 0.949)✓ 见 PanelColors.glassVeil
//
// ⚠️ 用法要点(踩过的):
//   · 白底窗口必须 `level = .floating` —— 用 `.normal` 会被前台终端盖住(量到的全是终端)✗
//   · 抓图用 `screencapture -x -R"x,y,w,h"`,坐标是**点**、**左上原点**;
//     面板玻璃 = 面板**窗口**内收 `PanelMetrics.shadowPadStrip`(=108pt)✓
//   · 玻璃上缘那条空带很窄(图标之上 ~20pt)⇒ 取样带取窄一点,别碰图标 ✓
//   · PNG 一律按 2x 读(Retina)⇒ 点的坐标 ×2 才是像素 ✓
import AppKit
import Foundation

// MARK: - 量尺

func loadPNG(_ path: String) -> (buf: [UInt8], W: Int, H: Int)? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let W = cg.width, H = cg.height
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    return (buf, W, H)
}

func lum(_ buf: [UInt8], _ W: Int, _ x: Int, _ y: Int) -> Double {
    let i = (y * W + x) * 4
    return (0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i+1]) + 0.0722 * Double(buf[i+2])) / 255
}

func describe(_ v: (Double, Double, Double)) -> String {
    let (r, g, b) = v
    let l = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    return String(format: "RGB %3.0f,%3.0f,%3.0f · L %5.1f/255 = %.3f", r, g, b, l * 255, l)
}

func sampleRect(_ path: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ step: Int) -> (Double, Double, Double) {
    guard let (buf, W, H) = loadPNG(path) else { print("  读不了 \(path)"); exit(1) }
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for yy in stride(from: y, to: min(y + h, H), by: max(1, step)) {
        for xx in stride(from: x, to: min(x + w, W), by: max(1, step)) {
            let i = (yy * W + xx) * 4
            r += Double(buf[i]); g += Double(buf[i+1]); b += Double(buf[i+2]); n += 1
        }
    }
    return (r / n, g / n, b / n)
}

// MARK: - 白底道具

final class BenchBackdrop: NSObject, NSApplicationDelegate {
    let seconds: Double
    var window: NSWindow?
    init(seconds: Double) { self.seconds = seconds }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = .white
        w.isOpaque = true
        w.level = .floating            // ⚠️ 必须高于普通窗口(否则被前台终端盖住),又低于 Glance 面板(popUpMenu)
        w.ignoresMouseEvents = true    // 不抢指针(量的时候指针还要用来唤起面板 ✓)
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // 大字:用来量"透过玻璃还剩多少对比/糊化"
        // `bg <秒> plain` ⇒ 纯白(不摆字与色块):量**边缘本身**时用 —— 有字时,
        // 玻璃会把字糊成一条暗带 ✗ 量到的"贴边暗带"其实是字的残留(2026-10-08 栽过 ✓)
        let plain = CommandLine.arguments.contains("plain")
        let lines = plain ? [] : ["玻璃质感对照 GLASS", "背景是白色的时候可见性", "native macOS liquid glass", "0123456789 ABCDEFG abcdefg"]
        for (i, t) in lines.enumerated() {
            let f = NSTextField(labelWithString: t)
            f.font = .systemFont(ofSize: 44, weight: .semibold)
            f.textColor = .black
            f.frame = NSRect(x: 60, y: 597 + CGFloat(2 - i) * 90, width: 1620, height: 62)
            host.addSubview(f)
        }
        // 色块:看折射与染色
        let boxColors: [NSColor] = plain ? [] : [.systemRed, .systemBlue, .systemGreen, .systemOrange]
        for (i, c) in boxColors.enumerated() {
            let box = NSView(frame: NSRect(x: 80 + CGFloat(i) * 200, y: 120, width: 160, height: 120))
            box.wantsLayer = true
            box.layer?.backgroundColor = c.cgColor
            host.addSubview(box)
        }
        w.contentView = host
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
    }
}

// MARK: - 入口

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"

switch mode {
case "bg":
    let secs = args.count > 2 ? (Double(args[2]) ?? 20) : 20
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = BenchBackdrop(seconds: secs)
    app.delegate = delegate
    app.run()

case "sample":
    guard args.count >= 7 else { print("用法: sample <png> x y w h [步长]"); exit(1) }
    let (r, g, b) = sampleRect(args[2], Int(args[3])!, Int(args[4])!, Int(args[5])!, Int(args[6])!,
                               args.count > 7 ? (Int(args[7]) ?? 1) : 1)
    print("  (\(args[3]),\(args[4]) \(args[5])x\(args[6]))  " + describe((r, g, b)))

case "vprofile":
    guard args.count >= 6, let (buf, W, H) = loadPNG(args[2]) else { print("用法: vprofile <png> x y0 y1"); exit(1) }
    let x = Int(args[3])!, y0 = Int(args[4])!, y1 = min(Int(args[5])!, H - 1)
    guard x >= 0, x < W, y0 < y1 else { print("  该列/区间不在图内"); exit(1) }
    var vals: [String] = []
    for y in y0...min(y1, y0 + 199) { vals.append(String(format: "%.3f", lum(buf, W, x, y))) }
    print("  x=\(x) y=\(y0)…\(y0 + vals.count - 1):")
    print("    " + vals.joined(separator: " "))
    let nums = vals.compactMap(Double.init)
    print(String(format: "    摘要: 最小 %.3f · 最大 %.3f", nums.min() ?? 0, nums.max() ?? 0))

case "profile":
    guard args.count >= 6, let (buf, W, H) = loadPNG(args[2]) else { print("用法: profile <png> y x0 x1"); exit(1) }
    let y = Int(args[3])!, x0 = Int(args[4])!, x1 = min(Int(args[5])!, W - 1)
    guard y >= 0, y < H, x0 < x1 else { print("  该行/区间不在图内"); exit(1) }
    var vals: [String] = []
    for x in x0...min(x1, x0 + 199) { vals.append(String(format: "%.3f", lum(buf, W, x, y))) }
    print("  y=\(y) x=\(x0)…\(x0 + vals.count - 1):")
    print("    " + vals.joined(separator: " "))
    let nums = vals.compactMap(Double.init)
    print(String(format: "    摘要: 最小 %.3f · 最大 %.3f", nums.min() ?? 0, nums.max() ?? 0))

case "compare":
    guard args.count >= 8 else { print("用法: compare <pngA> <pngB> <y0> <y1> <x0> <x1>"); exit(1) }
    let y0 = Int(args[4])!, y1 = Int(args[5])!, x0 = Int(args[6])!, x1 = Int(args[7])!
    let s = Double(x1 - x0), t = Double(y1 - y0)
    for p in [args[2], args[3]] {
        guard let (buf, W, _) = loadPNG(p) else { continue }
        var v: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 { v.append(lum(buf, W, x, y)) } }
        let m = v.reduce(0, +) / Double(v.count)
        let sd = (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
        let name = (p as NSString).lastPathComponent
        print(String(format: "  %-28@ L %.3f · 对比 sd %.4f", name as NSString, m, sd))
        _ = s; _ = t
    }

default:
    print("""
      GlassBench —— 玻璃量具台
        bg      [秒=20]                        起一块白底(大字 + 色块),N 秒后自动退
        sample  <png> x y w h [步长=1]          一块区域的平均色/L
        profile <png> y x0 x1                  横穿一条水平线(看左右边缘)
        vprofile <png> x y0 y1                 纵穿一条竖直线(看顶/底边缘)
        compare <pngA> <pngB> y0 y1 x0 x1      两图同一区域的 L 与对比(用来比"糊化程度")
      典型用法(与 2026-10-08 那次量玻璃一样):
        swift Tools/GlassBench.swift bg 20 &                      # ① 起白底
        swift Tools/SmokeHover.swift 0                            # ② 开面板(0 遍 = 只开不动)
        swift Tools/GlassBench.swift sample /tmp/a.png 60 3 300 8  # ③ 抓图 + 量(screencapture -x -R… 先抓)
      """)
}
