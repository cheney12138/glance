import AppKit
import GlanceCore
import SwiftUI

/// Dock 条带主视图（支持 `bottom` 横向与 `left` / `right` 纵向自适应布局）。
struct DockStripView: View {
    @ObservedObject var controller: DockController
    @AppStorage(Keys.panelSheen) private var glow = KeyDefaults.sheen

    private var m: DockMetrics { controller.metrics }
    private var isVertical: Bool { controller.position.isVertical }

    /// 包络窗框下玻璃壳贴哪条边。
    ///
    /// 增删动效期间窗框被撑成「新旧目标的外包络」（比内容大），靠这条对齐保证玻璃壳
    /// **贴死屏边、0 漂移**；平日窗框恰好等于 内容 + 2×pad，对齐值不影响任何像素 ✓
    private var stripAlignment: Alignment {
        switch controller.position {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    var body: some View {
        let stripSize = controller.stripContentSize
        let corner = m.rPanel

        RingGlassSurface(
            cornerRadius: corner,
            size: stripSize,
            epoch: controller.glassEpoch
        ) {
            stripContent
        }
        .overlay {
            launchNameTooltipOverlay(stripSize: stripSize)
        }
        .padding(m.shadowPadStrip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stripAlignment)
        .focusEffectDisabled(true)
    }

    // MARK: - 主条带内容

    @ViewBuilder
    private var stripContent: some View {
        if isVertical {
            VStack(spacing: 0) {
                itemsStrip
                if controller.showsTailToggleButton {
                    tailToggleSection
                }
            }
            .padding(.vertical, m.rowPadX)
            .padding(.horizontal, m.rowPadY)
        } else {
            HStack(spacing: 0) {
                itemsStrip
                if controller.showsTailToggleButton {
                    tailToggleSection
                }
            }
            .padding(.horizontal, m.rowPadX)
            .padding(.vertical, m.rowPadY)
        }
    }

    @ViewBuilder
    private var itemsStrip: some View {
        if controller.showingLaunchSegment {
            launchItemsStrip
        } else {
            runningItemsStrip
        }
    }

    @ViewBuilder
    private var runningItemsStrip: some View {
        if controller.runningSlots.isEmpty {
            emptyStateLabel("无本屏窗口")
        } else {
            // ★ 渲染**槽位表**而不是 `groups`：退出的 App 还要在原槽位收拢一下才消失。
            //   动效全程参数驱动（`progress` 0…1）—— 不用 `.transition`：系统开着「减弱动态效果」时
            //   SwiftUI 会把过渡直接吞掉，而 App 自己放行的弹簧（MotionPolicy）管得住参数动画 ✓
            let cells = ForEach(controller.runningSlots) { slot in
                let p = min(max(slot.progress, 0), 1)
                let iconScale = 0.22 + 0.78 * p
                let drop = (1 - p) * 10
                let dropX: CGFloat = controller.position == .left
                    ? -drop
                    : (controller.position == .right ? drop : 0)
                let dropY: CGFloat = controller.position == .bottom ? drop : 0

                DockRunningIconCell(
                    group: slot.group,
                    position: controller.position,
                    metrics: m,
                    selected: !slot.isExiting && controller.hoveredAppPID == slot.pid,
                    glow: glow,
                    // ★★ 2026-11-25 根因 C:后台图标落账的"令牌"。
                    //   本格子是纯值参数子视图 ⇒ 不递这个会变的值,SwiftUI 就会跳过 `body`,
                    //   真 logo 落了账也画不上屏,只能等 hover / 重开程序坞才变出来 ✗
                    iconRevision: controller.iconRevision
                )
                // 占位随 `progress` 伸缩：玻璃壳同时长缩，两边的总宽始终对得上 ✓
                .frame(
                    width: isVertical ? m.icon : m.pitch * slot.progress,
                    height: isVertical ? m.pitch * slot.progress : m.icon
                )
                // ⚠️ 命中区必须在 `.scaleEffect` / `.offset` **之前**装配：
                //   否则命中矩形会跟着收缩中的图标变小、变偏，动画期间点哪都点不中 ✗
                .contentShape(Rectangle())
                .onTapGesture {
                    // 只认 PID：动画期间同一个下标可能对应幽灵槽 / 新 App，按下标点会点错 ✗
                    controller.confirmApp(pid: slot.pid)
                }
                .allowsHitTesting(!slot.isExiting)
                .help(slot.group.appName)
                .scaleEffect(iconScale)
                .offset(x: dropX, y: dropY)
                .opacity(Double(p))
            }

            axisStack(cells)
                .background(alignment: .topLeading) {
                    runningPuck
                }
        }
    }

    @ViewBuilder
    private var launchItemsStrip: some View {
        if controller.launchables.isEmpty {
            emptyStateLabel("无未启动应用")
        } else {
            let cells = ForEach(Array(controller.launchables.enumerated()), id: \.element.id) { index, app in
                DockLaunchIconCell(
                    app: app,
                    position: controller.position,
                    metrics: m,
                    hovered: controller.hoveredLaunchIndex == index,
                    glow: glow
                )
                .frame(
                    width: isVertical ? m.icon : m.pitch,
                    height: isVertical ? m.pitch : m.icon
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.launchApp(app)
                }
                .help(app.name)
            }

            axisStack(cells)
                .background(alignment: .topLeading) {
                    launchPuck
                }
        }
    }

    @ViewBuilder
    private func axisStack<Content: View>(_ content: Content) -> some View {
        if isVertical {
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, -m.iconGap / 2)
        } else {
            HStack(spacing: 0) {
                content
            }
            .padding(.horizontal, -m.iconGap / 2)
        }
    }

    @ViewBuilder
    private func emptyStateLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: max(11, 12 * m.scale), weight: .medium))
            .foregroundStyle(PanelColors.txt2)
            .lineLimit(1)
            .frame(
                width: isVertical ? m.icon : m.emptyStripBodySpan,
                height: isVertical ? m.emptyStripBodySpan : m.icon
            )
    }

    // MARK: - 滑动托底

    private var runningPuck: some View {
        let slots = controller.runningSlots
        let hoveredIdx = slots.firstIndex { !$0.isExiting && $0.pid == controller.hoveredAppPID }
        // 偏移量 = 前面每一格**当前**占位的累加（不是下标 × pitch）：
        // 左侧有 App 正在退出、槽位正在收拢时，右侧选中的托底会跟着一起滑过去；
        // 无悬停时传 `nil`（绝不归零到第 0 格），避免下次悬停时从第一个 App 横穿飞过来 ✓
        let targetOffset: CGFloat? = hoveredIdx.map { idx in
            slots.prefix(idx).reduce(CGFloat.zero) { $0 + $1.progress } * m.pitch
        }

        return DockPuck(
            style: .running,
            position: controller.position,
            metrics: m,
            targetOffsetAlongAxis: targetOffset
        )
        .allowsHitTesting(false)
    }

    private var launchPuck: some View {
        let targetOffset: CGFloat? = if let idx = controller.hoveredLaunchIndex, !controller.launchables.isEmpty {
            CGFloat(idx) * m.pitch
        } else {
            nil
        }
        return DockPuck(
            style: .launch,
            position: controller.position,
            metrics: m,
            targetOffsetAlongAxis: targetOffset
        )
        .allowsHitTesting(false)
    }

    // MARK: - 环尾纯点击切换按钮（液态玻璃 2×2 真实缩略文件夹，严禁 onHover 触发切换）

    @ViewBuilder
    private var tailToggleSection: some View {
        let hint = controller.showingLaunchSegment ? "返回正在运行的应用" : "查看未启动的常用应用"

        let divider = Rectangle()
            .fill(PanelColors.entrySeparator)
            .frame(
                width: isVertical ? m.toggleDividerLength : m.toggleDividerThickness,
                height: isVertical ? m.toggleDividerThickness : m.toggleDividerLength
            )

        let button = Button(action: { controller.toggleLaunchSegment() }) {
            DockLauncherFolderTile(
                size: m.toggleButtonSize,
                showingLaunchSegment: controller.showingLaunchSegment,
                hovered: controller.hoveredTailToggle,
                previewApps: Array(controller.launchables.prefix(4))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .help(hint)

        if isVertical {
            VStack(spacing: m.toggleGap) {
                divider
                button
            }
            .padding(.top, m.toggleGap)
            .frame(width: m.icon)
        } else {
            HStack(spacing: m.toggleGap) {
                divider
                button
            }
            .padding(.leading, m.toggleGap)
            .frame(height: m.icon)
        }
    }

    // MARK: - 未启动段 App 名称提示胶囊

    @ViewBuilder
    private func launchNameTooltipOverlay(stripSize: CGSize) -> some View {
        if controller.showingLaunchSegment,
           let idx = controller.hoveredLaunchIndex,
           controller.launchables.indices.contains(idx) {
            let app = controller.launchables[idx]
            let centerAlongAxis = m.rowPadX + CGFloat(idx) * m.pitch + m.icon / 2
            let pill = Text(app.name)
                .font(.system(size: max(11, 12 * m.scale), weight: .medium))
                .foregroundStyle(PanelColors.thumbTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(PanelColors.chipBorder, lineWidth: PanelMetrics.hairline)
                )
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
                .frame(maxWidth: isVertical ? 94 : 180)
                .allowsHitTesting(false)

            switch controller.position {
            case .bottom:
                pill
                    .position(x: centerAlongAxis, y: -18)
            case .left:
                pill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: stripSize.width + 10, y: centerAlongAxis - stripSize.height / 2)
            case .right:
                pill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(x: -(stripSize.width + 10), y: centerAlongAxis - stripSize.height / 2)
            }
        }
    }
}

// MARK: - 图标单元格

private struct DockRunningIconCell: View {
    let group: AppGroup
    let position: DockPosition
    let metrics: DockMetrics
    let selected: Bool
    let glow: Bool
    /// **图标版本号**(2026-11-25 根因 C):本身不被读,只用来保证"后台图标落账"以后
    /// 这个纯值参数子视图真的重算一次 `body`(否则会死死卡着占位白纸 ✓)
    let iconRevision: Int

    /// 与启动环 `PanelView` 对齐的计数点脉冲（选中瞬间弹到 1.35 再回弹）与发牌动效（窗数变更逐个弹出）
    @State private var pop = false
    @State private var dealing = false

    private func popOnce() {
        pop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { pop = false }
    }

    var body: some View {
        let art = IconProvider.art(for: group.pid, bundleID: group.bundleID)
        let liftX: CGFloat = selected
            ? (position == .left ? metrics.iconLift : (position == .right ? -metrics.iconLift : 0))
            : 0
        let liftY: CGFloat = (selected && position == .bottom) ? -metrics.iconLift : 0

        let dotAlignment: Alignment = {
            switch position {
            case .bottom: return .bottom
            case .left: return .leading
            case .right: return .trailing
            }
        }()

        let drawSide = metrics.icon * art.fill
        Image(nsImage: art.image)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: drawSide, height: drawSide)
            // ⚠️ 关键：先收回到 `metrics.icon` 逻辑格框，再挂 `.overlay(alignment: dotAlignment) { windowDots }`，
            // 否则 `drawSide > metrics.icon` 会把计数点锚点推到舌头滑块外缘！
            .frame(width: metrics.icon, height: metrics.icon)
            .saturation(glow ? (selected ? 1.12 : 0.94) : 1)
            .brightness(glow ? (selected ? 0.04 : -0.02) : 0)
            .scaleEffect(selected ? metrics.iconScale : 1)
            .offset(x: liftX, y: liftY)
            .elevation(.icon, active: selected)
            .overlay(alignment: dotAlignment) { windowDots }
            .contentShape(Rectangle())
            .animation(MotionPolicy.animation(PanelMotion.select), value: selected)
    }

    @ViewBuilder
    private var windowDots: some View {
        let activeCount = group.windows.filter { !$0.isMinimized }.count
        let minimizedCount = group.windows.count - activeCount
        if activeCount + minimizedCount > 0 {
            let items = DockWindowDotsLayout.marks(
                activeCount: activeCount,
                minimizedCount: minimizedCount,
                available: metrics.icon,
                metrics: metrics.tally
            )
            let isSide = position.isVertical
            // 物理 90° 对称：
            // · bottom：图标上浮，计数点水平排布在底部滑块舌头内；
            // · left  ：图标右浮，计数点竖直排布在左侧（靠屏边）滑块舌头内；
            // · right ：图标左浮，计数点竖直排布在右侧（靠屏边）滑块舌头内。
            let edgeShift = metrics.dotBottom - (selected ? metrics.dotLift : 0)
            let dotOffsetX: CGFloat = {
                switch position {
                case .bottom: return 0
                case .left: return -edgeShift
                case .right: return edgeShift
                }
            }()
            let dotOffsetY: CGFloat = position == .bottom ? edgeShift : 0

            let marksContent = ForEach(Array(items.entries.enumerated()), id: \.offset) { idx, entry in
                Group {
                    switch entry.mark {
                    case .dot:
                        if entry.minimized {
                            Circle()
                                .strokeBorder(PanelColors.dot.opacity(0.75), lineWidth: 1)
                                .frame(width: items.sizes.dot, height: items.sizes.dot)
                        } else {
                            Circle()
                                .fill(PanelColors.dot)
                                .frame(width: items.sizes.dot, height: items.sizes.dot)
                        }
                    case .dash:
                        let dashW = isSide ? (metrics.dashHeight * items.sizes.scale) : items.sizes.dashWidth
                        let dashH = isSide ? items.sizes.dashWidth : (metrics.dashHeight * items.sizes.scale)
                        if entry.minimized {
                            Capsule()
                                .strokeBorder(PanelColors.dot.opacity(0.75), lineWidth: 1)
                                .frame(width: dashW, height: dashH)
                        } else {
                            Capsule()
                                .fill(PanelColors.dot)
                                .frame(width: dashW, height: dashH)
                        }
                    }
                }
                .scaleEffect(dealing ? 0.01 : 1)
                .opacity(dealing ? 0 : 1)
                .animation(
                    dealing ? nil : .timingCurve(0.3, 0.9, 0.35, 1.2, duration: 0.18).delay(Double(idx) * 0.036),
                    value: dealing
                )
            }

            Group {
                if isSide {
                    VStack(spacing: items.sizes.gap) { marksContent }
                } else {
                    HStack(spacing: items.sizes.gap) { marksContent }
                }
            }
            .opacity(0.85)
            // 与启动环一致的选中脉冲（只动 scale，不偏位置）
            .scaleEffect(pop ? 1.35 : 1)
            .animation(
                pop
                    ? MotionPolicy.animation(.spring(response: 0.14, dampingFraction: 0.55))
                    : MotionPolicy.animation(.spring(response: 0.30, dampingFraction: 0.45)),
                value: pop
            )
            .offset(x: dotOffsetX, y: dotOffsetY)
            .animation(MotionPolicy.animation(PanelMotion.select), value: selected)
            .onChange(of: selected) { _, isSelected in
                guard isSelected else { return }
                popOnce()
            }
            .onAppear {
                guard selected else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    if selected { popOnce() }
                }
            }
            .onChange(of: group.windows.count) { _, _ in
                dealing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { dealing = false }
            }
        }
    }
}

/// 未启动段图标格：与 Cmd+Tab 未启动环（`PanelView.launchRingCell`）保持 100% 同款视觉语义 ——
/// 去掉旧 `GhostTile` 灰框底壳与缩水，与运行段 1:1 等大；未悬停休眠态（降饱和 0.38、压暗 -0.07），
/// 悬停唤醒回满彩并上浮放大。
private struct DockLaunchIconCell: View {
    let app: DockAppsProvider.LaunchableApp
    let position: DockPosition
    let metrics: DockMetrics
    let hovered: Bool
    let glow: Bool

    var body: some View {
        let liftX: CGFloat = hovered
            ? (position == .left ? metrics.iconLift : (position == .right ? -metrics.iconLift : 0))
            : 0
        let liftY: CGFloat = (hovered && position == .bottom) ? -metrics.iconLift : 0
        let drawSide = metrics.icon * app.fill

        Image(nsImage: app.icon)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: drawSide, height: drawSide)
            .frame(width: metrics.icon, height: metrics.icon)
            .saturation(hovered ? (glow ? 1.12 : 1.0) : 0.38)
            .brightness(hovered ? (glow ? 0.04 : 0) : -0.07)
            .scaleEffect(hovered ? metrics.iconScale : 1)
            .offset(x: liftX, y: liftY)
            .elevation(.icon, active: hovered)
            .contentShape(Rectangle())
            .animation(MotionPolicy.animation(PanelMotion.select), value: hovered)
    }
}

// MARK: - 窗数记号排布（区分活动窗与最小化窗）

private enum DockWindowDotsLayout {
    struct Entry {
        let mark: WindowTally.Mark
        let minimized: Bool
    }

    static func marks(
        activeCount: Int,
        minimizedCount: Int,
        available: CGFloat,
        metrics: WindowTally.Metrics
    ) -> (entries: [Entry], sizes: WindowTally.Sizes) {
        var entries = WindowTally.marks(for: activeCount).map { Entry(mark: $0, minimized: false) }
            + WindowTally.marks(for: minimizedCount).map { Entry(mark: $0, minimized: true) }
        guard !entries.isEmpty, available > 0 else {
            return ([], WindowTally.Sizes(dot: metrics.dot, dashWidth: metrics.dashWidth, gap: metrics.gap, scale: 1))
        }

        func width(for items: [Entry], scale: CGFloat) -> CGFloat {
            let marksWidth = items.reduce(CGFloat.zero) {
                $0 + ($1.mark == .dash ? metrics.dashWidth : metrics.dot)
            }
            return marksWidth * scale + CGFloat(max(items.count - 1, 0)) * metrics.gap * scale
        }

        let natural = width(for: entries, scale: 1)
        let scale = min(1, max(metrics.minScale, available / max(natural, 1)))
        while entries.count > 1, width(for: entries, scale: scale) > available {
            entries.removeLast()
        }
        let sizes = WindowTally.Sizes(
            dot: metrics.dot * scale,
            dashWidth: metrics.dashWidth * scale,
            gap: metrics.gap * scale,
            scale: scale
        )
        return (entries, sizes)
    }
}

// MARK: - 环尾液态玻璃收纳文件夹图标（2×2 真实缩略图标网格 / 精致返回态）

private struct DockLauncherFolderTile: View {
    let size: CGFloat
    let showingLaunchSegment: Bool
    let hovered: Bool
    let previewApps: [DockAppsProvider.LaunchableApp]

    private var cornerRadius: CGFloat { size * 0.225 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let pad = max(size * 0.135, 5)
        let cellGap = max(size * 0.065, 2.5)
        let miniSize = max((size - pad * 2 - cellGap) / 2, 8)
        let miniCorner = miniSize * 0.24

        ZStack {
            // 通透的浅/深色磨砂液态玻璃壳，走 `PanelColors.dynamic` 动态色，与环同步换肤
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            hovered ? PanelColors.dockFolderTopHover : PanelColors.dockFolderTop,
                            hovered ? PanelColors.dockFolderBottomHover : PanelColors.dockFolderBottom,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    // 顶部高光棱线：模拟玻璃受光唇
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    hovered ? PanelColors.dockFolderRimTopHover : PanelColors.dockFolderRimTop,
                                    PanelColors.dockFolderRimBottom,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(
                    color: PanelColors.dockFolderShadow,
                    radius: hovered ? 6 : 4,
                    x: 0,
                    y: 2
                )

            if showingLaunchSegment {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: max(size * 0.36, 13), weight: .semibold))
                    .foregroundStyle(hovered ? PanelColors.dockFolderGlyphHover : PanelColors.dockFolderGlyph)
            } else if previewApps.isEmpty {
                // 极简四点阵列兜底
                let dot = max(size * 0.14, 5)
                VStack(spacing: cellGap * 1.4) {
                    HStack(spacing: cellGap * 1.4) {
                        Circle().fill(Color.primary.opacity(0.32)).frame(width: dot, height: dot)
                        Circle().fill(Color.primary.opacity(0.32)).frame(width: dot, height: dot)
                    }
                    HStack(spacing: cellGap * 1.4) {
                        Circle().fill(Color.primary.opacity(0.32)).frame(width: dot, height: dot)
                        Circle().fill(Color.primary.opacity(0.32)).frame(width: dot, height: dot)
                    }
                }
            } else {
                // 2×2 真实未启动 App 迷你图标预览（类似 macOS 文件夹 / App 资源库）
                VStack(spacing: cellGap) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: cellGap) {
                            ForEach(0..<2, id: \.self) { col in
                                let idx = row * 2 + col
                                if idx < previewApps.count {
                                    let app = previewApps[idx]
                                    Image(nsImage: app.icon)
                                        .renderingMode(.original)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: miniSize * app.fill, height: miniSize * app.fill)
                                        .frame(width: miniSize, height: miniSize)
                                        .clipShape(RoundedRectangle(cornerRadius: miniCorner, style: .continuous))
                                        // 统一未启动环休眠语义（降饱和 0.38、微压暗 -0.07），悬停入口时柔和唤醒回满彩
                                        .saturation(hovered ? 1.0 : 0.38)
                                        .brightness(hovered ? 0 : -0.07)
                                        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                                } else {
                                    Color.clear
                                        .frame(width: miniSize, height: miniSize)
                                }
                            }
                        }
                    }
                }
                .padding(pad)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(hovered ? 1.07 : 1.0)
        .animation(MotionPolicy.animation(PanelMotion.select), value: hovered)
        .contentShape(shape)
    }
}

// MARK: - Dock 滑动托底（支持横/纵双轴，首次选中贴屏边入场，不从首格飞来）

private struct DockPuck: View {
    enum Style {
        case running
        case launch

        var palette: PanelColors.PuckPalette {
            switch self {
            case .running: return PanelColors.puckPaletteRunning
            case .launch: return PanelColors.puckPaletteLaunch
            }
        }
    }

    let style: Style
    let position: DockPosition
    let metrics: DockMetrics
    /// 目标格沿条带主轴的偏移；`nil` 表示当前未选中任何格。
    let targetOffsetAlongAxis: CGFloat?

    /// 主轴当前渲染偏移（首次出现时禁用动画瞬时落位，仅在相邻切换时平滑滑动）
    @State private var renderedAxisOffset: CGFloat = 0
    /// 贴屏边入场进度：`0` = 潜于屏边透明，`1` = 完整浮出归位（参数驱动，抗 system reduceMotion）
    @State private var enterProgress: CGFloat = 0

    private var isVertical: Bool { position.isVertical }
    private var visible: Bool { targetOffsetAlongAxis != nil }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.rPuck, style: .continuous)
        let w = isVertical ? metrics.puckHeight : metrics.icon
        let h = isVertical ? metrics.icon : metrics.puckHeight
        let p = min(max(enterProgress, 0), 1)
        let entryTravel = max(12, metrics.iconLift * 2.2) * (1 - p)

        // 按 Dock 停靠边定向入场：bottom 从下往上、left 从左往右、right 从右往左
        let entryDX: CGFloat = {
            switch position {
            case .bottom: return 0
            case .left: return -entryTravel
            case .right: return entryTravel
            }
        }()
        let entryDY: CGFloat = position == .bottom ? entryTravel : 0

        let baseDX = isVertical ? (metrics.icon - metrics.puckHeight) / 2 : renderedAxisOffset
        let baseDY = isVertical ? renderedAxisOffset : (metrics.icon - metrics.puckHeight) / 2

        puckSurface(shape: shape)
            .frame(width: w, height: h)
            .scaleEffect(0.92 + 0.08 * p)
            .opacity(Double(p))
            .offset(x: baseDX + entryDX, y: baseDY + entryDY)
            .shadow(
                color: PanelColors.puckContactShadow.opacity(Double(p)),
                radius: 1.8 * p,
                y: 1 * p
            )
            .elevation(.puck, active: p > 0.5)
            .onAppear {
                if let initial = targetOffsetAlongAxis {
                    var snap = Transaction()
                    snap.disablesAnimations = true
                    withTransaction(snap) {
                        renderedAxisOffset = initial
                        enterProgress = 0
                    }
                    DispatchQueue.main.async {
                        guard targetOffsetAlongAxis != nil else { return }
                        withAnimation(MotionPolicy.animation(PanelMotion.select)) {
                            enterProgress = 1
                        }
                    }
                } else {
                    enterProgress = 0
                }
            }
            .onChange(of: targetOffsetAlongAxis) { oldValue, newValue in
                switch (oldValue, newValue) {
                case (nil, let target?):
                    // 首次选中：先跨帧无动画瞬时落位到目标格主轴坐标，再下一拍从贴屏边方向浮出入场，
                    // 避免 SwiftUI 合并同一 runloop 内的 transaction 导致滑块从旧格横穿飞来 ✓
                    var snap = Transaction()
                    snap.disablesAnimations = true
                    withTransaction(snap) {
                        renderedAxisOffset = target
                        enterProgress = 0
                    }
                    DispatchQueue.main.async {
                        guard targetOffsetAlongAxis != nil else { return }
                        withAnimation(MotionPolicy.animation(PanelMotion.select)) {
                            enterProgress = 1
                        }
                    }
                case (_?, let target?):
                    // 已在条带上连续滑动切换：保持浮出态，顺着主轴丝滑跟手滑过去 ✓
                    withAnimation(MotionPolicy.animation(PanelMotion.slide)) {
                        renderedAxisOffset = target
                        enterProgress = 1
                    }
                case (_?, nil):
                    // 移出无选中：原地向贴屏边轻沉淡出（不归零回第 0 格）✓
                    withAnimation(MotionPolicy.animation(.easeOut(duration: 0.14))) {
                        enterProgress = 0
                    }
                case (nil, nil):
                    break
                }
            }
    }

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
            .overlay(shape.strokeBorder(p.border, lineWidth: 0.75))

        if #available(macOS 26.0, *) {
            bodyLayer.glassEffect(visible ? .clear : .identity, in: shape)
        } else {
            bodyLayer
        }
    }
}
