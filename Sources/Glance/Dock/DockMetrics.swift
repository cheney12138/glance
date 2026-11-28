import CoreGraphics
import Foundation
import GlanceCore

/// Dock 替代面板的纯值度量表，复用 `PanelMetrics` 同源比例并按局部 `scale` / `trayScale` 计算。
/// 严禁读写 `PanelMetrics.sessionCap` / `trayCap` / `trayZoom` 等全局静态状态。
struct DockMetrics: Equatable, Sendable {
    static let baseIconSize: CGFloat = 88

    /// 用户在设置中选择的程序坞条带比例（默认 56pt / 88pt ≈ 0.636，独立于 ⌘Tab 的 1.2 固定比例）。
    static var preferredStripScale: CGFloat {
        Keys.dockIconSizePt / baseIconSize
    }

    /// 预览托盘比例：直接遵循用户在「程序坞 → 预览窗口尺寸」的配置（默认 120%，与 ⌘Tab 一致），独立于图标尺寸。
    static var preferredTrayScale: CGFloat {
        Keys.dockPreviewScaleRatio
    }

    let scale: CGFloat
    let trayScale: CGFloat

    init(
        scale: CGFloat = DockMetrics.preferredStripScale,
        trayScale: CGFloat = DockMetrics.preferredTrayScale
    ) {
        self.scale = scale
        self.trayScale = trayScale
    }

    // MARK: - 条带度量（随 `scale`）

    var icon: CGFloat { 88 * scale }
    var iconScale: CGFloat { PanelMetrics.iconScale }

    var iconClearance: CGFloat {
        let v = UserDefaults.standard.object(forKey: Keys.panelIconClearance) as? Double
        return (v.map { CGFloat($0) } ?? 13) * scale
    }

    var selectionOverflow: CGFloat { icon * (iconScale - 1) / 2 }
    var iconGap: CGFloat { iconClearance + selectionOverflow }
    var pitch: CGFloat { icon + iconGap }

    var rowPadX: CGFloat { 26 * scale }
    var rowPadY: CGFloat { 22 * scale }
    var iconLift: CGFloat { 8 * scale }
    var puckHeight: CGFloat { icon + 22 * scale }

    var rPanel: CGFloat { 34 * scale }
    var rPuck: CGFloat { 24 * scale }
    var ghostTileRadius: CGFloat { icon * 0.225 }

    var dot: CGFloat { max(4 * scale, 3) }
    var dotGap: CGFloat { 3 * scale }
    var dashHeight: CGFloat { dot * 0.6 }
    var dotBottom: CGFloat { 7 * scale }
    var dotLift: CGFloat { iconLift - selectionOverflow }

    var tally: WindowTally.Metrics {
        WindowTally.Metrics(
            dot: dot,
            dashWidth: dot * 2.5,
            gap: dotGap,
            minDot: max(2.5 * scale, 2.5),
            minGap: 1.7 * scale
        )
    }

    /// 环尾收纳文件夹图标：与周围 App 图标同体量（90% 边长），视觉融入而非漂浮小灰块
    var toggleButtonSize: CGFloat { icon * 0.90 }
    /// 分割线两侧静态留白：吃掉相邻图标浮起放大（`selectionOverflow`）后再多留少许视觉余量，
    /// 避免悬停靠近分割线的 App 时图标底缘/投影贴到分割线，同时保持静态几何零抖动 ✓
    var toggleGap: CGFloat { max(iconGap + selectionOverflow * 0.35, 14 * scale) }
    var toggleDividerThickness: CGFloat { PanelMetrics.hairline }
    var toggleDividerLength: CGFloat { icon * 0.56 }

    var toggleSectionAxisSpan: CGFloat {
        toggleGap + toggleDividerThickness + toggleGap + toggleButtonSize
    }

    var emptyStripBodySpan: CGFloat { 156 * scale }

    // MARK: - 托盘度量（随 `trayScale`）

    var rTray: CGFloat { 30 * trayScale }
    var rThumb: CGFloat { 10 * trayScale }
    var shotH: CGFloat { 122 * trayScale }
    var thumbGap: CGFloat { 14 * trayScale }
    var trayRowGap: CGFloat { 12 * trayScale }
    /// 无外层玻璃背板，仅留极轻内边距防卡片放大裁切（对齐 Cmd+Tab 托盘）
    var trayPadX: CGFloat { 6 * trayScale }
    var trayPadTop: CGFloat { 6 * trayScale }
    var trayPadBottom: CGFloat { 4 * trayScale }

    var chipH: CGFloat { 24 * trayScale }
    var chipIcon: CGFloat { 15 * trayScale }
    var chipDot: CGFloat { 6 * trayScale }
    var chipGap: CGFloat { 6 * trayScale }
    var chipRailWidth: CGFloat { 164 * trayScale }
    var chipRailGap: CGFloat { 6 * trayScale }
    var chipRailStep: CGFloat { chipH + chipRailGap }
    var titleSize: CGFloat { 12 * trayScale }
    var titleCharLimit: Int { max(12, Int(28 * trayScale)) }
    var trayMaxRows: Int { 4 }

    var shadowPadStrip: CGFloat { PanelMetrics.shadowPadStrip }
    var shadowPadPop: CGFloat { PanelMetrics.shadowPadPop }

    var cardMetrics: CardMetrics {
        CardMetrics(
            shotH: shotH,
            thumbMinW: PanelMetrics.thumbMinW,
            thumbMaxW: PanelMetrics.thumbMaxW,
            thumbGap: thumbGap,
            trayPadX: trayPadX,
            trayPadTop: trayPadTop,
            trayPadBottom: trayPadBottom,
            trayRowGap: trayRowGap
        )
    }

    func thumbWidth(aspect: CGFloat) -> CGFloat {
        trayScale * CardSizing.capWidth(aspect: aspect, cardMetrics)
    }

    func thumbSize(real: CGSize, aspect: CGFloat, widen: CGFloat = 1) -> CGSize {
        CardSizing.size(
            real: real,
            capWidth: thumbWidth(aspect: aspect) * widen,
            capHeight: shotH
        )
    }

    // MARK: - 条带几何

    /// 条带玻璃内容尺寸（`bottom` 为水平展开，`left`/`right` 为垂直展开）。
    func stripContentSize(itemCount: Int, position: DockPosition, hasToggle: Bool) -> CGSize {
        let itemsSpan: CGFloat = itemCount > 0
            ? CGFloat(itemCount) * icon + CGFloat(max(itemCount - 1, 0)) * iconGap
            : emptyStripBodySpan
        let tailSpan: CGFloat = hasToggle ? toggleSectionAxisSpan : 0
        let mainLength = rowPadX * 2 + itemsSpan + tailSpan
        let crossThickness = rowPadY * 2 + icon
        return position.isVertical
            ? CGSize(width: crossThickness, height: mainLength)
            : CGSize(width: mainLength, height: crossThickness)
    }

    /// 第 `index` 个图标格中心沿条带主轴的屏幕坐标（AppKit 全局坐标：左下原点，Y 向上）。
    func iconCenterAlongAxis(
        at index: Int,
        itemCount: Int,
        stripRect: CGRect,
        position: DockPosition
    ) -> CGFloat {
        let clamped = min(max(index, 0), max(itemCount - 1, 0))
        let offsetFromStart = rowPadX + CGFloat(clamped) * pitch + icon / 2
        if position.isVertical {
            // SwiftUI VStack 从上往下排，AppKit Y 轴向上：第 0 格靠近 stripRect.maxY
            return stripRect.maxY - offsetFromStart
        }
        return stripRect.minX + offsetFromStart
    }

    // MARK: - 托盘几何

    /// 当前屏幕留给托盘的最大可视尺寸（避开条带、间距与屏边安全距）。
    func trayMaxAvailableSize(
        visibleSize: CGSize,
        stripSize: CGSize,
        position: DockPosition,
        edgeMargin: CGFloat = DockLayoutGeometry.defaultEdgeMargin,
        gap: CGFloat = 14,
        screenEdgePad: CGFloat = 12
    ) -> CGSize {
        if position.isVertical {
            let maxW = max(220, visibleSize.width - stripSize.width - edgeMargin - gap - screenEdgePad)
            let maxH = max(180, visibleSize.height * 0.82)
            return CGSize(width: maxW, height: maxH)
        }
        let maxW = max(320, visibleSize.width * 0.88)
        let maxH = max(160, visibleSize.height - stripSize.height - edgeMargin - gap - screenEdgePad)
        return CGSize(width: maxW, height: maxH)
    }

    /// 侧边程序坞（`left` / `right`）轨道版式的「上预览卡 + 下芯片叠卡/展开列」几何（组内全窗恒定，切窗芯片不跳位）。
    struct SideRailGeometry {
        let cardSizes: [CGSize]
        let slotHeight: CGFloat
        let chipWidth: CGFloat
        let columnWidth: CGFloat
        let sectionGap: CGFloat
        let peekLayers: Int
        let peekStep: CGFloat
        let collapsedListHeight: CGFloat
        let expandedListHeight: CGFloat
        let listHeight: CGFloat
        let contentSize: CGSize
    }

    /// 侧边程序坞单窗/多窗共用的芯片宽度（窄竖窗不缩成蚂蚁、宽窗封顶 204*trayScale，单/多窗视觉完全一致）。
    func sideChipWidth(forMaxCardWidth maxCardW: CGFloat) -> CGFloat {
        let minSideChipW = 136 * trayScale
        let maxSideChipW = 204 * trayScale
        return min(max(maxCardW, minSideChipW), maxSideChipW)
    }

    func sideRailGeometry(
        windows: [WindowRecord],
        maxHeight: CGFloat,
        expanded: Bool = false
    ) -> SideRailGeometry {
        let sizes = windows.map { thumbSize(real: $0.bounds.size, aspect: $0.aspect) }
        let maxCardW = sizes.map(\.width).max() ?? PanelMetrics.thumbMinW
        let slotH = sizes.map(\.height).max() ?? shotH
        // 自适应芯片宽：与侧边单窗芯片同口径，单/多窗切换零宽跳与视觉割裂
        let chipW = sideChipWidth(forMaxCardWidth: maxCardW)
        let colW = max(maxCardW, chipW)
        // 与单窗 `DockThumbCard` 的 `chipGap` 保持严格一致，消除单/多窗卡片到芯片的间距位移
        let gap = chipGap
        let peekLayers = min(max(windows.count - 1, 0), 2)
        let peekStep = max(5, 5.5 * trayScale)
        let collapsedListHeight = chipH + CGFloat(peekLayers) * peekStep
        let naturalListH = CGFloat(windows.count) * chipH
            + CGFloat(max(windows.count - 1, 0)) * chipRailGap
        let maxListH = max(chipRailStep * 2, maxHeight - trayPadTop - slotH - gap - trayPadBottom)
        let expandedListHeight = min(naturalListH, maxListH)
        let listHeight = expanded ? expandedListHeight : collapsedListHeight
        let content = CGSize(
            width: trayPadX * 2 + colW,
            height: trayPadTop + slotH + gap + listHeight + trayPadBottom
        )
        return SideRailGeometry(
            cardSizes: sizes,
            slotHeight: slotH,
            chipWidth: chipW,
            columnWidth: colW,
            sectionGap: gap,
            peekLayers: peekLayers,
            peekStep: peekStep,
            collapsedListHeight: collapsedListHeight,
            expandedListHeight: expandedListHeight,
            listHeight: listHeight,
            contentSize: content
        )
    }

    /// 侧边程序坞（`left` / `right`）卡片模式竖排分列：单列优先，超屏高再均衡扩第 2/3 列。
    struct VerticalColumnLayout {
        let cols: Int
        let rowsPerCol: Int
        let contentSize: CGSize
    }

    func verticalCardColumns(cardSizes: [CGSize], maxHeight: CGFloat) -> VerticalColumnLayout {
        guard !cardSizes.isEmpty else {
            return VerticalColumnLayout(cols: 0, rowsPerCol: 0, contentSize: .zero)
        }
        let maxCols = min(cardSizes.count, 3)
        let availH = max(maxHeight - trayPadTop - trayPadBottom, 160)

        func measure(cols: Int) -> VerticalColumnLayout {
            let rowsPerCol = (cardSizes.count + cols - 1) / cols
            var totalW: CGFloat = 0
            var maxColH: CGFloat = 0
            for col in 0..<cols {
                let start = col * rowsPerCol
                let end = min(start + rowsPerCol, cardSizes.count)
                guard start < end else { continue }
                let slice = cardSizes[start..<end]
                let colW = slice.map(\.width).max() ?? 0
                let colH = slice.reduce(CGFloat.zero) { $0 + $1.height }
                    + CGFloat(max(slice.count - 1, 0)) * trayRowGap
                if col > 0 { totalW += thumbGap }
                totalW += colW
                if colH > maxColH { maxColH = colH }
            }
            return VerticalColumnLayout(
                cols: cols,
                rowsPerCol: rowsPerCol,
                contentSize: CGSize(
                    width: trayPadX * 2 + totalW,
                    height: trayPadTop + maxColH + trayPadBottom
                )
            )
        }

        var chosen = measure(cols: maxCols)
        for c in 1...maxCols {
            let candidate = measure(cols: c)
            if candidate.contentSize.height - trayPadTop - trayPadBottom <= availH + 0.5 {
                chosen = candidate
                break
            }
        }
        return chosen
    }

    func trayRowLayout(widths: [CGFloat], maxWidth: CGFloat) -> (rows: Int, cols: Int) {
        TrayGrid.fitRows(
            widths: widths,
            gap: thumbGap,
            padW: trayPadX * 2,
            roomW: max(maxWidth, 200),
            maxRows: trayMaxRows
        )
    }

    func trayContentSize(
        windows: [WindowRecord],
        layout: WindowLayout,
        position: DockPosition = .bottom,
        maxSize: CGSize,
        selectedIndex: Int = 0,
        widenSolo: Bool = true,
        sideStackExpanded: Bool = false
    ) -> CGSize {
        guard !windows.isEmpty else { return .zero }

        if layout == .rail, windows.count > 1 {
            if position.isVertical {
                return sideRailGeometry(
                    windows: windows,
                    maxHeight: maxSize.height,
                    expanded: sideStackExpanded
                ).contentSize
            }
            // 底部程序坞：对齐 Cmd+Tab 托盘 2026-10-26 定稿，槽宽取当前选中卡自己的宽度
            let sizes = windows.map { thumbSize(real: $0.bounds.size, aspect: $0.aspect) }
            let clampedSel = min(max(selectedIndex, 0), sizes.count - 1)
            let slotW = sizes[clampedSel].width
            let slotH = sizes[clampedSel].height
            let railH = max(slotH, chipRailStep)
            return CGSize(
                width: trayPadX * 2 + slotW + thumbGap + chipRailWidth,
                height: trayPadTop + railH + trayPadBottom
            )
        }

        // 仅底部横向 `.rail` 单窗（少了右侧芯片列）才加宽补偿；
        // 侧边（left/right）单窗与多窗本就是同一套「上预览卡 + 下芯片」竖排结构，保持 1.0 等宽避免切换跳位 ✓
        let widen: CGFloat = (!position.isVertical && layout == .rail && windows.count == 1 && widenSolo)
            ? PanelMetrics.soloWiden
            : 1
        let cardBoxSizes = windows.map { w in
            let box = thumbSize(real: w.bounds.size, aspect: w.aspect, widen: widen)
            let itemW = position.isVertical ? max(box.width, sideChipWidth(forMaxCardWidth: box.width)) : box.width
            return CGSize(width: itemW, height: box.height + chipGap + chipH)
        }
        if position.isVertical {
            return verticalCardColumns(cardSizes: cardBoxSizes, maxHeight: maxSize.height).contentSize
        }
        let widths = cardBoxSizes.map(\.width)
        let (rows, cols) = trayRowLayout(widths: widths, maxWidth: maxSize.width)
        return TrayGrid.contentSize(
            widths: widths,
            sizes: cardBoxSizes,
            rows: rows,
            cols: cols,
            cardMetrics
        )
    }

    // MARK: - 按屏幕自动收紧

    /// 按用户设定的程序坞尺寸与屏幕可视空间自动收紧 `scale`（横向按宽 88%、纵向按高 82%），
    /// 并独立为预览托盘计算 `trayScale`。
    static func fitted(
        visibleSize: CGSize,
        position: DockPosition,
        itemCount: Int,
        hasToggle: Bool,
        trayWindows: [WindowRecord] = [],
        layout: WindowLayout = WindowLayout.current,
        sideStackExpanded: Bool = false
    ) -> DockMetrics {
        let targetStripScale = preferredStripScale
        let targetTrayScale = preferredTrayScale
        let stripScale = fittedStripScale(
            visibleSize: visibleSize,
            position: position,
            itemCount: itemCount,
            hasToggle: hasToggle,
            preferredScale: targetStripScale
        )
        let stripMetrics = DockMetrics(scale: stripScale, trayScale: targetTrayScale)
        let stripSize = stripMetrics.stripContentSize(
            itemCount: itemCount,
            position: position,
            hasToggle: hasToggle
        )
        let trayAvail = stripMetrics.trayMaxAvailableSize(
            visibleSize: visibleSize,
            stripSize: stripSize,
            position: position
        )
        let trayScale = fittedTrayScale(
            availableSize: trayAvail,
            windows: trayWindows,
            layout: layout,
            position: position,
            preferredScale: targetTrayScale,
            sideStackExpanded: sideStackExpanded
        )
        return DockMetrics(scale: stripScale, trayScale: trayScale)
    }

    static func fittedStripScale(
        visibleSize: CGSize,
        position: DockPosition,
        itemCount: Int,
        hasToggle: Bool,
        preferredScale: CGFloat = DockMetrics.preferredStripScale
    ) -> CGFloat {
        let base = DockMetrics(scale: 1, trayScale: 1)
        let baseStrip = base.stripContentSize(
            itemCount: itemCount,
            position: position,
            hasToggle: hasToggle
        )
        let maxLen: CGFloat
        let maxThick: CGFloat
        let baseLen: CGFloat
        let baseThick: CGFloat
        if position.isVertical {
            maxLen = visibleSize.height * 0.82
            maxThick = visibleSize.width * 0.25
            baseLen = baseStrip.height
            baseThick = baseStrip.width
        } else {
            maxLen = visibleSize.width * 0.88
            maxThick = visibleSize.height * 0.28
            baseLen = baseStrip.width
            baseThick = baseStrip.height
        }
        let cap = min(maxLen / max(baseLen, 1), maxThick / max(baseThick, 1))
        return min(preferredScale, max(0.32, cap))
    }

    static func fittedTrayScale(
        availableSize: CGSize,
        windows: [WindowRecord],
        layout: WindowLayout,
        position: DockPosition = .bottom,
        preferredScale: CGFloat = DockMetrics.preferredTrayScale,
        sideStackExpanded: Bool = false
    ) -> CGFloat {
        guard !windows.isEmpty else { return preferredScale }

        let target = DockMetrics(scale: preferredScale, trayScale: preferredScale)
        let targetSize = target.trayContentSize(
            windows: windows,
            layout: layout,
            position: position,
            maxSize: availableSize,
            sideStackExpanded: sideStackExpanded
        )
        if targetSize.width <= availableSize.width + 0.5,
           targetSize.height <= availableSize.height + 0.5 {
            return preferredScale
        }

        let unit = DockMetrics(scale: 1, trayScale: 1)
        if layout == .rail, windows.count > 1 {
            let unitSize = unit.trayContentSize(
                windows: windows,
                layout: .rail,
                position: position,
                maxSize: availableSize,
                sideStackExpanded: sideStackExpanded
            )
            let cap = min(
                availableSize.width / max(unitSize.width, 1),
                availableSize.height / max(unitSize.height, 1)
            )
            return min(preferredScale, max(0.45, cap))
        }

        if position.isVertical {
            let unitSize = unit.trayContentSize(
                windows: windows,
                layout: layout,
                position: position,
                maxSize: availableSize,
                sideStackExpanded: sideStackExpanded
            )
            let cap = min(
                availableSize.width / max(unitSize.width, 1),
                availableSize.height / max(unitSize.height, 1)
            )
            return min(preferredScale, max(0.45, cap))
        }

        let widen: CGFloat = (layout == .rail && windows.count == 1) ? PanelMetrics.soloWiden : 1
        let unitBoxes = windows.map { w -> CGSize in
            let b = unit.thumbSize(real: w.bounds.size, aspect: w.aspect, widen: widen)
            return CGSize(width: b.width, height: b.height + unit.chipGap + unit.chipH)
        }
        let unitWidths = unitBoxes.map(\.width)
        var bestScale: CGFloat = 0.45
        for rows in 1...min(windows.count, unit.trayMaxRows) {
            let cols = (windows.count + rows - 1) / rows
            let rowHeights = TrayGrid.rowHeights(unitBoxes, rows: rows, cols: cols)
            let totalW = TrayGrid.maxRowWidth(unitWidths, rows: rows, cols: cols, gap: unit.thumbGap)
                + unit.trayPadX * 2
            let totalH = unit.trayPadTop
                + rowHeights.reduce(0, +)
                + max(CGFloat(max(rows, 1)) - 1, 0) * unit.trayRowGap
                + unit.trayPadBottom
            let fit = min(availableSize.width / max(totalW, 1), availableSize.height / max(totalH, 1))
            if fit > bestScale { bestScale = fit }
        }
        return min(preferredScale, max(0.45, bestScale))
    }
}
