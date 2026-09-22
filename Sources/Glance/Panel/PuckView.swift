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
    /// 目标格的横坐标（条带内容坐标系；用 `Self.offsetX(appIndex:)` 算）
    let offsetX: CGFloat
    /// 入场升起量（与"选中那一格"同源同值 ⇒ 两者永远同步）
    let entryRise: CGFloat
    /// 是否可见（换环后不上场）
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
        RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
            .fill(PanelColors.puck)
            // 托底上缘一道受光唇（demo: inset 0 1px 1px rgba(255,255,255,.6)）
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckLip, lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            // 底缘一道内阴影（demo: inset 0 -1px 6px rgba(0,0,0,.12)）—— 有厚度，不是贴纸
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous))
            // 发丝边：用 strokeBorder ⇒ 画在边界**内侧** ⇒ 尺寸/位置一个像素都没动 ✓
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckBorder, lineWidth: 1)
            )
            .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
            .opacity(visible ? 1 : 0)
            .offset(x: offsetX, y: entryRise)
            .elevation(.puck)
            .animation(animation, value: animationValue)
            // ⚠️ 故意**没有** `.animation(…, value: visible)`：消失必须当帧（见文件头第二条坑）
    }
}
