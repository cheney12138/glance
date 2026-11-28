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
    /// 玻璃风格按**外观**分档(2026-10-08):
    /// · 深色:.clear —— 用户实评"整个面板透明度不行",regular 在深底上像实心白板 ✗
    /// · 浅色:默认也给 .clear,但留一个 A/B 档位(`debug.glassStyleLight` = regular)去量
    ///   "白底可见性"到底差在哪(用户:「背景是白色的时候可见性就差一点」✓)
    @available(macOS 26.0, *)
    static func style(for appearance: NSAppearance) -> NSGlassEffectView.Style {
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua { return .clear }
        return DebugFlags.glassStyleLight == "regular" ? .regular : .clear
    }

    /// ★★ 2026-10-08(用户:「玻璃还是没有 macOS 原生自然, 背景是白色的时候可见性差一点」):
    /// 原生那层材质可以**两点反解**出来(用你给的那张图 + 本仓 2026-09-15 的白底剖面):
    ///   原生: 0.27 → 0.45 · 0.941 → 0.909   ⇒ 基色 **L≈0.84 · α≈0.32**
    ///   我们: 0.227 → 0.462 · 1.000 → 0.961 ⇒ 基色 **L≈0.89 · α≈0.355**
    /// ⇒ 底子几乎一样,差别只在"我们**偏亮** 0.012"(白底上 0.961 vs 原生应得 0.949)——
    ///   同方向、同级,正是用户读到的"白底上可见性差一点" ✓
    /// ⇒ 浅色补一道**很淡的中性灰 tint**(把基色从 0.89 压到 ≈0.84),不碰深色 ✓
    ///   ⚠️ 别再走回"白 .55"那条老路(2026-09-14 V1 实测"更丑了, 变成透明塑料片子"):
    ///   压平折射的是**高 α**,不是"有 tint"本身 ⇒ 这里 α 只有 0.10 ✓
    ///   (`.regular` 试过:白底实得 0.920 ⇒ 过头了 ✗ 见 debug.glassStyleLight 的档位)
    private static func scrim(for appearance: NSAppearance) -> NSColor? {
        // 浅色**不写 tintColor**:2026-10-08 实测在这个组合(`.clear` + 浅色)里它量不出任何变化 ✗
        // ⇒ 浅色那道纱改由视图层铺(`PanelColors.glassVeil`,玻璃之上、图标之下 ✓)
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return nil }
        // L=26 的中性冷灰(比纯黑多一点蓝,压出来不像墨块)
        return NSColor(srgbRed: 26 / 255, green: 27 / 255, blue: 31 / 255, alpha: 0.42)
    }

    func makeNSView(context: Context) -> NSView {
        // (2026-09-16 掉帧排查曾在此放过 A/B 开关 `debug.noGlass` 换 NSVisualEffectView 对比:
        //  结论是内建 ProMotion 屏的 60Hz 节奏与玻璃无关 —— 无玻璃照样 16.7ms P50,
        //  开关按"验证完的开关不留代码"的规矩撤掉,结论记在 docs/debugging.md §18)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // **.clear**:系统给的两种玻璃(regular 偏实、clear 偏透)。用户实评"整个面板透明度不行"
            // —— regular 在任何壁纸上都像一块实心白板,clear 才看得到背后
            glass.style = Self.style(for: glass.effectiveAppearance)
            glass.tintColor = Self.scrim(for: glass.effectiveAppearance)
            glass.contentView = NSView() // 给玻璃一个可包裹的内容层
            return glass
        }
        let fallback = NSVisualEffectView()
        fallback.material = .popover
        fallback.state = .active
        fallback.blendingMode = .behindWindow
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = cornerRadius
        fallback.layer?.cornerCurve = .continuous
        fallback.layer?.masksToBounds = true
        return fallback
    }

    final class Coordinator {
        /// 上一次写入的 tint。为什么不直接比 `glass.tintColor`:getter 返回的对象不保证
        /// 与写入的相等,存"自己写过的那份"才是可靠的对账依据
        var lastTint: NSColor?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 父 body 重渲染(换选中)就会进来一次 —— 只写真正会变的东西,别在这里做重活。
    ///
    /// ★ 2026-09-16 补 tint 的等值守卫(cornerRadius 早有,tintColor 漏了):
    /// 入场弹簧经 `@Published` 驱动,两棵根视图逐帧重算,这里逐帧被进一次 ——
    /// 旧版每次都**无条件**重写 tintColor(还每次新建一个动态 NSColor),
    /// 若 AppKit 不做等值短路,玻璃层就被逐帧标记重渲染,给入场动画白白加一笔。
    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
            let want = Self.style(for: glass.effectiveAppearance)
            if glass.style != want { glass.style = want }
            let tint = Self.scrim(for: glass.effectiveAppearance)
            if tint != context.coordinator.lastTint {
                glass.tintColor = tint
                context.coordinator.lastTint = tint
            }
        } else if let fallback = view as? NSVisualEffectView {
            if fallback.layer?.cornerRadius != cornerRadius {
                fallback.layer?.cornerRadius = cornerRadius
            }
        }
    }
}

/// 阴影呼吸区(96/80)让窗口比玻璃大出一整圈透明边——那圈边不能吃掉点击与 hover,
/// 否则托盘压住长条的呼吸区、以及"面板外点击 = 放弃"都会误判。
/// hitTest 在内容矩形外一律放行,事件穿到下一个窗口/桌面
/// 玻璃边的**总闸**。长条与托盘上那几道"边"(受光唇 / 顶缘内阴影 / 顶缘受光边)全挂在这一个 bool 上。
///
/// 2026-09-15 用户口径:「还是有边框看着,能完全去掉我看下吗」—— 那就做成一个开关,
/// 一次只动一个变量:关掉 = 一丝边都不画,形状完全由"填充与背景的对比"交代
/// (这也正是原生 ⌘Tab 的做法,见下面两张剖面表)。
enum PanelEdgeStyle {
    static let drawsEdge = false
}

/// 玻璃边 = **一条软的受光唇**,不是一条画上去的线。
///
/// 2026-09-15 病例(用户实拍对比 macOS 原生 ⌘Tab):「原生这个玻璃边框做的很自然,能复刻一下吗」。
/// 把两张截图按同一口径量了一遍(横穿左边缘取亮度剖面,2× 截图):
///
/// | | 边缘剖面 |
/// |---|---|
/// | **原生** | 背景 0.980 → **2–3px 柔和过渡**(0.902 / 0.894)→ 内部 0.898 |
/// | **我们(改前)** | 背景 0.337 → 0.329(**一条暗阶** = 画上去的 1px 线)→ 0.582(硬台阶)→ 内部 0.491 |
///
/// 结论有点反直觉:**原生那道边之所以自然,是因为它根本没有"边"** —— 只有玻璃自身的柔边
/// 加一圈软投影;定义形状的是**填充与背景的对比**,不是一条线。我们画了线,所以看着像贴上去的。
///
/// 改法:删掉 `strokeBorder(glassBorder, 1px)`,换成**内阴影**(平台自己的机制,渲染口径与系统一致),
/// 参数照原生的量值取:**1–1.5pt**、几乎只在上缘显出来 —— 白 10%(浅色)/ 白 16%(深色),
/// 半径 1.5、y 偏移 0.5。想要更"有边"就把 alpha 提上去,想更无形就归零。
struct GlassEdge: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if PanelEdgeStyle.drawsEdge {
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PanelColors.glassLip, lineWidth: 1.5)
                    .blur(radius: 1.0)
                    .allowsHitTesting(false)
            )
        } else {
            content
        }
    }
}

extension View {
    /// 给长条/托盘上"原生那道柔边"。见 `GlassEdge` 的两张剖面表。
    func glassEdge(cornerRadius: CGFloat) -> some View {
        modifier(GlassEdge(cornerRadius: cornerRadius))
    }
}

/// 环玻璃容器（⌘Tab 主环与程序坞条带共用，对齐舌头滑块 `Puck` 的 4 象限稳态液态玻璃配方）：
/// - **macOS 26+**：原生 `.glassEffect(.clear, in: shape)` 提供真实边缘光学折射，
///   内叠通透稳态微渐层 + 顶受光唇 + 8pt 底弧内影 + 0.75pt 无模糊利落折光发丝边，
///   外叠 1.8pt 紧贴接触影 + 14pt 抬升影（纯白/深色背景边缘皆清晰利落，且不盖过上方滑块亮度）。
/// - **macOS 14–25**：自动回退为 `NSVisualEffectView` 真实桌面毛玻璃 + 同源 4 象限稳态层 +
///   与 `PuckView` 一致的光学补偿层（上半弧穹顶柔光 + 对角菲涅尔折光棱 + 柔和内焦散边）+ 双层外投影，
///   老系统无需私有 API、零崩溃且保留精致玻璃质感。
struct RingGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let size: CGSize
    let epoch: Int
    /// 小胶囊态（如 ⌘Tab 无未启动应用提示芯片）收轻抬升影，避免小体量挂大重影
    var compactShadow: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let liftShadow = compactShadow ? PanelColors.ringGlassLiftShadowCompact : PanelColors.ringGlassLiftShadow
        let liftRadius: CGFloat = compactShadow ? 8 : 14
        let liftY: CGFloat = compactShadow ? 3 : 6

        // 全部走 `PanelColors.dynamic(...)`（`NSColor(name:)`），不读 `@Environment(\.colorScheme)`，
        // 保证预热过的离屏 ⌘Tab 面板与程序坞在浅/深模式切换后像素级对齐。
        let steadyBody = shape
            .fill(LinearGradient(
                colors: [PanelColors.ringGlassTop, PanelColors.ringGlassBottom],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                shape
                    .strokeBorder(PanelColors.ringGlassLip, lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, PanelColors.ringGlassBellyShadow],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 8)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(PanelColors.ringGlassBorder, lineWidth: 0.75))
            .allowsHitTesting(false)

        if #available(macOS 26.0, *) {
            content()
                .frame(width: size.width, height: size.height)
                .background(steadyBody)
                .glassEffect(.clear, in: shape)
                .id(epoch)
                .shadow(color: PanelColors.ringGlassContactShadow, radius: 1.8, x: 0, y: 1)
                .shadow(color: liftShadow, radius: liftRadius, x: 0, y: liftY)
        } else {
            ZStack {
                GlassBackground(cornerRadius: cornerRadius)
                    .id(epoch)
                legacyGlassOverlay(steadyBody, shape: shape, height: size.height)
                content()
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: PanelColors.ringGlassContactShadow, radius: 1.8, x: 0, y: 1)
            .shadow(color: liftShadow, radius: liftRadius, x: 0, y: liftY)
        }
    }

    /// macOS 14–25 光学补偿层（同 `PuckView.legacyGlassOverlay`）：
    /// 上半弧穹顶柔光 + 贴边内焦散柔亮边 + 对角菲涅尔高光棱。
    private func legacyGlassOverlay<Base: View>(_ base: Base,
                                                shape: RoundedRectangle,
                                                height: CGFloat) -> some View {
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
        return base
            .overlay(alignment: .top) {
                LinearGradient(colors: [PanelColors.puckLegacyDome, .clear],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: max(height * 0.42, 16))
            }
            .overlay(
                shape
                    .inset(by: 1.0)
                    .strokeBorder(PanelColors.puckLegacyInnerCaustic, lineWidth: 1.2)
                    .blur(radius: 0.7)
            )
            .overlay(
                shape.strokeBorder(fresnel, lineWidth: 1.0)
            )
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // 面板与托盘窗口尺寸由 PanelController / TrayGeometry 单一权威驱动；
        // 禁用 NSHostingView 默认的 intrinsic/minSize 反向推窗框，防止首帧淡入中途
        // 被 SwiftUI 内部边距撑高（例如托盘 317pt → 412pt 跳变与后备存储重分配）。
        if #available(macOS 13.0, *) { sizingOptions = [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 透明呼吸区宽度,与对应视图的 `.padding(shadowPad…)` 同值
    var pad: CGFloat = 0
    /// 顶部呼吸区宽度；nil 时沿用 `pad`（托盘顶缘紧贴卡片无需呼吸区，传 0 ✓）
    var padTop: CGFloat?

    /// 滚轮 / 双指滑动 ⇒ 转交面板控制器,语义**等价于 Tab / ⇧Tab**(CONTEXT.md「走 / 跳」)。
    /// 为什么放在这个 view:滚动事件由系统按"指针底下的那个窗口"派发,只有它收得到;
    /// 局部/全局 NSEvent 监听都拿不到,而且这条路**不需要任何权限**
    /// —— 比做触控板手势识别省掉一整套基础设施(IOKit + 冲突处理 + 多设备 + 睡眠挂起)。
    @MainActor var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?   // (dx, dy, isMomentum)

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.momentumPhase != [])
        super.scrollWheel(with: event)   // 不消费:保持"只旁观、不吞"的一贯做法
    }

    /// 非激活面板要声明它接受"第一下鼠标":AppKit 默认不把这颗 mouseDown 派发给非 key 窗口。
    /// 这条不是为某个功能加的(拖拽删除已整条退回,见 ADR-0012),而是面板的一般性正确设置:
    /// 我们永远不是 key window,任何需要"按下并持续跟踪"的交互都依赖它。来源:LumaRing 的 RingView 实证。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 🔬 Bug2 诊断(2026-09-19):合成器闸开后,点击已确认送到托盘窗口(win=托),
    // 但 SwiftUI 手势无声。这两行账回答"事件到底走没走到视图层":
    // 视图收到了而手势不响 ⇒ 吞在 SwiftUI 内部;视图没收到 ⇒ 吞在 AppKit 派发层
    override func mouseDown(with event: NSEvent) {
        if isTraceEnabled {
            let f = window?.frame ?? .zero
            print("[T6] 托盘视图 mouseDown 窗帧=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.maxX)),\(Int(f.maxY))) 自身bounds=\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.maxX)),\(Int(bounds.maxY)) loc=(\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))) clickCount=\(event.clickCount)")
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isTraceEnabled {
            print("[T6] 托盘视图 mouseUp loc=(\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)))")
        }
        super.mouseUp(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let top = padTop ?? pad
        guard pad > 0 || top > 0 else { return super.hitTest(point) }
        let local = superview.map { convert(point, from: $0) } ?? point
        // ★ 2026-11-28 病例修复(用户实报「三指唤起后，点芯片轨道打不开」):
        //   `NSHostingView.isFlipped == true`（原点在左上角，Y 向下递增）。
        //   旧写法恒用 `y = bounds.minY + pad`，在 `padTop = 0`（托盘顶缘无呼吸区、仅底缘留 96pt 阴影）时
        //   把 96pt 透明呼吸区错扣到了**顶部** 0…96pt，导致托盘上半截（含芯片轨道上方多枚芯片）
        //   全部被 `hitTest` 拒掉返回 nil ✗。按 `isFlipped` 分支后顶/底扣边严格对齐 ✓。
        let minY = isFlipped ? (bounds.minY + top) : (bounds.minY + pad)
        let hitRect = NSRect(x: bounds.minX + pad,
                             y: minY,
                             width: max(0, bounds.width - pad * 2),
                             height: max(0, bounds.height - pad - top))
        guard hitRect.contains(local) else { return nil }
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
