import SwiftUI
import AppKit

/// 面板的度量、色板与阴影阶梯 —— **全系统规格的唯一来源**(`PanelController` 的定位数学与视图同源)。
/// 契约 = `design/v4/Glance 面板 v1.10.html` + `design/v4/design-system.md`。
/// 本文件属于 `Design/` 模块:**不许 import 任何业务模块**(面板、设置、输入管线),只许被它们 import。

// MARK: - 度量(全部取自 demo 的实测值;HTML px = pt 一比一)

enum PanelMetrics {
    // § 长条
    static let icon: CGFloat = 78
    /// 选中图标**放大之后**,它的画面与左右邻居画面之间还要留多少净空 —— 这才是"呼吸感"
    /// 真正的设计量,间隙由它倒推,不写死。
    ///
    /// 算给谁看:只有选中的那一个会放大,溢出只发生在它那**一侧**,不是两侧 ——
    /// 溢出量 = 78 × (1.14 − 1) ÷ 2 = **5.46pt**。
    /// demo 的 `iconGap: 6` → 净空只有 6 − 5.46 = **0.5pt**,再算上图标那圈 5pt 软阴影,
    /// 实际是压在邻居身上的 —— "弹起来就跟左右碰上"就是这么来的。
    /// 默认 13 → 间隙 ≈ 18.5。可在设置 → 通用 里现场调。
    static var iconClearance: CGFloat {
        let v = UserDefaults.standard.object(forKey: "panel.iconClearance") as? Double
        return v.map { CGFloat($0) } ?? 13
    }
    /// 格间间隙 = 净空 + 选中放大吃掉的单侧溢出(78 × 0.14 ÷ 2 = 5.46)
    static var iconGap: CGFloat { iconClearance + icon * (iconScale - 1) / 2 }
    static let rowPadX: CGFloat = 26
    static let rowPadY: CGFloat = 22
    static let iconLift: CGFloat = 14
    static let iconScale: CGFloat = 1.14
    static let puckHeight: CGFloat = 94 // 图标 78 + 上下各 8
    // § 指针跟随高光(demo `radial-gradient(220px circle …, transparent 60%)`)
    static let sheenExtent: CGFloat = 220 // 结束形状**半径**(不是直径!)
    static let sheenStop: CGFloat = 0.6 // 透明落在 60% → 可见半径 132
    // § 确认涟漪(demo .ripple:140px,scale 4.2,.55s ease-out)
    static let ripple: CGFloat = 140
    static let rippleScale: CGFloat = 4.2
    static let tRipple: Double = 0.55
    // 窗数点(demo .win-dots{bottom:-11px} + 点高 4 → 点占图标盒下缘往下 7…11)
    static let dot: CGFloat = 4
    static let dotGap: CGFloat = 3
    static let dotBottom: CGFloat = 7
    // § 预览托盘
    static let thumbW: CGFloat = 128
    static let shotH: CGFloat = 64 // demo .win-body height:64px
    static let titleH: CGFloat = 24
    static var thumbH: CGFloat { shotH + titleH }
    static let captionH: CGFloat = 18
    static let thumbGap: CGFloat = 10
    static let trayGap: CGFloat = 12
    static let trayPadTop: CGFloat = 16
    static let trayPadX: CGFloat = 18
    static let trayPadBottom: CGFloat = 14
    // 圆角
    static let rPanel: CGFloat = 34
    static let rTray: CGFloat = 26
    static let rPuck: CGFloat = 24
    static let rThumb: CGFloat = 12
    // 发丝(demo 用 1px 亮边,不再是 0.5)
    static let hairline: CGFloat = 1
    // 字阶
    static let captionSize: CGFloat = 13.5
    static let countSize: CGFloat = 12
    static let titleSize: CGFloat = 10.5
    /// 标题双保险截断:128px 宽的缩略图先斩字符数,宽度截断兜底中英混排
    static let titleCharLimit = 12
    // 时长(弹簧的 response 见 PanelMotion;这里只剩纯透明度与退场节奏)
    static let tSettle: Double = 0.22
    static let tFade: Double = 0.38
    /// demo:确认后 90ms 开始退场,.38s 淡完;涟漪 .55s。窗口拆迁排在涟漪炸开之后
    static let tFlourish: Double = 0.45
    /// 托盘 ↔ 长条的视觉缝
    static let seam: CGFloat = 16
    /// 阴影呼吸区:窗口比玻璃大出来的部分,给阴影留落点。
    /// 必须与 PanelController 的 paddedSize / previewSize 严格一致——两套账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    /// 高斯尾要 ~y + 2.5×radius 才淡出(长条 30+75、托盘 22+55),垫不够就会被窗口裁成
    /// 方块——前两轮"黑影"的真凶,不是 alpha 太大。垫出来的透明边由 ClickThroughHostingView 放行点击
    static let shadowPadStrip: CGFloat = 96
    static let shadowPadPop: CGFloat = 80
    /// 长条最小宽度:单 App 时不至于缩成一枚图标
    static let minStripWidth: CGFloat = 280
}

// MARK: - 色板(浅 / 深双值,直接抄 demo 的 :root 与 prefers-color-scheme)

enum PanelColors {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func white(_ alpha: CGFloat) -> NSColor {
        NSColor(white: 1, alpha: alpha)
    }

    private static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 28 / 255, alpha: alpha)
    }

    /// 玻璃外轮廓:一圈 1px 亮边
    static let glassBorder = dynamic(white(0.85), white(0.45))
    /// 顶缘内阴影(demo `inset 0 1px 0 var(--glass-inner-shadow)`):深色 .25 这道暗线把玻璃
    /// "压厚",整块板子才不会读成发光塑料;浅色 .06 近乎无
    static let glassInner = dynamic(NSColor.black.withAlphaComponent(0.06),
                                    NSColor.black.withAlphaComponent(0.25))
    /// demo .panel-glass::before 的顶缘高光:overlay 混的白 40% → 折成等效普通 alpha(浅 .18 / 深 .10)
    static let glassTop = dynamic(white(0.18), white(0.10))
    /// 滑动托底
    static let puck = dynamic(white(0.62), white(0.26))
    /// 托底上缘受光唇(inset 0 1px 1px rgba(255,255,255,.6))
    static let puckLip = dynamic(white(0.6), white(0.35))
    /// 窗数点
    static let dot = dynamic(ink(0.55), white(0.65))
    /// 主文案(App 名)
    static let txt1 = dynamic(ink(0.92), white(0.95))
    /// 次文案(窗数、标题)
    static let txt2 = dynamic(ink(0.56), white(0.55))
    /// 缩略图纸边
    static let thumbBorder = dynamic(white(0.5), white(0.25))
    /// 缩略图底纸(demo .win-thumb background)
    static let thumbBg = dynamic(white(0.5), white(0.12))
    /// 标题条墨色(demo .win-title color)
    static let thumbTitle = dynamic(NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 25 / 255, alpha: 0.75),
                                    white(0.75))
    /// 缩略图标题条底色:截图之下的"纸"
    static let thumbPaper = dynamic(white(0.55), white(0.16))
    /// 选中缩略图的内圈聚焦光
    static let thumbFocus = dynamic(white(0.55), white(0.4))
    /// 指针跟随高光:demo 是 soft-light 的白 30%,混不进进程外的玻璃,折成等效普通 alpha。
    /// 换算:soft-light(白)= √b,按 .30 权重大约提亮 0.06~0.08;白 alpha .12/.16 给 0.05~0.09
    static let sheenAlphaLight: CGFloat = 0.14
    static let sheenAlphaDark: CGFloat = 0.20
}

// MARK: - Elevation(逐元素一根外阴影,数值逐字抄 demo;CSS blur 直径 ÷2 = radius)
//
// 深色 .50 是 demo --glass-shadow 的深色变体原值。曾经被压成 .22,因为呼吸区太小、
// 阴影被窗口裁成一圈方块("黑影");呼吸区补足后原值就是一团平滑渐隐的大软影。

enum PanelElevation {
    struct Layer {
        let y: CGFloat
        let radius: CGFloat
        let light: Double
        let dark: Double

        var color: Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                NSColor.black.withAlphaComponent(
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                )
            })
        }
    }

    case strip, tray, puck, icon, thumb, thumbActive

    var shadow: Layer {
        switch self {
        case .strip: Layer(y: 30, radius: 30, light: 0.22, dark: 0.50) // 0 30px 60px --glass-shadow
        case .tray: Layer(y: 22, radius: 22, light: 0.22, dark: 0.50) // 0 22px 44px --glass-shadow
        case .puck: Layer(y: 8, radius: 11, light: 0.22, dark: 0.22) // 0 8px 22px rgba(0,0,0,.22)
        case .icon: Layer(y: 5, radius: 5, light: 0.30, dark: 0.30) // 0 4px 10px rgba(0,0,0,.3)
        case .thumb: Layer(y: 8, radius: 9, light: 0.18, dark: 0.18) // 0 8px 18px rgba(0,0,0,.18)
        case .thumbActive: Layer(y: 10, radius: 11, light: 0.28, dark: 0.28) // 0 10px 22px rgba(0,0,0,.28)
        }
    }
}

extension View {
    func elevation(_ level: PanelElevation) -> some View {
        shadow(color: level.shadow.color, radius: level.shadow.radius, y: level.shadow.y)
    }
}


// MARK: - 布局度量共享(规格唯一来源;PanelController 的定位数学与视图同源)

enum PanelLayout {
    /// 截断的第一道:超 12 字符先斩,宽度截断兜底中英混排
    static func title(_ raw: String) -> String {
        raw.count > PanelMetrics.titleCharLimit ? String(raw.prefix(PanelMetrics.titleCharLimit)) + "…" : raw
    }
}
