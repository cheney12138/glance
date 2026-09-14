import SwiftUI
import AppKit

// MARK: - 玻璃与图标提供者

/// 原生映射:macOS 26+ 用 `NSGlassEffectView`(边缘折射系统自带,禁止手刻);
/// 低版本回退 `NSVisualEffectView` `.popover` / `.active`。
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    static var supportsLiquidGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }

    /// 玻璃 tint —— 原生侧唯一能调"玻璃本体色"的旋钮(系统官方 `tintColor`,折射/模糊仍是系统的)。
    ///
    /// ★ 2026-09-14 深色重建:**白 .30 黑 → 中灰 L=26 α=.42**,并把它的职责重新定义。
    ///
    /// **旧值(黑 .30)错在哪**:它被当成"一层压暗滤光片",而玻璃的透射率很高 ——
    /// 于是面板最终亮度几乎完全由**底下的壁纸**决定。实拍的后果:
    /// 相同的配方,托盘压在浅色代码编辑器上实得 **L≈53**,长条压在本就暗的码头上实得 **L≈95**,
    /// 两块本该同材质的板子差 **42 级**。玻璃"透光"这件最值钱的本事,变成了"两块板子读起来不是一套东西"。
    ///
    /// **新值想通的一件事**:tint 不该只是滤光片,它得**承担一部分固定基色**。
    /// 用一道够实的中性深灰(L=26,α=.42)把所有背景收进同一个区间 ——
    /// 亮壁纸(215)落到 ≈88,暗码头(60)落到 ≈32,两端差从 80+ 收到 56 级(zero 完美,但读起来一致了)。
    /// 剩下的差异交给**形**(glassTopEdge 的受光边 + glassBorder 的亮发丝)去抹平:
    /// 深色面板的"我是一块板"由亮线交代,不由亮度差交代。
    ///
    /// **浅色不压 tint**(2026-09-14 已试过一版,结论是否):试的是「白底玻璃实验台」的 V1
    /// 灰骨玻璃(`rgb(235,238,243)` α .55),实测用户评"更丑了,变成透明塑料片子" ——
    /// 因为 tint 把**折射与背景透光一起压平**了,面板从"材质"退化成"一片均匀的灰"。
    /// 白底上形不足的问题改由**形**承担(暗发丝边 + 暗槽托底,见 PanelColors 的 V2 那几行)。
    /// ⚠️ 深色这边 α 更高(.42)却不怕同一个病,原因是:深色底本来就暗,tint 与背景**同向**,
    /// 不会把折射压平 —— 压平的机制是"tint 与背景对着干",浅色才成立。
    private static func scrim(for appearance: NSAppearance) -> NSColor? {
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return nil }
        // L=26 的中性冷灰(比纯黑多一点蓝,压出来不像墨块)
        return NSColor(srgbRed: 26 / 255, green: 27 / 255, blue: 31 / 255, alpha: 0.42)
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // **.clear**:系统给的两种玻璃(regular 偏实、clear 偏透)。用户实评"整个面板透明度不行"
            // —— regular 在任何壁纸上都像一块实心白板,clear 才看得到背后
            glass.style = .clear
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
