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

    /// 把窗口平移到光标屏正中,尺寸不动
    static func center(_ window: NSWindow) {
        guard let screen = cursorScreen else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        ))
    }
}
