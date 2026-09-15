import SwiftUI
import GlanceCore

// Glance 入口。T1 范围:菜单栏图标 + 设置占位 + 退出。
// T2 追加:权限门禁——缺权限时启动即弹引导窗,菜单栏图标带警示态,菜单第一行实时报门禁。
// 结构备忘:MenuBarExtra 取代 AppDelegate+StatusBarController;T9 设置面板同样走 openWindow。
@main
struct GlanceApp: App {
    /// 碰一下那个全局 let:惰性初始化只在被访问时才跑,而它必须在任何 print 之前生效
    init() {
        _ = stdoutIsLineBuffered
        // 实验开关**必须自己报状态**:2026-09-15 用户给了两份日志,而"逐元素投影到底关没关"
        // 只能靠推论 —— 这种"读了半天不知道条件是什么"的日志,等于白测。
        if PanelElevation.elementShadowsOff {
            print("[调试] 逐元素投影已关闭(debug.noElementShadows)—— 诊断用,顶位会飘")
        }
        // 外观要在任何窗/面板画出来之前摆好(面板取的全是按外观解析的动态色)
        AppearancePreference.apply()
        // AX 超时也在此刻定死:它是进程级设置,晚一步就有一次无上限的跨进程等待
        AXWindowList.installGlobalMessagingTimeout()
        // **最先跑**:两个实例会抢同一组 ⌘Tab 并画出叠在一起的面板(见 SingleInstanceGuard 的病例),
        // 而且必须在 NativeHotkeys / 事件 tap 之前拦住,退出时系统状态才是一行没动
        SingleInstanceGuard.enforce()
    }

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
            Button("检查更新…") { UpdateChecker.checkForUpdates() }
            Divider()
            Button("退出 Glance") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // 自绘菜单栏图(Assets 里的 MenuBarIcon,按 template 渲染:形状定 / 颜色系统给)。
            // 权限缺失时仍回退到系统符号,警示语义不让位
            //
            // ★ 两格走的是**两个不同的构造器**,不能合并成三元表达式:
            //   · `Image(_ name:)` —— 只查 asset catalog("MenuBarIcon" 在里面);
            //   · `Image(systemName:)` —— 只查 SF Symbols("exclamationmark.triangle" 在里面)。
            //   2026-09-14 真机日志连报两行
            //   “No image named 'exclamationmark.triangle' found in asset catalog” ——
            //   合并写法把 SF Symbol 名喂给了 asset catalog,查不到就画一个**空图**,
            //   于是“缺权限”这件事在菜单栏上其实一直**没有可见信号**(日志之外无人知晓)。
            Group {
                if permissions.allGranted {
                    Image("MenuBarIcon")
                } else {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
                .onAppear {
                    // 恢复守卫 + 启动自愈要先装:上一次运行如果被 SIGKILL,原生 ⌘Tab 会一直死着
                    // (见 NativeSwitcherHotkeys),这件事与权限是否齐备无关
                    NativeHotkeyGuards.install()
                    NativeHotkeys.restoreAll()
                    permissions.refresh()
                    if !permissions.allGranted { showPermissions() }
                    MruEvidence.shared.start()
                    // 缩略图保温:App 激活时就把它那几扇窗拍好(AltTab 的取法,见 ThumbnailRefresher)
                    ThumbnailRefresher.shared.start()
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
        // 设置窗是"一张纸":标题栏交给窗内的构图(demo 的红绿灯直接浮在纸的左上角,
        // 棱镜边压在它们下面)。窗口标题仍在 Window 菜单里,窗口照旧可拖、可关。
        .windowStyle(.hiddenTitleBar)
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
