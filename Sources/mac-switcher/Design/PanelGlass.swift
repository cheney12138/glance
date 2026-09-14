import SwiftUI
import AppKit

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
