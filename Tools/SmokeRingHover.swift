// 冒烟:指针 hover 与"环里第几格"是否对齐(2026-09-22)。
//
//   swift Tools/SmokeRingHover.swift
//
// 判据:把**真实指针**warp 到面板窗口的水平**正中**,再看日志里 `启动选中(…): [i/N]` 是哪一格。
//   环是**居中**的 ⇒ 正中应当落在**中间那一格**(N=3 ⇒ i=2)。
//   病例(本轮):窗框宽度改成"两环更宽者"后,未启动环内容居中,而命中还在按玻璃左缘算 ⇒
//   整排选中右移 ⇒ 同样这一下会落到第 4 格之外(什么都不选)或错格 ✗
import AppKit
import CoreGraphics

let cmd: CGKeyCode = 0x37, tab: CGKeyCode = 0x30, down: CGKeyCode = 0x7D, esc: CGKeyCode = 0x35
let src = CGEventSource(stateID: .hidSystemState)
func post(_ k: CGKeyCode, _ d: Bool, _ f: CGEventFlags) {
    CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: d).map { $0.flags = f; $0.post(tap: .cghidEventTap) }
}
func tap(_ k: CGKeyCode, _ f: CGEventFlags) { post(k, true, f); usleep(35_000); post(k, false, f) }
func wait(_ ms: UInt32) { usleep(ms * 1000) }

// 从日志里读面板窗口框(最后一条 [窗框] 主面板)
func panelFrame() -> CGRect? {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glance/trace.log")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    let re = try! NSRegularExpression(pattern: #"\[窗框\] 主面板[^ ]* [0-9.,]+ [0-9.]+x[0-9.]+ → ([0-9.-]+),([0-9.-]+) ([0-9.]+)x([0-9.]+)"#)
    let lines = text.split(separator: "\n")
    for line in lines.reversed() {
        let s = String(line)
        if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let x = Double((s as NSString).substring(with: m.range(at: 1))),
           let y = Double((s as NSString).substring(with: m.range(at: 2))),
           let w = Double((s as NSString).substring(with: m.range(at: 3))),
           let h = Double((s as NSString).substring(with: m.range(at: 4))) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }
    return nil
}

let n = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cheney12138.macswitcher").count
print("  Glance 实例数:\(n)"); if n != 1 { exit(2) }

post(cmd, true, [.maskCommand]); wait(80)
tap(tab, [.maskCommand]); wait(500)     // 唤起
tap(down, [.maskCommand]); wait(700)    // ↓ 进未启动环
guard let f = panelFrame() else { print("  ✗ 读不到面板窗框"); exit(2) }
// 注:窗口 y 是 Cocoa 坐标(左下原点),NSEvent/CGWarp 也用同一坐标系 ⇒ 直接用
let target = CGPoint(x: f.midX, y: f.midY)
print(String(format: "  面板窗 %.0f,%.0f %.0fx%.0f ⇒ 指针 warp 到正中 %.0f,%.0f", f.minX, f.minY, f.width, f.height, target.x, target.y))
CGWarpMouseCursorPosition(target)
CGAssociateMouseAndMouseCursorPosition(1)
wait(700)
tap(esc, [.maskCommand]); wait(120); post(cmd, false, [])
print("  完成(看日志里 [T6] 启动选中/启动区选中 的 [i/N])")
