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
        mirrorStdoutToLogFileIfTracing()   // trace 时把 stdout 落到 ~/Library/Logs/Glance/trace.log
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
                    // 双击 ⌥ 把指针送到下一块屏（仅"旁观"事件流，绝不吞键）。默认关，
                    // 开关 key: pointer.doubleOptionJumps(触发键 2026-09-17 由 ⌃ 改 ⌥:与 IDEA 冲突)
                    DoubleOptionTap.shared.start()
                    // 三指点按 = 唤起面板且**这一局不散场**(见 ThreeFingerTap:原始触摸只在私有框架里)。
                    // 默认关;开着三指拖移也能共存 —— 判据是"恰好三指且 ≤0.3s"
                    ThreeFingerTap.shared.onFire = { hotkeys.beginPinnedSession() }
                    // 四指轻点(T91)= **唤起并直接进未启动环**。同一枚检测器,手指越多越具体:
                    // 三指 = 打开这个工具;四指 = 跳过已启动的,直接看没启动的。
                    // 走控制器自己的入口(闸都在它手里:launchables 空 / 已经在未启动环里 ⇒ 安静不动)
                    ThreeFingerTap.shared.onFireFour = { [weak panelController] in
                        hotkeys.beginPinnedSession()
                        panelController?.requestLaunchRing()   // ⚠️ 只记意图:此刻 launchables 还是上一局的
                    }
                    ThreeFingerTap.shared.start()
                    hotkeys.onScroll = { [weak panelController] e in panelController?.handleScrollEvent(e) }
                    // T91 表一 ⑤:别处的键盘输入 ⇒ 钉住的那一局自己收("牛皮糖")
                    hotkeys.onElsewhereInput = { [weak panelController] in
                        panelController?.dismissForOutsideInput()
                    }
                    panelController.onSessionEnd = { [weak hotkeys] in hotkeys?.endSession() }
                    if permissions.allGranted { hotkeys.start(); scheduleWarmup() }
                }
                // 门禁从缺到齐的那一瞬,触发层上线(首次启动已齐则靠上面 onAppear)
                .onChange(of: permissions.allGranted) { _, granted in
                    if granted { hotkeys.start(); scheduleWarmup() }
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

    /// 冷启动预热(T86):启动后空闲 2.5s 干两件没人看的事 ——
    /// ① 语境屏枚举 + 预截一遍:把冷枚举管线(T85 实测 256ms:CGWindowList / AX 首连 / SCK 全是
    ///    第一次)与空缓存整个暖掉,首局唤起直接吃热路径(实测上屏 353ms → 84ms);
    /// ② 两块面板窗(NSPanel + SwiftUI hosting)先建好但不显示:首局"开窗 80ms"(T85 实测)
    ///    不占唤起那一拍。
    /// 权限齐了才发:预截没有屏幕录制权限只会白失败;权限中途补齐走 onChange 那条路,同样能到这。
    private func scheduleWarmup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [panelController] in
            ThumbnailRefresher.shared.coldStartSweep()
            panelController.prewarmPanels()
        }
    }
}
