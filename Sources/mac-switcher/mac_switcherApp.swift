import SwiftUI

// mac-switcher 入口。T1 范围:菜单栏图标 + 设置占位 + 退出。
// 结构备忘:原计划 AppDelegate + StatusBarController 由 SwiftUI MenuBarExtra 一体取代,
// T9 设置面板用 openWindow 接 Window 场景,届时再按需补 AppDelegate。
@main
struct MacSwitcherApp: App {
    init() {
        print("[mac-switcher] launched — ⇧⌘Y 面板里应该看得到这一行")
    }

    var body: some Scene {
        MenuBarExtra {
            Button("设置…") {}
                .disabled(true) // T9 占位:设置面板未施工,先灰着
            Divider()
            Button("退出 mac-switcher") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // 切换器语义图标:三个窗口成组;T9 前后如需要可换自定义图标
            Image(systemName: "rectangle.3.group")
        }
        .menuBarExtraStyle(.menu) // DockDoor 式朴素菜单,不要 .window 的浮层
    }
}
