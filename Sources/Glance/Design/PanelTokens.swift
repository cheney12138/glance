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
    /// 给别的模块(如 `PanelMotion`)按基准值取一个跟着缩放走的量。
    /// 暴露的是"缩放后的值",不是 `k` 本身 —— 外面不该关心基线与倍率的区别。
    static func scaled(_ base: CGFloat) -> CGFloat { k(base) }

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
    /// 环 hover 热区内缩(2026-09-19 用户实报「碰到边边就选中」):hover 选中要求
    /// 指针落在格子内缩后的中心区;点按目标仍是整格(见 PanelController.hoverApp)
    static var hoverInsetX: CGFloat { k(12) }
    static var hoverInsetY: CGFloat { k(10) }

    /// ★ 上浮幅度:14 → **8**(2026-09-15,用户实评"选中上浮离边框有点近了",并裁定
    /// "**克制上浮的程度**,不要损失动效的灵动")。
    ///
    /// 为什么不是"加上边距":那一条我试过 —— 上边距要 +24pt 才够,而**没选中的时候**长条就白白
    /// 厚了一圈(用户原话:"加上边距也太丑了,你要考虑没选中的时候啊")。**别为了一个瞬时状态
    /// 去改常态的版式**。
    ///
    /// 幅度与"灵动"是两件事:灵动来自**弹簧曲线**(`PanelMotion.select`,damping .55 的回弹)
    /// 和**放大倍率**(`iconScale` 1.14),不来自位移。所以砍幅度、**曲线一格不动**。
    /// 现在的账(@1.2):上浮 9.6 + 放大外溢 7.4 = 视觉上移 17pt,距上沿 26.4 − 17 = **9.4pt**(原来 2.2)。
    /// 还想再收就动这一条;要更"活"是动 `PanelMotion.select`,不是动这里。
    static var iconLift: CGFloat { k(8) }
    /// 选中放大倍率是**比例**,不随尺寸变(变尺寸不该改变选中态的强烈程度)
    static let iconScale: CGFloat = 1.14
    /// 托底高度 = 图标 + 上下各 11。
    ///
    /// 2026-09-15 用户口径:「优化一下托底,我觉得有点小了,高度稍微的加长一点点」——
    /// `k(16)`(上下各 8)→ **`k(22)`**(上下各 11):base 104 → 110、@1.2 实得 124.8 → **132pt**(+7.2)。
    /// 只动高度、宽度一格未碰(宽度 = `icon`,由格子决定)。
    /// 安全线:长条内容高 = `rowPadY*2 + icon` = 158.4pt @1.2,托底 132pt 仍在里面(上下各余 13.2)。
    static var puckHeight: CGFloat { icon + k(22) }
    // § 指针跟随高光(demo `radial-gradient(220px circle …, transparent 60%)`)
    static var sheenExtent: CGFloat { k(220) } // 结束形状**半径**(不是直径!)
    static let sheenStop: CGFloat = 0.6 // 透明落在 60% → 可见半径 132
    // § 确认涟漪(demo .ripple:140px,scale 4.2,.55s ease-out)
    static var ripple: CGFloat { k(140) }
    static let rippleScale: CGFloat = 4.2
    static let tRipple: Double = 0.55
    // 窗数点(记账法:圆点=1 扇 / 短横=5 扇)
    static var dot: CGFloat { max(k(4), 3) }
    static var dotGap: CGFloat { k(3) }
    /// 窗数记账法的基准尺寸。**裁量全在 `GlanceCore.WindowTally`**(含为什么不用"每窗一粒点"、
    /// 为什么保留 24→25 的进位跳变、以及极端窗数下从尾部摘记号的兜底),这里只给设计 token ——
    /// 调外观只改这几个数。
    static var tally: WindowTally.Metrics {
        WindowTally.Metrics(dot: dot, dashWidth: dot * 2.5, gap: dotGap,
                            minDot: max(k(2.5), 2.5), minGap: k(1.7))
    }
    /// 短横高度。**不参与宽度裁量**(只影响观感),所以留在设计 token 里单独当旋钮。
    ///
    /// 2026-09-15 病例(用户实拍):原值 1.6×宽 / 0.42×高 → 面积 7.7×2.0 ≈ 15pt²,
    /// 而圆点 π·2.4² ≈ 18pt² —— **代表 5 的记号比代表 1 的还轻** ✗,层级是反的。
    /// 改 2.5× / 0.6× → 12.0×2.9 ≈ 35pt²(圆点的 1.9 倍):同一族、但明显更重。
    /// 对照图与另两档候选见 `design/窗数记号实验台.html`(python3 design/tally-lab.py 可重出)。
    static var dashHeight: CGFloat { dot * 0.6 }
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
    /// T88 起卡宽**随窗比例自适应**:`thumbW` 退役,宽度走 `thumbWidth(aspect:)`
    /// (196 = 122 × 1.61,恰好是旧定尺的等效值 —— 比例正常的横窗宽度几乎不变)
    static var shotH: CGFloat { k(122) } // 截图区(高度恒定,宽度变)
    /// 卡宽下/上限(基准 pt,过 k() 前夹):防极端竖条/横幅把一行撑爆或缩成纸条
    static let thumbMinW: CGFloat = 96
    static let thumbMaxW: CGFloat = 264

    /// 卡宽 = 高 × 窗口比例(122 = `shotH` 的基准,同源勿各写各的),夹限后过会期缩放。
    /// 卡片比例与截图比例由此**按构造相等** —— `fill` 不再裁内容,竖窗(微信登录窗那种
    /// 自绘窗)不再塞在横卡里留大灰边(2026-09-17 用户实拍病例)
    /// **卡片尺寸 = min(真实窗口尺寸, 设计上限)** —— 卡片尺寸的唯一来源。
    ///
    /// 用户口径(2026-09-21,连着三张截图讲清楚):
    ///   · IDEA 那种**大**窗口 ⇒ 卡片**钉在上限**("按照 idea 这个大小, 限制死了")✓ 不许跟着变大;
    ///   · Sublime 那种**被缩小过**的窗口 ⇒ 卡片**跟着真窗缩**("这个时候卡片自适应调整为跟真实窗口
    ///     一样的形状, 是 ok 的")✓ —— 形状与真窗一致 ⇒ 渲染 1:1 ⇒ 既不放大也不裁 ✓;
    ///   · **反之(大)就不行** ⇒ 上限永远管着 ✓。
    /// 推论:一行里的卡片可以**大小不一**(用户接受"参差不齐" ⇒ 换来"所见即真窗大小");
    ///       因此托盘的行高、内容高度、命中判定都必须按**每张卡的实际高度**算,不能再当常量 ✗。
    static func thumbSize(real: CGSize, aspect: CGFloat) -> CGSize {
        let capW = thumbWidth(aspect: aspect)          // 上限:沿用原来的"随比例自适应 + 夹上下限"
        let capH = shotH
        guard real.width > 1, real.height > 1 else { return CGSize(width: capW, height: capH) }
        let s = min(1, capW / real.width, capH / real.height)   // 只许缩小,不许放大
        return CGSize(width: (real.width * s).rounded(), height: (real.height * s).rounded())
    }

    static func thumbWidth(aspect: CGFloat) -> CGFloat {
        k(min(max(122 * max(aspect, 0.2), thumbMinW), thumbMaxW))
    }
    // § 卡面压色(方案 D:统一底色 + 低透明度截图,`design/卡面实验台.html` 对照图拍板 2026-09-16)
    /// 非选中卡的**截图不透明度**(选中/悬停 = 1,恢复原样)。0.30 = 实验台默认值:
    /// 底色接管卡面,内容只留"结构"可辨(侧栏 / 终端网格 / 标签页)——"认窗"靠结构,
    /// "哪个 App"靠图标层,"哪一扇"靠标题芯片,三者都不受压色影响
    static let thumbWash: Double = 0.30
    /// 红绿灯上方那层**毛玻璃**的模糊半径与渐变高度(固定 UI 规格:灯本身固定 11pt,不随卡片缩放)。
    /// 用户口径:"要跟现在 Switcher 长条一样的模糊,但是是渐变效果" —— 所以这是模糊,不是暗色遮罩
    /// 14 → 26、46 → 62(2026-09-14 用户实评"模糊度不够高,而且好像没覆盖红绿灯的区域")。
    /// 高度的取法:要**盖过灯那一行并留出余量** —— 灯在 9…20pt,渐变到 62pt 才收干,
    /// 头顶这一行才算真的"坐在毛玻璃上"。
    /// ⚠️ 一句技术实话:纯模糊对**白色内容**几乎无效(白糊了还是白),所以"看不出覆盖"很大程度
    /// 是内容太素,不是没生效(对比同位置的结构化内容最明显)。要让白底内容也读得出"毛玻璃",
    /// 就得在模糊之上再压一层**极淡的白/灰膜**(材质的做法) —— 那会改变画面亮度,单独一轮再议
    static let lightsBlur: CGFloat = 26
    /// 2026-09-15:62 → 78。用户要"没有底边",而**任何渐变被固定高度截断都会留出边** ✗ ——
    /// 62 时最后收干段只剩十几个点,视觉上仍是一条边;拉长到 78 让尾段有足够距离收干 ✓。
    static let lightsFade: CGFloat = 78
    /// 窗口名**芯片**(2026-09-14 用户要求:标题从卡片内挪到**卡片外**下方,做成芯片样式 ——
    /// "显示在预览框里很丑…不影响文字显示,又不跟预览窗耦合,位置相对 app 的每个窗口居中")
    static var chipH: CGFloat { k(18) }
    /// 芯片前面的**选中圆点**(2026-09-14 用户要求:多窗口时"浮动效果不明显",要一眼看出选中的是哪扇窗)。
    /// 颜色选**系统强调色**:与 macOS 的选中语言一致,而且跟随用户在系统设置里挑的强调色。
    /// 未选中时留一颗极淡的灰点**占位** —— 否则圆点出现/消失会让芯片文字左右跳
    /// ★ 2026-09-21 方案 1「身份自带」(用户裁定,见 design/预览托盘-形态对照.html):
    /// 胶囊里带一枚**小 App 图标** ⇒ "这张卡属于谁"写在卡片**自己身上** ✓
    /// 动机:原来靠"位置"抚示归属(卡片在哪个图标下面)⇒ 而位置和行宽绑死 ⇒ 窗口一多必出屏 ✗,
    /// 而且小组居中后跟选中图标毫无几何关系 ✗(用户实拍"错了十万八千里")。
    /// 归到卡片自己身上之后,**位置就自由了** ⇒ 后续可以"永远居中、换 App 不动"✓
    static var chipIcon: CGFloat { k(12) }
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

    /// T91 表三那枚芯片的**玻璃**尺寸(说话局长条窗口里装的全部内容)。
    /// v2(2026-09-18 用户实评「太大太重」):240×52 是长条量级的配重,套在一句 12pt 的
    /// 话上就是一块板 ⇒ 收到 168×36(面积约砍半),文字/内边距见 PanelView 的胶囊。
    /// ⚠️ 口径必须只有一本:这是**玻璃**的账,窗口 = 它 + 2 × shadowPadStrip(见 paddedSize);
    /// 胶囊圆角 = height / 2(见 PanelView 的 GlassBackground)。上一版一边拿它当玻璃、
    /// 一边拿它当窗口去减呼吸区 ⇒ 算出**负圆角**;更早一版内容按 240 算、窗口按"整局最大"算
    /// ⇒ AppKit Update Constraints 布局递归(触发层被带走)。两本账只许留一本。
    static let hintContentSize = NSSize(width: 168, height: 36)

    // § 启动区(历史):v11 的"分割线 + 入口槽"与 T89 尾格均已随双环模型 C 撤除
    // (hover 误触病例 + ADR-0013);活下来的只有托盘/启动段共用的幽灵壳度量(下面 ghostTileRadius)。
    /// **幽灵贴圆角**(T84):走 macOS 图标的比例(≈22.5%) ——
    /// 幽灵贴(启动段的壳)的立身之本是"读起来是一枚 app 图标形状的壳"
    static var ghostTileRadius: CGFloat { icon * 0.225 }
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
    /// ⚠️ 2026-09-15:原来的 `glassBorder`(墨 12% / 白 34%)是**画上去的 1px 线**,
    /// 实测与 macOS 原生 ⌘Tab 的柔边不同口径,已由 `glassLip` 取代(见 `PanelGlass.GlassEdge`)。
    /// 留一行记录:改回硬线只需把它接回 `strokeBorder`。
    static let glassBorder = dynamic(ink(0.12), white(0.34))
    /// 玻璃边的"受光唇":软边,几乎只在上缘显出来。数值取自原生剖面的量值(1–1.5px 级)
    static let glassLip = dynamic(white(0.10), white(0.16))
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
    /// 入口槽分隔缝的**中段色**(两端收干的渐变由视图承担)。浅色暗、深色亮 —— 与发丝边同一族:
    /// 它要读成"玻璃上的一道记号",不是"画上去的一条线"
    /// 入口槽分割线(v10 定色,用户口径:浅色主体下为**黑**,暗色主体下为**白**,
    /// 就是为了视觉上有区别)。v11 起它站在入口槽**前面**,负责"区与区之间"
    static let entrySeparator = dynamic(ink(0.30), white(0.34))
    /// 分割线的选中/悬停态(v10 预留;v11 分割线不做选中表达,暂不接线)
    static let entrySeparatorHot = dynamic(ink(0.58), white(0.70))
    /// **幽灵贴**(T84):托盘启动行的「壳」(v15 起入口槽不用它 —— 那里是纯点阵,无底座)。
    /// 比 puck 收一档 —— 壳是**座位**,不是主角:坐进去的图标必须比壳先被看见
    static let ghostTile = dynamic(white(0.42), slate(138, alpha: 0.62))
    /// 瓷贴发丝边(v14):浅色暗发丝收形;**深色透明** —— 白色受光唇/亮边让瓷贴读起来
    /// 像一枚 App 窗口(用户裁定去掉),深色的"这是入口"由底色差自己交代
    static let ghostTileBorder = dynamic(ink(0.10), NSColor.clear)
    /// 窗数点:浅色 ink .55(暗点,坐在亮玻璃上);深色白 .72 ——
    /// 旧版 .65 压在半透明玻璃上实得 L≈175,泛灰不清爽,深色的点必须更亮更纯
    static let dot = dynamic(ink(0.55), white(0.72))
    /// 主文案(App 名)
    static let txt1 = dynamic(ink(0.92), white(0.95))
    /// 次文案(窗数、标题)
    static let txt2 = dynamic(ink(0.56), white(0.62))
    /// 缩略图纸边:与长条同一族(浅色暗发丝 / 深色亮发丝)
    static let thumbBorder = dynamic(ink(0.12), white(0.30))
    /// 缩略图卡面**统一底色**(方案 D,2026-09-16 用户对照图拍板;实验台 `design/卡面实验台.html`):
    /// 非选中卡的截图压到 `PanelMetrics.thumbWash`(30%),底色接管卡面 —— 一排过去不再深浅乱跳;
    /// 选中的那张截图不透明,底色看不见(恢复原样)。**必须实色**:半透底会透出玻璃背后的壁纸,
    /// 壁纸一换"统一"就漏了(深色重建那轮的同一教训)。浅 `#eceff3` / 深 `#2b3037` 都是实验台拖出来的定稿值。
    /// (旧值 白 .60 / slate(52) 半透,是"提白"那轮的口径,本轮取代)
    static let thumbBg = dynamic(
        NSColor(srgbRed: 236 / 255, green: 239 / 255, blue: 243 / 255, alpha: 1),
        NSColor(srgbRed: 43 / 255, green: 48 / 255, blue: 55 / 255, alpha: 1)
    )
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
    /// **浅色那一格 2026-09-21 改了**(用户实报:「去掉背景之后,底部的芯片在纯白场景下字体容易被污染」):
    /// 原来浅色是 `white .26` —— 那是**按"芯片坐在托盘玻璃上"设计**的 ✓(玻璃已经把背景模糊过一遍,
    /// 芯片只需一层淡雾 ✓)。但外层玻璃撤掉之后 ✗,芯片直接坐在**任意背景**上 ——
    /// 纯白窗口上 `white .26` 几乎等于没有底 ⇒ 深灰字直接和背后的 Finder 列表打架 ✗。
    /// 新前提:**芯片必须自己站住**(它现在是自由浮在桌面上的元素,不再有玻璃垫着)⇒
    /// 浅色提到 **.72**(一枚浅胶囊 ✓,深灰字永远有同一个落点 ✓);
    /// 深色不动(slate 22 α .40 在深背景上本来就立得住 ✓ 且那是上一轮逐轮调出来的 ✓)
    /// ★ 2026-09-21 深色那格也改了(用户实报:「芯片显示的内容还是被影响了」+ 截图:
    ///   芯片坐在深色 IDE 的**亮色代码**上 ⇒ α .40 的底把背后的亮码透上来,浅色字被冲淡 ✗)。
    ///   旧值 `.40` 成立的前提是「芯片坐在**托盘玻璃**上」(玻璃已经把背景模糊过一遍 ✓)——
    ///   外层玻璃撤掉后,它直接坐在**任意背景**上 ⇒ 必须自己站住:
    ///   深色 slate(22) α .40 → **.74**;浅色那格同理(.26 → .72,见下)。
    ///   铁律:漂浮元素不得假设"下面一定有玻璃" ✓(写进 docs/预览托盘-铁律.md)
    /// ★ 2026-09-21 第三次修正(用户实报「还是会污染」+ 截图):
    ///   芯片坐在深色 IDE 的**亮色代码/白字**上 ⇒ 不管 .40 还是 .74,只要不是**实质上不透明**,
    ///   背后的高对比内容就会透上来跟标题打架 ✗。
    ///   ⇒ 两格都推到 **.90**(看上去仍是一枚胶囊 ✓,但对比度由它自己完全掌握 ✓)。
    ///   这是·权宜之计;根治办法写在 `design/预览托盘-设计说明.md`:
    ///     **把标题挪进卡片画面之内**(压在卡底 + 渐变兜底)⇒ 它永远坐在"这张窗自己的画"上,
    ///     不再需要跟任意背景比对比度 ✓。
    static let chipBg = dynamic(white(0.90), slate(18, alpha: 0.90))
    /// 芯片的边。
    /// 底变透之后,边的职责从"给不透明块收边"变成"交代这是一块玻璃" —— 深色 .14 → **.24**。这不是加重:半透底在**深**玻璃上只剩 Δ −15 的亮度差,
    /// 全靠这道亮唇才立得住(浅底那条 Δ −81 由底自己承担)。
    /// 实拍落点:浅底 L≈147(柔和的边)、深底 L≈88(清楚的边)。
    ///
    /// ★ 深夜那一轮把它压回来了:深色 `.24` → **`.10`**。原来那条"亮唇"就是 Aqua 的**镜面反光边**,
    /// 在半透底上尤其像"贴上去的塑料标签";现在它只做一件事 —— 给这层雾**留一丝边界**,
    /// 收在白 .10(压在半透底上合成 L≈128 对 118,Δ≈10:看得出来"这里有一块",但读不出"一根亮线")。
    /// 浅色 .06 不动。
    /// 浅色 .06 → **.10**(2026-09-21,与 `chipBg` 同一次):底变实之后需要一根清楚的边界,
    /// 否则白底上一枚浅胶囊读不出"这里有一块" ✓。深色 .10 不动。
    static let chipBorder = dynamic(ink(0.10), white(0.10))
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
        // ⚠️ 2026-09-15 病例(白底上"边框被模糊了"):量了白底上的边缘剖面 ——
        //   我们:背景 0.914 → **0.796(一圈暗晕)** → 内部 1.000   ← 暗晕 ΔL 0.118
        //   原生:背景 0.980 → 0.902 → 0.898                  ← 几乎没有暗晕
        // 填充本身的对比其实够(1.000 vs 0.914 = 0.086,与原生同级 0.08);
        // 让它"糊"的是这圈又宽又重的投影 —— 看着就像一条被模糊掉的边框。
        // 本次**只动 alpha**(y/radius 保持 demo 的 30/30,一次只动一个变量):
        // 浅色 .22 → .06,暗晕按比例落到 ≈0.03。若还嫌糊,下一个旋钮是 y 与 radius。
        // 2026-09-15 第二轮(用户:「边界还是有模糊感,看下原生为什么不会」)——把原生在**白底**上的
        // 剖面也量了(y=180 / y=300 两条一致):
        //   原生:背景 0.941 → 0.909 → 0.914(内部)   1–2px 干脆一步;内部比背景**暗** 0.027;无暗晕
        //   我们:背景 0.914 → 0.796 → 1.000(内部)   内部比背景**亮** 0.086;暗晕 ΔL 0.118
        // 结论:原生浅底上把背景**压暗**(方向正确 → 边界是色阶),而且**不投影**;
        // 我们提亮 + 套着一圈比它整道色阶还大 4 倍的暗晕 —— 模糊感就是这圈暗晕给的。
        // 所以浅色投影直接归零(留 0.02 的一口气);深色不动(深底上那是"浮起",不是"糊")。
        // 2026-09-15 第三轮(用户:「底部还是不够明显,加点阴影强化?整体白值跟透明度我觉得 ok 了」):
        // 填充与透明度不动,把投影从"大而软"改成**朝下的紧贴影** ——
        //   旧:`y:30 blur:30` → 四周一圈 ΔL 0.118 的暗晕(那就是"糊")
        //   新:`y:8  blur:10 α .13` → 阴影被推到**下方** ~8pt、只散 10pt:
        //        底边得到一条可见的接触影,左右两侧只剩很淡的一半,顶边几乎为零(offset 抵消)。
        // 这与原生那套不冲突:原生浅底靠"压暗背景"定形,我们靠"底边接触影"+填充的 0.086 色阶。
        case .strip: Layer(y: 8, radius: 10, light: 0.13, dark: 0.62) // 原 demo:0 30px 60px
        // 托盘:2026-09-14 用户实评"外圈怎么有一圈阴影晕染" —— blur 22 太散,在深底上读成
        // 一圈光晕而不是"贴在面上"。收到 13,并压低 alpha:阴影该紧贴边缘、只交代"浮起"这一件事。
        // 深色 .40 → **.55**:长条是 .62,托盘是贴在长条头顶的"子板",层级要低一档但仍在同一族里
        // 同一物理:托盘是同一块玻璃,一并对齐;它的影子落在长条上,正好把两块的接缝交代出来
        case .tray: Layer(y: 6, radius: 8, light: 0.11, dark: 0.55)
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
    /// 投影。`active == false` 时**参数归零**(而不是拿掉这个修饰符)——
    ///
    /// 2026-09-15 定稿(用户口径:**帧率优先**):SwiftUI 的 `.shadow(...)` 会给整棵子树做一次
    /// 离屏光栅化,11 个图标就是 11 次 ✗。实测(同一台机器、同一块屏、只改这一处):
    /// `[打卡] … 开窗`(首帧渲染)从典型 **18–30ms** 降到 **10–13ms**,从"超过一帧"进到"一帧以内" ✓。
    /// 现在只让**选中的那一颗**带投影(1 次而不是 N 次)。
    ///
    /// 为什么用"参数归零"而不是 `if`:**修饰符链必须保持同一条**。图标格子的选中态每次 Tab 都在变,
    /// 用条件包裹会改变视图身份,把选中弹簧的动画打断 ✗;改数值不会。
    func elevation(_ level: PanelElevation, active: Bool = true) -> some View {
        let s = level.shadow
        return shadow(color: active ? s.color : .clear,
                      radius: active ? s.radius : 0,
                      y: active ? s.y : 0)
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

// MARK: - 红绿灯公共组件(2026-09-19 从 PreviewPanelView 抽出,见 TrafficLights 头注)

/// **红绿灯公共组件**(2026-09-19 从 PreviewPanelView 抽出):关闭/最小化/缩放
/// 三粒灯的唯一定义,任何表面复用这一套(色 token 同在本文件,`PanelColors.tl*`)。
struct TrafficLights: View {
    let wid: CGWindowID
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
    /// 未选中的卡片:三粒灯去饱和(= macOS 上"非激活窗口"的样子 ✓)
    let dimmed: Bool
    /// **红灯禁用**(2026-09-18 用户裁定):Glance 自己的窗(设置/权限)在预览卡上的
    /// 红灯置灰、点了没反应 —— 切换器不能从面板上关掉自己的窗再"自杀"
    var closeDisabled: Bool = false
    /// 哪一粒被直接踩到(nil = 没踩到整组):
    /// 整组里**任意一粒**被悬停 → 三粒一起出符号;只有被直接踩到的那一粒放大
    @State private var hoveredDot: Int?

    var body: some View {
        // spacing 归零、每粒自带 3pt 内边:间距不变(11+6),但两粒之间的缝也算"踩到"
        HStack(spacing: 0) {
            light(PanelColors.tlClose, "xmark", closeDisabled ? "Glance 的窗口不能在这里关闭" : "关闭窗口", 0, close, disabled: closeDisabled)
            light(PanelColors.tlMin, "minus", "最小化窗口", 1, minimize)
            light(PanelColors.tlZoom, "arrow.up.left.and.arrow.down.right", "缩放窗口", 2, zoom)
        }
    }

    private func light(_ color: Color, _ symbol: String, _ hint: String,
                       _ index: Int, _ action: @escaping () -> Void,
                       disabled: Bool = false) -> some View {
        TrafficLight(color: color, symbol: symbol, hint: hint,
                     showsGlyph: hoveredDot != nil,
                     hovering: hoveredDot == index,
                     dimmed: dimmed || disabled,
                     action: disabled ? {} : action)
            .padding(3)
            // 逐粒听 hover,而不是给 HStack 挂一个:容器上的 onHover 会被子按钮吃掉
            // (实机现形:只有被踩到的那一粒出符号,另两粒没反应)
            .onHover { inside in
                if inside {
                    hoveredDot = index
                } else if hoveredDot == index {
                    hoveredDot = nil
                }
            }
    }
}

/// 一粒灯。状态由父级传(整组管符号、单粒管放大 —— 两个层级,与 macOS 同构)
struct TrafficLight: View {
    let color: Color
    let symbol: String
    let hint: String
    let showsGlyph: Bool
    let hovering: Bool
    /// 未选中 = 灰(见 TrafficLights.dimmed)
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        // Button 而不是 onTapGesture:卡片本身挂着"点一下 = 确认"的手势,
        // Button 才能把它隔开(子级优先),不会误触确认
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    // 符号色 = 本色的深色版(黑 50% 叠上去就是系统那个暗红/暗赭/暗绿)
                    Image(systemName: symbol)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.5))
                        .opacity(showsGlyph ? 1 : 0)
                }
                .scaleEffect(hovering ? 1.15 : 1)
                // 去饱和是"克制"的来源:亮点只在你看着它的时候出现。
                // 用 saturation+opacity 而非新增灰色常量 —— 灰值随明暗外观自动正确,
                // 也不必为一个中间态往设计系统里塞 token ✓
                .saturation(dimmed ? 0 : 1)
                .opacity(dimmed ? 0.55 : 1)
                .animation(.easeOut(duration: 0.18), value: dimmed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: showsGlyph)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)   // 焦点环全系统关闭(红绿灯永不长蓝框)
        .help(hint)
    }
}


/// **单枚红灯关闭钮**(公共化便利件):sheet/编辑器这类"一张纸"界面的退出点,
/// 与窗口红绿灯同一套语言 —— 不再另画 xmark 圆钮。
struct TrafficLightClose: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        TrafficLight(color: PanelColors.tlClose, symbol: "xmark", hint: "关闭",
                     showsGlyph: true, hovering: hovered, dimmed: false, action: action)
            .scaleEffect(hovered ? 1.1 : 1)
            .padding(3)
            .onHover { hovered = $0 }
    }
}

// MARK: - 托盘**窗口**的几何(唯一来源)

/// 托盘窗(底部那排窗口卡)的几何 —— **一处算,处处读**。
///
/// 为什么要它(P0-2,2026-09-21):托盘的几何原来在**三个地方各算一遍** ✗ ——
///   · 窗口尺寸:`PanelController.previewSize()`(用"整局最大内容" + 向上取整);
///   · 窗口位置:`PanelController.previewFrame()`(x 一度用"**当前组**内容宽",尺寸却用整局最大 ✗);
///   · 内容大小:`PreviewPanelView`(用它自己的 `previewContentSize()`,带小数)。
///   三本账只要有一处取整规则/取数来源不同,就会互相改来改去。实机账(全在日志里):
///     `[窗框] 托盘窗 1082x406 → 1081x405` 一局 **100+ 次**(两本账差 1pt 的 ping-pong)✗;
///     `[窗框] 托盘窗 418.0,527.0 → 418.5,527.2` 一局 **104 次**(原点是亚像素,被 AppKit 吸附)✗;
///     `[窗框] 托盘窗 …` 一局 **335 次**(x 随"当前组"变 ⇒ 窗口左右滑)✗。
///
/// 约定(写进类型,不靠自觉):
///   · 输入只有三样:**本局最大内容尺寸**(整局恒定)、主面板窗框、所在屏可用区;
///   · 输出的尺寸与原点**取整规则写在这里**(尺寸向上取整 = AppKit 对内容视图的行为;原点向下取整 = AppKit 对窗口原点的吸附);
///   · 别处**不许**再自己算窗口尺寸/位置 —— 要改就改这里一处;
///   · `contentSize`(玻璃/内容自己的大小)是**另一件事**(随选中格变),本类型只提供"窗口",不合并两者。
struct TrayGeometry {
    /// 托盘窗的尺寸(已按上面的取整规则定死)
    let windowSize: NSSize
    /// 托盘窗的原点(屏幕坐标,已取整)
    let windowOrigin: NSPoint
    /// 窗口框(交给 `setFrame`)
    var frame: NSRect { NSRect(origin: windowOrigin, size: windowSize) }

    /// - Parameters:
    ///   - maxContentSize: 本局所有托盘内容里的**最大**尺寸(整局恒定 ⇒ 窗口整局只落位一次)
    ///   - panelFrame: 主面板窗框(托盘与它同轴、并贴在它下沿)
    ///   - screenArea: 面板所在屏的可用区(用来保证托盘不出屏)
    init(maxContentSize: NSSize, panelFrame: NSRect, screenArea: NSRect) {
        let pad = PanelMetrics.shadowPadPop * 2
        let size = NSSize(width: (maxContentSize.width + pad).rounded(.up),
                          height: (maxContentSize.height + pad).rounded(.up))
        // 缝是两块**玻璃**之间的空当,不是两个窗框之间:缝 = padPop + padStrip − 帧距,
        // 反解出帧距 = padPop + padStrip − seam(两窗在各自的透明呼吸区里大幅重叠,靠点击穿透互不相扰)
        let frameGap = PanelMetrics.shadowPadPop + PanelMetrics.shadowPadStrip - PanelMetrics.seam
        var x = panelFrame.midX - size.width / 2          // 窗口居中 ⇒ 内容随之居中(与长条同轴)
        let margin = PanelMetrics.screenMargin
        if size.width <= screenArea.width - margin * 2 {
            x = min(max(x, screenArea.minX + margin), screenArea.maxX - margin - size.width)
        }
        self.windowSize = size
        self.windowOrigin = NSPoint(x: x.rounded(.down), y: (panelFrame.maxY - frameGap).rounded(.down))
    }
}
