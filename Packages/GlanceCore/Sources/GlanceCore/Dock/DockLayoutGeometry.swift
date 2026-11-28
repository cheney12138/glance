import CoreGraphics

/// Dock 条带、预览托盘与过渡桥保活区的纯几何计算（AppKit 全局坐标：左下原点，Y 向上）。
public enum DockLayoutGeometry {
    /// 默认贴屏边呼吸距（对齐 macOS 原生 Dock 紧贴屏边的 4pt 距离，避免常驻时悬在半空漏出大条桌面缝）
    public static let defaultEdgeMargin: CGFloat = 4

    /// 计算 Dock 条带玻璃内容矩形（贴对应屏幕边、另一轴居中，并留边缘呼吸距 edgeMargin）
    public static func stripContentRect(
        contentSize: CGSize,
        position: DockPosition,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edgeMargin: CGFloat = defaultEdgeMargin
    ) -> CGRect {
        let margin = max(0, edgeMargin)
        let axisEndPad = max(margin, 12)
        switch position {
        case .bottom:
            let x = clampedOrigin(
                center: visibleFrame.midX,
                length: contentSize.width,
                minEdge: visibleFrame.minX,
                maxEdge: visibleFrame.maxX,
                pad: axisEndPad
            )
            let y = screenFrame.minY + margin
            return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)

        case .left:
            let x = screenFrame.minX + margin
            let y = clampedOrigin(
                center: visibleFrame.midY,
                length: contentSize.height,
                minEdge: visibleFrame.minY,
                maxEdge: visibleFrame.maxY,
                pad: axisEndPad
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)

        case .right:
            let x = screenFrame.maxX - margin - contentSize.width
            let y = clampedOrigin(
                center: visibleFrame.midY,
                length: contentSize.height,
                minEdge: visibleFrame.minY,
                maxEdge: visibleFrame.maxY,
                pad: axisEndPad
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
        }
    }

    /// 计算托盘玻璃内容矩形（按 bottom→上 / left→右 / right→左 展开，中心对齐 anchorPoint 并夹紧在屏内）
    public static func trayContentRect(
        traySize: CGSize,
        stripRect: CGRect,
        anchorCenterAlongAxis: CGFloat,
        position: DockPosition,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat = 14,
        screenEdgePad: CGFloat = 12
    ) -> CGRect {
        let pad = max(0, screenEdgePad)
        let _ = screenFrame // 保留契约参数；托盘统一夹紧在 visibleFrame 内以避开菜单栏

        switch position {
        case .bottom:
            let x = clampedOrigin(
                center: anchorCenterAlongAxis,
                length: traySize.width,
                minEdge: visibleFrame.minX,
                maxEdge: visibleFrame.maxX,
                pad: pad
            )
            let rawY = stripRect.maxY + gap
            let y = clampedValue(
                rawY,
                length: traySize.height,
                minEdge: visibleFrame.minY,
                maxEdge: visibleFrame.maxY,
                pad: pad
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: traySize)

        case .left:
            let rawX = stripRect.maxX + gap
            let x = clampedValue(
                rawX,
                length: traySize.width,
                minEdge: visibleFrame.minX,
                maxEdge: visibleFrame.maxX,
                pad: pad
            )
            let y = clampedOrigin(
                center: anchorCenterAlongAxis,
                length: traySize.height,
                minEdge: visibleFrame.minY,
                maxEdge: visibleFrame.maxY,
                pad: pad
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: traySize)

        case .right:
            let rawX = stripRect.minX - gap - traySize.width
            let x = clampedValue(
                rawX,
                length: traySize.width,
                minEdge: visibleFrame.minX,
                maxEdge: visibleFrame.maxX,
                pad: pad
            )
            let y = clampedOrigin(
                center: anchorCenterAlongAxis,
                length: traySize.height,
                minEdge: visibleFrame.minY,
                maxEdge: visibleFrame.maxY,
                pad: pad
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: traySize)
        }
    }

    /// 判断点是否处于「条带 ∪ 托盘 ∪ 二者之间过渡桥」的保活区内（防止鼠标从条带滑向托盘途中误判离开）
    public static func isPointInInteractiveRegion(
        point: CGPoint,
        stripRect: CGRect,
        trayRect: CGRect?,
        position: DockPosition,
        slop: CGFloat = 14
    ) -> Bool {
        let s = max(0, slop)
        if stripRect.insetBy(dx: -s, dy: -s).contains(point) {
            return true
        }
        guard let tray = trayRect else {
            return false
        }
        if tray.insetBy(dx: -s, dy: -s).contains(point) {
            return true
        }
        let bridge = transitionBridgeRect(stripRect: stripRect, trayRect: tray, position: position)
        return bridge.insetBy(dx: -s, dy: -s).contains(point)
    }

    /// 判断点是否落在「以 `anchor` 为顶点、以托盘面向条带那条边（两端各外扩 `edgeSlop`）为底边」的三角形内。
    ///
    /// 为什么需要它（Safe-Triangle 防误串）：预览托盘贴着当前悬停图标居中展开后，用户从条带一侧斜向
    /// 移往托盘，途中必然要压过隔壁图标的命中格 ⇒ 60Hz hover 轮询会当场切格、托盘跳走，手感像「误串/发木」。
    /// 只有**同时**满足下列两条，才认定为「正在朝这个托盘斜向推进」，可由调用方短暂宽限不切图标：
    ///   ① 比 anchor 更靠近托盘那条边（法向推进 > 0.5pt）—— 纯粹沿条带横扫、或远离托盘时恒为 false
    ///     ⇒ 调用方仍保持 0ms 瞬时切图标，绝不发木；
    ///   ② 落在上述三角形内（含边界，叉积同号判定）。
    /// 退化三角形（三点共线，面积为 0）一律视为不命中。
    public static func isPointInTrayApproachTriangle(
        point: CGPoint,
        anchor: CGPoint,
        trayRect: CGRect,
        position: DockPosition,
        edgeSlop: CGFloat = 14
    ) -> Bool {
        let slop = max(0, edgeSlop)
        let edgeStart: CGPoint
        let edgeEnd: CGPoint
        // 法向推进量：> 0 表示沿「条带 → 托盘」方向前进（AppKit Y 向上）
        let advancement: CGFloat
        switch position {
        case .bottom:
            edgeStart = CGPoint(x: trayRect.minX - slop, y: trayRect.minY)
            edgeEnd = CGPoint(x: trayRect.maxX + slop, y: trayRect.minY)
            advancement = point.y - anchor.y

        case .left:
            edgeStart = CGPoint(x: trayRect.minX, y: trayRect.minY - slop)
            edgeEnd = CGPoint(x: trayRect.minX, y: trayRect.maxY + slop)
            advancement = point.x - anchor.x

        case .right:
            edgeStart = CGPoint(x: trayRect.maxX, y: trayRect.minY - slop)
            edgeEnd = CGPoint(x: trayRect.maxX, y: trayRect.maxY + slop)
            advancement = anchor.x - point.x
        }

        guard advancement > 0.5 else { return false }
        return isPoint(point, inside: anchor, edgeStart, edgeEnd)
    }

    // MARK: - Helpers

    /// 叉积同号（含边界）判定 `p` 是否落在三角形 (v0, v1, v2) 内；退化三角形返回 false。
    private static func isPoint(
        _ p: CGPoint,
        inside v0: CGPoint,
        _ v1: CGPoint,
        _ v2: CGPoint
    ) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let epsilon: CGFloat = 0.0001
        let area = cross(v0, v1, v2)
        guard abs(area) > epsilon else { return false }
        let sign: CGFloat = area > 0 ? 1 : -1
        // 三条边的叉积同号 ⇒ 点在三角形内；>= -epsilon 让边界点也算命中
        return sign * cross(v0, v1, p) >= -epsilon
            && sign * cross(v1, v2, p) >= -epsilon
            && sign * cross(v2, v0, p) >= -epsilon
    }

    private static func transitionBridgeRect(
        stripRect: CGRect,
        trayRect: CGRect,
        position: DockPosition
    ) -> CGRect {
        switch position {
        case .bottom:
            let minX = min(stripRect.minX, trayRect.minX)
            let maxX = max(stripRect.maxX, trayRect.maxX)
            let minY = min(stripRect.maxY, trayRect.minY)
            let maxY = max(stripRect.maxY, trayRect.minY)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .left:
            let minX = min(stripRect.maxX, trayRect.minX)
            let maxX = max(stripRect.maxX, trayRect.minX)
            let minY = min(stripRect.minY, trayRect.minY)
            let maxY = max(stripRect.maxY, trayRect.maxY)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .right:
            let minX = min(trayRect.maxX, stripRect.minX)
            let maxX = max(trayRect.maxX, stripRect.minX)
            let minY = min(stripRect.minY, trayRect.minY)
            let maxY = max(stripRect.maxY, trayRect.maxY)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private static func clampedOrigin(
        center: CGFloat,
        length: CGFloat,
        minEdge: CGFloat,
        maxEdge: CGFloat,
        pad: CGFloat
    ) -> CGFloat {
        clampedValue(center - length / 2, length: length, minEdge: minEdge, maxEdge: maxEdge, pad: pad)
    }

    private static func clampedValue(
        _ rawOrigin: CGFloat,
        length: CGFloat,
        minEdge: CGFloat,
        maxEdge: CGFloat,
        pad: CGFloat
    ) -> CGFloat {
        let paddedMin = minEdge + pad
        let paddedMax = maxEdge - pad
        if length <= paddedMax - paddedMin {
            return min(max(rawOrigin, paddedMin), paddedMax - length)
        }
        let fullSpan = maxEdge - minEdge
        if length <= fullSpan {
            return min(max(rawOrigin, minEdge), maxEdge - length)
        }
        return minEdge + (fullSpan - length) / 2
    }
}
