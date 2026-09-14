import SwiftUI
import AppKit
import GlanceCore

/// 设置面板 —— 施工契约 = 设计 demo `design/v4/Glance 设置 v1.html`(纸面 + 棱镜边 + 玻璃舌头分段控件),
/// token 与偏离备案见 `design/settings-spec.md`。
///
/// 与旧版(DockDoor 式 `NavigationSplitView` 侧边栏 + `Form`)的分野:
/// 1. 侧边栏换成 demo 的**居中分段控件**,舌头用 `matchedGeometryEffect` 滑;
/// 2. `Form` 换成**平铺信息表**:组 → 行(标题 + 说明 + 尾部控件),不再"每组一张卡片"套娃;
/// 3. 开关自绘成 demo 的 34×20 小号(demo 的"光束点亮"意象 = 关闭玻璃灰 / 打开强调蓝)。
///
/// 内容边界不变(Q8 冻结:通用 / 快捷键 / 关于,三节打住)。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionMonitor

    enum Page: String, CaseIterable, Identifiable {
        case general = "通用"
        case shortcut = "快捷键"
        case about = "关于"
        var id: String { rawValue }
        /// demo 的三枚线性图标;SF Symbols 取语义最近的一对一
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .shortcut: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    @State private var page: Page = .general
    @AppStorage("debug.pinPanelOnRelease") private var pinPanel = false
    /// 默认 true = 本 App 自己放行完整动效(macOS 没有 per-app 的 reduce-motion 豁免 API)
    @AppStorage("motion.alwaysAnimate") private var alwaysAnimate = true
    /// 图标呼吸感:选中放大后与左右邻居之间**还剩**多少净空(pt)。间隙由它倒推
    @AppStorage("panel.iconClearance") private var iconClearance: Double = 13
    /// 颜色外观:auto / light / dark(默认 auto = 跟随系统)
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.auto
    @AppStorage("panel.puckRiseFromBottom") private var puckRiseFromBottom = true
    /// 系统"减弱动态效果"的实时值(改完系统设置回来重开这个面板即可刷新)
    @State private var systemReduced = MotionPolicy.systemReduced

    var body: some View {
        VStack(spacing: 0) {
            prismEdge
            SettingsTabRail(page: $page)
                .padding(.top, SettingsMetrics.tabsTop)
                .padding(.bottom, SettingsMetrics.tabsBottom)
            content
        }
        .frame(width: SettingsMetrics.windowW, height: SettingsMetrics.contentH)
        // 纸铺满整窗:窗口用 `.hiddenTitleBar`,红绿灯直接浮在这张纸的左上角(demo 的构图)
        .background {
            SettingsWindowChrome().frame(width: 0, height: 0) // 零尺寸:只管窗,不接事件
            SettingsTheme.paper
        }
        // 棱镜边量的是**窗顶**,不是"标题栏下沿":隐藏标题栏后系统仍会给顶部留 32pt 安全区,
        // 不豁免的话整条光带会被顶下去 32pt(实测 39 → 71),跟 demo 就不是一回事了。
        // 红绿灯占的是最上面 0…32pt,光带在 39pt,不会撞上。
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { systemReduced = MotionPolicy.systemReduced }
    }

    /// demo `.prism-edge`:窗顶唯一一道光谱(张力备案见 `SettingsTheme.prism`)
    private var prismEdge: some View {
        SettingsTheme.prism
            .frame(height: SettingsMetrics.prismHeight)
            .opacity(SettingsMetrics.prismOpacity)
            .padding(.top, SettingsMetrics.prismTop)
    }

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                switch page {
                case .general: generalPane
                case .shortcut: ShortcutPane()
                case .about: aboutPane
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.contentPadX)
            .padding(.top, SettingsMetrics.contentPadTop)
            .padding(.bottom, SettingsMetrics.contentPadBottom)
        }
    }

    // MARK: - 通用

    private var generalPane: some View {
        Group {
            SettingsGroup(label: "外观") {
                SettingsRow(title: "颜色外观", desc: "面板与设置窗同步生效。") {
                    BeamSegmented(options: [
                        .init(id: AppearancePreference.auto, label: "自动"),
                        .init(id: AppearancePreference.light, label: "浅色"),
                        .init(id: AppearancePreference.dark, label: "深色"),
                    ], value: $appearance)
                }
                SettingsRow(title: "图标呼吸感",
                            desc: "选中图标放大后与邻居的净空,间隙由它推算。",
                            hairline: false) {
                    HStack(spacing: 8) {
                        Slider(value: clearanceBinding, in: 4...28)
                            .controlSize(.small)
                            .frame(width: 150)
                            .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                        Text("\(Int(iconClearance)) pt")
                            .font(SettingsFont.rowValue)
                            .foregroundStyle(SettingsTheme.ink2)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
            .onChange(of: appearance) { _, _ in AppearancePreference.apply() }

            SettingsGroup(label: "启动与行为") {
                SettingsRow(title: "登录时启动", desc: "关闭则需手动打开。") {
                    BeamSwitch(isOn: $store.launchAtLogin)
                }
                SettingsRow(title: "松手保持面板",
                            desc: "关闭 = 松手即确认(原生节奏)。",
                            hairline: false) {
                    BeamSwitch(isOn: $pinPanel)
                }
            }

            SettingsGroup(label: "动效") {
                SettingsRow(title: "系统减弱动态效果") {
                    RowValue(systemReduced ? "已开启" : "未开启")
                }
                SettingsRow(title: "强制完整动效",
                            desc: "系统开启减弱时仍播弹簧;关闭则位移类降为淡入淡出。") {
                    BeamSwitch(isOn: $alwaysAnimate)
                }
                SettingsRow(title: "托底从底部升起",
                            desc: "关闭则托底从上一格滑过来。",
                            hairline: false) {
                    BeamSwitch(isOn: $puckRiseFromBottom)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        Group {
            SettingsGroup(label: "版本信息") {
                SettingsRow(title: "名称") { RowValue("Glance") }
                SettingsRow(title: "版本") { RowValue(bundle("CFBundleShortVersionString")) }
                SettingsRow(title: "构建", hairline: false) { RowValue(bundle("CFBundleVersion")) }
            }
            SettingsGroup(label: "权限") {
                SettingsRow(title: "辅助功能", desc: "读取与聚焦窗口。缺失则切换器不工作。") {
                    PermissionBadge(granted: permissions.accessibilityGranted)
                }
                SettingsRow(title: "屏幕录制", desc: "抓取窗口缩略图。", hairline: false) {
                    PermissionBadge(granted: permissions.screenCaptureGranted)
                }
            }
        }
    }

    private func bundle(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }

    /// 取整到 1pt 的滑杆:不用 `Slider(step:)` —— 带 step 的滑杆会在轨道下方画一排刻度点,
    /// demo 里没有任何刻度语言。连续拖动、落在整数上,读数与 `PanelMetrics` 读到的值一致。
    private var clearanceBinding: Binding<Double> {
        Binding(get: { iconClearance }, set: { iconClearance = $0.rounded() })
    }
}

/// 快捷键页:录制式改键(Q8 冻结)。按一下胶囊进录制态,下一次"修饰键+普通键"
/// 即写入;Esc 取消。只允许 ⌥/⌘/⌃ 当修饰键 —— ⇧ 永久留给反向导航。
struct ShortcutPane: View {
    @State private var config = TriggerConfig.load()
    @State private var recording = false
    @State private var monitor: Any?
    /// 唤起落点:true(默认,macOS 原生)= 直接切一次(上一个 App);false = 只定位到当前 App
    @AppStorage("switch.advanceOnOpen") private var advanceOnOpen = true
    /// 颜色外观:auto / light / dark(见 AppearancePreference)
    /// ` 循环窗口(默认关:它是系统级快捷键,只能用户显式开)
    @AppStorage("switch.graveCyclesWindows") private var graveCyclesWindows = false

    var body: some View {
        Group {
            SettingsGroup(label: "触发") {
                SettingsRow(title: "接管系统 ⌘Tab",
                            desc: "关闭则用 ⌥Tab,系统热键一行不动。退出时还原。") {
                    BeamSwitch(isOn: takeoverBinding)
                }
                SettingsRow(title: "唤起即切换",
                            desc: "唤起时已选中上一个 App;关闭则只定位到当前 App。") {
                    BeamSwitch(isOn: $advanceOnOpen)
                }
                SettingsRow(title: "触发键",
                            desc: "点一下后按下新组合,修饰键只收 ⌥ / ⌘ / ⌃。",
                            hairline: false) {
                    Button {
                        recording ? stopRecording() : startRecording()
                    } label: {
                        KeyChip(text: recording ? "按下新组合…" : chip(config), highlighted: recording)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                    .help(recording ? "按 Esc 取消录制" : "点一下开始录制新的触发键")
                }
            }
            SettingsGroup(label: "导航") {
                SettingsRow(title: "` 循环窗口",
                            desc: "仅在面板打开时生效,不会触发系统的 ⌘`。") {
                    BeamSwitch(isOn: $graveCyclesWindows)
                }
                SettingsRow(title: "循环切换") { KeyChip(text: "Tab / ⇧ Tab") }
                SettingsRow(title: "切换窗口", desc: "只有一扇窗时不响应,也不会跨到邻 App。") {
                    KeyChip(text: "← →")
                }
                SettingsRow(title: "确认 / 放弃", desc: "松开 ⌥ 聚焦选中窗,Esc 放弃。",
                            hairline: false) {
                    KeyChip(text: "松开 ⌥ / Esc")
                }
            }
            SettingsGroup(label: "窗口操作") {
                SettingsRow(title: "退出 App / 关窗 / 最小化", desc: "执行后面板保留。") {
                    KeyChip(text: "Q / W / M")
                }
                SettingsRow(title: "全屏 / 隐藏 App", desc: "隐藏的 App 图标保留,只是没有可预览的窗。",
                            hairline: false) {
                    KeyChip(text: "F / H")
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    /// 触发键胶囊文案:demo 的键位块是"修饰键 + 空格 + 键名",`TriggerConfig.display` 是紧贴写法
    private func chip(_ c: TriggerConfig) -> String {
        c.modifierSymbol + " " + c.keyName
    }

    /// 篡位开关:开 = 触发键写成 ⌘Tab + 显式记下"用户要接管";关 = 清掉键(⇒ ⌥Tab)+ 撤销接管。
    /// **读的是显式 flag**,不是"触发键恰好是 ⌘Tab"——口径见 `TriggerConfig.takeoverEnabled`。
    private var takeoverBinding: Binding<Bool> {
        Binding(
            get: { TriggerConfig.takeoverEnabled },
            set: { on in
                if on {
                    UserDefaults.standard.set(0x30, forKey: "trigger.keyCode")
                    UserDefaults.standard.set("command", forKey: "trigger.modifier")
                    TriggerConfig.setTakeover(true)
                } else {
                    UserDefaults.standard.removeObject(forKey: "trigger.keyCode")
                    UserDefaults.standard.removeObject(forKey: "trigger.modifier")
                    TriggerConfig.setTakeover(false)
                }
                config = TriggerConfig.load()
                print("[T13] ⌘Tab 篡位: \(on ? "接管(系统热键将被关掉)" : "还原 ⌥Tab(系统热键恢复)")")
            }
        )
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { stopRecording(); return nil } // Esc 取消
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let mod = allowedModifier(in: flags) else { return event } // 没有合法修饰键,继续等
            UserDefaults.standard.set(Int(event.keyCode), forKey: "trigger.keyCode")
            UserDefaults.standard.set(mod, forKey: "trigger.modifier")
            // 录到与系统热键重叠的和弦(⌘Tab / ⌘`)→ 显式标记"用户要接管"。
            // 不标的话原生那条会在 Dock/WindowServer 层就吃掉事件,我们注册的 Carbon 热键根本收不到
            // (见 docs/adr/0005);标记之后那个开关会跟着亮起来,用户看得见自己动了什么。
            let recorded = TriggerConfig.load()
            TriggerConfig.setTakeover(NativeHotkeys.overlapsNativeHotkey(recorded))
            config = recorded
            print("[T9] 触发键改为: \(config.display)")
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func allowedModifier(in flags: NSEvent.ModifierFlags) -> String? {
        if flags.contains(.option) { return "option" }
        if flags.contains(.command) { return "command" }
        if flags.contains(.control) { return "control" }
        return nil
    }
}
