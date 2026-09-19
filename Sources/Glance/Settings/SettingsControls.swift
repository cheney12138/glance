import SwiftUI

/// 设置窗的可复用件(demo 的 `.group` / `.row` / `.switch` / `.key` / `.tabs` 逐一对应)。
///
/// demo 是数据驱动渲染(`panes` 数组 + `rowHTML`),原生不做那一层:设置项自带 Binding、
/// 录制键自带 State,数据表反而要把状态搬进模型。这里保留 demo 的**结构**:
/// 组(可选小标题)→ 行(标题 + 说明 + 尾部控件 + 发丝)。

// MARK: - 组

/// demo `.group` + `.group-label`:一叠行,可选一枚小圆点 + 小标题。
/// 组间距由父级 `VStack(spacing: SettingsMetrics.groupGap)` 给,组自身不加下边距。
struct SettingsGroup<Content: View>: View {
    var label: String? = nil
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
                        .fill(SettingsTheme.ink)
                        .frame(width: 3, height: 13)
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SettingsTheme.ink)
                }
                .padding(.bottom, SettingsMetrics.labelGap)
                .id(anchor)   // 锚点 = 标题本体(无标题的组不参与定位)
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
        }
    }
}

// MARK: - 开关

/// demo `.switch`:关闭是玻璃灰轨道,打开是那条唯一的强调蓝。
/// 自绘而非 `Toggle(.switch)`:原生开关是 51×31 的固定尺寸,跟这张纸的行节奏不成比例
/// (demo 是 34×20 的小号),且 macOS 原生开关没有"轨道染色"这一档。
struct BeamSwitch: View {
    @Binding var isOn: Bool

    private var travel: CGFloat {
        SettingsMetrics.switchW - SettingsMetrics.switchKnob - SettingsMetrics.switchInset * 2
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? SettingsTheme.beam : SettingsTheme.trackOff)
                    .animation(SettingsMotion.tint, value: isOn)
                Circle()
                    .fill(.white)
                    .frame(width: SettingsMetrics.switchKnob, height: SettingsMetrics.switchKnob)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .offset(x: isOn ? SettingsMetrics.switchInset + travel : SettingsMetrics.switchInset)
                    .animation(MotionPolicy.animation(SettingsMotion.knob), value: isOn)
            }
            .frame(width: SettingsMetrics.switchW, height: SettingsMetrics.switchH)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain) // 用 Button 而不是 onTapGesture:焦点与 VoiceOver 白拿
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
        .accessibilityLabel(isOn ? "已开启" : "已关闭")
    }
}

// MARK: - 窗口本身

/// 内容区盖不到的那两件事,只能落到窗上:
/// 1. **窗口底色**:`.frame(600×H)` 只是内容,窗口比它高出一条标题栏,不刷底会露白边;
/// 2. **整张纸可拖**:无标题栏窗口若只能拖顶上一条,手感是残的(控件自己会吃掉手势,无误拖)。
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.apply() }

    final class ChromeView: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 窗关闭时 SwiftUI 先把本视图摘离窗口(willClose 通知因此没人收 —— 实测),
            // 摘离这一刻就是收工信号
            if window == nil, closeObserver != nil {
                print("[帧] 设置探针 收工(视图摘离窗口)")
                FrameProbe.shared.stop()
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
            }
            apply()
        }

        func apply() {
            guard let window else { return }
            window.backgroundColor = SettingsTheme.paperNS
            window.isMovableByWindowBackground = true
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

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
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
    @Namespace private var puckNS

    /// 时辰问候:按中国传统的一天分八段(晨/上午/正午/午后/黄昏/夜晚/深夜/破晓前),
    /// 文学一点,深夜两段带一点劝歇的体贴。用户此刻在做什么,话就说到什么。
    static func greeting(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<8:    return "晨光熹微,一日方长。"
        case 8..<11:   return "日色渐明,事可从容。"
        case 11..<13:  return "日头正高,先吃口热饭。"
        case 13..<17:  return "日光渐斜,茶要趁热。"
        case 17..<19:  return "暮色四合,归途有风。"
        case 19..<23:  return "夜色温柔,灯下事慢慢做。"
        case 23...23:  return "夜深了,眼睛也该歇歇。"
        default:       return "万籁俱寂,好梦。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsView.Page.allCases) { p in
                tab(p)
                if page == p {
                    ForEach(p.groups, id: \.self) { g in
                        subTab(page: p, group: g)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.sidebarInset)   // 选中块内缩,不贴侧栏边
            Spacer(minLength: 0)
            // 时辰问候(2026-09-19 五修,用户裁定):从侧栏顶部挪到**底部角落** ——
            // 顶部还给导航(三个目录往上移);字体回系统体,与整页文字样式一致,不另立语言
            TimelineView(.everyMinute) { ctx in
                Text(Self.greeting(for: ctx.date))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, SettingsMetrics.sidebarInset + SettingsMetrics.sidebarRowPadX)
            .padding(.trailing, SettingsMetrics.sidebarInset)
            .padding(.bottom, SettingsMetrics.tabsBottom + 4)
        }
    }

    private func tab(_ p: SettingsView.Page) -> some View {
        Button {
            withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { page = p }
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
                if page == p {
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
    private func subTab(page p: SettingsView.Page, group g: String) -> some View {
        let id = p.anchor(g)
        return Button {
            selection = id
        } label: {
            Text(g)
                .font(.system(size: 11.5, weight: selection == id ? .semibold : .regular))
                .foregroundStyle(selection == id ? SettingsTheme.ink : SettingsTheme.ink2)
                .padding(.leading, 22)          // 缩进:正好落在页面行文字的起点下
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
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
                .buttonStyle(.plain)
                .focusEffectDisabled(!SettingsTheme.showsFocusRing)
                .accessibilityAddTraits(value == o.id ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.tabRail)
        )
    }
}
