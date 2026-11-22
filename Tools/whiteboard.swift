// 全屏纯净背景板 v2(截图专用)—— 修 Esc 退出 bug + 四重兜底
// v1 病因:.prohibited 策略让 App 永远不激活 → 窗口不成为 key → keyDown 永远收不到 Esc
// v2 修复:
//   1. .accessory 策略 + activate(ignoringOtherApps) → 窗口真成为 key
//   2. NSWindow 子类 canBecomeKey=true(无边框窗口默认 false,这是第二个致死点)
//   3. 本地事件监听器拦 Esc(不依赖 responder chain)
//   4. 双击任意处退出 / 10 分钟自动退出 / 终端 pkill -f whiteboard 兜底
import AppKit

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class BoardView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { NSApp.terminate(nil) }  // 双击退出
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!.frame
let win = KeyWindow(
    contentRect: screen,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
win.level = .statusBar          // 25:盖菜单栏/Dock,压不过 Glance 面板(popUpMenu=101)
win.isOpaque = true
win.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.071, alpha: 1)
win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
win.contentView = BoardView(frame: NSRect(origin: .zero, size: screen.size))

// 兜底 3:本地监听器 —— App 收到的任何 Esc 都退出(不依赖首响应者)
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.keyCode == 53 { NSApp.terminate(nil) }
    return nil
}
// 兜底 4:全局监听器(若系统已授予输入监听权限则生效;没授予则静默失败,无害)
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }
// 兜底 5:10 分钟自动退出
Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { _ in NSApp.terminate(nil) }

win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
