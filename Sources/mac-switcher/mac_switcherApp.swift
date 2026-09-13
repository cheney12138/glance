import SwiftUI

// mac-switcher 入口。T1 范围:菜单栏图标 + 设置占位 + 退出。
// T2 追加:权限门禁——缺权限时启动即弹引导窗,菜单栏图标带警示态,菜单第一行实时报门禁。
// 结构备忘:MenuBarExtra 取代 AppDelegate+StatusBarController;T9 设置面板同样走 openWindow。
@main
struct MacSwitcherApp: App {
    @StateObject private var permissions = PermissionMonitor()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Button(permissions.statusLine) { showPermissions() }
            Divider()
            Button("设置…") {}
                .disabled(true) // T9 占位
            Divider()
            Button("退出 mac-switcher") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: permissions.allGranted ? "rectangle.3.group" : "exclamationmark.triangle")
                .onAppear {
                    permissions.refresh()
                    if !permissions.allGranted { showPermissions() }
                }
        }
        .menuBarExtraStyle(.menu)

        Window("mac-switcher 权限", id: "permissions") {
            PermissionGuideView(monitor: permissions)
        }
        .windowResizability(.contentSize)
    }

    /// LSUIElement 应用的窗口不会自动到前台,先 activate 再开窗
    private func showPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "permissions")
        // openWindow 内部异步,窗口对象要到下一圈 runloop 才挂得上,稍后把它钉到光标屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "permissions" }) else { return }
            CursorScreenAnchor.center(w)
        }
    }
}
