// 按窗口截图 / 采样像素(验证"只有真窗口才看得见"的那类问题)。
//
//   swift Tools/CaptureWindow.swift list [owner 子串]        # 列窗口(id / owner / layer / alpha / bounds / 标题)
//   swift Tools/CaptureWindow.swift shot --out /tmp/w.png (--id N | --owner Glance) [--screen] [--sample 300,39 ...]
//
// 两条截图路各自能干到哪(实机验证过,别搞反):
//   **per-window**(默认,`CGWindowListCreateImage`):普通窗(终端/编辑器窗口)内容完整;
//     但 **Glance 自己的玻璃面板截出来是全空的** —— 玻璃由窗口服务器在进程外合成,不在我们的层树里
//     (与 design-system v1.11 那条 "glass 混不进进程外合成" 是同一件物理事实)。
//   **region**(`--screen`,`screencapture -R`):拿到的是**合成后的屏幕**,玻璃与它背后的内容都在
//     —— 代价是要给**发起进程**「屏幕录制」权限。
//
// 为什么不用离屏渲染(ImageRenderer / cacheDisplay):那两条路有两个盲区 ——
//   ① AppKit 单独绘制的**焦点环**抓不到(蓝框就是这么漏过离屏验证的);
//   ② `ImageRenderer` 把 `ScrollView` 渲成**空白**。
// 窗口服务器合成一遍再截回来,才是用户看到的那张图。
//
// 权限:截**自己**参与的窗口一般不需要录屏授权;截别人的窗口需要给**发起进程**录屏权限。
// 失败时本工具会提示(整幅全透明 = 没拿到内容)。

import AppKit
import CoreGraphics

// MARK: - 参数

private var subcommand = "list"
private var ownerFilter: String?
private var titleFilter: String?
private var windowID: CGWindowID?
private var outPath = "/tmp/glance-window.png"
private var samples: [(CGFloat, CGFloat)] = []
private var screenRegion = false

private func parseArgs() {
    var rest = Array(CommandLine.arguments.dropFirst())
    if let first = rest.first, !first.hasPrefix("-") {
        subcommand = first
        rest.removeFirst()
    }
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--out", "-o": outPath = rest.isEmpty ? outPath : rest.removeFirst()
        case "--screen", "-s": screenRegion = true
        case "--id": windowID = rest.isEmpty ? nil : CGWindowID(rest.removeFirst())
        case "--owner": ownerFilter = rest.isEmpty ? nil : rest.removeFirst()
        case "--title": titleFilter = rest.isEmpty ? nil : rest.removeFirst()
        case "--sample":
            guard !rest.isEmpty else { break }
            parseSamples(rest.removeFirst())
        default:
            if ownerFilter == nil, !arg.hasPrefix("-") { ownerFilter = arg }
        }
    }
}

// MARK: - 窗口清单

/// 采样点两种写法都收:`--sample 300,39`(一对数字)与 `--sample 300x39,600x80`(多个点,可叠多个 --sample)
private func parseSamples(_ value: String) {
    let tokens = value.split(separator: ",").map(String.init)
    if tokens.contains(where: { $0.lowercased().contains("x") }) {
        for token in tokens {
            let parts = token.lowercased().split(separator: "x")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { continue }
            samples.append((CGFloat(x), CGFloat(y)))
        }
        return
    }
    var index = 0
    while index + 1 < tokens.count {
        if let x = Double(tokens[index]), let y = Double(tokens[index + 1]) {
            samples.append((CGFloat(x), CGFloat(y)))
        }
        index += 2
    }
}

private struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let title: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

private func onScreenWindows() -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return raw.compactMap { info in
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return WindowInfo(
            id: id,
            owner: info[kCGWindowOwnerName as String] as? String ?? "?",
            title: (info[kCGWindowName as String] as? String) ?? "",
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            bounds: bounds
        )
    }
}

private func match(_ window: WindowInfo) -> Bool {
    if let windowID { return window.id == windowID }
    if let ownerFilter, !window.owner.localizedCaseInsensitiveContains(ownerFilter) { return false }
    if let titleFilter, !window.title.localizedCaseInsensitiveContains(titleFilter) { return false }
    return ownerFilter != nil || titleFilter != nil
}

private func describe(_ window: WindowInfo) -> String {
    String(format: "id=%-7u %-22@ layer=%d alpha=%.2f %.0fx%.0f @(%.0f,%.0f) %@",
           window.id, window.owner as NSString, window.layer, window.alpha,
           window.bounds.width, window.bounds.height,
           window.bounds.origin.x, window.bounds.origin.y,
           window.title.isEmpty ? "(无标题)" : window.title)
}

// MARK: - 截图与采样

private func hex(_ color: NSColor?) -> String {
    guard let c = color?.usingColorSpace(.sRGB) else { return "n/a" }
    return String(format: "#%02X%02X%02X a%.2f",
                  Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
}

private func shot(_ window: WindowInfo) {
    // 玻璃面板只能走整屏裁剪(screencapture -R):per-window 那条对玻璃是全空的
    if screenRegion {
        let rect = "\(Int(window.bounds.origin.x)),\(Int(window.bounds.origin.y)),\(Int(window.bounds.width)),\(Int(window.bounds.height))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R" + rect, outPath]
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: outPath))) ?? Data()) else {
            print("screencapture 失败(多半是发起进程没有「屏幕录制」权限):— 系统设置 → 隐私与安全性 → 屏幕录制")
            return
        }
        print("窗口:\(describe(window))")
        print("写出(整屏裁剪 -R\(rect)):\(outPath)  \(rep.pixelsWide)x\(rep.pixelsHigh)px")
        reportSamples(rep, bounds: window.bounds)
        return
    }

    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window.id,
                                             [.boundsIgnoreFraming, .bestResolution]) else {
        print("截不到 id=\(window.id)(窗口可能刚消失)")
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: outPath))

    let scale = Double(rep.pixelsWide) / max(window.bounds.width, 1)
    print("窗口:\(describe(window))")
    print("写出:\(outPath)  \(rep.pixelsWide)x\(rep.pixelsHigh)px(\(scale)x,即 \(Int(window.bounds.width))x\(Int(window.bounds.height))pt)")
    if window.bounds.width != 0, abs(scale - 2) > 0.01 {
        print("提示:非 2x 屏,采样点按 pt×\(scale) 换算")
    }

    // 整幅全透明 = 没拿到内容:要么缺录屏权限,要么这是玻璃面板(见本文件顶部注释)——两种都提示
    var opaque = 0
    var probes = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 32, 1)) {
        for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 32, 1)) {
            probes += 1
            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { opaque += 1 }
        }
    }
    if opaque == 0 {
        print("⚠️  \(probes) 个探测点全透明:要么发起进程缺「屏幕录制」权限,要么这是玻璃面(玻璃在进程外合成)")
        print("    前者 → 系统设置 → 隐私与安全性 → 屏幕录制;后者 → 加 `--screen` 走整屏裁剪")
    }

    reportSamples(rep, bounds: window.bounds)
}

private func reportSamples(_ rep: NSBitmapImageRep, bounds: CGRect) {
    let scale = Double(rep.pixelsWide) / max(bounds.width, 1)
    for (x, y) in samples {
        let px = Int(x * CGFloat(scale))
        let py = Int(y * CGFloat(scale))
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else {
            print(String(format: "采样 (%.1f,%.1f)pt 越界", x, y))
            continue
        }
        print(String(format: "采样 (%.1f,%.1f)pt = 像素(%d,%d) → %@", x, y, px, py, hex(rep.colorAt(x: px, y: py))))
    }
}

// MARK: - 主流程

parseArgs()
switch subcommand {
case "list":
    let windows = onScreenWindows().filter { ownerFilter == nil && titleFilter == nil ? true : match($0) }
    print("屏幕上的窗口 \(windows.count) 个:")
    for window in windows { print("  " + describe(window)) }
case "shot":
    let candidates = onScreenWindows().filter(match)
    guard let target = candidates.first else {
        print("没匹配到窗口。先 `list` 看看;Glance 的面板只在导航态存在(要跑 InjectChord 或手按一次)")
        exit(1)
    }
    if candidates.count > 1 {
        print("匹配到 \(candidates.count) 个,取第一个(可用 --id 指定):")
        for window in candidates { print("  " + describe(window)) }
    }
    shot(target)
default:
    print("用法:\n  swift Tools/CaptureWindow.swift list [owner 子串]\n  swift Tools/CaptureWindow.swift shot --out /tmp/w.png (--id N | --owner Glance) [--sample 300,39]")
    exit(2)
}
