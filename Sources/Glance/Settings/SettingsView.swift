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
/// 文案纪律(2026-09-15 用户口径:「描述太冗余,一点都不高级简洁;有的也不准确;不好解释的就别写。保持克制」):
///   1. **一行说不清就不写** —— 标题 + 控件已经说清的,不再复述(只有 RowValue 的行尤其不该有说明);
///   2. **不出现内部名词**:pid、重枚举、动态色、发丝、一行代码…… 用户不读这些;
///   3. **键帽跟着配置走**,不硬写(触发键可以从 ⌥Tab 改成 ⌘Tab,"松开 ⌥" 就会变成假话);
///   4. 准确性优先于简短,但**两难时选删**:不好解释的行为,宁可不写(写半句比不写更糟);
///   5. **语域是产品文档,不是对话**:陈述句、书面语,不用口语与表情符号;只写这个开关做什么,
///      不写动机、不写设计史、不写开发者感受(2026-09-15 用户实评:「毕竟是一个产品,功能描述要严谨严肃一点」)。
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
    /// App 间距:选中放大后与左右邻居之间**还剩**多少净空(pt)。间隙由它倒推
    /// (旧名"图标呼吸感"是内部黑话,2026-09-15 按用户口径改成"App 间距")
    @AppStorage("panel.iconClearance") private var iconClearance: Double = 13
    /// 颜色外观:auto / light / dark(默认 auto = 跟随系统)
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.auto
    /// 启动区(方案 E):Dock 常驻且未启动的 App 在面板环尾展示。默认开(展示层新增,不抢任何按键)
    @AppStorage("panel.showLaunchables") private var showLaunchables = true
    /// Tab 是否进未启动区(2026-09-18):默认开;关闭后段只能靠 ↓/↑ 进出
    @AppStorage("panel.tabEntersLaunchSection") private var tabEntersLaunchSection = true
    /// 从上一个 App 滑过来(额外的一层入场动效;上浮是通用的那一层,永远在)
    @AppStorage("panel.slideFromLastApp") private var slideFromLastApp = false
    /// 光效总闸:指针柔光 + 图标静态反光(默认开;开关是给不喜欢面板里有光的人)
    @AppStorage("panel.sheen") private var sheen = true
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
                SettingsRow(title: "颜色外观", desc: "面板与设置窗口同步生效。") {
                    BeamSegmented(options: [
                        .init(id: AppearancePreference.auto, label: "自动"),
                        .init(id: AppearancePreference.light, label: "浅色"),
                        .init(id: AppearancePreference.dark, label: "深色"),
                    ], value: $appearance)
                }
                SettingsRow(title: "App 间距",
                            desc: "选中图标与两侧图标的距离。",
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
                SettingsRow(title: "登录时启动", desc: "关闭后需手动启动。") {
                    BeamSwitch(isOn: $store.launchAtLogin)
                }
                SettingsRow(title: "保持面板打开",
                            desc: "关闭后松开按键即确认,面板随之关闭。",
                            hairline: false) {
                    BeamSwitch(isOn: $pinPanel)
                }
                SettingsRow(title: "展示 Dock 常驻应用",
                            desc: "未启动的 Dock 应用排在面板尾部,选中即可启动。") {
                    BeamSwitch(isOn: $showLaunchables)
                }
                SettingsRow(title: "Tab 进入未启动区",
                            desc: "关闭后使用 ↓ 键进入。",
                            hairline: false) {
                    BeamSwitch(isOn: $tabEntersLaunchSection)
                }
            }

            SettingsGroup(label: "动效") {
                SettingsRow(title: "系统减弱动态效果") {
                    RowValue(systemReduced ? "已开启" : "未开启")
                }
                SettingsRow(title: "强制完整动效", desc: "关闭后遵循系统设置。") {
                    BeamSwitch(isOn: $alwaysAnimate)
                }
                SettingsRow(title: "高光效果", desc: "指针移动时的动态高光,以及图标上的明暗对比。") {
                    BeamSwitch(isOn: $sheen)
                }
                SettingsRow(title: "承接上次选中位置",
                            desc: "关闭后选中标记不再滑动,仅上浮。",
                            hairline: false) {
                    BeamSwitch(isOn: $slideFromLastApp)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        Group {
            // 品牌头(2026-09-18 用户:「面板就没有 glance 的图标」—— 设置页通篇没有 App 图标,
            // CodeIsland 有,惯例缺失):图标直接取 NSApplication 的实际图标(与 Finder/Dock 同源,
            // 换 AppIcon 资产时这里自动跟)。名称与版本并进这枚头 —— 原「版本信息」两行文字
            // 被它完全复述,按文案纪律第 1 条删除
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Glance")
                        .font(.system(size: 17, weight: .semibold))
                    Text("版本 \(bundle("CFBundleShortVersionString"))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 14)   // 左缘与 SettingsGroup 的组标题胶囊/行标题同线(都从 contentPadX 起步)
            SettingsGroup(label: "权限") {
                SettingsRow(title: "辅助功能", desc: "用于读取与聚焦窗口。缺失时切换器无法工作。") {
                    PermissionBadge(granted: permissions.accessibilityGranted)
                }
                SettingsRow(title: "屏幕录制", desc: "用于生成窗口预览。", hairline: false) {
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
    /// ` App 内切换窗口(默认关:它是系统级快捷键,只能用户显式开)
    @AppStorage("switch.graveCyclesWindows") private var graveCyclesWindows = false
    /// 双击 ⌥ 把指针送到另一块屏(默认关:macOS 无此功能 ⇒ 按"默认对齐 macOS"的规则是关)。
    /// 触发键曾是 ⌃,2026-09-17 因与 IDEA 快捷键打架改 ⌥;key 随之换名,不做旧值迁移。
    /// 落焦(键盘跟过去)是跳屏的固定语义,不再有子开关(T87 v2 用户裁定)
    @AppStorage("pointer.doubleOptionJumps") private var doubleOptionJumps = false
    /// 面板出现期间,滚轮/双指滑动是否换组(默认开:与 Tab 同义)
    @AppStorage("switch.scrollMovesSelection") private var scrollMovesSelection = true
    /// 换组速度(次/秒)。存**速度**而不是节流间隔:间隔与手感是倒数关系,
    /// 滑杆若线性映射到间隔,两端手感会严重不均(慢端几乎不动)。默认 10 = 原 0.10s。
    @AppStorage("panel.scrollSpeed") private var scrollSpeed: Double = 10

    var body: some View {
        Group {
            SettingsGroup(label: "触发") {
            SettingsRow(title: "双击 ⌥ 指针跳到另一块屏",
                        desc: "指针落在另一块屏正中间，键盘也跟着过去。") {
                BeamSwitch(isOn: $doubleOptionJumps)
            }
            SettingsRow(title: "滚动切换应用") {
                BeamSwitch(isOn: $scrollMovesSelection)
            }
            SettingsRow(title: "切换速度", hairline: false) {
                HStack(spacing: 10) {
                    // 照抄"App 间距"那一行的形状:裸 Slider(不用 step:)—— 带 step 的滑杆
                    // 会在轨道下方画一排刻度点,而本设计里没有任何刻度语言。
                    Slider(value: $scrollSpeed, in: 3...20)
                        .frame(width: 150)
                        .disabled(!scrollMovesSelection)      // 开关关掉时置灰:主从关系一眼可见
                        .opacity(scrollMovesSelection ? 1 : 0.4)
                        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                    Text("\(Int(scrollSpeed)) 次/秒")
                        .font(SettingsFont.rowValue)
                        .foregroundStyle(SettingsTheme.ink2)
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                        .opacity(scrollMovesSelection ? 1 : 0.4)
                }
            }
                SettingsRow(title: "接管系统 ⌘Tab",
                            desc: "关闭后使用 ⌥Tab,不改动系统设置,退出时还原。") {
                    BeamSwitch(isOn: takeoverBinding)
                }
                SettingsRow(title: "唤起即切换", desc: "关闭后停留在当前 App。") {
                    BeamSwitch(isOn: $advanceOnOpen)
                }
                SettingsRow(title: "触发键",
                            desc: "点击后按下新的组合键。修饰键支持 ⌥、⌘、⌃。",
                            hairline: false) {
                    Button {
                        recording ? stopRecording() : startRecording()
                    } label: {
                        KeyChip(text: recording ? "按下新组合…" : chip(config),
                                editable: true, highlighted: recording)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                    .help(recording ? "按 Esc 取消录制" : "点一下开始录制新的触发键")
                }
            }
            SettingsGroup(label: "导航") {
                SettingsRow(title: "App 内切换窗口", key: "`", desc: "在同一个 App 的窗口之间移动。") {
                    BeamSwitch(isOn: $graveCyclesWindows)
                }
                SettingsRow(title: "切换 App") { KeyChip(text: "Tab / ⇧ Tab") }
                SettingsRow(title: "切换窗口", desc: "仅有单个窗口时不响应。") {
                    KeyChip(text: "← →")
                }
                SettingsRow(title: "确认 / 放弃", hairline: false) {
                    KeyChip(text: "松开 " + config.modifierSymbol + " / Esc")
                }
            }
            SettingsGroup(label: "窗口操作") {
                SettingsRow(title: "退出 App / 关窗 / 最小化", desc: "操作完成后面板保持打开。") {
                    KeyChip(text: "Q / W / M")
                }
                SettingsRow(title: "全屏 / 隐藏 App", desc: "隐藏后应用仍在列表中,但不再显示窗口预览。",
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
