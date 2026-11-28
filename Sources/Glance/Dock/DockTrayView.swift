import AppKit
import GlanceCore
import SwiftUI

/// Dock 窗口预览托盘视图（严格遵循全局 `WindowLayout.current`：`.row` 卡片行 / `.rail` 芯片轨道）。
struct DockTrayView: View {
    @ObservedObject var controller: DockController
    @ObservedObject var snapshotter: Snapshotter

    private var m: DockMetrics { controller.metrics }

    private var group: AppGroup? { controller.activeHoveredGroup }
    private var windows: [WindowRecord] { group?.windows ?? [] }

    private var selIndex: Int {
        guard !windows.isEmpty else { return 0 }
        return min(max(controller.selectedWindowIndex, 0), windows.count - 1)
    }

    private var useRail: Bool {
        WindowLayout.current == .rail && windows.count > 1
    }

    var body: some View {
        let traySize = controller.trayContentSize

        // 与 Cmd+Tab 预览托盘同口径（2026-09-21 裁定）：撤掉最外层玻璃背板，
        // 只保留悬浮窗口卡自身阴影与芯片胶囊，避免厚重灰壳盖在卡片外。
        trayBody
            .id(controller.glassEpoch)
            .padding(.top, m.trayPadTop)
            .padding(.horizontal, m.trayPadX)
            .padding(.bottom, m.trayPadBottom)
            .frame(
                width: traySize.width,
                height: traySize.height,
                alignment: controller.position.isVertical ? .top : .center
            )
            .padding(m.shadowPadPop)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusEffectDisabled(true)
    }

    @ViewBuilder
    private var trayBody: some View {
        if windows.isEmpty {
            EmptyView()
        } else if useRail {
            if controller.position.isVertical {
                sideRailLayout
            } else {
                railLayout
            }
        } else {
            if controller.position.isVertical {
                sideColumnCardLayout
            } else {
                rowLayout
            }
        }
    }

    /// 侧边程序坞贴边对齐方向：右侧程序坞靠右贴边、左侧程序坞靠左贴边。
    private var sideHorizontalAlignment: HorizontalAlignment {
        controller.position == .right ? .trailing : .leading
    }

    // MARK: - `.row` 卡片行（底部横向） / 竖排卡片列（侧边纵向）

    private var rowLayout: some View {
        let widen: CGFloat = (WindowLayout.current == .rail && windows.count == 1)
            ? PanelMetrics.soloWiden
            : 1
        let widths = windows.map { m.thumbSize(real: $0.bounds.size, aspect: $0.aspect, widen: widen).width }
        let (rows, cols) = m.trayRowLayout(widths: widths, maxWidth: controller.trayAvailableSize.width)
        let rowsSafe = max(rows, 1)
        let colsSafe = max(cols, 1)

        return VStack(alignment: .leading, spacing: m.trayRowGap) {
            ForEach(0..<rowsSafe, id: \.self) { row in
                HStack(alignment: .bottom, spacing: m.thumbGap) {
                    let start = row * colsSafe
                    let end = min(start + colsSafe, windows.count)
                    ForEach(start..<end, id: \.self) { index in
                        let window = windows[index]
                        let box = m.thumbSize(real: window.bounds.size, aspect: window.aspect, widen: widen)
                        DockThumbCard(
                            window: window,
                            bundleID: group?.bundleID,
                            image: window.isMinimized ? nil : snapshotter.cache[window.wid],
                            liveBox: LivePreviewPool.shared.box(for: window.wid),
                            box: box,
                            metrics: m,
                            selected: index == selIndex,
                            showsChip: true
                        )
                        .onHover { inside in
                            if inside {
                                controller.hoverWindow(at: index)
                            }
                        }
                        .onTapGesture {
                            controller.confirmWindow(window)
                        }
                    }
                }
            }
        }
    }

    /// 侧边程序坞卡片模式：单列竖排优先，超出屏高时均衡扩第 2/3 列，避免横穿正文。
    private var sideColumnCardLayout: some View {
        // 侧边单窗与多窗同为「上预览卡 + 下芯片」竖排结构，不乘 soloWiden，避免单/多窗切换时卡片缩放跳位 ✓
        let widen: CGFloat = 1
        let cardBoxes = windows.map { w -> CGSize in
            let box = m.thumbSize(real: w.bounds.size, aspect: w.aspect, widen: widen)
            let itemW = max(box.width, m.sideChipWidth(forMaxCardWidth: box.width))
            return CGSize(width: itemW, height: box.height + m.chipGap + m.chipH)
        }
        let grid = m.verticalCardColumns(cardSizes: cardBoxes, maxHeight: controller.trayAvailableSize.height)
        let colsSafe = max(grid.cols, 1)
        let rowsPerCol = max(grid.rowsPerCol, 1)

        return HStack(alignment: .top, spacing: m.thumbGap) {
            ForEach(0..<colsSafe, id: \.self) { col in
                // 右侧程序坞将主列（第 0 列）放在最靠右贴近程序坞的位置，溢出列往左延展
                let logicalCol = controller.position == .right ? (colsSafe - 1 - col) : col
                let start = logicalCol * rowsPerCol
                let end = min(start + rowsPerCol, windows.count)
                if start < end {
                    VStack(alignment: sideHorizontalAlignment, spacing: m.trayRowGap) {
                        ForEach(start..<end, id: \.self) { index in
                            let window = windows[index]
                            let box = m.thumbSize(real: window.bounds.size, aspect: window.aspect, widen: widen)
                            DockThumbCard(
                                window: window,
                                bundleID: group?.bundleID,
                                image: window.isMinimized ? nil : snapshotter.cache[window.wid],
                                liveBox: LivePreviewPool.shared.box(for: window.wid),
                                box: box,
                                metrics: m,
                                selected: index == selIndex,
                                showsChip: true,
                                chipWidthOverride: m.sideChipWidth(forMaxCardWidth: box.width)
                            )
                            .onHover { inside in
                                if inside {
                                    controller.hoverWindow(at: index)
                                }
                            }
                            .onTapGesture {
                                controller.confirmWindow(window)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - `.rail` 芯片轨道（底部：左卡右轨 / 侧边：上卡下轨）

    /// 底部程序坞：左大预览卡 + 右芯片列（居中对齐，对齐 Cmd+Tab `ChipRailGroup`）。
    private var railLayout: some View {
        let sizes = windows.map { m.thumbSize(real: $0.bounds.size, aspect: $0.aspect) }
        let selectedWindow = windows[selIndex]
        let selectedBox = sizes[selIndex]
        let slotW = selectedBox.width
        let slotH = selectedBox.height
        let railH = max(slotH, m.chipRailStep)

        return HStack(alignment: .center, spacing: m.thumbGap) {
            DockThumbCard(
                window: selectedWindow,
                bundleID: group?.bundleID,
                image: selectedWindow.isMinimized ? nil : snapshotter.cache[selectedWindow.wid],
                liveBox: LivePreviewPool.shared.box(for: selectedWindow.wid),
                box: selectedBox,
                metrics: m,
                selected: true,
                showsChip: false
            )
            .frame(width: slotW, height: slotH, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.confirmWindow(selectedWindow)
            }

            DockChipRail(
                windows: windows,
                bundleID: group?.bundleID,
                selectedIndex: selIndex,
                laneWidth: m.chipRailWidth,
                railHeight: railH,
                verticalAlignment: .center,
                metrics: m,
                onHoverChip: { controller.hoverWindow(at: $0) },
                onTapChip: { controller.confirmWindow(windows[$0]) }
            )
        }
    }

    /// 侧边程序坞：上大预览卡水平居中 + 下方 macOS 通知式芯片叠卡（悬停叠卡区向下展开，移回预览卡不收起）。
    private var sideRailLayout: some View {
        let expanded = controller.isSideChipStackExpanded
        let geom = m.sideRailGeometry(
            windows: windows,
            maxHeight: controller.trayAvailableSize.height,
            expanded: expanded
        )
        let selectedWindow = windows[selIndex]
        let selectedBox = geom.cardSizes[selIndex]

        return VStack(alignment: .center, spacing: geom.sectionGap) {
            DockThumbCard(
                window: selectedWindow,
                bundleID: group?.bundleID,
                image: selectedWindow.isMinimized ? nil : snapshotter.cache[selectedWindow.wid],
                liveBox: LivePreviewPool.shared.box(for: selectedWindow.wid),
                box: selectedBox,
                metrics: m,
                selected: true,
                showsChip: false
            )
            .frame(width: geom.columnWidth, height: geom.slotHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.confirmWindow(selectedWindow)
            }

            DockSideChipStack(
                windows: windows,
                bundleID: group?.bundleID,
                selectedIndex: selIndex,
                geom: geom,
                metrics: m,
                expanded: expanded,
                onExpand: { controller.expandSideChipStack() },
                onHoverChip: { controller.hoverWindow(at: $0) },
                onTapChip: { controller.confirmWindow(windows[$0]) },
                onTapSelected: { controller.confirmWindow(selectedWindow) }
            )
        }
        .frame(width: geom.columnWidth, alignment: .top)
    }
}

// MARK: - 窗口缩略图卡片

private struct DockThumbCard: View {
    let window: WindowRecord
    let bundleID: String?
    let image: NSImage?
    @ObservedObject var liveBox: LiveFrameBox
    let box: CGSize
    let metrics: DockMetrics
    let selected: Bool
    let showsChip: Bool
    /// 侧边程序坞单窗芯片与多窗叠卡芯片共用同一自适应宽度；底部模式传 nil 维持与卡片等宽。
    var chipWidthOverride: CGFloat? = nil

    @State private var hovered = false

    private var isActive: Bool { selected || hovered }

    private var liveFrame: CGImage? {
        guard !window.isMinimized else { return nil }
        return LivePreviewPool.enabled ? liveBox.image : nil
    }

    private var displayTitle: String {
        let raw = WindowTitle.display(raw: window.title, bundleID: bundleID)
        return WindowTitle.middleTruncate(raw, limit: metrics.titleCharLimit)
    }

    var body: some View {
        VStack(spacing: metrics.chipGap) {
            previewSurface
            if showsChip {
                chipView
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
        }
    }

    private var previewSurface: some View {
        let cardShape = RoundedRectangle(cornerRadius: metrics.rThumb, style: .continuous)

        return ZStack {
            if let liveFrame {
                Image(decorative: liveFrame, scale: PanelScreen.scale)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: box.width + 6, height: box.height + 6)
                    .clipped()
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: box.width + 6, height: box.height + 6)
                    .clipped()
            } else {
                Rectangle().fill(PanelColors.thumbBg)
                Image(nsImage: IconProvider.art(for: window.pid, bundleID: bundleID).image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(box.width, box.height) * 0.36, height: min(box.width, box.height) * 0.36)
                    .opacity(0.35)
            }
        }
        .opacity(isActive ? 1.0 : 0.86)
        .saturation(window.isMinimized ? 0 : (isActive ? 1.0 : 0.90))
        .brightness(window.isMinimized ? -0.05 : 0)
        .frame(width: box.width, height: box.height)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if window.isMinimized {
                HStack(spacing: 4) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: max(9, 10 * metrics.trayScale), weight: .semibold))
                        .foregroundStyle(PanelColors.tlMin)
                    Text("最小化")
                        .font(.system(size: max(9.5, 10.5 * metrics.trayScale), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                )
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        // 对齐 Cmd+Tab 托盘 2026-10-20 裁定：预览卡不画描边（任何亮线/细框在深色下都会读成丑边框），
        // 厚度与选中层次只靠底层静态形状的 `.elevation` 阴影承担。
        .background(PanelColors.thumbBg)
        .clipShape(cardShape)
        .background {
            cardShape
                .fill(PanelColors.thumbBg)
                .elevation(isActive ? .thumbLift : .thumb)
        }
        .scaleEffect(isActive ? 1.02 : 0.98, anchor: .bottom)
        .animation(MotionPolicy.animation(.easeOut(duration: 0.14)), value: isActive)
    }

    private var chipView: some View {
        HStack(spacing: 5) {
            Image(nsImage: IconProvider.art(for: window.pid, bundleID: bundleID).smallImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: metrics.chipIcon, height: metrics.chipIcon)
                .clipShape(RoundedRectangle(cornerRadius: metrics.chipIcon * 0.30, style: .continuous))
                .saturation(window.isMinimized ? 0 : (isActive ? 1 : 0.65))
                .opacity(window.isMinimized ? (isActive ? 0.60 : 0.46) : 1)

            Text(displayTitle)
                .font(.system(size: metrics.titleSize, weight: .regular))
                .foregroundStyle(PanelColors.thumbTitle)
                .opacity(window.isMinimized ? (isActive ? 0.88 : 0.66) : 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if window.isMinimized {
                Image(systemName: "minus.circle")
                    .font(.system(size: max(metrics.titleSize - 2, 9.5), weight: .medium))
                    .foregroundStyle(PanelColors.tlMin.opacity(isActive ? 0.95 : 0.75))
            }

            Circle()
                .fill(isActive ? PanelColors.chipDotOn : Color.clear)
                .frame(width: metrics.chipDot, height: metrics.chipDot)
                .overlay(
                    Circle()
                        .strokeBorder(PanelColors.chipDotOff, lineWidth: PanelMetrics.hairline)
                        .opacity(isActive ? 0 : 1)
                )
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(width: chipWidthOverride ?? box.width, height: metrics.chipH)
        .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
        .shadow(color: .black.opacity(isActive ? 0.10 : 0), radius: 3, y: 1)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    isActive ? PanelColors.chipBorder : PanelColors.chipBorderOff,
                    style: StrokeStyle(
                        lineWidth: PanelMetrics.hairline,
                        dash: window.isMinimized ? [3.5, 2.5] : []
                    )
                )
        )
    }
}

// MARK: - `.rail` 右侧芯片轨道

private struct DockChipRail: View {
    let windows: [WindowRecord]
    let bundleID: String?
    let selectedIndex: Int
    let laneWidth: CGFloat
    let railHeight: CGFloat
    var verticalAlignment: Alignment = .center
    let metrics: DockMetrics
    let onHoverChip: (Int) -> Void
    let onTapChip: (Int) -> Void

    /// 与 Cmd+Tab `ChipRailGroup` 完全同款的芯片切换动效状态：
    /// 仅对起点（`selFrom`）与终点（`selectedIndex`）两枚芯片交叉淡入/缩放，
    /// 避免中间路过的芯片产生涟漪，且换 App 时当拍就位不乱滑。
    @State private var selFrom: Int = 0
    @State private var selF: CGFloat = 0
    @State private var selAnimGate: Bool = false

    private var fits: Bool {
        let totalH = CGFloat(windows.count) * metrics.chipH
            + CGFloat(max(windows.count - 1, 0)) * metrics.chipRailGap
        return totalH <= railHeight + 0.5
    }

    var body: some View {
        let content = VStack(spacing: metrics.chipRailGap) {
            ForEach(Array(windows.enumerated()), id: \.element.wid) { index, window in
                railChip(window: window, index: index)
            }
        }
        .frame(width: laneWidth)

        Group {
            if fits {
                content
                    .frame(width: laneWidth, height: railHeight, alignment: verticalAlignment)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    content
                }
                .frame(width: laneWidth, height: railHeight)
            }
        }
        .onAppear {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                selAnimGate = false
                selFrom = selectedIndex
                selF = CGFloat(selectedIndex)
            }
        }
        .onChange(of: selectedIndex) { old, new in
            // 起点同拍写好，避免跨格跳选（如 3→1）时中间芯片闪亮一帧
            selFrom = old
            DispatchQueue.main.async {
                selAnimGate = true
                selF = CGFloat(new)
                DispatchQueue.main.async { selAnimGate = false }
            }
        }
        .onChange(of: bundleID) { _, _ in
            selAnimGate = false
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                selFrom = selectedIndex
                selF = CGFloat(selectedIndex)
            }
        }
    }

    private func railChip(window: WindowRecord, index: Int) -> some View {
        let span = CGFloat(selectedIndex - selFrom)
        let p: CGFloat = span == 0 ? 1 : min(max((selF - CGFloat(selFrom)) / span, 0), 1)
        let em: CGFloat = index == selectedIndex ? p
            : (index == selFrom ? 1 - p : 0)

        return DockRailChipView(
            window: window,
            bundleID: bundleID,
            width: laneWidth,
            metrics: metrics,
            em: em
        )
        .scaleEffect(0.964 + 0.036 * em)
        .animation(
            selAnimGate
                ? MotionPolicy.animation(.spring(response: 0.30, dampingFraction: 1.0))
                : nil,
            value: selF
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                onHoverChip(index)
            }
        }
        .onTapGesture {
            onHoverChip(index)
            onTapChip(index)
        }
    }
}

/// 芯片轨道单枚胶囊芯片视图（供 `DockChipRail` 与 `DockSideChipStack` 共用）。
private struct DockRailChipView: View {
    let window: WindowRecord
    let bundleID: String?
    let width: CGFloat
    let metrics: DockMetrics
    let em: CGFloat
    var contentOpacity: CGFloat = 1
    /// 叠卡收起态纵深（0=顶层、1=中层、2=底层；非叠卡场景为 nil）。
    var stackDepth: Int? = nil
    /// 叠卡收起权重：`1` = 完全收起（启用实色分层与接触阴影），`0` = 展开态（回到常规胶囊材质）。
    var stackCollapse: CGFloat = 0

    var body: some View {
        let title = WindowTitle.middleTruncate(
            WindowTitle.display(raw: window.title, bundleID: bundleID),
            limit: metrics.titleCharLimit
        )
        let collapse = stackDepth != nil ? min(max(stackCollapse, 0), 1) : 0
        let depth = stackDepth ?? 0
        let showMinimizedDash = window.isMinimized && (depth == 0 || collapse < 0.85)
        let shadowColor: Color = stackDepth != nil && collapse > 0.01
            ? PanelColors.chipStackShadow(depth: depth).opacity(collapse)
            : .black.opacity(0.10 + 0.05 * em)
        let shadowRadius: CGFloat = stackDepth != nil && collapse > 0.01
            ? (depth == 0 ? 4.0 : (depth == 1 ? 2.5 : 4.0))
            : (3 + 2 * em)
        let shadowY: CGFloat = stackDepth != nil && collapse > 0.01
            ? (depth == 0 ? 2.0 : (depth == 1 ? 1.5 : 2.0))
            : (1 + 1 * em)

        HStack(spacing: 6) {
            Image(nsImage: IconProvider.art(for: window.pid, bundleID: bundleID).smallImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: metrics.chipIcon, height: metrics.chipIcon)
                .clipShape(RoundedRectangle(cornerRadius: metrics.chipIcon * 0.30, style: .continuous))
                .saturation(window.isMinimized ? 0 : (0.65 + 0.35 * em))
                .opacity(window.isMinimized ? (0.46 + 0.14 * em) : (0.86 + 0.14 * em))

            // 两层文字按 `em` 交叉淡，平滑过渡前景色
            ZStack(alignment: .leading) {
                Text(title)
                    .foregroundStyle(PanelColors.chipFgOff)
                    .opacity(1 - em)
                Text(title)
                    .foregroundStyle(PanelColors.chipFgOn)
                    .opacity(em)
            }
            .font(.system(size: metrics.titleSize, weight: .regular))
            .opacity(window.isMinimized ? (0.66 + 0.24 * em) : 1)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            if window.isMinimized {
                Image(systemName: "minus.circle")
                    .font(.system(size: max(metrics.titleSize - 2, 9.5), weight: .medium))
                    .foregroundStyle(PanelColors.tlMin.opacity(0.75 + 0.20 * em))
            }

            ZStack {
                Circle()
                    .strokeBorder(PanelColors.chipDotOff, lineWidth: PanelMetrics.hairline)
                    .opacity(1 - em)
                Circle()
                    .fill(PanelColors.chipDotOn)
                    .opacity(em)
            }
            .frame(width: metrics.chipDot, height: metrics.chipDot)
        }
        .opacity(contentOpacity)
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .frame(width: width, height: metrics.chipH, alignment: .center)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(window.isMinimized ? PanelColors.chipBg.opacity(0.82 + 0.12 * em) : PanelColors.chipBg)
                if let depth = stackDepth, collapse > 0.001 {
                    Capsule(style: .continuous)
                        .fill(PanelColors.chipStackBg(depth: depth))
                        .opacity(collapse)
                }
            }
        )
        .shadow(
            color: shadowColor,
            radius: shadowRadius,
            y: shadowY
        )
        .overlay(
            ZStack {
                Capsule(style: .continuous)
                    .strokeBorder(
                        PanelColors.chipBorder,
                        style: StrokeStyle(
                            lineWidth: PanelMetrics.hairline,
                            dash: showMinimizedDash ? [3.5, 2.5] : []
                        )
                    )
                    .opacity(1 - collapse)
                if let depth = stackDepth, collapse > 0.001 {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            PanelColors.chipStackBorder(depth: depth),
                            style: StrokeStyle(
                                lineWidth: PanelMetrics.hairline,
                                dash: showMinimizedDash ? [3.5, 2.5] : []
                            )
                        )
                        .opacity(collapse)
                }
            }
        )
    }
}

/// 侧边程序坞 macOS 通知式芯片叠卡：
/// - 采用参数驱动（`fan: 0 → 1`）逐枚弹簧滑出，不走 `.transition`（规避系统 `reduceMotion` 吃掉过渡动画，见 `PanelMotion.swift` 2026-10-08 消元结论）；
/// - 收起态同一批真芯片叠在顶层芯片后方（露最多 2 层 94%/88% 宽底边），悬停叠卡区时各芯片按轻微错峰弹簧从后方滑出展开。
private struct DockSideChipStack: View {
    let windows: [WindowRecord]
    let bundleID: String?
    let selectedIndex: Int
    let geom: DockMetrics.SideRailGeometry
    let metrics: DockMetrics
    let expanded: Bool
    let onExpand: () -> Void
    let onHoverChip: (Int) -> Void
    let onTapChip: (Int) -> Void
    let onTapSelected: () -> Void

    @State private var fan: CGFloat = 0
    @State private var fanAnimGate: Bool = false
    @State private var selFrom: Int = 0
    @State private var selF: CGFloat = 0
    @State private var selAnimGate: Bool = false

    private var naturalListHeight: CGFloat {
        CGFloat(windows.count) * metrics.chipH
            + CGFloat(max(windows.count - 1, 0)) * metrics.chipRailGap
    }

    private var needsScroll: Bool {
        naturalListHeight > geom.expandedListHeight + 0.5
    }

    private func stackRank(for index: Int) -> Int {
        if index == selectedIndex { return 0 }
        return index < selectedIndex ? (index + 1) : index
    }

    var body: some View {
        let deck = ZStack(alignment: .top) {
            ForEach(Array(windows.enumerated()), id: \.element.wid) { index, window in
                stackedChip(window: window, index: index)
            }

            if !expanded {
                Color.clear
                    .frame(width: geom.chipWidth, height: geom.collapsedListHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            onExpand()
                        }
                    }
                    .onTapGesture {
                        onTapSelected()
                    }
                    .zIndex(Double(windows.count + 2))
            }
        }
        .frame(
            width: geom.chipWidth,
            height: needsScroll ? naturalListHeight : geom.listHeight,
            alignment: .top
        )

        Group {
            if needsScroll {
                ScrollView(.vertical, showsIndicators: false) {
                    deck
                }
                .scrollDisabled(!expanded)
                .frame(width: geom.chipWidth, height: geom.listHeight, alignment: .top)
            } else {
                deck
            }
        }
        .onAppear {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                fanAnimGate = false
                fan = expanded ? 1 : 0
                selAnimGate = false
                selFrom = selectedIndex
                selF = CGFloat(selectedIndex)
            }
        }
        .onChange(of: expanded) { _, nowExpanded in
            if nowExpanded {
                // 等一拍让托盘 NSPanel 先撑开下方透明空间，再驱动参数 `fan: 0 → 1` 逐枚滑出
                DispatchQueue.main.async {
                    guard expanded else { return }
                    fanAnimGate = true
                    fan = 1
                    DispatchQueue.main.async { fanAnimGate = false }
                }
            } else {
                fanAnimGate = false
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    fan = 0
                }
            }
        }
        .onChange(of: selectedIndex) { old, new in
            selFrom = old
            DispatchQueue.main.async {
                selAnimGate = true
                selF = CGFloat(new)
                DispatchQueue.main.async { selAnimGate = false }
            }
        }
        .onChange(of: bundleID) { _, _ in
            fanAnimGate = false
            selAnimGate = false
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                fan = expanded ? 1 : 0
                selFrom = selectedIndex
                selF = CGFloat(selectedIndex)
            }
        }
    }

    private func stackedChip(window: WindowRecord, index: Int) -> some View {
        let rank = stackRank(for: index)
        let clampedRank = min(rank, geom.peekLayers)

        // 展开态下复用与 Cmd+Tab / 底部轨道同款的选中高亮插值
        let span = CGFloat(selectedIndex - selFrom)
        let p: CGFloat = span == 0 ? 1 : min(max((selF - CGFloat(selFrom)) / span, 0), 1)
        let expandedEm: CGFloat = index == selectedIndex ? p
            : (index == selFrom ? 1 - p : 0)
        let collapsedEm: CGFloat = rank == 0 ? 1 : 0
        let em = collapsedEm + (expandedEm - collapsedEm) * fan

        // 收起态（fan=0）叠在顶层芯片后方；展开态（fan=1）滑落至完整列表槽位
        let collapsedY = CGFloat(clampedRank) * geom.peekStep
        let expandedY = CGFloat(index) * metrics.chipRailStep
        let offsetY = collapsedY + (expandedY - collapsedY) * fan

        let collapsedScaleX = 1.0 - 0.06 * CGFloat(clampedRank)
        let collapsedScaleY = 1.0 - 0.02 * CGFloat(clampedRank)
        let expandedScale = 0.964 + 0.036 * expandedEm
        let scaleX = collapsedScaleX + (expandedScale - collapsedScaleX) * fan
        let scaleY = collapsedScaleY + (expandedScale - collapsedScaleY) * fan

        // 可见的 3 层叠卡（rank 0/1/2）收起态一律保持 1.0 不透明，避免低 alpha 透底重影与浅壁纸发灰倒置；
        // 深度层级改由 `PanelColors.chipStackBg/Border/Shadow(depth:)` 实色阶与层间接触阴影表达。
        // 第 4 枚起（rank >= 3）在收起态完全隐藏，展开时随 `fan: 0 → 1` 淡入。
        let collapsedOpacity: CGFloat = rank <= geom.peekLayers ? 1.0 : 0.0
        let opacity = collapsedOpacity + (1.0 - collapsedOpacity) * fan

        let collapsedContentOpacity: CGFloat = rank == 0 ? 1.0 : 0.0
        let contentOpacity = collapsedContentOpacity + (1.0 - collapsedContentOpacity) * fan

        // 轻微错峰弹簧（顶层响应略快、后层顺次跟进），复刻 macOS 通知叠卡展开的流动感
        let fanSpring = MotionPolicy.animation(
            .spring(response: 0.30 + Double(min(rank, 5)) * 0.028, dampingFraction: 0.84)
        )
        let selSpring = MotionPolicy.animation(.spring(response: 0.30, dampingFraction: 1.0))

        return DockRailChipView(
            window: window,
            bundleID: bundleID,
            width: geom.chipWidth,
            metrics: metrics,
            em: em,
            contentOpacity: contentOpacity,
            stackDepth: clampedRank,
            stackCollapse: 1 - fan
        )
        // 命中层必须挂在 `.scaleEffect` / `.offset` **之前**（2026-11-25 修）：`offset` 只平移绘制与
        // 命中层的合成结果，挂在其后的 `.contentShape` / `.onHover` / `.onTapGesture` 会退化成
        // 在 ZStack 顶部 y=0 那一条未偏移的布局框上判定 —— 滑到下方的第 2/3/4 枚芯片
        // 视觉位置与命中位置错位，hover 与点击全部落空。
        .contentShape(Rectangle())
        .onHover { inside in
            if expanded, inside {
                onHoverChip(index)
            }
        }
        .onTapGesture {
            guard expanded else { return }
            onHoverChip(index)
            onTapChip(index)
        }
        .allowsHitTesting(expanded)
        .scaleEffect(x: scaleX, y: scaleY, anchor: .top)
        .offset(y: offsetY)
        .opacity(opacity)
        .zIndex(Double(windows.count - rank))
        .animation(fanAnimGate ? fanSpring : nil, value: fan)
        .animation(selAnimGate ? selSpring : nil, value: selF)
    }
}
