import SwiftUI

/// 滚动视图的命名坐标系(组标题的位置都在这个坐标系里量)
enum SettingsScrollSpace { static let name = "settingsScroll" }

/// 设置窗的可复用件(demo 的 `.group` / `.row` / `.switch` / `.key` / `.tabs` 逐一对应)。
///
/// demo 是数据驱动渲染(`panes` 数组 + `rowHTML`),原生不做那一层:设置项自带 Binding、
/// 录制键自带 State,数据表反而要把状态搬进模型。这里保留 demo 的**结构**:
/// 组(可选小标题)→ 行(标题 + 说明 + 尾部控件 + 发丝)。

// MARK: - 组

/// demo `.group` + `.group-label`:一叠行,可选一枚小圆点 + 小标题。
/// 组间距由父级 `VStack(spacing: SettingsMetrics.groupGap)` 给,组自身不加下边距。
/// **滚动 → 左侧导航跟着走**(2026-09-22 用户实报「设置面板滑动, 左侧导航不会跟着移动」)。
///
/// 原来只有**单向**:点导航 ⇒ `scrollTo` 滚内容 ✓;反过来没人做 ✗
/// (整个 Settings 目录里没有任何 PreferenceKey/GeometryReader 回写机制 ✓)。
/// 口径:各组标题把自己在滚动坐标系里的 minY 报上来,外层挑"已越过顶部预留带、且离它最近"的那一组
/// ⇒ 高亮它 ✓。**汇报用的 id 就是 `SettingsGroup.anchor`**(与导航点击同一个字符串 ✓ 不会对不上)。
struct GroupOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// **内容底部哨兵**(2026-10-09 用户实报:「我已经滑动到最底部了, 但是导航到不了最后一个」)
///
/// 病例(附截图):上面那套"滚动 → 导航跟着走"取的是"**已越过顶部预留带**的组里最靠下的那个" ✓,
///   可**最后一组永远到不了那条线** —— 它下面没内容了 ✗ ⇒ 滑到底时导航停在**倒数第二组** ✗
///   (截图里:左侧停在「未启动环」,而右侧内容已经停在「动效」= 最后一组 ✓)。
/// 口径:把"内容真正的底"报上来,与**视口高度**一比就知道到底没有 ✓
///   两个哨兵都是零布局成本(`.background` + `Color.clear` ✓)
struct ContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// 视口高度(ScrollView 自己的 frame)—— 与 `ContentBottomKey` 一起判"到底了没有" ✓
struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SettingsGroup<Content: View>: View {
    var label: String? = nil
    /// 组标题旁的可选图标（SF Symbols），增加分组辨识度与呼吸感。
    var icon: String? = nil
    /// 侧栏子菜单的滚动锚点(锚点 id = "\(页):\(组名)");nil = 不参与定位
    var anchor: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组前留白:组间距的另一半(父级组间距 8 + 本段 18 = 26,常态视觉不变)。
            // ⚠️ 锚点 id **不挂在这里**(2026-09-19 二修,用户实评「点击导航过去上面空白留得太多」):
            // 视口顶部另有 18pt 预留带(scrollTopPad),id 挂留白的话导航落点 = 18+18 = 36pt,
            // 空得突兀。id 挂在**标题**上 ⇒ 导航落点 = 预留带 18pt,与手动滚动的边距同一条
            Color.clear.frame(height: SettingsMetrics.anchorHeadroom)
            if let label {
                // 组标题 = 一级标题(2026-09-19 三修):**16pt bold + 行首一道墨色短标**,
                // 与行标题严格同线,层级不靠边框靠字号 + 记号
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(SettingsTheme.beam)
                        .frame(width: 3, height: 13)
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SettingsTheme.ink)
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.ink2.opacity(0.75))
                    }
                }
                .padding(.bottom, SettingsMetrics.labelGap)
                .id(anchor)   // 锚点 = 标题本体(无标题的组不参与定位)
                // 把标题位置报给外层(滚动 → 导航跟手)。量的是**标题本体**,
                // 与 `.id(anchor)` 同一处 ⇒ 落点/高亮同一条边距 ✓
                .background(
                    GeometryReader { geo in
                        // anchor 是可选:无锚点的组**不汇报**(与"不参与定位"同一口径 ✓)
                        let y = geo.frame(in: .named(SettingsScrollSpace.name)).minY
                        Color.clear.preference(key: GroupOffsetKey.self,
                                               value: anchor.map { [$0: y] } ?? [:])
                    }
                )
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 行

/// demo `.row`:左一列(标题 + 可选说明)+ 右侧尾部控件,底部一条发丝。
///
/// `hairline` 由调用方给:demo 是 `.group .row:last-child{border-bottom:none}`,
/// SwiftUI 里没有"我是最后一个子视图"的查询,与其搞一层序号推导,不如显式标注。
struct SettingsRow<Trailing: View>: View {
    let title: String
    /// 标题前挂一枚键位胶囊(如 ` App 内切换窗口)。
    ///
    /// 2026-09-15 病例:原来是裸字符「` 循环窗口」—— 用户实评"可能不知道 ` 是什么,
    /// 还以为是手抖打多了字符"。裸反引号在正文里没有"这是个按键"的体量,
    /// 包成胶囊后才和 `← →`、`Tab / ⇧Tab` 那些键位**同一种语言**。
    var key: String? = nil
    /// 一句话说清"关掉会怎样",不解释实现。**别写 Markdown**:它是 `String`,
    /// `Text(_: some StringProtocol)` 不解析,`**加粗**` 会把星号原样印在纸上。
    var desc: String? = nil
    var hairline: Bool = true
    @ViewBuilder var trailing: Trailing
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: SettingsMetrics.rowGap) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        if let key { KeyChip(text: key) }
                        Text(title)
                            .font(SettingsFont.rowTitle)
                            .foregroundStyle(SettingsTheme.ink)
                    }
                    if let desc {
                        Text(desc)
                            .font(SettingsFont.rowDesc)
                            .foregroundStyle(SettingsTheme.ink2)
                            .lineSpacing(4) // demo line-height:1.55 @ 11.5px
                            // 硬上限两行:设置项不是文档,超了说明该写进代码注释而不是 UI
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: SettingsMetrics.descMaxW, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.vertical, SettingsMetrics.rowPadY)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? SettingsTheme.tabRail : .clear)
                    .padding(.horizontal, -8)
                    .padding(.vertical, 2)
            }
            .onHover { over in
                // hover 淡底走 `SettingsMotion.hover`(2026-11-25:原来这里是一条裸 `.easeOut(0.14)`,
                // 绕过 token ⇒ 改 hover 手感时要改两处;收回 `SettingsMotion.hover` 后一处生效 ✓)
                withAnimation(MotionPolicy.animation(SettingsMotion.hover)) { hovered = over }
            }

            if hairline {
                Rectangle()
                    .fill(SettingsTheme.hairline)
                    .frame(height: SettingsMetrics.hairline)
            }
        }
    }
}

/// demo `.row-value`:右侧纯文本值(未开启 / 1.0.0 / 已授权)。
struct RowValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SettingsFont.rowValue)
            .monospacedDigit()   // 版本号这类数字右对齐时不跳字
            .foregroundStyle(SettingsTheme.ink2)
    }
}

/// demo `.key`:等宽键位胶囊。**两副相貌,别混用**。
///
/// 2026-09-15 病例(用户实拍):`Tab / ⇧ Tab`、`Q / W / M` 这些只是**键位说明**,
/// 而「触发键」那枚是**能点进去改**的 —— 两者长得一模一样,用户点说明没反应,以为是 bug。
/// 修法:把"能不能改"从**芯片自己身上**说出来 ——
/// · 只读(默认):**无边框** + 文字 `ink2` + 底色减半 = 禁用相貌;
/// · 可改(`editable`,只有触发键):底色足、文字上墨色、**常驻一圈强调色描边**;
/// · 录制中(`highlighted`):描边打满 —— 描边在 = 能改,描边满 = 正在录。
struct KeyChip: View {
    let text: String
    /// 这枚键位**能不能改**(只有「触发键」那枚是 true)
    var editable: Bool = false
    /// 正在录制(只在 editable 时有意义)
    var highlighted: Bool = false

    var body: some View {
        Text(text)
            .font(SettingsFont.key)
            .foregroundStyle(highlighted ? SettingsTheme.beam
                                         : (editable ? SettingsTheme.ink : SettingsTheme.ink2))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SettingsTheme.keyBg.opacity(editable ? 1 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsTheme.beam, lineWidth: SettingsMetrics.hairline)
                    // 描边在 = 能改;描边满 = 正在录。只读的那枚一根线都没有
                    .opacity(highlighted ? 1 : (editable ? 0.4 : 0))
            )
            // 录制点灯/熄灭:描边、底色、前景色一起柔和过渡(参数驱动 ⇒ 减少动效下也在演 ✓)
            // 挂在最外层,一处覆盖上面三处色值
            .animation(MotionPolicy.animation(SettingsMotion.status), value: highlighted)
    }
}

/// 权限状态徽标。绿/橙是**状态语义**,不是装饰色:与 `PermissionGuideView` 同一套口径。
struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(granted ? "已授权" : "未授权")
                .font(SettingsFont.rowValue)
                .foregroundStyle(SettingsTheme.ink2)
                // 文字换内容时交叉淡化(不是硬跳);与圆点变色同一条曲线、同一拍 ✓
                .contentTransition(.opacity)
        }
        // 授权状态是**异步到达**的(系统弹窗点完之后才变):平滑过渡才不会读成"闪了一下" ✓
        .animation(MotionPolicy.animation(SettingsMotion.status), value: granted)
    }
}

// MARK: - 开关

/// demo `.switch`:关闭是玻璃灰轨道,打开是那条唯一的强调蓝。
/// 自绘而非 `Toggle(.switch)`:原生开关是 51×31 的固定尺寸,跟这张纸的行节奏不成比例
/// (demo 是 34×20 的小号),且 macOS 原生开关没有"轨道染色"这一档。
///
/// **2026-11-25 补物理手感**(覆盖全设置页 19 个开关):hover 轨道提亮 + 按住时拨杆**横向拉宽**。
/// 拉宽而不是等比放大,是与原生 iOS/macOS 拨杆对齐的做法:按住那一刻读作"捏住了它",
/// 松手后胶囊先收回圆形、再弹到另一端 ✓
struct BeamSwitch: View {
    @Binding var isOn: Bool

    private var travel: CGFloat {
        SettingsMetrics.switchW - SettingsMetrics.switchKnob - SettingsMetrics.switchInset * 2
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            // 视觉全部在 `BeamSwitchStyle` 里画:按下态只有 ButtonStyle 拿得到
            // (SwiftUI 没有"正在按下"的环境值;拿 `LongPressGesture` 拼会在快速连点时丢事件 ✗)
            Color.clear.frame(width: SettingsMetrics.switchW, height: SettingsMetrics.switchH)
        }
        .buttonStyle(BeamSwitchStyle(isOn: isOn, travel: travel))
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
        .accessibilityLabel(isOn ? "已开启" : "已关闭")
    }
}

/// 开关本体的画法(按下拉宽 + hover 提亮)。独立成类型只为拿到 `configuration.isPressed` ✓
private struct BeamSwitchStyle: ButtonStyle {
    let isOn: Bool
    let travel: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Knob(configuration: configuration, isOn: isOn, travel: travel)
    }

    private struct Knob: View {
        let configuration: Configuration
        let isOn: Bool
        let travel: CGFloat
        @State private var hovering = false

        /// 按住时多出来的 4pt(原生拨杆同样是 16 → 20 那一档)
        private var stretch: CGFloat { configuration.isPressed ? 4 : 0 }
        private var knobWidth: CGFloat { SettingsMetrics.switchKnob + stretch }
        /// 拉宽的左缘:**靠向哪一端由 isOn 决定** —— 开着时右缘不动(向左长),关着时左缘不动 ✓
        /// (居中向两边长会读成"变胖",不是"被捏住")
        private var knobOffsetX: CGFloat {
            let resting = isOn ? SettingsMetrics.switchInset + travel : SettingsMetrics.switchInset
            return isOn ? resting - stretch : resting
        }

        var body: some View {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? SettingsTheme.beam : SettingsTheme.trackOff)
                    // hover:轨道叠一层薄白 + 一圈极浅投影 = "这里有反应"的物理反馈
                    .overlay(Capsule().fill(Color.white.opacity(hovering ? 0.10 : 0)))
                    .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 2, y: 1)
                    // ★ 2026-10-08:同上 —— 设置面板自己的动效也必须归 Glance 的开关管 ✓
                    .animation(MotionPolicy.animation(SettingsMotion.tint), value: isOn)
                    .animation(MotionPolicy.animation(SettingsMotion.hover), value: hovering)
                // 拨杆:静止时宽=高 ⇒ 就是个圆;Capsule 只是为了能横向拉长
                Capsule()
                    .fill(.white)
                    .frame(width: knobWidth, height: SettingsMetrics.switchKnob)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .offset(x: knobOffsetX)
                    .animation(MotionPolicy.animation(SettingsMotion.knob), value: isOn)
                    .animation(MotionPolicy.animation(SettingsMotion.press), value: configuration.isPressed)
            }
            .frame(width: SettingsMetrics.switchW, height: SettingsMetrics.switchH)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - 窗口本身

/// 内容区盖不到的那两件事,只能落到窗上:
/// 1. **窗口底色**:`.frame(600×H)` 只是内容,窗口比它高出一条标题栏,不刷底会露白边;
/// 2. **整张纸可拖**:无标题栏窗口若只能拖顶上一条,手感是残的(控件自己会吃掉手势,无误拖);
/// 3. **开窗无位移居中 + 内容自适应重居中**:首帧未就位前先按 `alpha=0` 完成布局并落到光标屏正中,
///    消除先出现在旧位/角落再 0.1s 跳回屏中的闪烁;后续内容尺寸变化(`didResize`)同步保居中。
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.apply() }

    final class ChromeView: NSView {
        private var closeObserver: NSObjectProtocol?
        private var resizeObserver: NSObjectProtocol?
        private weak var configuredWindow: NSWindow?
        private var isCentering = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 窗关闭时 SwiftUI 先把本视图摘离窗口(willClose 通知因此没人收 —— 实测),
            // 摘离这一刻就是收工信号
            if window == nil {
                if closeObserver != nil {
                    print("[帧] 设置探针 收工(视图摘离窗口)")
                    FrameProbe.shared.stop()
                }
                teardownObservers()
                configuredWindow = nil
                return
            }
            apply()
        }

        func apply() {
            guard let window else { return }
            window.backgroundColor = SettingsTheme.paperNS
            window.isMovableByWindowBackground = true
            window.isRestorable = false

            if window !== configuredWindow {
                teardownObservers()
                configuredWindow = window

                // 首次挂载且窗口尚未上屏时,先在 alpha=0 下完成 SwiftUI 首轮 .contentSize 定框并居中,
                // 再同帧拉回可见,彻底消灭"先在右上角/旧位闪一下再往左位移"的问题。
                if !window.isVisible {
                    window.alphaValue = 0
                    if window.frame.width > 1, window.frame.height > 1 {
                        recenter(window, preferWindowScreen: false)
                    }
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.recenter(window, preferWindowScreen: false)
                        window.alphaValue = 1
                    }
                } else {
                    recenter(window, preferWindowScreen: true)
                }

                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.recenter(window, preferWindowScreen: true)
                    }
                }

                // 🔬 滚动掉帧排查(2026-09-19 用户「感觉滚动有点掉帧」):设置窗在台期间挂
                // 帧间隔探针,关窗即打 P50/P95/长帧结论 —— 先量再治(每帧都慢 vs 偶发长帧,
                // 药方相反,见 FrameProbe 头注)。trace 门控,常态零开销
                if isTraceEnabled, let content = window.contentView {
                    print("[帧] 设置探针 挂上(contentView=\(type(of: content)))")
                    FrameProbe.shared.start(on: content, label: "设置")
                    closeObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: window, queue: .main
                    ) { _ in
                        print("[帧] 设置探针 收工(willClose)")
                        FrameProbe.shared.stop()
                    }
                } else if isTraceEnabled {
                    print("[帧] 设置探针 没挂上(isTrace=\(isTraceEnabled) contentView=\(window.contentView.map { "\($0)" } ?? "nil"))")
                }
            }
        }

        private func recenter(_ window: NSWindow, preferWindowScreen: Bool) {
            guard !isCentering else { return }
            isCentering = true
            defer { isCentering = false }
            CursorScreenAnchor.center(window, preferWindowScreen: preferWindowScreen)
        }

        private func teardownObservers() {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            closeObserver = nil
            resizeObserver = nil
        }

        deinit {
            teardownObservers()
        }
    }
}

// MARK: - 分段控件(demo `.tabs` + `.tab-puck`)

/// 设置窗口的**左侧目录栏**:页面行 + 当前页的组子菜单(2026-09-19 用户:
/// 「把每一个目录的一级菜单挪出来,方便点击,不用用户在每个目录里面找」)。
/// 页行点击 = 切页 + 跳第一组;子菜单点击 = 页内滚到对应组(锚点滚动,见 SettingsView.content)。
/// 选中态沿用切换器的"滑动玻璃舌头"(`matchedGeometryEffect`)。
struct SettingsTabRail: View {
    @Binding var page: SettingsView.Page
    @Binding var selection: String?   // 锚点 id = "\(页):\(组名)"
    /// ★ 2026-11-12 二修:舌头(puck)自己的页 —— 与 `page` 分家(见 tab() 里的病例注释)
    @State private var puckPage: SettingsView.Page = .general
    @State private var greetingSeed = 0
    /// 当前页子菜单的**淡入**系数(2026-11-25:替掉原来那条 `.transition`,见 body 里的病例注释)。
    /// 参数驱动 ⇒ 系统开着「减弱动态效果」也照样演(opacity 不受框架降级影响 ✓)
    @State private var submenuReveal: Double = 1
    @Namespace private var puckNS

    /// 时辰问候:按中国传统的一天分八段(晨/上午/正午/午后/黄昏/夜晚/深夜/破晓前),
    /// 文学一点,深夜两段带一点劝歇的体贴。轻点可换同刻小句子。
    static func greeting(for date: Date, variant: Int = 0) -> (icon: String, text: String) {
        let hour = Calendar.current.component(.hour, from: date)
        let alt = variant % 2 == 1
        switch hour {
        case 5..<8:    return ("sunrise", alt ? "露水未散,写点顺手的代码。" : "晨光熹微,一日方长。")
        case 8..<11:   return ("sun.max", alt ? "窗口齐整,万事有序。" : "日色渐明,事可从容。")
        case 11..<13:  return ("sun.max.fill", alt ? "手边停一停,胃也要照顾。" : "日头正高,先吃口热饭。")
        case 13..<17:  return ("cup.and.saucer", alt ? "风吹纸页,切窗只需一瞬间。" : "日光渐斜,茶要趁热。")
        case 17..<19:  return ("sunset", alt ? "收拾好手头几扇窗再走。" : "暮色四合,归途有风。")
        case 19..<23:  return ("moon.stars", alt ? "玻璃映着灯火,夜色正好。" : "夜色温柔,灯下事慢慢做。")
        case 23...23:  return ("moon.zzz", alt ? "早点合上盖子吧。" : "夜深了,眼睛也该歇歇。")
        default:       return ("sparkles", alt ? "星河未落,注意休息。" : "万籁俱寂,好梦。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsView.Page.allCases) { p in
                tab(p)
                if page == p {
                    ForEach(p.groups, id: \.self) { g in
                        subTab(page: p, group: g)
                            // ★★ 2026-11-12 病例(用户实拍:「导航栏点击切换的时候…乱七八糟」):
                            //   切页那一下旧页的子菜单走**默认过渡 = 淡出** ⇒ 旧文字还没淡完、
                            //   新页子菜单已插入、下面的行还在下滑 ⇒ 三层叠在一起 = "叠影乱跳" ✗
                            //   ⇒ 旧子菜单**瞬移退场**(removal .identity:不淡、不滑、立刻让位 ✓);
                            //   新子菜单快速淡入(只动 opacity,不碰布局 ✓);行位移继续平滑下移 ✓
                            //   舌头(puck)照常滑 —— 它挂在页面行上,与子菜单的过渡互不相干 ✓
                            //
                            // ★ 2026-11-25 改参数驱动(原来这里是 `.transition(.asymmetric(...))`):
                            //   本机 `com.apple.universalAccess reduceMotion = 1`,SwiftUI 会把 `.transition`
                            //   直接抹成瞬切 ⇒ 那段"新子菜单淡入"根本看不见 ✗
                            //   换成 `submenuReveal`(opacity)后:旧子菜单仍**当帧让位**(布局瞬切、不淡出 ⇒ 不叠影 ✓),
                            //   新子菜单按 `SettingsMotion.contentSwap` 柔和浮现 —— 不依赖框架的过渡处理 ✓
                    }
                    .opacity(submenuReveal)
                }
            }
            .padding(.horizontal, SettingsMetrics.sidebarInset)   // 选中块内缩,不贴侧栏边
            Spacer(minLength: 0)
            // 时辰问候(2026-09-19 五修,用户裁定):从侧栏顶部挪到**底部角落** ——
            // 顶部还给导航(三个目录往上移);字体回系统体,与整页文字样式一致,不另立语言
            TimelineView(.everyMinute) { ctx in
                let mood = Self.greeting(for: ctx.date, variant: greetingSeed)
                HStack(spacing: 5) {
                    Image(systemName: mood.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.ink2.opacity(0.85))
                    Text(mood.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(MotionPolicy.animation(SettingsMotion.tint)) {
                        greetingSeed &+= 1
                    }
                }
                .help("点一下换句问候")
            }
            .padding(.leading, SettingsMetrics.sidebarInset + SettingsMetrics.sidebarRowPadX)
            .padding(.trailing, SettingsMetrics.sidebarInset)
            .padding(.bottom, SettingsMetrics.tabsBottom + 4)
        }
        .onChange(of: page) { _, _ in
            // 换页的子菜单淡入分两拍(与 SettingsView 的切页淡入同一套写法):
            //   第一拍归零 —— 用 `disablesAnimations` 的事务,保证旧子菜单**不淡出**当帧让位;
            //   第二拍淡回 —— 走 `SettingsMotion.contentSwap`,已被 `MotionPolicy` 纳管 ✓
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { submenuReveal = 0 }
            DispatchQueue.main.async {
                withAnimation(MotionPolicy.animation(SettingsMotion.contentSwap)) {
                    submenuReveal = 1
                }
            }
        }
    }

    private func tab(_ p: SettingsView.Page) -> some View {
        Button {
            // ★★ 2026-11-12 二修(用户实报:「文字和icon不是同步的, icon跑的要慢一点"):
            //   一修(asymmetric 过渡)只治了叠影,但**布局位移仍在动画事务里** ⇒
            //   页行(带 icon)还在慢慢滑,新子菜单文字已瞬时就位 ⇒ 两层快慢不一致 ✗
            //   ⇒ 终案:**布局瞬切、舌头单独滑**:
            //     ① `page` 走禁用动画的事务(所有行同帧就位,文字/图标天生同步 ✓)
            //     ② `puckPage` 只驱动背景舌头(matchedGeometry,不参与布局),单独进动画
            //        ⇒ 舌头从旧行平滑滑到新行,其余一切当帧到位 ✓
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { page = p }
            withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { puckPage = p }
            selection = p.anchor(p.groups[0])   // 切页同时跳到该页第一组
        } label: {
            HStack(spacing: 7) {
                Image(systemName: p.icon)
                    .font(.system(size: 12))
                    .frame(width: 15)
                    .foregroundStyle(SettingsTheme.ink)
                Text(p.rawValue)
                    .font(.system(size: 13, weight: page == p ? .semibold : .medium))
                    .foregroundStyle(SettingsTheme.ink)   // 主行未选也用墨色:页是"地方",层级必须压住组
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.sidebarRowPadX)
            .padding(.vertical, 7)
            .background {
                if puckPage == p {
                    // 选中块**内缩**(不随行全宽出血):System Settings/DockDoor 的侧栏做法,
                    // 圆角小一号(7),高度收一档 —— 是"高亮行",不是"黑牌子"
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SettingsTheme.puck)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [SettingsTheme.puckLip, .clear],
                                                   startPoint: .top, endPoint: .center),
                                    lineWidth: SettingsMetrics.hairline)
                        )
                        .matchedGeometryEffect(id: "puck", in: puckNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
    }

    /// 组子菜单:缩进挂在页面行下,点击 = 页内滚到该组。选中 = 墨色加粗,不再铺块(避免与页面行的 puck 打架)
    /// 层级三线拉开(2026-09-19 用户实评「主副菜单不够明显」,判据见 settings-spec §4-11):
    /// 比主行小一档半(11.5 vs 13)、常规字重、未选与选中都灰(选中只加重转墨,不上色不上块)
    ///
    /// 2026-11-25:hover 淡底 + 按压微缩交给 `SettingsButtonStyle`(与全窗其余可点元素同一层手感),
    /// 选中态的颜色变化走 `SettingsMotion.hover` —— 跟手反馈不能比指针慢一档 ✓
    private func subTab(page p: SettingsView.Page, group g: String) -> some View {
        let id = p.anchor(g)
        return Button {
            selection = id
        } label: {
            Text(g)
                .font(.system(size: 11.5, weight: selection == id ? .semibold : .regular))
                .foregroundStyle(selection == id ? SettingsTheme.ink : SettingsTheme.ink2)
                .padding(.leading, 22)          // 缩进:正好落在页面行文字的起点下
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsButtonStyle(scale: 0.98, hoverTint: true, cornerRadius: 6))
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
        // 字重不可插值,颜色可以:选中/未选之间文字颜色淡入淡出
        .animation(MotionPolicy.animation(SettingsMotion.hover), value: selection)
    }
}

// MARK: - 分段控件

/// 多选一(目前给「颜色外观」的三档用)。
///
/// 视觉不另起一套:凹槽轨道 `tabRail` + 选中处一枚会滑的实心舌 `puck` + 顶部受光唇 `puckLip`,
/// 与 `SettingsTabRail` 完全同源 —— 同一个 App 里"多选一"只该有一种长相,
/// 否则用户会以为它们不是一类东西。
struct BeamSegmented: View {
    struct Option: Identifiable {
        let id: String   // 落进 UserDefaults 的值
        let label: String
    }

    let options: [Option]
    @Binding var value: String
    /// 未选中项的 hover 淡底(选中项的舌头已由 puck 表达,hover 不再叠一层)
    @State private var hoveredID: String?
    @Namespace private var segNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                Button {
                    guard value != o.id else { return }
                    withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { value = o.id }
                } label: {
                    Text(o.label)
                        .font(SettingsFont.tab)
                        .foregroundStyle(value == o.id ? SettingsTheme.ink : SettingsTheme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background {
                            // hover 淡底:**只给未选中项**(选中的舌头本身就是那层底,再叠会发脏 ✗)
                            RoundedRectangle(cornerRadius: SettingsMetrics.puckRadius, style: .continuous)
                                .fill(SettingsTheme.tabRail
                                    .opacity(hoveredID == o.id && value != o.id ? 0.9 : 0))
                            if value == o.id {
                                RoundedRectangle(cornerRadius: SettingsMetrics.puckRadius,
                                                 style: .continuous)
                                    .fill(SettingsTheme.puck)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: SettingsMetrics.puckRadius,
                                                         style: .continuous)
                                            .strokeBorder(
                                                LinearGradient(colors: [SettingsTheme.puckLip, .clear],
                                                               startPoint: .top, endPoint: .center),
                                                lineWidth: SettingsMetrics.hairline)
                                    )
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: segNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                // 按压微缩:hover 底色自己画(见上面背景层),这里只要"按住有反应" ✓
                .buttonStyle(SettingsButtonStyle(scale: 0.96, hoverTint: false))
                .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                .onHover { over in
                    withAnimation(MotionPolicy.animation(SettingsMotion.hover)) {
                        if over { hoveredID = o.id } else if hoveredID == o.id { hoveredID = nil }
                    }
                }
                // 换档那一拍:文字颜色(墨 ↔ 灰)跟着舌头一起过渡,不是硬跳 ✓
                .animation(MotionPolicy.animation(SettingsMotion.tint), value: value)
                .accessibilityAddTraits(value == o.id ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.tabRail)
        )
    }
}
