import GlanceCore
import SwiftUI

/// 滑动托底（用户口中的"白色滑块"）—— **独立一块，方便调试与修改**。
///
/// 2026-09-22 从 `PanelView` 里拆出来（那里内联了 40 行、夹在 500 行视图中间 ⇒ 改一个数
/// 得先找半天 ✗）。现在**凡是托底的事都在这一个文件里**：几何 / 视觉 / 动效 / 落点数学。
///
/// ## 它是什么
/// 选中那一格**坐着的板**：宽 = 图标宽、比图标高出 `PanelTokens.puckHeight - icon`。
/// 它**不画在格子里**：挂在条带的最左缘、用 `offset(x:)` 滑到目标格
/// （这样它才能在格与格之间"滑过去"，而不是每格各画一枚 ✓）。
///
/// ## 调它时看三样（三个都在 `PanelTokens` / `PanelColors`）
/// | 想改什么 | 在哪 |
/// |---|---|
/// | 高度（露出一截的厚度） | `PanelMetrics.puckHeight` |
/// | 圆角 | `PanelMetrics.rPuck` |
/// | 颜色 / 受光唇 / 发丝边 / 底缘内阴影 | `PanelColors.puck` · `puckLip` · `puckBorder` |
/// | 滑的速度与回弹 | `PanelMotion.slide`（`select` 是图标上浮那一档，两者要**同一档**） |
/// | 落点（第 i 格 ⇒ x） | `Self.offsetX(appIndex:)` ↓ |
///
/// ## 两条踩过的坑（别走回去）
/// · **换环后它不上场**（`opacity`）：未启动环的选中由"上浮"表达 ✓（用户实拍「嵌套太多圆角边框」✗）
/// · **它的消失不做动画**：`entrySelected` 那一发不加 animation —— 否则会和"滑到 appIndex"
///   叠着演，读起来像"选中滑走了"（用户实报「未启动的环上会有一个向右淡出的滑块效果」✗）
/// · **不要用 `.animation(nil)` 图省事**：2026-09-21 因为"飞行途中看起来不居中"这么干过 ✗，
///   第二天用户就要回来了（「能跟随指针有一个滑动的动效就行了」）—— 那是**飞行中的一帧**
///   被当成静止姿态，不是真错位 ✓
struct Puck: View {
    /// 启动环（实感亮玻璃）vs 未启动环（稍轻透的冷雾玻璃）—— 共享同一套 3D 玻璃滑块实现，
    /// 以后调整滑块几何/弧面内影/受光唇/阴影，**只改这一个视图**即可同步生效。
    enum Style {
        case running
        case launch

        var palette: PanelColors.PuckPalette {
            switch self {
            case .running: return PanelColors.puckPaletteRunning
            case .launch:  return PanelColors.puckPaletteLaunch
            }
        }
    }

    /// 材质档位（默认主环 `.running`）
    var style: Style = .running
    /// 目标格的横坐标（条带内容坐标系；用 `Self.offsetX(appIndex:)` 算）
    let offsetX: CGFloat
    /// 入场升起量（与"选中那一格"同源同值 ⇒ 两者永远同步）
    let entryRise: CGFloat
    /// 是否可见（换环时当帧显隐，不做动画）
    let visible: Bool
    /// 滑的动效（`PanelController.selectionAnimation(PanelMotion.slide)`；开局第一帧给 nil）
    let animation: Animation?
    /// 动效的**观察值** = 当前选中格（值一变就重跑弹簧）
    let animationValue: Int

    /// 第 `appIndex` 格的落点 X。**唯一来源在 `RingGrid`**（与命中/图标中心同一个算式 ✓）
    static func offsetX(appIndex: Int) -> CGFloat {
        RingGrid.puckOffsetX(appIndex: appIndex,
                             icon: PanelMetrics.icon,
                             gap: PanelMetrics.iconGap)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
        puckSurface(shape: shape)
            .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
            .opacity(visible ? 1 : 0)
            .offset(x: offsetX, y: entryRise)
            .shadow(color: visible ? PanelColors.puckContactShadow : .clear,
                    radius: visible ? 1.8 : 0,
                    y: visible ? 1 : 0)
            .elevation(.puck, active: visible)
            .animation(animation, value: animationValue)
            // ⚠️ 故意**没有** `.animation(…, value: visible)`：消失必须当帧（见文件头第二条坑）
    }

    /// 滑块统一材质（全系统一套实现）：
    /// 1. 表面层（macOS 14–26 共用）：
    ///    - 浅色纯白高透晶面 / 深色高稳态烟熏玻璃渐层，保证黑白背景下质感一致；
    ///    - 顶受光唇 + 8pt 底缘弧面内影 + 0.75pt 亮白折光边；
    /// 2. 光学层（按系统版本分流）：
    ///    - macOS 26+：底层叠加原生 `.glassEffect(.clear, in: shape)` 提供真实边缘折射（隐藏态切 `.identity` 零开销）；
    ///    - macOS 14–25：叠加轻量级「穹顶柔光 + 对角菲涅尔折光棱 + 内焦散柔边」三层光学补偿，
    ///      配合外层 `NSVisualEffectView` 真毛玻璃，无私有 API、零离屏截图、老机型同样流畅；
    /// 3. 双层外投影：1.8pt 紧贴接触影 + 7pt 抬升影，纯白/深色背景都自然立住。
    @ViewBuilder
    private func puckSurface(shape: RoundedRectangle) -> some View {
        let p = style.palette
        let bodyLayer = shape
            .fill(LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom))
            .overlay(
                shape
                    .strokeBorder(p.lip, lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, p.bellyShadow], startPoint: .top, endPoint: .bottom)
                    .frame(height: 8)
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(p.border, lineWidth: 0.75)
            )

        if #available(macOS 26.0, *) {
            bodyLayer
                .glassEffect(visible ? .clear : .identity, in: shape)
        } else {
            legacyGlassOverlay(bodyLayer, shape: shape)
        }
    }

    /// macOS 14–25 滑块光学补偿层：模拟 macOS 26 `.glassEffect(.clear)` 的穹顶柔光、
    /// 对角菲涅尔亮棱与向内衰减的内焦散边，避免旧系统退化成平面半透色块。
    private func legacyGlassOverlay<Content: View>(_ content: Content,
                                                   shape: RoundedRectangle) -> some View {
        let fresnel = LinearGradient(
            stops: [
                .init(color: PanelColors.puckLegacyFresnelPeak, location: 0.0),
                .init(color: PanelColors.puckLegacyFresnelMid, location: 0.34),
                .init(color: PanelColors.puckLegacyFresnelMid, location: 0.66),
                .init(color: PanelColors.puckLegacyFresnelPeak, location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return content
            // ① 上半弧玻璃穹顶柔光（补足无原生透镜时的晶面通透感）
            .overlay(alignment: .top) {
                LinearGradient(colors: [PanelColors.puckLegacyDome, .clear],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: PanelMetrics.puckHeight * 0.44)
            }
            // ② 贴边向内衰减的内焦散柔亮边（复刻原生玻璃边缘柔和过渡）
            .overlay(
                shape
                    .inset(by: 1.0)
                    .strokeBorder(PanelColors.puckLegacyInnerCaustic, lineWidth: 1.2)
                    .blur(radius: 0.7)
            )
            // ③ 对角菲涅尔折光棱（左上/右下圆角聚光，四边自然收淡）
            .overlay(
                shape.strokeBorder(fresnel, lineWidth: 1.1)
            )
            .clipShape(shape)
    }
}
