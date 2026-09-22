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
        // ★ 重型开关**开机自报**(2026-09-21 第二次"量具改变被测物"后加的)：
        //   `dumpSources` 被上轮实验留在 ON 上,之后每次 hover 都在往磁盘写 PNG ⇒
        //   用户报"又掉帧了",量到的长帧里有一部分是**量具自己**。⇒ 不允许静默开着。
        DebugFlags.reportHeavySwitchesIfNeeded()
        // 外观要在任何窗/面板画出来之前摆好(面板取的全是按外观解析的动态色)
        AppearancePreference.apply()
        // AX 超时也在此刻定死:它是进程级设置,晚一步就有一次无上限的跨进程等待
        AXWindowList.installGlobalMessagingTimeout()
        // **最先跑**:两个实例会抢同一组 ⌘Tab 并画出叠在一起的面板(见 SingleInstanceGuard 的病例),
        // 而且必须在 NativeHotkeys / 事件 tap 之前拦住,退出时系统状态才是一行没动
        SingleInstanceGuard.enforce()
        // ★ 调试开关**只随启动参数生效**(2026-09-19 病例:自动化测试用 defaults 把
        //   pinPanelOnRelease 留成 ON 后忘了复位 ⇒ 用户实报「点空白关不掉面板」——
        //   钉住模式下"面板外点击不免死"本来就是设计)。普通启动一律清掉:
        //   要钉住,用 `open --args -debug.pinPanelOnRelease 1`,进程死了开关自动失效
        if !ProcessInfo.processInfo.arguments.contains("-debug.pinPanelOnRelease") {
            UserDefaults.standard.removeObject(forKey: Keys.debugPinPanelOnRelease)
        }
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

    private func showPermissions() {
        showWindow(id: "permissions")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Snapshotter.shared.precaptureOwnWindows() }
    }
    private func showSettings() {
        showWindow(id: "settings")
        // 设置窗是**打开时才建**的,冷启动预热拍不到它 —— 它入环后的第一眼不该是「截图中…」
        // (2026-09-18 用户实报)。窗建好、渲染落定(0.6s)后立刻把自己的普通图层窗拍进缓存;
        // 此后关面板预拍会持续保鲜。悬浮面板是 popUpMenu 图层,不在名单里
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Snapshotter.shared.precaptureOwnWindows() }
    }

    /// 冷启动预热(T86):启动后空闲 2.5s 干两件没人看的事 ——
    /// ① 语境屏枚举 + 预截一遍:把冷枚举管线(T85 实测 256ms:CGWindowList / AX 首连 / SCK 全是
    ///    第一次)与空缓存整个暖掉,首局唤起直接吃热路径(实测上屏 353ms → 84ms);
    /// ② 两块面板窗(NSPanel + SwiftUI hosting)先建好但不显示:首局"开窗 80ms"(T85 实测)
    ///    不占唤起那一拍。
    /// 权限齐了才发:预截没有屏幕录制权限只会白失败;权限中途补齐走 onChange 那条路,同样能到这。
    ///
    /// ★ 2026-09-18 拆成两笔(用户实报「白光又出现了」—— 日志:启动后 1.6s 就唤起,
    /// `[唤起] 缓存 0.0MB/0 张、按键→上屏 264ms`,而 `[保温]` 2538ms 才跑):
    /// 两件事的"贵"差一个量级,不该绑在同一个 2.5s 上 ——
    ///   · 两块面板窗构建 + 首帧合成预热 = 便宜(几十 ms)⇒ 提前到 **0.6s**;
    ///   · 冷枚举扫屏 + 全量预截 = 贵(百 ms 级,AX/CGWindowList/SCK 全是第一次)⇒ 仍等 2.5s。
    /// 这样"启动后立刻唤起"也有预热过的合成器与建好的窗口,冷启动的白光没有可乘之机
    /// (扫屏还没跑只影响"第一眼有没有图",那是另一件事,不闪)。
    private func scheduleWarmup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [panelController] in
            panelController.prewarmPanels()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [panelController] in
            ThumbnailRefresher.shared.coldStartSweep()
        }
        // 诊断钩子(自动化复现用,平时不生效):`open … --args -debug.autoOpenSettings 1`
        // 启动后自动开一次设置窗 —— 复现"设置窗关闭后 Glance 仍在环里"的病例
        if DebugFlags.autoOpenSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showSettings() }
        }
        // 🔬 AX 探针(2026-09-19,CatDesk 关窗不出现病例):defaults write debug.axprobePid
        // <pid> 后重启,借本 App 的辅助功能权限查目标进程 AX 眼里的窗口账 ——
        // 判别「CG 全量清单有窗但 onscreen=false」到底是"别屏 Space 的窗"还是"orderOut 的窗"
        if let pidStr = DebugFlags.axprobePid,
           let pid = pid_t(pidStr) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let app = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                print("[AX探针] pid=\(pid) err=\(err.rawValue)")
                if err == .success, let ws = value as? [AXUIElement] {
                    print("[AX探针] AX 窗口数 \(ws.count)")
                    for w in ws {
                        var t: CFTypeRef?
                        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
                        print("[AX探针]   - \(t as? String ?? "(无题)")")
                    }
                }
            }
        }
    }
}
