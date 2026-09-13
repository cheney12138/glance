import SwiftUI

// mac-switcher 入口。T1 范围:菜单栏图标 + 设置占位 + 退出。
// T2 追加:权限门禁——缺权限时启动即弹引导窗,菜单栏图标带警示态,菜单第一行实时报门禁。
// 结构备忘:MenuBarExtra 取代 AppDelegate+StatusBarController;T9 设置面板同样走 openWindow。
@main
struct MacSwitcherApp: App {
    @StateObject private var permissions = PermissionMonitor()
    @Environment(\.openWindow) private var openWindow
    private let hotkeys = HotkeyTapCenter()
    private let panelController = PanelController()

    var body: some Scene {
        MenuBarExtra {
            // 权限行只在缺权时出现——授权完成后日日看它 = 视觉纳税(用户评审拍板)
            if !permissions.allGranted {
                Button(permissions.statusLine) { showPermissions() }
                Divider()
            }
            Button("设置…") { showSettings() }
            Divider()
            Button("退出 Glance") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: permissions.allGranted ? "rectangle.3.group" : "exclamationmark.triangle")
                .onAppear {
                    permissions.refresh()
                    if !permissions.allGranted { showPermissions() }
                    MruEvidence.shared.start()
                    hotkeys.onAction = { [weak panelController] a in panelController?.handle(a) }
                    hotkeys.onCmdClick = { point in CmdClickFix.handle(point: point) }
                    panelController.onSessionEnd = { [weak hotkeys] in hotkeys?.endSession() }
                    if permissions.allGranted { hotkeys.start() }
                }
                // 门禁从缺到齐的那一瞬,触发层上线(首次启动已齐则靠上面 onAppear)
                .onChange(of: permissions.allGranted) { _, granted in
                    if granted { hotkeys.start() }
                }
        }
        .menuBarExtraStyle(.menu)

        Window("Glance 权限", id: "permissions") {
            PermissionGuideView(monitor: permissions)
        }
        .windowResizability(.contentSize)

        Window("Glance 设置", id: "settings") {
            SettingsView(store: SettingsStore.shared, permissions: permissions)
        }
        .windowResizability(.contentSize)
    }

    /// LSUIElement 应用的窗口不会自动到前台。macOS 14 起 activate 降级为"请求",
    /// 且零窗 agent 的激活请求会被压制(实机现形:首次点设置躺在后面,二次正常)。
    /// 所以开窗后补一剂:再激活 + 显式 makeKeyAndOrderFront + orderFrontRegardless
    private func showWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) else { return }
            NSApp.activate(ignoringOtherApps: true)
            CursorScreenAnchor.center(w)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
    }

    private func showPermissions() { showWindow(id: "permissions") }
    private func showSettings() { showWindow(id: "settings") }
}
