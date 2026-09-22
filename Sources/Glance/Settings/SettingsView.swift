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
        /// 本页的**组标题 = 侧栏子菜单**(2026-09-19 用户:「把每一个目录的一级菜单挪出来,
        /// 方便点击,不用用户在每个目录里找」)。顺序即页内顺序;锚点 id = "\(rawValue):\(组名)"。
        var groups: [String] {
            switch self {
            case .general: return ["外观", "实时预览", "应用与面板", "手势操控", "触感", "未启动环", "动效"]
            case .shortcut: return ["触发", "导航", "窗口操作"]
            case .about: return ["权限"]
            }
        }
        func anchor(_ group: String) -> String { "\(rawValue):\(group)" }
    }

    @State private var page: Page = .general
    /// 侧栏当前锚点(锚点 id = "\(页):\(组名)")。页行点击 = 切页 + 跳到该页第一组;
    /// 子菜单点击 = 页内滚动定位。nil = 不定位
    @State private var navSelection: String? = Page.general.anchor(Page.general.groups[0])
    /// 程序化滚动(点导航)之后的一小段"静默期":期间不把滚动位置回写成导航高亮(见 onChange 的注释)
    @State private var suppressNavSpyUntil: CFAbsoluteTime = 0
    /// 打开的未启动环名单编辑器(nil = 关着)。白/黑共用一个编辑器视图
    @State private var launchEditor: LaunchListEditor.Kind?
    @AppStorage(Keys.panelPinOnRelease) private var pinPanel = KeyDefaults.pinOnRelease
    /// 默认 true = 本 App 自己放行完整动效(macOS 没有 per-app 的 reduce-motion 豁免 API)
    @AppStorage(Keys.motionAlwaysAnimate) private var alwaysAnimate = KeyDefaults.alwaysAnimate
    /// App 间距:选中放大后与左右邻居之间**还剩**多少净空(pt)。间隙由它倒推
    /// (旧名"图标呼吸感"是内部黑话,2026-09-15 按用户口径改成"App 间距")
    @AppStorage(Keys.panelIconClearance) private var iconClearance: Double = 13
    /// 悬停触感(键名来自 `GlanceCore.HapticPolicy.defaultsKey` ✓ 一个源,不写两遍 ✓)
    /// 触感强度档("light"/"medium"/"strong")
    @AppStorage(Keys.hapticStrength) private var hapticStrength = "medium"
    @AppStorage(Keys.hapticEnabled) private var hapticEnabled = HapticPolicy.enabledDefault

    /// 实时预览档位(`live.previewTier` 是 **String** 型的既有键 ⇒ 这里换算,键名一个字不改 ✓)
    @State private var liveTier: Double = Double(LivePreviewPool.tierFps)
    private var tierBinding: Binding<Double> {
        Binding(get: { liveTier },
                set: { newValue in
                    liveTier = newValue.rounded()
                    // 写回既有键(档位只在"起流/换档"时被读 ⇒ 下一次路过即生效 ✓ 不用重启 ✓)
                    UserDefaults.standard.set(String(Int(liveTier)), forKey: Keys.livePreviewTier)
                })
    }
    /// 颜色外观:auto / light / dark(默认 auto = 跟随系统)
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.auto
    /// 启动区(方案 E):Dock 常驻且未启动的 App 在面板环尾展示。默认开(展示层新增,不抢任何按键)
    @AppStorage(Keys.panelShowLaunchables) private var showLaunchables = KeyDefaults.showLaunchables
    /// Tab 是否进未启动区(2026-09-18):默认开;关闭后段只能靠 ↓/↑ 进出
    @AppStorage(Keys.panelTabEntersLaunchSection) private var tabEntersLaunchSection = KeyDefaults.tabEntersLaunchSection
    // 手势开关(2026-09-19 入 UI):键已存在于现网(此前只能 defaults write),默认关
    @AppStorage(Keys.pointerThreeFingerTapPanel) private var threeFingerTapPanel = KeyDefaults.threeFingerTapPanel
    @AppStorage(Keys.pointerFourFingerTapLaunchRing) private var fourFingerTapLaunchRing = KeyDefaults.fourFingerTapLaunchRing
    /// 从上一个 App 滑过来(额外的一层入场动效;上浮是通用的那一层,永远在)
    /// 光效总闸:指针柔光 + 图标静态反光(默认开;开关是给不喜欢面板里有光的人)
    @AppStorage(Keys.panelSheen) private var sheen = KeyDefaults.sheen
    /// 系统"减弱动态效果"的实时值(改完系统设置回来重开这个面板即可刷新)
    @State private var systemReduced = MotionPolicy.systemReduced

    var body: some View {
        VStack(spacing: 0) {
            prismEdge
            HStack(spacing: 0) {
                // 左侧目录:页面行 + 当前页的组子菜单(点了直接跳组,不用页内翻找)
                SettingsTabRail(page: $page, selection: $navSelection)
                    .padding(.top, SettingsMetrics.tabsTop + SettingsMetrics.railTopClear)
                    .padding(.bottom, SettingsMetrics.tabsBottom)
                    .frame(width: SettingsMetrics.sidebarW, alignment: .top)
                // 目录与内容之间一道发丝(行 hairline 的同款色,不做新语言)
                Rectangle()
                    .fill(SettingsTheme.hairline)
                    .frame(width: SettingsMetrics.hairline)
                    .padding(.vertical, SettingsMetrics.tabsTop)
                content
            }
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
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)   // ★ 窗口根:焦点环全窗禁用
        // ★ 名单编辑器的弹出点挂在**窗口根**:曾深挂在 ScrollView 内的组上 ——
        //   macOS 上滚动容器内的 sheet 有"首击不弹,得点两次"的怪癖(2026-09-19 用户实报)
        .sheet(item: $launchEditor) { kind in
            LaunchListEditor(kind: kind)
        }
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
        ScrollViewReader { proxy in
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
            // **关掉到顶回弹**(2026-09-19,用户录屏自诊:「滚到头之后回弹不顺畅,一卡一卡的」):
            // 帧账证明滚动期主线程很闲(P95 8.4ms@120Hz),磕绊出在系统橡皮筋动画本身的节奏,
            // App 摸不到它 —— 那就不要回弹:惯性到顶后顺滑减速停住。SwiftUI 没有这个开关,
            // 借 background 钩子摸到底下的 NSScrollView 关竖向弹性
            .background(ScrollElasticityHook())
            // **顶部预留带**(2026-09-19,用户实报「滚动的时候还是到顶了」):视口顶部常驻
            // 18pt 纸色渐隐 —— 手动滚动时组标题最多走到带下沿才开淡出,不再顶到棱镜边;
            // 锚点 scrollTo 的落点也在带下方(导航与手动滚动共用同一条边距,spec §2)
            .safeAreaInset(edge: .top, spacing: 0) {
                LinearGradient(colors: [SettingsTheme.paper, SettingsTheme.paper.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: SettingsMetrics.scrollTopPad)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            // 侧栏子菜单点了 ⇒ 滚到对应组(锚点 id 由 SettingsGroup 挂)
            .onChange(of: navSelection) { _, sel in
                guard let sel else { return }
                // ★ 记下"这是程序化滚动":接下来 0.4s 内**不许**回写 navSelection,
                //   否则回写会再触发本 onChange ⇒ 自己和自己打架(来回抖)✗
                suppressNavSpyUntil = CFAbsoluteTimeGetCurrent() + 0.4
                withAnimation(MotionPolicy.animation(SettingsMotion.puck)) {
                    proxy.scrollTo(sel, anchor: .top)
                }
            }
            // ★ 反向:**滚动 → 左侧导航跟着走**(2026-09-22 用户实报后新增;此前只有单向 ✓→✗)
            .coordinateSpace(name: SettingsScrollSpace.name)
            .onPreferenceChange(GroupOffsetKey.self) { offsets in
                guard CFAbsoluteTimeGetCurrent() > suppressNavSpyUntil else { return }   // 程序化滚动期间不回写
                // 顶部预留带(scrollTopPad)下方 40pt 视为"已进入这一组"⇒ 在越过的组里取**最靠下**的那个 = 当前组 ✓
                let passed = offsets.filter { $0.value <= 40 }
                let current = passed.max { $0.value < $1.value }?.key
                    ?? offsets.min { $0.value < $1.value }?.key          // 一个都没越过(最顶上)⇒ 取最靠上的
                if let current, navSelection != current { navSelection = current }
            }
        }
    }

    // MARK: - 通用

    private var generalPane: some View {
        Group {
            SettingsGroup(label: "外观", anchor: Page.general.anchor("外观")) {
                SettingsRow(title: "颜色外观", desc: "面板与设置窗口同步生效。") {
                    BeamSegmented(options: [
                        .init(id: AppearancePreference.auto, label: "自动"),
                        .init(id: AppearancePreference.light, label: "浅色"),
                        .init(id: AppearancePreference.dark, label: "深色"),
                    ], value: $appearance)
                }
                // ★ 2026-09-22 结构整理:"高光效果"是**外观**(指针高光 + 图标明暗),不是动效 ✗
                //   ⇒ 从"动效"挪进"外观" ✓(它的实现细节请看 SettingsRow 自己的 desc)
                SettingsRow(title: "高光效果", desc: "指针移动时的动态高光,以及图标上的明暗对比。") {
                    BeamSwitch(isOn: $sheen)
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

            // ★ 2026-09-22 用户实报「你刚才加的帧率控制,为什么会在外观这一级」✗
            //   —— 实时预览是**行为/性能**档位,不是外观 ⇒ 从"外观"搬出来独立成组 ✓
            //   键名不换(`live.previewTier`,String 型现存值 "0"/"10" 原样继承 ✓)
            SettingsGroup(label: "实时预览", anchor: Page.general.anchor("实时预览")) {
                // ★ 2026-09-22 用户要求:「现在 live 是开着的吗, 做成设置, 给几个档位,
                //   用bar控制, 0 代表关闭, 最大 30fps」。
                //   键名不换(`live.previewTier`,String 型现存值 "0"/"10" 原样继承 ✓)
                //   档位 = 0(关) / 5 / 10 / 15 / 20 / 25 / 30;选中那一条用这个档位,
                //   其余窗口恒 5fps(见 LivePreviewPool 的分档)。
                SettingsRow(title: "实时预览",
                            desc: "面板里显示窗口的实时画面。0 = 关闭,改完下一次路过即生效。") {
                    HStack(spacing: 8) {
                        Slider(value: tierBinding, in: 0...30, step: 5)
                            .controlSize(.small)
                            .frame(width: 150)
                            .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                        Text(liveTier > 0 ? "\(Int(liveTier)) fps" : "关")
                            .font(SettingsFont.rowValue)
                            .foregroundStyle(SettingsTheme.ink2)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            // 原"启动与行为":去掉两条属于"未启动环"的行之后,这组只剩"应用/面板的生命周期" ✓
            // ⇒ 改名为「应用与面板」(名字里不再兜着别的东西)
            SettingsGroup(label: "应用与面板", anchor: Page.general.anchor("应用与面板")) {
                SettingsRow(title: "登录时启动", desc: "关闭后需手动启动。") {
                    BeamSwitch(isOn: $store.launchAtLogin)
                }
                SettingsRow(title: "保持面板打开",
                            desc: "关闭后松开按键即确认,面板随之关闭。",
                            hairline: false) {
                    BeamSwitch(isOn: $pinPanel)
                }
            }

            // **手势操控**(2026-09-19,用户:「这次也做成开关吧」):两枚真开关直读既有
            // defaults 键 —— 此前这两个功能只能 `defaults write` 开,没有 UI(病例:另一台
            // 机器装完 0.3.2 三指四指"根本唤不起来",真凶是 UserDefaults 每机独立、新机
            // 全默认关)。键名不换:已装机用户的现网值原样继承;UserDefaults 直读 = 改了
            // 立即生效,不重启(手势层每次事件都现读)
            SettingsGroup(label: "手势操控", anchor: Page.general.anchor("手势操控")) {
                SettingsRow(title: "三指点按唤起面板",
                            desc: "三指轻点触控板唤起切换面板,该局不随松手散场。") {
                    BeamSwitch(isOn: $threeFingerTapPanel)
                }
                SettingsRow(title: "四指点按进未启动环",
                            desc: "四指轻点触控板,唤起并直接进入未启动环。",
                            hairline: false) {
                    BeamSwitch(isOn: $fourFingerTapLaunchRing)
                }
            }

            // ★ 2026-09-22 用户要求:「hover 震动,app 和预览容器都需要, 做成设置开关」。
            //   策略层**早就写好了**(`GlanceCore.HapticPolicy`:只有 hover 类事件会震,其余事件的反馈
            //   交给视觉脉冲 —— 2026-09-20 用户自己裁定的 ✓);缺的是"触发点"与"设置里这一行" ✗
            //   两个面(环上的 App / 托盘里的窗口)共用**一个**开关:对人是同一件事
            //   ("指针挪到别的东西上了")⇒ 拆成两条只会让人多读一行 ✓(要拆随时说 ✓)
            SettingsGroup(label: "触感", anchor: Page.general.anchor("触感")) {
                SettingsRow(title: "悬停触感",
                            desc: "指针移到环上的 App、或托盘的窗口上时,触控板震一下。") {
                    BeamSwitch(isOn: $hapticEnabled)
                }
                // ★ 2026-09-22 用户报「没感受到震感, 是不是强度太低了」——
                //   实话:触感 API **没有强度参数**,只有三档离散手感;而且**设备差异比档位差异还大**
                //   (同一档:外接板很弱、内置板清晰)。所以把档位摆出来,你自己按手感和设备选 ✓
                SettingsRow(title: "触感强度",
                            desc: "触感只有这三档(没有更细的强度可调);设备不同,手感差别很大。",
                            hairline: false) {
                    BeamSegmented(options: HapticStrength.allCases.map { .init(id: $0.rawValue, label: $0.label) },
                                  value: $hapticStrength)
                }
            }

            // 原"未启动环名单"只装白/黑名单 ⇒ 而"哪些 App 会进环""Tab 能不能跨段"被拆在别的组 ✗
            // ⇒ 合成一组「未启动环」:**关于这个环的一切都在这儿** ✓
            SettingsGroup(label: "未启动环", anchor: Page.general.anchor("未启动环")) {
                SettingsRow(title: "展示 Dock 常驻应用",
                            desc: "未启动的 Dock 应用排在面板尾部,选中即可启动。") {
                    BeamSwitch(isOn: $showLaunchables)
                }
                SettingsRow(title: "Tab 进入未启动区",
                            // 2026-09-22 补：原小字只写了“怎么进”，没写“怎么回” ⇒ 用户关掉开关后以为
                            // “未启动段进不去 / 出不来”（实为 Tab 不再跨段，进出口改由 ↓/↑ 承担）。
                            // 面向用户的文案纪律：**一个开关把哪条路改掉了，就要把新的进出口写出来**。
                            desc: "关闭后改用 ↓ 进入未启动区、↑ 返回（四指轻点可直接进入）。") {
                    BeamSwitch(isOn: $tabEntersLaunchSection)
                }
                SettingsRow(title: "白名单",
                            desc: "不在 Dock 常驻的 App 也会进未启动环。") {
                    listCountButton(.whitelist)
                }
                SettingsRow(title: "黑名单",
                            desc: "即使 Dock 常驻也不进未启动环。",
                            hairline: false) {
                    listCountButton(.blacklist)
                }
            }


            SettingsGroup(label: "动效", anchor: Page.general.anchor("动效")) {
                SettingsRow(title: "系统减弱动态效果") {
                    RowValue(systemReduced ? "已开启" : "未开启")
                }
                SettingsRow(title: "强制完整动效", desc: "关闭后遵循系统设置。") {
                    BeamSwitch(isOn: $alwaysAnimate)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        Group {
            // 品牌头(2026-09-19 二修,布局听用户的):**大图标独占一排、左右居中**,
            // 距上方留一点高度;下面才是正常的文字内容(名称/版本行 + 权限组)。
            // 图标直接取 NSApplication 的实际图标(与 Finder/Dock 同源,换资产自动跟)
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
            .frame(maxWidth: .infinity)   // 左右居中
            .padding(.top, 18)            // "距离上方有一点点的高度"
            .padding(.bottom, 6)          // 图标与文字之间只留呼吸:外层 VStack 的 groupGap 会再垫一层,这里给多了就空
            HStack(spacing: 0) {
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
            SettingsGroup(label: "权限", anchor: Page.about.anchor("权限")) {
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

    /// 名单行尾部的操作入口:描边胶囊「N 个 ›」—— 之前的裸数字读不出"能点",
    /// 用户实评「你倒是给我添加操作入口啊」。胶囊 = 这一页"可点"的通用暗示,不另立语言。
    private func listCountButton(_ kind: LaunchListEditor.Kind) -> some View {
        Button {
            launchEditor = kind
        } label: {
            HStack(spacing: 5) {
                Text("\(DockAppsProvider.listCount(forKey: kind.defaultsKey)) 个")
                    .font(SettingsFont.rowValue)
                    .foregroundStyle(SettingsTheme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline)
            )
            // ★ 描边胶囊内部是透明的,SwiftUI 命中测试只认不透明像素 ——
            //   不补 contentShape 的话只有文字能点(用户实报「只能点到 4 上面」)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
    }
}

/// 借 background 钩子摸到 SwiftUI `ScrollView` 底下的 NSScrollView,关掉竖向橡皮筋。
/// 为什么要摸(2026-09-19,用户录屏自诊):设置窗滚动到顶的回弹"一卡一卡的" —— 帧账
/// (FrameProbe)证明滚动期主线程很闲,磕绊出在系统弹性动画的节奏本身,SwiftUI 又
/// 不给关它的开关;`verticalScrollElasticity = .disallowed` 后惯性到顶顺滑减速停住。
/// 只动竖向(本页没有横向滚动),不动其它 App 的任何滚动行为
private struct ScrollElasticityHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            var p: NSView? = superview
            while let v = p {
                if let sv = v as? NSScrollView {
                    sv.verticalScrollElasticity = .none
                    return
                }
                p = v.superview
            }
        }
    }
}

// MARK: - 未启动环名单(白/黑名单,2026-09-19)

/// 名单编辑器:白/黑共用一套骨架,只有文案与存取 key 不同。
/// 条目行内 − 删除;「添加 App…」弹选择器。**两名单互斥由选择器保证** ——
/// 已在对方名单的 App 根本不出现(用户裁定,spec note 6),冲突从根上不发生。
private struct LaunchListEditor: View {
    enum Kind: String, Identifiable {
        case whitelist, blacklist
        var id: String { rawValue }
        var title: String { self == .whitelist ? "白名单" : "黑名单" }
        var desc: String {
            self == .whitelist ? "这些 App 不在 Dock 常驻也会进未启动环。"
                               : "这些 App 即使 Dock 常驻也不进未启动环。"
        }
        var defaultsKey: String { "launch.\(rawValue)" }
        /// 对方名单的 key:选择器的排除集 = 两名单并集
        var otherKey: String { self == .whitelist ? "launch.blacklist" : "launch.whitelist" }
    }

    let kind: Kind
    @State private var ids: [String] = []
    @State private var showingPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TrafficLightClose { dismiss() }
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            Text(kind.title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            Text(kind.desc)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 4)
            if ids.isEmpty {
                Text("还没有 App。点下面「添加 App…」挑一个。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(ids, id: \.self) { id in
                            listRow(id)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 10)
            }
            HStack {
                Button {
                    showingPicker = true
                } label: {
                    Text("添加 App…")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                // 蓝框 = 系统焦点环(2026-09-19 用户:「不要这个蓝框」);这一页的按钮都不吃焦点
                .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 380, alignment: .topLeading)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)   // ★ sheet 根   // 内容从左上起,不再垂直居中悬着
        .onAppear { ids = UserDefaults.standard.stringArray(forKey: kind.defaultsKey) ?? [] }
        .sheet(isPresented: $showingPicker) {
            AppPicker(exclude: Self.combinedIDs(except: kind)) { id in
                ids.append(id)
                save()
            }
        }
    }

    private func listRow(_ id: String) -> some View {
        let app = DockAppsProvider.resolvedApp(id)
        return HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5))
                Text(app.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                ids.removeAll { $0 == id }
                save()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled(!SettingsTheme.showsFocusRing)
            .help("从名单移除")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func save() {
        DockAppsProvider.setList(ids, forKey: kind.defaultsKey)
    }

    /// 两名单并集(去掉自己这边的)—— 选择器的排除集,互斥的实现点
    static func combinedIDs(except kind: Kind) -> Set<String> {
        var all = Set(UserDefaults.standard.stringArray(forKey: kind.otherKey) ?? [])
        all.formUnion(UserDefaults.standard.stringArray(forKey: kind.defaultsKey) ?? [])
        return all
    }
}

/// 应用选择器:扫 /Applications 与 /System/Applications(两级深),图标 + 名称 + 搜索。
/// 已在任一名单里的 App 不出现(互斥);本 App 自己也不出现(把自己加进未启动环没有意义)。
private struct AppPicker: View {
    let exclude: Set<String>
    let onAdd: (String) -> Void
    @State private var query = ""
    @State private var apps: [DockAppsProvider.InstalledApp] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 左上角关闭钮 = 公共红绿灯单灯(与窗口红绿灯同一套语言)
                TrafficLightClose { dismiss() }
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            Text("添加 App")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            TextField("搜索", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                // 搜索收窄到**唯一**一个 App 时,回车直接收录(2026-09-19 用户要求)
                .onSubmit {
                    if filtered.count == 1 {
                        onAdd(filtered[0].id)
                        dismiss()
                    }
                }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { app in
                        row(app)
                    }
                    if filtered.isEmpty {
                        Text("没有匹配的 App")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.top, 10)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled(!SettingsTheme.showsFocusRing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 420)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)   // ★ sheet 根
        .onAppear { apps = DockAppsProvider.scanInstalledApps() }
    }

    private var filtered: [DockAppsProvider.InstalledApp] {
        apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func row(_ app: DockAppsProvider.InstalledApp) -> some View {
        Button {
            onAdd(app.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                    Text(app.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 快捷键页:录制式改键(Q8 冻结)。按一下胶囊进录制态,下一次"修饰键+普通键"
/// 即写入;Esc 取消。只允许 ⌥/⌘/⌃ 当修饰键 —— ⇧ 永久留给反向导航。
struct ShortcutPane: View {
    @AppStorage(Keys.panelSlideFromLastApp) private var slideFromLastApp = KeyDefaults.slideFromLastApp
    /// 接管系统 ⌘`(opt-in,默认关 ⇒ 关着时一个字都不变 ✓)
    @AppStorage(Keys.triggerTakeoverGraveCyclesWindows) private var graveTakeover = KeyDefaults.takeoverGraveCyclesWindows

    @State private var config = TriggerConfig.load()
    @State private var recording = false
    @State private var monitor: Any?
    /// 唤起落点:true(默认,macOS 原生)= 直接切一次(上一个 App);false = 只定位到当前 App
    @AppStorage(Keys.switchAdvanceOnOpen) private var advanceOnOpen = KeyDefaults.advanceOnOpen
    /// 颜色外观:auto / light / dark(见 AppearancePreference)
    /// ` App 内切换窗口(默认关:它是系统级快捷键,只能用户显式开)
    @AppStorage(Keys.switchGraveCyclesWindows) private var graveCyclesWindows = KeyDefaults.graveCyclesWindows
    /// 双击 ⌥ 把指针送到另一块屏(默认关:macOS 无此功能 ⇒ 按"默认对齐 macOS"的规则是关)。
    /// 触发键曾是 ⌃,2026-09-17 因与 IDEA 快捷键打架改 ⌥;key 随之换名,不做旧值迁移。
    /// 落焦(键盘跟过去)是跳屏的固定语义,不再有子开关(T87 v2 用户裁定)
    @AppStorage(Keys.pointerDoubleOptionJumps) private var doubleOptionJumps = KeyDefaults.doubleOptionJumps
    /// 面板出现期间,滚轮/双指滑动是否换组(默认开:与 Tab 同义)
    @AppStorage(Keys.switchScrollMovesSelection) private var scrollMovesSelection = KeyDefaults.scrollMovesSelection
    /// 换组速度(次/秒)。存**速度**而不是节流间隔:间隔与手感是倒数关系,
    /// 滑杆若线性映射到间隔,两端手感会严重不均(慢端几乎不动)。默认 10 = 原 0.10s。
    @AppStorage(Keys.panelScrollSpeed) private var scrollSpeed: Double = 10

    var body: some View {
        Group {
            SettingsGroup(label: "触发", anchor: SettingsView.Page.shortcut.anchor("触发")) {
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
                // ★ 2026-09-22 用户要求:「能拦截系统的 cmd+`(只在当前屏幕内容的同类型app跳转)」
                //   「开放到设置面板上,我自己调试」⇒ 两个旋钮都摆在这里 ✓
                SettingsRow(title: "接管系统 ⌘`",
                            // ★ 2026-09-22 用户裁掉了"以哪块屏为准"这个配置项 ⇒ 口径只留一种,
                            //   小字就必须把这一种说清楚(不然又是一个"要试才知道"的开关 ✗)
                            desc: "关闭时 ⌘` 交给系统(会在所有屏幕的同 App 窗口间跳)。"
                                + "打开后只在你**当前正在用的那块屏**里跳,与鼠标指针无关。") {
                    BeamSwitch(isOn: $graveTakeover)
                }
                SettingsRow(title: "唤起即切换", desc: "关闭后停留在当前 App。") {
                    BeamSwitch(isOn: $advanceOnOpen)
                }
                // ★ 2026-09-22 结构整理:它不是"动效",是**唤起落点**(与上一行同一件事)✗
                //   ⇒ 从通用页的"动效"挪到快捷键页的"触发",紧挨"唤起即切换" ✓
                //   ⚠️ 搬运当次把它**嵌进了上一行的尾部控件位** ✗(编译得过,渲染是错的 ——
                //      行会套在另一行里)。这里改回**兄弟行**,并把发丝线交回来(它后面还有「触发键」)✓
                SettingsRow(title: "承接上次选中位置",
                            desc: "关闭后选中标记不再滑动,仅上浮。") {
                    BeamSwitch(isOn: $slideFromLastApp)
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
            SettingsGroup(label: "导航", anchor: SettingsView.Page.shortcut.anchor("导航")) {
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
            SettingsGroup(label: "窗口操作", anchor: SettingsView.Page.shortcut.anchor("窗口操作")) {
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
                    UserDefaults.standard.set(0x30, forKey: Keys.triggerKeyCode)
                    UserDefaults.standard.set("command", forKey: Keys.triggerModifier)
                    TriggerConfig.setTakeover(true)
                } else {
                    UserDefaults.standard.removeObject(forKey: Keys.triggerKeyCode)
                    UserDefaults.standard.removeObject(forKey: Keys.triggerModifier)
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
            UserDefaults.standard.set(Int(event.keyCode), forKey: Keys.triggerKeyCode)
            UserDefaults.standard.set(mod, forKey: Keys.triggerModifier)
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
