import SwiftUI
import AppKit

/// 切换器主面板 —— 施工契约 = 最新设计 demo「Liquid Glass App Switcher」。
///
/// 本文件是全系统度量与色板的**唯一来源**:`PanelController` 的定位数学与两个面板视图同源,
/// 任何数值只在这里定义一次。
///
/// 与 v1.10 的分野:选择态不再是"图标底下贴一块托底",而是一枚**会滑动的 puck**(胶囊托底,
/// 宽度=图标宽、上下各出 8px),配图标 14px 上浮 + 1.14 放大 + 未选降饱和;玻璃边缘恢复
/// 1px 亮边 + 指针跟随的 sheen。玻璃底色仍交给原生 `NSGlassEffectView`,不手写 tintColor。
///
/// v1.11 = 动效对表,三处机械病因的处治(别再退回去):
/// 1. **sheen 看不见**:demo 的 `.panel-sheen` 是 `mix-blend-mode: soft-light` 叠在**玻璃 DOM
///    元素**上;原生这边玻璃是 WindowServer 在**进程外**合成的,压根不在我们的层树里 —— SwiftUI
///    的 `blendMode(.softLight)` 对着透明底混了个寂寞。改成等效亮度的普通 alpha 合成,
///    并且按 demo 的 z 序落位:玻璃之上、puck 与图标**之下**(旧版画在最顶上,糊在图标脸上)。
/// 2. **动效僵硬**:过冲 `timingCurve` 在 SwiftUI 里不可靠,而且每次打断都从**零速度**重起 ——
///    横扫面板就一顿一顿。可打断的动效一律换弹簧(`PanelMotion`):弹簧带着当前速度续跑,
///    打断是"接力"不是"重起"。
/// 3. **sheen 拖着玻璃重渲染**:指针每挪一像素写一次 `@State`,整个 body(含玻璃
///    `NSViewRepresentable`)重算一遍,`updateNSView` 被按在地上摩擦。sheen 改由自带
///    `CAGradientLayer` 的 `SheenNSView` 自己听本窗 `.mouseMoved`,只挪一个 layer 的 position。
struct PanelView: View {
    @ObservedObject var controller: PanelController

    private var reduced: Bool { MotionPolicy.reduced }

    var body: some View {
        ZStack {
            GlassBackground(cornerRadius: PanelMetrics.rPanel)
            // demo .panel-glass::before:顶缘一道白,到 30% 高度收干
            glassTopLight
            // demo .ripple:确认瞬间从选中图标炸开的一圈白光(画在图标之下,不糊图标)
            if controller.confirmPulse > 0, !reduced {
                ConfirmRipple(center: selectedIconCenter)
                    .id(controller.confirmPulse)
            }
            // demo .panel-sheen:玻璃之上、图标之下
            SheenOverlay(
                active: controller.isVisible,
                pointer: { [weak controller] in controller?.pointerInContent() }
            )

            iconStrip
                .padding(.horizontal, PanelMetrics.rowPadX)
                .padding(.vertical, PanelMetrics.rowPadY)
        }
        .frame(width: controller.contentSize().width, height: controller.contentSize().height)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rPanel, style: .continuous))
        // 外轮廓:1px 亮边一圈(浅 .85 / 深 .45)。装饰层必须让路,否则吃掉图标的 hover/点击
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.rPanel, style: .continuous)
                .strokeBorder(PanelColors.glassBorder, lineWidth: PanelMetrics.hairline)
                .allowsHitTesting(false)
        )
        // 顶缘内阴影(demo inset 0 1px 0 --glass-inner-shadow):深色下这道暗线顺着圆角压住亮度
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.rPanel, style: .continuous)
                .strokeBorder(PanelColors.glassInner, lineWidth: PanelMetrics.hairline)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        // 入场 = demo 的 .switcher-wrap:scale .90→1(.48s 过冲)+ 渐入(.38s)
        .scaleEffect(controller.isVisible ? 1 : 0.9)
        .animation(MotionPolicy.animation(PanelMotion.rise), value: controller.isVisible)
        .opacity(controller.isVisible ? 1 : 0)
        .animation(MotionPolicy.animation(PanelMotion.fade(PanelMetrics.tFade)), value: controller.isVisible)
        .elevation(.strip)
        .padding(PanelMetrics.shadowPadStrip) // 必须与 PanelController.paddedSize 口径一致
    }

    // MARK: - 图标层

    private var iconStrip: some View {
        // spacing 归零、格子自己吃掉左右各半个间隙(hitSlop),两端再负 padding 收回来 ——
        // 这样格与格之间没有"鼠标划过却什么都不选中"的死区。间隙放大到 ~24 之后,
        // 死区宽达格子的 30%,指针横扫面板会明显发木。
        HStack(spacing: 0) {
            ForEach(Array(controller.groups.enumerated()), id: \.element.pid) { i, group in
                IconCell(
                    group: group,
                    selected: i == controller.appIndex,
                    // 面板没在台上就不许动:窗口是复用的,上一局的选中会在新一局开局时
                    // 从第 5 位"飞"回第 1 位。demo 的 positionPuck(_, animate:false) 同理
                    motion: controller.isVisible ? MotionPolicy.animation(PanelMotion.select) : nil
                )
                .frame(width: PanelMetrics.icon + PanelMetrics.iconGap, height: PanelMetrics.icon)
                .contentShape(Rectangle())
                .onHover { inside in if inside { controller.hoverApp(i) } }
                // 点图标 = 选中;再点已选中的 = 确认它的头牌窗(或激活无窗应用)
                .onTapGesture {
                    if i == controller.appIndex { controller.confirmSelection() } else { controller.hoverApp(i) }
                }
            }
        }
        .padding(.horizontal, -PanelMetrics.iconGap / 2) // 首格左、末格右各收回半个间隙
        // demo 的 .puck 是 z-index:1、.app-row 是 z-index:2——托底在图标**后面**。
        // SwiftUI 里 overlay 画在内容上面,会把选中格蒙住并吃掉点击,必须用 background。
        .background(alignment: .leading) { puck.allowsHitTesting(false) }
    }

    /// 滑动托底:宽 = 图标宽,上下各出 8px;换选中时整枚胶囊弹过去(位移+宽度同曲线)
    private var puck: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
            .fill(PanelColors.puck)
            // demo: inset 0 1px 1px rgba(255,255,255,.6)——托底上缘一道受光唇
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckLip, lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            // demo: inset 0 -1px 6px rgba(0,0,0,.12)——底缘一道内阴影,托底才有厚度,不是贴纸
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous))
            .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
            .offset(x: CGFloat(max(controller.appIndex, 0)) * (PanelMetrics.icon + PanelMetrics.iconGap))
            .elevation(.puck)
            // 弹簧,不是过冲 timingCurve:连着 Tab 横扫时,每一次打断都从**当前速度**续跑。
            // isVisible 闸同 IconCell:开局那一次落位是"就位",不是"滑过去"
            .animation(controller.isVisible ? MotionPolicy.animation(PanelMotion.slide) : nil,
                       value: controller.appIndex)
    }

    /// demo .panel-glass::before:`linear-gradient(180deg, rgba(255,255,255,.4), transparent 30%)`
    /// + `mix-blend-mode: overlay`。与 sheen 同样的处境(混不进进程外的玻璃),同样折成等效 alpha
    private var glassTopLight: some View {
        LinearGradient(
            colors: [PanelColors.glassTop, .clear],
            startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.3)
        )
        .allowsHitTesting(false)
    }

    /// 确认涟漪的圆心 = 选中图标的中心(含 14px 上浮,demo 取的是变换后的 rect 中心)
    private var selectedIconCenter: CGPoint {
        let n = CGFloat(controller.groups.count)
        let size = controller.contentSize()
        let stripW = n * PanelMetrics.icon + max(n - 1, 0) * PanelMetrics.iconGap
        return CGPoint(
            x: (size.width - stripW) / 2
                + CGFloat(controller.appIndex) * (PanelMetrics.icon + PanelMetrics.iconGap)
                + PanelMetrics.icon / 2,
            y: PanelMetrics.rowPadY + PanelMetrics.icon / 2 - PanelMetrics.iconLift
        )
    }
}

// MARK: - 图标格(选中 = 上浮 14 + 放大 1.14 + 提亮;未选 = 压暗去饱和)

private struct IconCell: View {
    let group: AppGroup
    let selected: Bool
    /// 该用的动效(nil = 不动:"面板不在台上"或系统要求降级)
    let motion: Animation?

    var body: some View {
        let art = IconProvider.art(for: group.pid)
        Image(nsImage: art.image)
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .saturation(selected ? 1.15 : 0.92)
            .brightness(selected ? 0.05 : -0.04)
            // 倍率 = 选中放大 × 图标透明边距补偿。**补偿是必须的**:macOS 图标的画面只占画布
            // 87.5%(Finder/Safari/Xcode/Terminal 实测 .875,Chrome .867,Obsidian .83),
            // 直接铺进 78pt 格子,画面就只有 68pt —— 比 demo 里铺满格子的色块小一圈,
            // 面板四周的留白跟着全部放大,这就是"下巴长的离谱"的真身(实测选中图标下方
            // 空出 24.5pt,demo 只有 16.5pt)。补偿后画面正好铺满格子,与 demo 一比一对齐。
            .scaleEffect((selected ? PanelMetrics.iconScale : 1) * art.fill)
            .offset(y: selected ? -PanelMetrics.iconLift : 0)
            // 不变量:阴影跟图片 alpha 走,不裁圆角、不套矩形 box-shadow
            .elevation(.icon)
            .overlay(alignment: .bottom) { windowDots }
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .contentShape(Rectangle())
            // 真实弹簧:response 越小越"脆",dampingFraction 越小回弹越明显。
            // 不用 .32s 的过冲 bezier —— 它在 SwiftUI 里不可靠,且每次打断从零速重起
            .animation(motion, value: selected)
    }

    /// 窗数点:每扇窗一粒,坐在图标下缘 7…11px 处(demo bottom:-11)
    @ViewBuilder private var windowDots: some View {
        if group.windows.count > 0 {
            HStack(spacing: PanelMetrics.dotGap) {
                ForEach(0..<group.windows.count, id: \.self) { _ in
                    Circle()
                        .fill(PanelColors.dot)
                        .frame(width: PanelMetrics.dot, height: PanelMetrics.dot)
                }
            }
            .opacity(0.8)
            .offset(y: PanelMetrics.dotBottom)
        }
    }
}

// MARK: - 指针跟随高光(demo .panel-sheen)
//
// demo:`radial-gradient(220px circle at mx my, rgba(255,255,255,.30), transparent 60%)`
//      + `mix-blend-mode: soft-light`,z 序在 `.panel-glass` 之上、`.puck`/`.app-row` 之下,
//      `transition: background .08s linear`(只跟光,不跟手粘死)。
//
// 两条原生现实决定了它不能照抄:
// 1. **混不动**:soft-light 要采样背后的像素,而原生玻璃由 WindowServer 在进程外合成,
//    我们层树里那一块是透明的 —— 对着透明底混,混出个寂寞。折换:soft-light(白)的等效
//    结果是 √b,按 .30 权重约提亮 0.06~0.08;白 alpha .12/.16 的普通合成给 0.05~0.09,肉眼等价。
// 2. **不能走 SwiftUI 状态**:指针每像素一写,整个 body(含玻璃 NSViewRepresentable)重算,
//    `updateNSView` 次次重进,拖着玻璃重渲染 —— 横扫面板一顿一顿的就是它。
//
// 3. **拿不到鼠标事件**:面板是 `nonactivatingPanel`,永不成 key。AppKit 的 mouseMoved
//    只投给 key 窗口(上一版走 `addLocalMonitorForEvents(.mouseMoved)`,一个事件都收不到,
//    光晕从来没亮过),NSTrackingArea 在 non-key 窗口上也不可靠。
//
// 解法:**不靠事件**。`TimelineView(.animation)` 每帧问一次 `NSEvent.mouseLocation`
// (全局读数,与谁 key、有没有事件无关),`Canvas` 直接画。三个好处:
// ① 它是纯 SwiftUI 内容,z 序就是写在 ZStack 里的顺序,不会被玻璃的 NSView 顶掉;
// ② 每帧只重算这一个叶子视图 —— 玻璃的 `updateNSView` 与图标一概不碰;
// ③ 指针位置用闭包现问,不进 `@State`,指针怎么划都不产生状态变更。

struct SheenOverlay: View {
    /// 面板在台上吗(不在台上就让时间轴停摆,省掉每秒 60 次空转)
    let active: Bool
    /// 指针在面板内容坐标里的位置(nil = 不在面板上)
    let pointer: () -> CGPoint?
    @State private var tracker = SheenTracker()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(paused: !active)) { _ in
            Canvas { ctx, _ in
                guard let (p, alpha) = tracker.step(target: pointer()) else { return }
                let peak = (scheme == .dark ? PanelColors.sheenAlphaDark : PanelColors.sheenAlphaLight) * alpha
                let r = PanelMetrics.sheenExtent // demo 的 220px 是**结束形状半径**
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(peak), location: 0),
                            .init(color: .white.opacity(0), location: PanelMetrics.sheenStop),
                        ]),
                        center: p, startRadius: 0, endRadius: r
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// 光晕的跟手状态:位置带滞后(只跟光,不跟手粘死),进出面板带淡入淡出。
/// 故意做成**引用类型**:每帧改它不算 SwiftUI 状态变更,不会触发任何视图重算。
final class SheenTracker {
    private var point: CGPoint?
    private var intensity: CGFloat = 0
    private var logged = false
    /// demo 的 `transition: background .08s linear`:60fps 下每帧追 45%,约 80ms 跟到位
    private let follow: CGFloat = 0.45

    /// 返回这一帧该画的位置与强度;nil = 不画
    func step(target: CGPoint?) -> (CGPoint, CGFloat)? {
        if let t = target {
            // 第一次被点亮打一行:光晕有没有被驱动起来,日志里一眼可见(只打一次)
            if !logged { logged = true; print("[T6] 光晕上线:指针 \(Int(t.x)), \(Int(t.y))") }
            point = point.map { CGPoint(x: $0.x + (t.x - $0.x) * follow, y: $0.y + (t.y - $0.y) * follow) } ?? t
            intensity += (1 - intensity) * 0.35
            return (point!, intensity)
        }
        intensity += (0 - intensity) * 0.18
        guard intensity > 0.01, let p = point else { point = nil; intensity = 0; return nil }
        return (p, intensity)
    }
}

// MARK: - 确认涟漪(demo .ripple)

/// demo 在确认瞬间往**壁纸层**丢一枚 `.ripple`:scale 0→4.2、opacity .9→0、.55s ease-out,
/// 90ms 后面板开始退场。原生没那层壁纸可画(demo 的波纹在玻璃**下面**,我们压在玻璃下等于没画),
/// 折中:画在玻璃之上、图标之下,裁进面板圆角 —— 读起来就是"玻璃被点亮了一下",图标不糊。
private struct ConfirmRipple: View {
    let center: CGPoint
    @State private var grown = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0), location: 0.7),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: PanelMetrics.ripple / 2
                )
            )
            .frame(width: PanelMetrics.ripple, height: PanelMetrics.ripple)
            .scaleEffect(grown ? PanelMetrics.rippleScale : 0.01)
            .opacity(grown ? 0 : 0.9)
            .position(center)
            .onAppear { withAnimation(.easeOut(duration: PanelMetrics.tRipple)) { grown = true } }
            .allowsHitTesting(false)
    }
}

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

// MARK: - 动效(弹簧,不是过冲 bezier)
//
// 旧版把 demo 的 `cubic-bezier(.22,1.6,.36,1)` 原样抄成 `.timingCurve(0.22, 1.6, 0.36, 1)`:
// ① y>1 的过冲曲线在 SwiftUI 里不可靠(引擎对越界控制点的处理跟 CSS 不是一回事);
// ② 更要命的是**每打断一次就从零速度重起** —— 连按 Tab 横扫面板时,puck 与图标每次都
//    "顿"一下再弹出去,看着就是机械僵硬。弹簧保留当前速度朝新目标续跑,打断即接力。

/// 动效总闸。**这是本项目的头号"看起来没动效"陷阱**:
/// 实测这台开发机的 `com.apple.universalAccess reduceMotion = 1` ——
/// 旧代码把所有动效写成 `.animation(reduceMotion ? nil : 弹簧)`,系统开关一开,
/// 弹簧、puck 滑动、入场**全部静默归零**,观感就是"弹起来但很硬,没有任何曲线"。
///
/// 现在的规矩:
/// 1. 尊重系统偏好,但**不是掐掉动画**——位移类降级成 160ms 的短淡入淡出
///    (Apple 的 reduce-motion 指引就是"别位移,改淡入淡出",而不是"东西凭空跳过去");
/// 2. **默认全效放行**。macOS 的"减弱动态效果"只有系统级开关,没有 per-app 豁免 API ——
///    想"只给这一个 App 放行",唯一的落点就是 App 自己这套开关(默认开)。
///    设置 → 通用 里可以关掉,回到跟随系统的行为;
/// 3. 面板每次出现打一行日志,动效在不在线一眼可见。
enum MotionPolicy {
    /// 覆盖开关:true = 无视系统偏好,始终播放完整动效(默认 true = 本 App 自己放行)。
    /// 用 `object(forKey:)` 而不是 `bool(forKey:)`:后者在"用户从没写过"时返回 false,
    /// 那样默认值就无法是 true。设置面板的 @AppStorage 用同一个 key、同样默认 true,
    /// 两边口径一致。
    static var alwaysAnimate: Bool {
        UserDefaults.standard.object(forKey: "motion.alwaysAnimate") as? Bool ?? true
    }

    static var systemReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 是否处于"降级动效"模式
    static var reduced: Bool { !alwaysAnimate && systemReduced }

    /// 取动效:正常给弹簧;降级给一记短淡出(不位移、也不硬跳)
    static func animation(_ full: Animation, reduced reducedDuration: Double = 0.16) -> Animation {
        reduced ? .easeOut(duration: reducedDuration) : full
    }

    static var describe: String {
        if alwaysAnimate {
            return systemReduced ? "完整动效(本 App 已放行;系统「减弱动态效果」开着)" : "完整动效"
        }
        return "降级为淡入淡出 —— 系统「减弱动态效果」开着,可在设置里放行本 App"
    }
}

enum PanelMotion {
    /// 图标选中(demo .app-icon 的 .32s):response 越小越"脆",dampingFraction 越小回弹越明显
    static let select = Animation.spring(response: 0.32, dampingFraction: 0.55)
    /// puck 滑移(demo .puck 的 .38s):阻尼比图标大一点,托底不抖
    static let slide = Animation.spring(response: 0.38, dampingFraction: 0.62)
    /// 缩略图选中(demo .win-thumb 的 .18s ease):demo 无过冲,阻尼给到 .9
    static let thumb = Animation.spring(response: 0.20, dampingFraction: 0.9)
    /// 容器入场(demo .switcher-wrap .48s / .preview-tray .28s,都带一点过冲)
    static let rise = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// 纯透明度(demo 的 ease)
    static func fade(_ duration: Double) -> Animation { .easeOut(duration: duration) }
}

// MARK: - 玻璃与图标提供者

/// 原生映射:macOS 26+ 用 `NSGlassEffectView`(边缘折射系统自带,禁止手刻);
/// 低版本回退 `NSVisualEffectView` `.popover` / `.active`。
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    static var supportsLiquidGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }

    /// 深色偏亮的解药 = demo 深色方案的 `--wallpaper-overlay: rgba(6,7,12,.30)`。
    /// HTML 压的是壁纸,原生压不了壁纸,只能把同一层中性灰压进玻璃(官方 tintColor,
    /// 不是手写底色:折射/模糊仍是系统的,这只是加一片中灰滤光片)。
    /// 浅色不压——系统玻璃本来就通透,再蒙一层白纱就糊成灰板(v1.6 的旧账)
    private static func scrim(for appearance: NSAppearance) -> NSColor? {
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return nil }
        return NSColor(srgbRed: 6 / 255, green: 7 / 255, blue: 12 / 255, alpha: 0.30)
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = Self.scrim(for: glass.effectiveAppearance)
            glass.contentView = NSView() // 给玻璃一个可包裹的内容层
            return glass
        }
        let fallback = NSVisualEffectView()
        fallback.material = .popover
        fallback.state = .active
        fallback.blendingMode = .behindWindow
        return fallback
    }

    /// 父 body 重渲染(换选中)就会进来一次 —— 只写真正会变的东西,别在这里做重活
    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
            glass.tintColor = Self.scrim(for: glass.effectiveAppearance)
        }
    }
}

/// 阴影呼吸区(96/80)让窗口比玻璃大出一整圈透明边——那圈边不能吃掉点击与 hover,
/// 否则托盘压住长条的呼吸区、以及"面板外点击 = 放弃"都会误判。
/// hitTest 在内容矩形外一律放行,事件穿到下一个窗口/桌面
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    /// 透明呼吸区宽度,与对应视图的 `.padding(shadowPad…)` 同值
    var pad: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard pad > 0 else { return super.hitTest(point) }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.insetBy(dx: pad, dy: pad).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// 真实 App 图标(NSRunningApplication.icon),pid 维度缓存。
/// .original:阻止 SwiftUI 把图标当模板图——非 key 窗口里模板图会被染灰
///
/// v1.11 追加**画面边距补偿**:macOS 图标的画面并不铺满画布,四周留了 6%~9% 的透明边。
/// 实测(Finder/Safari/Xcode/Terminal 0.875、Chrome 0.867、Obsidian 0.829),
/// 就按每个图标量出来的真实比例补,不写死经验值 ——
/// 不补的话,图标画面只有格子的 87.5%,面板四周留白整体放大,选中图标下方能空出 24.5pt
/// (demo 只有 16.5pt),看起来就是一个"长的离谱的下巴"。
enum IconProvider {
    struct Art {
        let image: NSImage
        /// 画布 ÷ 画面(≥1)。外面乘进 scaleEffect,画面就正好铺满 78pt 格子
        let fill: CGFloat
    }

    private static var cache: [pid_t: Art] = [:]

    static func art(for pid: pid_t) -> Art {
        if let a = cache[pid] { return a }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        let a = Art(image: img, fill: fillRatio(of: img))
        cache[pid] = a
        return a
    }

    /// 量画面占画布的比例(取倒数 = 补偿倍率)。
    ///
    /// 采样口径是标定过的:**128×128 + 最近邻 + alpha > 128(半透明边缘算画面边界)**,
    /// 与全分辨率真值误差 ≤0.001。换成 96px 双线性、或阈值放到 alpha>8(会把图标自带那圈
    /// 极淡的外发光/投影也算进画面)都会偏 3~5%,务必别改。
    ///
    /// 这套口径下 Finder/Safari/Xcode/Terminal/Chrome/Ghostty 一致落在 **0.805** ——
    /// 正好是 Apple 图标模板的安全区(1024 画布里的 824,squircle 外留 100px 给投影),
    /// 也就是说**画面只占画布 80.5%**。自定义全出血图标会量到 ~1.0,自然不放大。
    private static func fillRatio(of image: NSImage) -> CGFloat {
        let side = 128
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 1 }
        ctx.interpolationQuality = .none // 最近邻:双线性的模糊边会把包围盒撑大 3~5%
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            let row = buf + y * side * 4
            for x in 0..<side where row[x * 4 + 3] > 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return 1 }
        let covered = max(CGFloat(maxX - minX + 1) / CGFloat(side),
                          CGFloat(maxY - minY + 1) / CGFloat(side))
        // 夹在 1…1.3:全出血的自定义图标不放大,边距离谱的也别放太狠
        return min(max(1 / covered, 1), 1.3)
    }
}

// MARK: - 布局度量共享(规格唯一来源;PanelController 的定位数学与视图同源)

enum PanelLayout {
    /// 截断的第一道:超 12 字符先斩,宽度截断兜底中英混排
    static func title(_ raw: String) -> String {
        raw.count > PanelMetrics.titleCharLimit ? String(raw.prefix(PanelMetrics.titleCharLimit)) + "…" : raw
    }
}
