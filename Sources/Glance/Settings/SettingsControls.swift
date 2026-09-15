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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                // 组标题 = 这一页的主标题(2026-09-15):13pt 半粗 + 上墨色 + 一圈发丝边框胶囊。
                // 原来那颗 4pt 小圆点 + 11pt 灰字比行标题还轻,层级是反的。
                Text(label)
                    .font(SettingsFont.groupLabel)
                    .foregroundStyle(SettingsTheme.ink)
                    .padding(.horizontal, SettingsMetrics.labelPadX)
                    .padding(.vertical, SettingsMetrics.labelPadY)
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.labelRadius, style: .continuous)
                            .strokeBorder(SettingsTheme.labelBorder, lineWidth: SettingsMetrics.hairline)
                    )
                    .padding(.bottom, SettingsMetrics.labelGap)
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.backgroundColor = SettingsTheme.paperNS
            window.isMovableByWindowBackground = true
        }
    }
}

// MARK: - 分段控件(demo `.tabs` + `.tab-puck`)

/// demo 明说这条控件的机制是**复用切换器本身的"滑动玻璃舌头"**:一颗 puck 在底槽里滑,
/// 位置靠 `matchedGeometryEffect` 而不是手算宽高 —— 手算版本(demo 的 `positionPuck`)
/// 要在窗口 resize 时补一次 `getBoundingClientRect`,原生交给布局系统。
struct SettingsTabRail: View {
    @Binding var page: SettingsView.Page
    @Namespace private var puckNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsView.Page.allCases) { p in
                tab(p)
            }
        }
        .padding(SettingsMetrics.tabRailPadding)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.tabRadius, style: .continuous)
                .fill(SettingsTheme.tabRail)
        )
    }

    private func tab(_ p: SettingsView.Page) -> some View {
        Button {
            guard page != p else { return }
            withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { page = p }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: p.icon)
                    .font(.system(size: 12.5))
                Text(p.rawValue)
                    .font(SettingsFont.tab)
            }
            .foregroundStyle(page == p ? SettingsTheme.ink : SettingsTheme.ink2)
            .padding(.horizontal, SettingsMetrics.tabItemPadX)
            .padding(.vertical, SettingsMetrics.tabItemPadY)
            .background {
                if page == p {
                    RoundedRectangle(cornerRadius: SettingsMetrics.puckRadius, style: .continuous)
                        .fill(SettingsTheme.puck)
                        // demo 是 `inset 0 1px 0 --glass-edge` 的顶部受光唇:上面一道白,
                        // 到中线收干 —— 直接换成一圈自顶向下的亮边描线,免得再叠一层遮罩
                        .overlay(
                            RoundedRectangle(cornerRadius: SettingsMetrics.puckRadius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [SettingsTheme.puckLip, .clear],
                                                   startPoint: .top, endPoint: .center),
                                    lineWidth: SettingsMetrics.hairline)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "puck", in: puckNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 分段控件的"蓝框":见 `SettingsTheme.showsFocusRing`
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
