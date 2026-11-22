import AppKit

/// 自家窗口一律落在光标所在屏:鼠标在哪块屏,语境就在哪块屏。
/// 与 CONTEXT.md「语境屏」同一条哲学,作用范围 = 一切自家窗口
/// (权限引导、T6 切换器面板、T9 设置面板),不许出现"弹到另一块屏"的自家窗。
enum CursorScreenAnchor {
    /// 光标所在屏;找不到(理论上不该发生)退回主屏
    static var cursorScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    }

    /// 把窗口平移到屏幕正中,尺寸不动（默认落在光标所在屏；传 `preferWindowScreen` 时在窗口当前所在屏上自适应保居中）
    static func center(_ window: NSWindow, preferWindowScreen: Bool = false) {
        let screen = (preferWindowScreen ? window.screen : nil) ?? cursorScreen ?? window.screen
        guard let screen else { return }
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return }
        let target = screen.frame
        let rawX = target.midX - size.width / 2
        let rawY = target.midY - size.height / 2
        let clampedX = min(max(rawX, target.minX), max(target.minX, target.maxX - size.width))
        let clampedY = min(max(rawY, target.minY), max(target.minY, target.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }
}
