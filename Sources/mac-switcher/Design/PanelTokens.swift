import SwiftUI
import AppKit
import GlanceCore

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
    /// 选中放大后,图标**画面**相对格子单侧溢出的量。
    /// 画面本来就被 `IconProvider.art` 的 fill 补偿铺满格子,所以溢出直接是 icon × 0.14 ÷ 2,
    /// 不需要再乘 fill —— 这一点很容易算错(乘了会把 88 格子的溢出算成 18pt)。
    static var selectionOverflow: CGFloat { icon * (iconScale - 1) / 2 }
    /// 格间间隙 = 净空 + 选中放大吃掉的单侧溢出
    static var iconGap: CGFloat { iconClearance + selectionOverflow }
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
    /// 窗数点在选中态要**跟着图标一起抬**多少。
    ///
    /// 2026-09-14 实拍诊断:点是挂在格子底边上的(`dotBottom` 从格底往下 7pt,中心落在 +5),
    /// 而托底下缘在格底 +8 —— 点底距托底底边只剩 **1.2pt**,看着就是"贴着托盘底边";更要命的是
    /// 图标上浮 14pt 之后**点没动**,两者本就固定的"点在图标下缘"关系被扯开,点看起来掉队了
    /// (用户实评:"托盘底部距离显示窗口数量的那两个点几乎是挨着的")。
    ///
    /// 抬的量是 `iconLift − selectionOverflow` 而不是 iconLift 全量:图标放大后**画面下缘本身
    /// 就上移了 selectionOverflow**,点若抬满 14pt 会反过来钻进图标画面里。抬这个差值,
    /// 点与图标画面的间距在选中/未选中两态下都是同一个 dotBottom,关系恒定;
    /// 抬完点底距托底底边 ≈ 8.8pt,不再是贴边。
    static var dotLift: CGFloat { iconLift - selectionOverflow }
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
    /// 窗口名**芯片**(2026-09-14 用户要求:标题从卡片内挪到**卡片外**下方,做成芯片样式 ——
    /// "显示在预览框里很丑…不影响文字显示,又不跟预览窗耦合,位置相对 app 的每个窗口居中")
    static var chipH: CGFloat { k(18) }
    /// 芯片前面的**选中圆点**(2026-09-14 用户要求:多窗口时"浮动效果不明显",要一眼看出选中的是哪扇窗)。
    /// 颜色选**系统强调色**:与 macOS 的选中语言一致,而且跟随用户在系统设置里挑的强调色。
    /// 未选中时留一颗极淡的灰点**占位** —— 否则圆点出现/消失会让芯片文字左右跳
    static var chipDot: CGFloat { k(5) }
    /// 卡片与芯片之间的缝:两者解耦的分界(芯片不在卡片的环/影/浮起里)
    static var chipGap: CGFloat { k(6) }
    static var thumbH: CGFloat { shotH + chipGap + chipH }
    static var thumbGap: CGFloat { k(14) }
    /// 卡片**换行**后的行间距(与卡间距不同档:行与行之间要能读成两排,不能糊成一片)
    static var trayRowGap: CGFloat { k(12) }
    /// 托盘最多几行。超过这个数就不换行了 —— 再往下堆就不是"托盘"了,
    /// 那属于病理情况(几十扇窗),此时宁可让尺寸继续缩(见 `PanelController.trayFitScale`)
    static let trayMaxRows = 4
    /// 托盘的**上**留白。走了一圈才定:题头行删掉之后,托盘的视觉重心掉到了下面
    /// (上 12 / 下 18),用户实评"重心在顶部,留白跑到下面了" —— 于是**调换**:
    /// 上 20 / 下 12。芯片是贴着卡片的一条注脚,它离卡片近才对;空气留在顶上,整块托盘才"浮"起来
    static var trayPadTop: CGFloat { k(20) }
    static var trayPadX: CGFloat { k(22) }
    static var trayPadBottom: CGFloat { k(12) }
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
    /// 标题字号 12 → 10.5(同上:"字体缩小一点")
    static var titleSize: CGFloat { k(10.5) }
    /// 标题双保险截断的**第一道**:只做病理保护(标量是字符数,中英混排靠宽度截断兜底)。
    /// 2026-09-14 实评:12 把终端 tab 名 "π - tab-group-search" 斩成 "π - tab-grou…",
    /// 卡片加宽到 196 后提到 28;同时又随尺寸同比例放宽(面板调大 = 一行能装更多字)
    static var titleCharLimit: Int { Int(28 * scale) }
    // 时长:进/退场一律瞬现,这里不再有时长常量(弹簧的 response 见 PanelMotion)
    /// 托盘 ↔ 长条的视觉缝
    static var seam: CGFloat { k(16) }
    /// 玻璃收进语境屏时,与屏边留的安全边(长条与托盘共用)。
    ///
    /// **必须是同一个口径**:`PanelController.applySessionScaleCap` 用它算"本局放得下多大",
    /// `previewFrame` 用它把托盘摆回屏内。两处一旦不同口径,就会出现"算的时候放得下、
    /// 摆的时候出屏" —— 2026-09-14 的托盘出屏(最左那张预览卡被推到屏外)正是这个病的变体:
    /// 算的时候量的是玻璃,摆的时候量的是**窗口**(玻璃 + 两侧透明呼吸区),凭空多出 192pt。
    static let screenMargin: CGFloat = 24

    /// 阴影呼吸区:窗口比玻璃大出来的部分,给阴影留落点。
    /// 必须与 PanelController 的 paddedSize / previewSize 严格一致——两套账不一致会触发
    /// AppKit "Update Constraints" 布局递归直接 FAULT 崩溃(T6 实机现形)。
    ///
    /// 注意它是**透明**的:它越出屏幕什么也看不见,所以"放不放得下"只该拿玻璃去算。呼吸区
    /// 超过自身阴影落点(transparent)之外没有画任何东西,可以随便出屏。
    /// 阴影的 radius 是**定值**(不随面板尺寸缩放),所以垫的量也不用乘 scale,
    /// 只按面板最大档(1.5)留足余量。垫出来的透明边由 ClickThroughHostingView 放行点击
    static let shadowPadStrip: CGFloat = 108
    static let shadowPadPop: CGFloat = 96
    /// 长条最小宽度:单 App 时不至于缩成一枚图标
    static var minStripWidth: CGFloat { k(280) }
}

// MARK: - 色板(浅 / 深双值)
//
// ★ 2026-09-14 深色模式重建 —— 这一整节换过一次设计语言,别再退回旧写法。
//
// **旧版深色为什么"几乎0设计"**:每一格深色值都是「拿浅色值换一个 alpha」得来的 ——
// puck 白 .62 → 白 .26、glassBorder 黑 .12 → 白 .22、thumbBg 白 .60 → 白 .12。
// 于是深色不是一套配色,而是浅色的**残影**。实拍量出来的三条硬伤:
//
//   ① **托盘几乎纯黑**(实测 L≈53,而长条玻璃 L≈95):scrim(黑 .30)压在浅色壁纸上
//      会把背景整片压暗,玻璃的模糊/透光就全没了;而长条底下压的是深色码头,
//      同一配方算出 42 级的亮度差 —— 两块板子读起来不是一套东西。
//   ② **「形」全部隐形**(实测长条托底 Δ=12、发丝边 Δ=3):浅色的"形"靠**暗**在亮底上成立
//      (暗发丝、暗槽、贴身阴影);深色的底本来就是暗的,再叠白 .22/.26 这种低 alpha,
//      合成出来只比玻璃亮十来个色阶 —— 等于没画。
//   ③ 白色系 token 在深底上**泛灰**:白 .65 的窗数点压在半透明玻璃上,实得 L≈175,
//      既不是白也不够亮,读起来是"脏"而不是"亮" —— 深色里的高光必须**更亮更纯**,
//      不能只降 alpha。
//
// **重建后的规矩**(三条,深色任何改动都得守):
//   1. **深色不是"减掉的浅色",是另一套明度轴**。浅色 = 亮底 + 暗形;深色 = 暗底 + **亮形**。
//      所以深色的每个 token 都要问"它在暗底上够不够亮",而不是"它比浅色暗多少"。
//   2. **对比度按绝对色阶配,按"离玻璃几级"验收**:
//      长条玻璃 ≈ L 78(目标);选中托底要比它亮 **≥60 级**(实测旧版只有 12 级)。
//   3. **玻璃不压 tint 到黑**。深色的 scrim 只做到"给玻璃一点中性冷调",不承担压暗背景 ——
//      压暗是壁纸自己的事。旧版 .30 的黑直接把玻璃压成墨块。

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

    /// 深色的**实色**构造器:定的是绝对色阶,不是 alpha。
    /// 深色面板是"压在壁纸上的暗玻璃",用实色比用低 alpha 白可靠 ——
    /// 低 alpha 白的实际亮度取决于它底下的壁纸,壁纸一换就崩(这正是旧版翻车的方式)。
    private static func slate(_ level: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: level / 255, green: (level + 1.5) / 255, blue: (level + 4) / 255, alpha: alpha)
    }

    /// 玻璃外轮廓:浅色**暗发丝**(black .12);深色**亮发丝** —— 深色的"形"必须由亮线承担
    /// (白 .22 → 白 .34:旧值在 L=78 的玻璃上只有约 20 级的提升,还偏灰)。
    ///
    /// 2026-09-14 用户"白底玻璃实验台"的病理:浅色那套「形」原本全由**白色系** token 承担,
    /// 在纯白底上它们与背景同色隐形 —— 面板退化成"浮着的图标 + 一团阴影",
    /// 用户实评:"边框看起来有点模糊"。macOS 自己就是这么做的(浅底色窗口的边是暗发丝)。
    /// 对应实验台 **V2 灰色族收边**(只改浅色族)。深色同理反着来:亮线收边。
    static let glassBorder = dynamic(ink(0.12), white(0.34))
    /// 顶缘内阴影(demo `inset 0 1px 0 var(--glass-inner-shadow)`):浅色 .06 近乎无;
    /// 深色这道暗线把玻璃"压厚",整块板子才不会读成发光塑料(黑 .25 保留)
    static let glassInner = dynamic(NSColor.black.withAlphaComponent(0.06),
                                    NSColor.black.withAlphaComponent(0.25))
    /// 顶缘**受光边**(深色专用):深色面板的厚度由这道亮线交代 ——
    /// 黑影子在黑底上没有对手,单靠阴影板子是扁的。浅色返回**全透明**:
    /// 浅色曾经有过的 `glassTopLight`(白 .18 铺到 30% 高度)是"整个面板透明度不行"的元凶,别再回来。
    /// 白 .30 是画在 1.5% 高度上的一道边,不是一层纱
    static let glassTopEdge = dynamic(NSColor.clear, white(0.30))
    /// 选中托底(舌头)—— 浅色 **白 .62 定版**(2026-09-14 用户终审:"我还是喜欢最开始那个白色的,
    /// 更像滑块一样")。
    ///
    /// 这一格试过三个值,都对过照,记在这里免得后人重走:
    ///   · 白 .62 —— 这一次选它。读到的是**滑块/胶囊托底**,icon 压在上面像浮起来的滑块头;
    ///   · 黑 .10 —— 白底上看得见,但太透,"背景从里面透出来" → 用户评"透明塑料片子";
    ///   · 黑 .20 —— 实了,但观感是"灰膏",丢了滑块感。
    /// 代价(已知并接受):**纯白底上它比有色背景上显弱** —— 因为它是"亮",亮在白上不显形。
    ///
    /// **深色改用实色 L=138**(旧版 白 .26 合成后只有 L≈77,只比玻璃亮 12 级 → 看不见)。
    /// 深色里"选中"要读成**一块更亮的板**,靠的是绝对亮度而不是 alpha;
    /// 实色还带来一个好处:哪怕底下的壁纸变了,托底与玻璃的**落差恒定**。
    static let puck = dynamic(white(0.62), slate(138, alpha: 0.92))
    /// 托底发丝边:白底上"本体隐形"的那一半就靠它 —— 边是暗的,白底上才看得见形。
    /// 深色反过来:托底已经比玻璃亮,边要用**更亮的**唇来交代"这是一块浮起来的板"
    static let puckBorder = dynamic(ink(0.08), white(0.16))
    /// 上缘受光唇:浅色 .6 是"果冻感"的一半;深色**提到 .5** ——
    /// 深色托底是实色,受光唇是它唯一"玻璃感"的来源,弱了就变成一张塑料片
    static let puckLip = dynamic(white(0.6), white(0.5))
    /// 窗数点:浅色 ink .55(暗点,坐在亮玻璃上);深色白 .72 ——
    /// 旧版 .65 压在半透明玻璃上实得 L≈175,泛灰不清爽,深色的点必须更亮更纯
    static let dot = dynamic(ink(0.55), white(0.72))
    /// 主文案(App 名)
    static let txt1 = dynamic(ink(0.92), white(0.95))
    /// 次文案(窗数、标题)
    static let txt2 = dynamic(ink(0.56), white(0.62))
    /// 缩略图纸边:与长条同一族(浅色暗发丝 / 深色亮发丝)
    static let thumbBorder = dynamic(ink(0.12), white(0.30))
    /// 缩略图底纸:浅色**提白**到 .60 —— 实验台 V2 的另一半:边收暗了,纸面就要更实,
    /// 卡片的"形"才立得住(否则暗边包着一团半透明的灰,更糊)。
    /// 深色同样走**实色**(L=52):旧版 白 .12 在深玻璃上几乎与玻璃同色,卡片没有边界
    static let thumbBg = dynamic(white(0.60), slate(52))
    /// 标题条墨色(demo .win-title color):深色必须是**亮字** ——
    /// 它坐在深色芯片上,旧版 白 .75 已经偏灰,提到 .88;
    /// 深夜那轮芯片底再淡一档(见 `chipBg`),字补到 **.92** 兜住对比度。
    static let thumbTitle = dynamic(NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 25 / 255, alpha: 0.75),
                                    white(0.92))
    /// 缩略图标题条底色:截图之下的"纸"(与底纸同一档)
    static let thumbPaper = dynamic(white(0.60), slate(64))
    /// 芯片前的选中圆点:亮 = **系统强调色**(跟 macOS 的选中语言一致,且跟随用户在系统设置里挑的颜色);
    /// 暗 = 极淡的灰点**占位**(圆点出现/消失会让芯片文字左右跳)
    static let chipDotOn = Color.accentColor
    /// 深色 .26 → **.32**:芯片底变透(浅底上从 L45 抬到 L113)之后,同一颗灰点的可见度掉了一档,补回来
    static let chipDotOff = dynamic(ink(0.18), white(0.32))
    /// 窗口名芯片的底。
    /// 2026-09-14 用户实评"显示效果上感觉有点重了,芯片可以再轻盈一些" —— 浅色那一格往下压过:
    /// 从"近白实底"改成**半透**(和玻璃同呼吸,而不是贴在上面的一张标签),边从 .10 压到 .06。
    /// 芯片不靠底色立住,它靠**文字**在底上立住 —— 所以底可以很淡。
    ///
    /// ★ 2026-09-14 晚 深色重做:用户实评"暗色模式下有点重了…更像一个 label 而没有那种玻璃的清透感"。
    /// 一量就清楚,**病不在深,在不透明**:
    ///   · 托盘玻璃(实测 L≈174…218,底下是浅色文档,玻璃把它透上来了)
    ///     vs 芯片底(实测**恒为** L≈45,因为这正是实色 `slate(44)` 自己)
    ///     → Δ = **−150**,一块近黑的长条压在浅灰玻璃上;
    ///   · 更要命的是这个 45 **不随背景变**:壁纸一换,四周的玻璃从 L53 摆到 L200,
    ///     芯片纹丝不动 —— 一个"不跟着材质走"的东西贴在会走的东西上,读起来当然是标签而不是玻璃。
    ///
    /// 新值把它定义成**同一块玻璃上的第二层淡色**,而不是"压在玻璃上的一张牌":
    /// α .46 让底下的毛玻璃透上来 —— 浅底落到 **L≈113**(Δ −81,重量砍掉近一半),
    /// 深底落到 **L≈35**。玻璃本来就在替我们模糊背景,所以"清透"不需要芯片自己再做一次模糊:
    /// 透过它看到的是**已经毛玻璃化**的画面,这就是玻璃叠玻璃该有的样子。
    ///
    /// ★ 2026-09-14 深夜 再收一档(用户:"说白了,像是零几年的 macOS 系统那种玻璃质感太过时了"):
    /// 这一轮不是"再淡一点",而是**换掉了材质语言**。上一版虽然半透,但还挂着 Aqua 时代那两件套 ——
    /// **上缘高光唇 + 亮描边**(下面两格),合起来正是"零几年那种会反光的玻璃胶囊"。
    /// 现在:底从「slate(18) α .46」收到 **「slate(22) α .40」**,不再当"牌子"、只当**一层雾**;
    /// 深浅两态共用同一套配方(**平铺淡色 + 一根几乎看不见的发丝边,没有高光、没有渐变、没有唇**)。
    /// 结果:浅底 L≈118、深底 L≈41 —— 而"哪里需要它"由底自己决定:
    /// 压在白底玻璃上它显形(替白字找一个落点),压在本就暗的玻璃上它几乎消失(那里白字本来就够)。
    ///
    /// **浅色一格不动**(白 .26 是用户逐轮调出来的),只换深色。
    static let chipBg = dynamic(white(0.26), slate(22, alpha: 0.40))
    /// 芯片的边。
    /// 底变透之后,边的职责从"给不透明块收边"变成"交代这是一块玻璃" —— 深色 .14 → **.24**。这不是加重:半透底在**深**玻璃上只剩 Δ −15 的亮度差,
    /// 全靠这道亮唇才立得住(浅底那条 Δ −81 由底自己承担)。
    /// 实拍落点:浅底 L≈147(柔和的边)、深底 L≈88(清楚的边)。
    ///
    /// ★ 深夜那一轮把它压回来了:深色 `.24` → **`.10`**。原来那条"亮唇"就是 Aqua 的**镜面反光边**,
    /// 在半透底上尤其像"贴上去的塑料标签";现在它只做一件事 —— 给这层雾**留一丝边界**,
    /// 收在白 .10(压在半透底上合成 L≈128 对 118,Δ≈10:看得出来"这里有一块",但读不出"一根亮线")。
    /// 浅色 .06 不动。
    static let chipBorder = dynamic(ink(0.06), white(0.10))
    /// 红绿灯:macOS 系统规格色(#FF5F57 / #FEBC2E / #28C840),深浅一致不随外观变
    static let tlClose = dynamic(NSColor(srgbRed: 1.0, green: 95 / 255, blue: 87 / 255, alpha: 1),
                                 NSColor(srgbRed: 1.0, green: 95 / 255, blue: 87 / 255, alpha: 1))
    static let tlMin = dynamic(NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1),
                               NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1))
    static let tlZoom = dynamic(NSColor(srgbRed: 40 / 255, green: 200 / 255, blue: 64 / 255, alpha: 1),
                                NSColor(srgbRed: 40 / 255, green: 200 / 255, blue: 64 / 255, alpha: 1))
    /// 选中缩略图的内圈聚焦光:深色提到 .62 —— 聚焦圈要在**深色截图**上也读得出,
    /// 而截图本身多半是暗的(终端、编辑器),.4 会被截图吃掉
    static let thumbFocus = dynamic(white(0.55), white(0.62))
    /// 指针跟随高光:demo 是 soft-light 的白 30%,混不进进程外的玻璃,折成等效普通 alpha。
    /// 换算:soft-light(白)= √b,按 .30 权重大约提亮 0.06~0.08;白 alpha .12/.16 给 0.05~0.09。
    /// 深色 .20 → **.26**:深玻璃的底更暗,同样的 alpha 提亮量感知上更小(暗部 Weber 效应),
    /// 不补的话手电筒扫过深色面板几乎看不出光
    static let sheenAlphaLight: CGFloat = 0.14
    static let sheenAlphaDark: CGFloat = 0.26
}

// MARK: - Elevation(逐元素一根外阴影,数值逐字抄 demo;CSS blur 直径 ÷2 = radius)
//
// ★ 2026-09-14 深色重建 —— 深色的阴影不只是"更黑",而是**换了一套逻辑**。
//
// 浅色:阴影的任务是"在亮底上把板子抠出来",所以它要**实**(alpha 高、半径小、贴身)。
// 深色:底是暗的,黑影子在黑底上**没有对手** —— 一味加大 alpha 只会得到一团更黑的黑,
// 板子反而没有边界。深色里真正把板子"抬起来"的是两道一起用:
//   ① 一道**更黑的贴身暗**(把面板与它背后那层壁纸切开,alpha 要到 .60 量级);
//   ② 一道**亮的顶缘**(glassBorder 白 .34 + glassInner 的暗槽形成"厚度")。
// 也就是说深色的立体感有一半来自**亮线**,不能全指望阴影 —— 旧版把 .50 的黑往上一堆,
// 结果就是"面板周围一圈脏",板子本身还是扁的。

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
        case .strip: Layer(y: 30, radius: 30, light: 0.22, dark: 0.62) // 0 30px 60px
        // 托盘:2026-09-14 用户实评"外圈怎么有一圈阴影晕染" —— blur 22 太散,在深底上读成
        // 一圈光晕而不是"贴在面上"。收到 13,并压低 alpha:阴影该紧贴边缘、只交代"浮起"这一件事。
        // 深色 .40 → **.55**:长条是 .62,托盘是贴在长条头顶的"子板",层级要低一档但仍在同一族里
        case .tray: Layer(y: 14, radius: 13, light: 0.17, dark: 0.55)
        // puck:浅色按实验台 P2 收成"贴身影"。深色 .22 → **.45** ——
        // 深色托底现在是 L=138 的**亮板**,底下必须有一道够黑的影子,它才"浮"在玻璃之上;
        // .22 的黑在 L=78 的玻璃上几乎不留痕,托底会读成"贴纸"
        case .puck: Layer(y: 5, radius: 7, light: 0.14, dark: 0.45)
        // icon:浅色 .18(实评"底下的阴影在白底下看着像缺了一块")。
        // 深色 .30 → **.45**:图标坐在 L=138 的亮托底上,影子不够就飘着
        case .icon: Layer(y: 5, radius: 5, light: 0.18, dark: 0.45)
        case .thumb: Layer(y: 8, radius: 9, light: 0.18, dark: 0.42)
        case .thumbActive: Layer(y: 10, radius: 11, light: 0.28, dark: 0.55)
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
    /// 截断的第一道:超 `titleCharLimit` 先按**中段**斩(信息在尾部,见 `WindowTitle.middleTruncate`),
    /// 第二道由视图的 `.truncationMode(.middle)` 按真实宽度收尾(中英混排只有它算得准)。
    static func title(_ raw: String) -> String {
        WindowTitle.middleTruncate(raw, limit: PanelMetrics.titleCharLimit)
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
