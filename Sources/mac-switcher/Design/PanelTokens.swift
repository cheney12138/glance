import SwiftUI
import AppKit

/// 面板的度量、色板与阴影阶梯 —— **全系统规格的唯一来源**(`PanelController` 的定位数学与视图同源)。
/// 本文件属于 `Design/` 模块:**不许 import 任何业务模块**(面板、设置、输入管线),只许被它们 import。

// MARK: - 度量

/// 所有几何量 = **基准值 × `scale`**。
///
/// `scale` 来自设置 → 通用 的「面板尺寸」无极 bar(2026-09-14 用户要求:整体尺寸不想只有一档)。
/// 纪律:尺寸只能从这一处出 —— 写死第二份就会与面板定位数学对不上,
/// 会重现 T6 那种 "Update Constraints 布局递归 → FAULT" 崩。
enum PanelMetrics {
    /// 尺寸系数 —— **写死 1.2,不给用户调**(用户拍板 2026-09-14):
    /// "既然可能超限, 就默认 120% 的尺寸, 然后把无极 bar 给下掉, 不允许用户改了,
    ///  macOS 本身也没有开这个口子, 我们不开没问题"。
    /// 曾经有过 0.7…1.5 的无极 bar,实测 120% 才是最舒服的一档,而且可调就必须把
    /// "放不下怎么办"也丢给用户去理解 —— 不如定死一档 + 自动收紧。
    /// (UserDefaults 里的 `panel.scale` 不再读:老值留着无害,哪天要恢复调档直接读回去就行)
    static let fixedScale: CGFloat = 1.2

    static var scale: CGFloat {
        // 屏幕放不下时以放得下为准(sessionCap 由 PanelController 每局算出,见下)
        min(fixedScale, sessionCap)
    }

    /// 本会期的尺寸上限 —— 由 `PanelController` 在 begin 时按"语境屏可视宽 + 本屏 App 数 + 最大窗数"算出。
    ///
    /// 为什么不能让 bar 自己封顶(用户提议锁死 150 以下):面板宽度**取决于本屏 App 数**,
    /// 而 App 数每局都不同,两块屏的宽度也不同(主屏 1920 / 副屏 1728)。固定砍到 140%
    /// 在 15 个 App 时照样溢出,在 5 个 App 时又白牺牲了尺寸。算出来的 cap 两边都照顾。
    /// 默认无穷大 = 不设限(面板不在台上时没有会期,设置页读到的就是用户值)。
    static var sessionCap: CGFloat = .greatestFiniteMagnitude

    /// 基准值 → 实值。所有需要随「面板尺寸」缩放的量都过这一手
    private static func k(_ base: CGFloat) -> CGFloat { base * scale }

    // § 长条
    /// 图标边长基准 88(2026-09-14 用户实评"窗口太小":78 → 88,长条整体随比例放大)
    static var icon: CGFloat { k(88) }
    /// 选中图标**放大之后**,它的画面与左右邻居画面之间还要留多少净空 —— 这才是"呼吸感"
    /// 真正的设计量,间隙由它倒推,不写死。可在设置 → 通用 里现场调(也随尺寸同比例缩放)。
    static var iconClearance: CGFloat {
        let v = UserDefaults.standard.object(forKey: "panel.iconClearance") as? Double
        return k(v.map { CGFloat($0) } ?? 13)
    }
    /// 格间间隙 = 净空 + 选中放大吃掉的单侧溢出(icon × 0.14 ÷ 2)
    static var iconGap: CGFloat { iconClearance + icon * (iconScale - 1) / 2 }
    static var rowPadX: CGFloat { k(26) }
    static var rowPadY: CGFloat { k(22) }
    static var iconLift: CGFloat { k(14) }
    /// 选中放大倍率是**比例**,不随尺寸变(变尺寸不该改变选中态的强烈程度)
    static let iconScale: CGFloat = 1.14
    static var puckHeight: CGFloat { icon + k(16) } // 图标 + 上下各 8
    // § 指针跟随高光(demo `radial-gradient(220px circle …, transparent 60%)`)
    static var sheenExtent: CGFloat { k(220) } // 结束形状**半径**(不是直径!)
    static let sheenStop: CGFloat = 0.6 // 透明落在 60% → 可见半径 132
    // § 确认涟漪(demo .ripple:140px,scale 4.2,.55s ease-out)
    static var ripple: CGFloat { k(140) }
    static let rippleScale: CGFloat = 4.2
    static let tRipple: Double = 0.55
    // 窗数点
    static var dot: CGFloat { max(k(4), 3) }
    static var dotGap: CGFloat { k(3) }
    static var dotBottom: CGFloat { k(7) }
    // § 预览托盘
    /// 2026-09-14 用户实评"预览窗口太小":128×64 → 196×122(≈16:10,看得清窗口里写了什么)
    static var thumbW: CGFloat { k(196) }
    static var shotH: CGFloat { k(122) } // 截图区
    /// 红绿灯上方那层**毛玻璃**的模糊半径与渐变高度(固定 UI 规格:灯本身固定 11pt,不随卡片缩放)。
    /// 用户口径:"要跟现在 Switcher 长条一样的模糊,但是是渐变效果" —— 所以这是模糊,不是暗色遮罩
    /// 14 → 26、46 → 62(2026-09-14 用户实评"模糊度不够高,而且好像没覆盖红绿灯的区域")。
    /// 高度的取法:要**盖过灯那一行并留出余量** —— 灯在 9…20pt,渐变到 62pt 才收干,
    /// 头顶这一行才算真的"坐在毛玻璃上"。
    /// ⚠️ 一句技术实话:纯模糊对**白色内容**几乎无效(白糊了还是白),所以"看不出覆盖"很大程度
    /// 是内容太素,不是没生效(对比同位置的结构化内容最明显)。要让白底内容也读得出"毛玻璃",
    /// 就得在模糊之上再压一层**极淡的白/灰膜**(材质的做法) —— 那会改变画面亮度,单独一轮再议
    static let lightsBlur: CGFloat = 26
    static let lightsFade: CGFloat = 62
    /// 标题条高 30 → 22(2026-09-14 用户实评"底部的项目名压缩一下空间,给的太多了")
    static var titleH: CGFloat { k(22) }
    static var thumbH: CGFloat { shotH + titleH }
    static var captionH: CGFloat { k(22) }
    static var thumbGap: CGFloat { k(14) }
    static var trayGap: CGFloat { k(16) }
    /// 预览托盘的题头留白(用户实评 2026-09-14:"顶部额头会不会有点宽了"):
    /// 20 → 12。题头那一行本来就只有一行小字、左右大段空着,上方再留 24pt 就显得头重
    static var trayPadTop: CGFloat { k(12) }
    static var trayPadX: CGFloat { k(22) }
    static var trayPadBottom: CGFloat { k(18) }
    // 圆角
    static var rPanel: CGFloat { k(34) }
    static var rTray: CGFloat { k(30) }
    static var rPuck: CGFloat { k(24) }
    static var rThumb: CGFloat { k(16) }
    /// 发丝不随尺寸缩放:0.5pt 的物理意义就是"一根线",放大成 2pt 就不再是发丝了
    static let hairline: CGFloat = 1
    // 字阶(随卡片一起放大)
    /// 题头(App 名)13pt:2026-09-14 把面板截图丢给一份通用评审后对方**唯一说对的一条** ——
    /// "字体偏大偏黑,像网页弹窗"。原值是 15 基准 ×1.2 = **18pt**,而 macOS 自己的窗口标题是 13;
    /// 现在 13 ×1.2 ≈ 15.6,字重同步从 semibold 降到 medium(见 PreviewPanelView)
    static var captionSize: CGFloat { k(13) }
    static var countSize: CGFloat { k(12) }
    /// 标题字号 12 → 10.5(同上:"字体缩小一点")
    static var titleSize: CGFloat { k(10.5) }
    /// 标题双保险截断的**第一道**:只做病理保护(标量是字符数,中英混排靠宽度截断兜底)。
    /// 2026-09-14 实评:12 把终端 tab 名 "π - tab-group-search" 斩成 "π - tab-grou…",
    /// 卡片加宽到 196 后提到 28;同时又随尺寸同比例放宽(面板调大 = 一行能装更多字)
    static var titleCharLimit: Int { Int(28 * scale) }
    // 时长:进/退场一律瞬现,这里不再有时长常量(弹簧的 response 见 PanelMotion)
    /// 托盘 ↔ 长条的视觉缝
    static var seam: CGFloat { k(16) }
    /// 阴影呼吸区:窗口比玻璃大出来的部分,给阴影留落点。
    /// 必须与 PanelController 的 paddedSize / previewSize 严格一致——两套账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    /// 阴影的 radius 是**定值**(不随面板尺寸缩放),所以垫的量也不用乘 scale,
    /// 只按面板最大档(1.5)留足余量。垫出来的透明边由 ClickThroughHostingView 放行点击
    static let shadowPadStrip: CGFloat = 108
    static let shadowPadPop: CGFloat = 96
    /// 长条最小宽度:单 App 时不至于缩成一枚图标
    static var minStripWidth: CGFloat { k(280) }
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

    /// 玻璃外轮廓:浅色用**暗发丝**(black .12),深色仍是白 .22。
    ///
    /// 2026-09-14 用户"白底玻璃实验台"的病理:浅色那套「形」原本全由**白色系** token 承担,
    /// 在纯白底上它们与背景同色隐形 —— 面板退化成"浮着的图标 + 一团阴影",
    /// 用户实评:"边框看起来有点模糊"。macOS 自己就是这么做的(浅底色窗口的边是暗发丝)。
    /// 对应实验台 **V2 灰色族收边**(只改浅色族,深色一律不动)。
    static let glassBorder = dynamic(ink(0.12), white(0.22))
    /// 顶缘内阴影(demo `inset 0 1px 0 var(--glass-inner-shadow)`):深色 .25 这道暗线把玻璃
    /// "压厚",整块板子才不会读成发光塑料;浅色 .06 近乎无
    static let glassInner = dynamic(NSColor.black.withAlphaComponent(0.06),
                                    NSColor.black.withAlphaComponent(0.25))
    /// 滑动托底
    /// 选中托底(舌头)—— **白 .62 定版**(2026-09-14 用户终审:"我还是喜欢最开始那个白色的,
    /// 更像滑块一样")。
    ///
    /// 这一格试过三个值,都对过照,记在这里免得后人重走:
    ///   · 白 .62 —— 这一次选它。读到的是**滑块/胶囊托底**,icon 压在上面像浮起来的滑块头;
    ///   · 黑 .10 —— 白底上看得见,但太透,"背景从里面透出来" → 用户评"透明塑料片子";
    ///   · 黑 .20 —— 实了,但观感是"灰膏",丢了滑块感。
    /// 代价(已知并接受):**纯白底上它比有色背景上显弱** —— 因为它是"亮",亮在白上不显形。
    /// 白底的"形"由暗发丝边与卡片纸面承担(见下面 V2 那几行),不再让舌头兼职。
    /// 托底本体:**半透明白 .62**(用户终审过的"滑块感")。
    ///
    /// 试过 P2 的实白 .96(实验台推荐档),用户实测评:
    ///   · 纯白底**确实好转**;
    ///   · 但**深色背景上太白、丢了果冻感,变成纸质卡片** —— .96 不透明,就没有"背景从它里面透出来"的那口气了。
    /// 所以回到 .62 的**果冻质感**,改用"形"的两味补丁去救白底(见 puckBorder 与 PanelElevation.puck):
    /// 轮廓给出边界、影子贴身给出归属,不再要求本体自己变不透明。
    static let puck = dynamic(white(0.62), white(0.26))
    /// 托底发丝边(保留):白底上"本体隐形"的那一半就靠它 —— 边是暗的,白底上才看得见形。
    /// 半透明本体 + 一道发丝边 = 白底有形、深底仍有果冻感。深色不留(实验台 dark 为透明)
    static let puckBorder = dynamic(ink(0.08), NSColor.clear)
    /// 上缘受光唇:浅色**保留** .6 —— 它是"果冻感"的一半(本体回到半透明白之后,这道唇才有意义;
    /// 只在 P2 那张不透明纸片上是多余的双层高光)。深色 .35 不动
    static let puckLip = dynamic(white(0.6), white(0.35))
    /// 窗数点
    static let dot = dynamic(ink(0.55), white(0.65))
    /// 主文案(App 名)
    static let txt1 = dynamic(ink(0.92), white(0.95))
    /// 次文案(窗数、标题)
    static let txt2 = dynamic(ink(0.56), white(0.55))
    /// 缩略图纸边:浅色也用暗发丝(与长条同一族)
    static let thumbBorder = dynamic(ink(0.12), white(0.25))
    /// 缩略图底纸:浅色**提白**到 .60 —— 实验台 V2 的另一半:边收暗了,纸面就要更实,
    /// 卡片的"形"才立得住(否则暗边包着一团半透明的灰,更糊)
    static let thumbBg = dynamic(white(0.60), white(0.12))
    /// 标题条墨色(demo .win-title color)
    static let thumbTitle = dynamic(NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 25 / 255, alpha: 0.75),
                                    white(0.75))
    /// 缩略图标题条底色:截图之下的"纸"(与底纸同一档白度)
    static let thumbPaper = dynamic(white(0.60), white(0.16))
    /// 红绿灯:macOS 系统规格色(#FF5F57 / #FEBC2E / #28C840),深浅一致不随外观变
    static let tlClose = dynamic(NSColor(srgbRed: 1.0, green: 95 / 255, blue: 87 / 255, alpha: 1),
                                 NSColor(srgbRed: 1.0, green: 95 / 255, blue: 87 / 255, alpha: 1))
    static let tlMin = dynamic(NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1),
                               NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1))
    static let tlZoom = dynamic(NSColor(srgbRed: 40 / 255, green: 200 / 255, blue: 64 / 255, alpha: 1),
                                NSColor(srgbRed: 40 / 255, green: 200 / 255, blue: 64 / 255, alpha: 1))
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
        // 托盘:2026-09-14 用户实评"外圈怎么有一圈阴影晕染" —— blur 22 太散,在深底上读成
        // 一圈光晕而不是"贴在面上"。收到 13,并压低 alpha:阴影该紧贴边缘、只交代"浮起"这一件事
        case .tray: Layer(y: 14, radius: 13, light: 0.17, dark: 0.40)
        // puck:浅色按实验台 P2 收成"贴身影"(0 5px 14px .14 → radius = 14÷2),
        // 影子贴身、永远有所属,不再悬空;深色保持原值(实验台 dark 未改)
        case .puck: Layer(y: 5, radius: 7, light: 0.14, dark: 0.22)
        // icon:浅色 .30 → .18(2026-09-14 用户实评"底下的阴影在白底下看着像缺了一块")
        // —— 那圈阴影紧贴图标下方,浅色托底上会读成"托底被挖了一块";深色不动
        case .icon: Layer(y: 5, radius: 5, light: 0.18, dark: 0.30) // 0 4px 10px rgba(0,0,0,.3)
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

    /// 第 `appIndex` 个图标格的中心 X(长条**内容**坐标系)。
    ///
    /// **唯一来源**:确认涟漪的圆心、指针高光要挖的洞、以及托盘的横向锚点都取它。
    /// 三处各算一遍的话,只要有一处漏改就会错位(而且错得很小,看不出来但一直歪着)。
    static func iconCenterX(appIndex: Int, appCount: Int, contentWidth: CGFloat) -> CGFloat {
        let n = CGFloat(max(appCount, 1))
        let stripW = n * PanelMetrics.icon + max(n - 1, 0) * PanelMetrics.iconGap
        return (contentWidth - stripW) / 2
            + CGFloat(max(appIndex, 0)) * (PanelMetrics.icon + PanelMetrics.iconGap)
            + PanelMetrics.icon / 2
    }
}
