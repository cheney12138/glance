import SwiftUI
import AppKit

/// 设置窗的样式契约 = 设计 demo `design/v4/Glance 设置 v1.html`(600×480 的独立纸窗),
/// token/度量/偏离备案见 `design/settings-spec.md`。
///
/// 与切换器面板的分工:面板是**液态玻璃浮层**,设置窗是**一张纸** —— 不透明纸底、
/// 顶上唯一一道棱镜色散边、一颗会滑的玻璃舌头。同一套"光透过玻璃"的语言,两种材质。
///
/// 未落地的 demo 元素:`theme-switch`(系统/浅色/深色三连)是 demo 自己的评审开关,
/// 不是产品件 —— 原生窗跟随系统外观,不另造第二套主题选择器
/// (design-system 不变量:token 只有一份,深浅两态)。
enum SettingsTheme {

    // MARK: - 色板(demo `:root` 与 `[data-theme=dark]` 逐字抄)

    /// 纸底 `--paper`:浅 `#eceef2` / 深 `#101116`
    static let paper = dynamic(srgb(0xEC, 0xEE, 0xF2), srgb(0x10, 0x11, 0x16))
    /// 纸底的 NSColor 版:窗口**自身**的底色要它(内容区盖不住整窗,见 `SettingsWindowChrome`)
    static let paperNS = dynamicNS(srgb(0xEC, 0xEE, 0xF2), srgb(0x10, 0x11, 0x16))
    /// 主文案 `--ink`:#16171c / #eef0f4
    static let ink = dynamic(srgb(0x16, 0x17, 0x1C), srgb(0xEE, 0xF0, 0xF4))
    /// 次文案 `--ink-2`:墨 56% / 白 55%
    static let ink2 = dynamic(srgb(0x16, 0x17, 0x1C, 0.56), srgb(0xEE, 0xF0, 0xF4, 0.55))
    /// 行发丝 `--hairline`:墨 9% / 白 9%
    static let hairline = dynamic(srgb(0x16, 0x17, 0x1C, 0.09), white(alpha: 0.09))
    /// 分段控件底槽 `--tab-rail`
    static let tabRail = dynamic(srgb(0x16, 0x17, 0x1C, 0.05), white(alpha: 0.05))
    /// 玻璃舌头 `--glass`(demo 的 `.tab-puck`)
    static let puck = dynamic(white(alpha: 0.55), white(alpha: 0.07))
    /// 舌头受光唇 `--glass-edge`(demo `inset 0 1px 0`)
    static let puckLip = dynamic(white(alpha: 0.80), white(alpha: 0.14))
    /// 开关关闭态轨道 `--track-off`
    static let trackOff = dynamic(srgb(0x16, 0x17, 0x1C, 0.14), white(alpha: 0.18))
    /// 键位胶囊底 `--key-bg`
    static let keyBg = dynamic(srgb(0x16, 0x17, 0x1C, 0.06), white(alpha: 0.09))

    /// 光束 = 开关打开态。demo 的 `--beam: #2f6fed` 是"那条唯一的强调蓝"的示意值,
    /// 原生取系统 accent(`--accent: #007AFF` / `#0A84FF`),不另造第三种蓝。
    static var beam: Color { .accentColor }

    /// 焦点环开关(**全窗一处**,改这一个 Bool 就能回滚)。默认**关**。
    ///
    /// 实机病:窗口一打开,SwiftUI 就把第一个可聚焦控件(分段控件的"通用")点成聚焦态,
    /// 纸上于是**常驻**一个 demo 里没有的蓝框 —— 它不是"正在用键盘导航"的临时指示,
    /// 而是开窗即来、不点别处不走的噪音(实机截图:蓝框在"通用",舌头已经在"关于")。
    /// 按 FKA(`NSApp.isFullKeyboardAccessEnabled`)收口试过了:这台机器上它就是 `true`,
    /// 等于没收 —— 所以在这里一律关掉。
    ///
    /// 代价与取舍:系统开了键盘导航的用户看不到焦点指示(Tab 照旧走得动、空格/回车照旧能激活);
    /// 这颗胶囊的身份由舌头表达,不依赖焦点环。要回滚:把这个改成 `true`。
    static let showsFocusRing = false

    /// demo `.prism-edge`:光谱七色,**全窗唯一一次出现光谱色**。
    ///
    /// 与 design-system v1.10 不变量 2("全系统彩色仅两源:聚焦蓝 + 红绿灯")的张力备案:
    /// 那条管的是切换器面板;设置窗的棱镜边是 demo 明确指定的签名时刻(Glance = 光透过玻璃)。
    /// 若要回严格合规:把这一处换成 `LinearGradient(colors: [beam, beam])` 即可,其余不动。
    static let prism = LinearGradient(
        stops: [
            .init(color: hue(0xFF6B6B), location: 0.00),
            .init(color: hue(0xFFB648), location: 0.16),
            .init(color: hue(0xFFE066), location: 0.32),
            .init(color: hue(0x4ADE80), location: 0.48),
            .init(color: hue(0x38BDF8), location: 0.66),
            .init(color: hue(0x8B7CF6), location: 0.84),
            .init(color: hue(0xFF6B6B), location: 1.00),
        ],
        startPoint: .leading, endPoint: .trailing)

    // MARK: - 动态色工具(与 `PanelColors` 同一套写法:浅/深两值,不手写 NSAppearance)

    private static func dynamicNS(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: dynamicNS(light, dark))
    }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    private static func white(alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }

    /// 光谱色**不随深浅外观变**(demo 的 `.prism-edge` 是一份固定渐变),所以不走 `dynamic`
    private static func hue(_ rgb: Int) -> Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255,
              opacity: 1)
    }
}

/// 度量:HTML px = pt,一比一。demo 的 `.window` 600×480、行距 13、发丝 1(不是面板的 0.5)。
enum SettingsMetrics {
    static let windowW: CGFloat = 600
    /// 内容高度。demo 是 600×480 的 mock 窗,但它的「通用」只有 4 行;本 App 多一行真设置
    /// (图标呼吸感),照 480 排会当场把最后一行的说明切掉半行 —— 宁可窗高比 mock 高一条标题栏。
    /// 实测:内容 480 → 窗口 **512**(480 + 系统标题栏那一条 32pt;隐藏标题栏后它仍然占位)。
    /// 窗底不铺纸会露白边,见 `SettingsWindowChrome`。
    static let contentH: CGFloat = 480
    /// 棱镜边到窗顶的距离:给红绿灯让位(demo `.chrome` = 14pt 上留白 + 11pt 灯 + 14pt 下留白)
    static let prismTop: CGFloat = 39
    static let prismHeight: CGFloat = 2
    static let prismOpacity: Double = 0.55
    /// 顶部导航条上下留白(demo `.tabs-wrap` 16 / 14)
    static let tabsTop: CGFloat = 16
    static let tabsBottom: CGFloat = 14
    static let tabRailPadding: CGFloat = 3
    static let tabItemPadX: CGFloat = 14
    static let tabItemPadY: CGFloat = 7
    static let tabRadius: CGFloat = 12
    static let puckRadius: CGFloat = 9
    /// 内容区留白(demo `.content` 左右 28 / 上下 2、26)
    static let contentPadX: CGFloat = 28
    static let contentPadTop: CGFloat = 2
    static let contentPadBottom: CGFloat = 26
    /// 组间距(demo `.group{margin-bottom:20}`)
    static let groupGap: CGFloat = 20
    /// 行:上下 13、行内左右间距 16
    static let rowPadY: CGFloat = 13
    static let rowGap: CGFloat = 16
    /// 说明文案的最大宽度(demo `.row-desc{max-width:400px}`):让长说明先折行,不等尾巴
    static let descMaxW: CGFloat = 400
    static let hairline: CGFloat = 1
    /// 开关 34×20、钮 16、内缩 2 → 行程 14(demo `.switch::after{translateX(14px)}`)
    static let switchW: CGFloat = 34
    static let switchH: CGFloat = 20
    static let switchKnob: CGFloat = 16
    static let switchInset: CGFloat = 2
}

/// 字阶(demo 的 13 / 12.5 / 11.5 / 11 四档,全部 SF Pro)
enum SettingsFont {
    static let rowTitle = Font.system(size: 13)
    static let rowDesc = Font.system(size: 11.5)
    static let rowValue = Font.system(size: 12.5)
    static let tab = Font.system(size: 12.5, weight: .medium)
    static let groupLabel = Font.system(size: 11)
    static let key = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

/// 动效。demo 的两条过冲 bezier(`.34s cubic-bezier(.22,1.5,.36,1)` 的舌头、
/// `.22s cubic-bezier(.3,1.5,.6,1)` 的拨杆)在原生一律折算成弹簧 —— 理由同 `PanelMotion`:
/// SwiftUI 的过冲 `timingCurve` 不可靠,且每次打断都从零速度重起,弹簧才是"接力"。
enum SettingsMotion {
    /// 玻璃舌头:demo 明说要复用切换器那套"滑动玻璃舌头"机制 → 直接用同一颗弹簧
    static let puck = PanelMotion.slide
    /// 开关拨杆(demo .22s 的轻过冲)
    static let knob = Animation.spring(response: 0.22, dampingFraction: 0.72)
    /// 纯状态色过渡(demo 的 `.2s ease`)
    static let tint = Animation.easeOut(duration: 0.2)
}
