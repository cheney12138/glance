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
    /// 指针光晕开关(设置 → 通用 →「指针光晕」)
    @AppStorage("panel.sheen") private var sheen = true
    @ObservedObject var controller: PanelController

    var body: some View {
        ZStack {
            GlassBackground(cornerRadius: PanelMetrics.rPanel)
            // 顶缘静态高光(旧 `glassTopLight`,白 .18)2026-09-14 已删:
            // 用户实评"整个面板透明度都不行"—— 它就是那层白纱的主体。
            // **浅色**不要这层,但**深色**要一道更窄更亮的 —— 见 glassTopEdge 的注释。
            glassTopEdge
            // demo .panel-sheen:玻璃之上、图标之下。
            //
            // v0.3 回退(2026-09-14 实拍):曾经试过给高光**挖掉图标格**(even-odd 遮罩),
            // 想让光斑只落在玻璃上 —— 结果是遮罩的**硬边界**在手电筒扫过时把每个格子
            // 读成了一个圆角"槽"(用户原话:"把后面 app 的浮起容器的槽给照出来了"),
            // 比原来的毛病重。结论:光斑落在 App 上也行(很浅,.14/.20 不影响观感),
            // 不准为了躲它去切硬边 —— 渐变上任何硬边界都是新的形状,不是遮罩。
            // 指针光晕(跟手柔光)—— 2026-09-15 做成**配置项**(用户口径:"有人不一定喜欢这个光效")。
            // 用 `if` 而不是"传 active:false":关掉时这层视图连同它的 TimelineView 一起不存在,
            // 不是"画一个看不见的东西",是真的没有开销。@AppStorage ⇒ 设置里一改立刻生效(不用重开面板)。
            if sheen {
                SheenOverlay(
                    active: controller.isVisible,
                    pointer: { [weak controller] in controller?.pointerInContent() }
                )
            }

            iconStrip
                .padding(.horizontal, PanelMetrics.rowPadX)
                // 上下对称:选中态"往上长"的那一段由**克制幅度**承担,不由边距承担
                // (加边距会让未选中时的长条白厚一圈,见 PanelTokens.iconLift 的取舍)
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
        // 入场与退场**都不做动效**(v1.12 砍入场,2026-09-14 砍退场):
        // ⌘Tab 是效率动作,面板要"已经在",关闭要"已经没了"——两头都不该让用户等动画。
        // 窗口由控制器直接 orderOut,这里的 opacity 只是兜住"显示中"这个状态
        .opacity(controller.isVisible ? 1 : 0)
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
                    // 开局第一帧/animation 关掉时给 nil:窗口是复用的,上一局的选中会在新一局开局时
                    // 从第 5 位"飞"回第 1 位。demo 的 positionPuck(_, animate:false) 同理
                    motion: controller.selectionAnimation(PanelMotion.select)
                )
                .frame(width: PanelMetrics.icon + PanelMetrics.iconGap, height: PanelMetrics.icon)
                // 入场升起**只给选中的那一格**(与托底同一次 withAnimation、同一根 spring):
                // ① 正确范围:第一版做成整行一起升 → "全部图标一起弹出来了"(用户实评,太重);
                // ② 为什么选中格必须跟着动:"正常 Tab 切换"里动的就是托底 + 新选中的那个图标,
                //    其余的只是被取消选中 —— 只滑托底而图标已经就位,读起来就是"两个动作各走各的";
                // ③ 幅度 = `entryFloatDistance`(选中图标自己的上浮量):读作"轻轻浮上来",不是"钻出来"
                .offset(y: i == controller.appIndex ? controller.contentEntryRise : 0)
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
            // 发丝边:把"纸片"放在玻璃上(实验台 P2)。用 strokeBorder = 画在边界**内侧**,
            // 所以托底的尺寸/位置一个像素都没动(用户口径:只改颜色,大小位置动效别动)
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckBorder, lineWidth: 1)
            )
            .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
            .offset(x: CGFloat(max(controller.appIndex, 0)) * (PanelMetrics.icon + PanelMetrics.iconGap),
                    // 纵向 = 入场升起(与选中那一格同源同值,所以两者永远同步)
                    y: controller.contentEntryRise)
            .elevation(.puck)
            // 弹簧,不是过冲 timingCurve:连着 Tab 横扫时,每一次打断都从**当前速度**续跑。
            // 上膛门(开局第一帧 + 设置开关)见 PanelController.selectionAnimation
            .animation(controller.selectionAnimation(PanelMotion.slide), value: controller.appIndex)
    }

    /// 顶缘一道**极窄的**受光边(深色专用)。
    ///
    /// 深色面板的"厚度"不来自阴影 —— 黑影子在黑底上没有对手。真正让人读出"这是块板"
    /// 的是顶缘这道亮线:光从上方来,玻璃的上沿受光,下沿背光,板子就有了厚度。
    /// macOS 自己的深色窗口、NSGlassEffectView 的深色态都有这道线。
    ///
    /// 与已删的 `glassTopLight`(白 .18 铺到 30% 高度)的区别在**高度**:
    /// 那道是一层纱(浅色上就是"透明度不行"的元凶),这道只有 1.5% 高度、只够描一条边。
    /// 浅色返回透明色(不改浅色)。
    private var glassTopEdge: some View {
        LinearGradient(
            colors: [PanelColors.glassTopEdge, .clear],
            startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.015)
        )
        .allowsHitTesting(false)
    }

    /// 确认涟漪的圆心 = 选中图标的中心(含 14px 上浮,demo 取的是变换后的 rect 中心)。
    /// X 与托盘锚点同源(`PanelLayout.iconCenterX`)
    private var selectedIconCenter: CGPoint {
        CGPoint(
            x: PanelLayout.iconCenterX(
                appIndex: controller.appIndex,
                appCount: controller.groups.count,
                contentWidth: controller.contentSize().width
            ),
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

    /// **光效总闸**(设置 → 通用 →「光效」):指针那团游走的柔光 + 这里的静态反光是同一件事的两半,
    /// 一起开、一起关(用户口径:"app 上的静态反光也关闭,一齐开启,或者关闭")。
    /// 关掉时图标回到**本来的样子**(不额外提亮、也不压暗),选中态靠放大 + 上浮 + 托底交代 ——
    /// 那三样是"形",不是"光",不受这个开关影响。
    @AppStorage("panel.sheen") private var glow = true

    var body: some View {
        let art = IconProvider.art(for: group.pid)
        Image(nsImage: art.image)
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .saturation(glow ? (selected ? 1.15 : 0.92) : 1)
            .brightness(glow ? (selected ? 0.05 : -0.04) : 0)
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

    /// 窗数点:每扇窗一粒,坐在图标下缘(demo bottom:-11)。
    ///
    /// 选中时必须跟着图标一起抬(`dotLift`,理由见 PanelTokens)—— 点挂的是**格子**底边,
    /// 而图标选中后是"上浮 + 放大"两件事一起动,点不跟就会掉队到托盘底边上去。
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
            .offset(y: PanelMetrics.dotBottom - (selected ? PanelMetrics.dotLift : 0))
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
