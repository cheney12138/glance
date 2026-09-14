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
            SettingsGroup {
                SettingsRow(title: "开机时启动 Glance",
                            desc: "登录到这台 Mac 后自动拉起;关掉后需要手动从应用程序里启动。") {
                    BeamSwitch(isOn: $store.launchAtLogin)
                }
                SettingsRow(title: "松手不关闭切换器面板",
                            desc: "开启后松开 ⌥ 面板保持打开:Tab/←→ 继续导航,Enter 确认聚焦,Esc 放弃。"
                                + "关闭则回到「松手即确认」的原生节奏。") {
                    BeamSwitch(isOn: $pinPanel)
                }
                SettingsRow(title: "图标呼吸感",
                            desc: "选中图标放大 \(String(format: "%.2f", PanelMetrics.iconScale)) 倍后,它与左右邻居"
                                + "之间还剩多少净空 —— 间隙由它倒推(当前 "
                                + "\(String(format: "%.1f", PanelMetrics.iconGap)) pt)。设计 demo 只有 0.5 pt,"
                                + "再算上图标那圈软阴影,实际是压在邻居身上的。",
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
            SettingsGroup {
                SettingsRow(title: "托底从底部升起",
                            desc: "开:无论新选中在第几格,托底都从面板**下缘升起** —— 距离恒定且短。"
                                + "关:从**上一局那个格子**滑过来(例:从 a 切到 b 后 b 排到第一、"
                                + "a 落在第六位,托底要横跨整条从右滑到左)。两种都会滑,区别只在起点。",
                            hairline: false) {
                    BeamSwitch(isOn: $puckRiseFromBottom)
                }
            }
            SettingsGroup {
                SettingsRow(title: "系统「减弱动态效果」") {
                    RowValue(systemReduced ? "已开启" : "未开启")
                }
                SettingsRow(title: "为本 App 放行完整动效",
                            desc: "即使系统开启了减弱动态效果,Glance 的弹簧动画和玻璃反光依旧保留完整版本。"
                                + "关掉后动效不会消失,只是位移类降级成 160ms 淡入淡出。",
                            hairline: false) {
                    BeamSwitch(isOn: $alwaysAnimate)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        Group {
            SettingsGroup {
                SettingsRow(title: "App 名称") { RowValue("Glance") }
                SettingsRow(title: "版本") { RowValue(bundle("CFBundleShortVersionString")) }
                SettingsRow(title: "构建", hairline: false) { RowValue(bundle("CFBundleVersion")) }
            }
            SettingsGroup {
                SettingsRow(title: "辅助功能",
                            desc: "监听 ⌥Tab、读取与聚焦窗口 —— 没有它,切换器整体不工作。") {
                    PermissionBadge(granted: permissions.accessibilityGranted)
                }
                SettingsRow(title: "屏幕录制",
                            desc: "预截窗口缩略图 —— 没有它,展开层显示不出窗口内容。"
                                + "权限异常时:菜单栏 →「权限」可重开引导,或用 README 里的 tccutil 命令彻底重置。",
                            hairline: false) {
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

    var body: some View {
        Group {
            SettingsGroup(label: "触发") {
                SettingsRow(title: "接管系统切换器(⌘Tab)",
                            desc: "默认关闭,触发键是 ⌥Tab —— 系统热键一行都不动。开启后 Glance 会关掉系统自己那条 "
                                + "⌘Tab 热键(私有 SkyLight API,与 alt-tab 同款做法),再以 Carbon 热键接管:"
                                + "不吞键、不抢事件。退出时会还原;若被强制杀掉,下次启动 Glance 会自动把它修回来"
                                + "(见 docs/adr/0005)。") {
                    BeamSwitch(isOn: takeoverBinding)
                }
                SettingsRow(title: "唤起即切换",
                            desc: "开(默认,与 macOS 一致):唤起面板时已选中**上一个 App**,"
                                + "一次 ⌘Tab 就完成一次切换;⇧⌘Tab 落到最后一个。"
                                + "关:唤起只定位到**当前 App**,再按一次 Tab 才切走。") {
                    BeamSwitch(isOn: $advanceOnOpen)
                }
                SettingsRow(title: "触发键",
                            desc: "默认 ⌥Tab。点一下进录制态,按下新的「修饰键 + 普通键」即写入,Esc 取消;"
                                + "修饰键只收 ⌥ / ⌘ / ⌃。改完即时生效,不用重启。",
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
            SettingsGroup(label: "面板内导航") {
                SettingsRow(title: "向后 / 向前循环切换") { KeyChip(text: "Tab / ⇧ Tab") }
                SettingsRow(title: "在展开层的窗之间移动",
                            desc: "组内只有一扇窗时 ←→ 无语义,静默吞掉 —— 绝不允许跨界滑到邻 App。") {
                    KeyChip(text: "← →")
                }
                SettingsRow(title: "确认 / 放弃", desc: "松开 ⌥ = 聚焦当前选中的那扇窗;Esc = 什么都不聚焦。") {
                    KeyChip(text: "松开 ⌥ / Esc")
                }
                SettingsRow(title: "退出 App / 关窗 / 最小化",
                            desc: "破坏性操作,**处决即散场**:动作一发本轮切换事务立刻结束,想继续切就重新触发一局。",
                            hairline: false) {
                    KeyChip(text: "Q / W / M")
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
