import CoreGraphics

/// 单块显示器的几何快照（AppKit 全局坐标系：左下原点，Y 向上）。
public struct DockDisplayRect: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// 单段有效的边缘触发传感条。
public struct DockSensorStrip: Equatable, Sendable {
    public let displayID: UInt32
    public let rect: CGRect

    public init(displayID: UInt32, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}

/// 多屏外边缘传感条几何计算（AppKit 全局坐标系：左下原点，Y 向上）。
public enum DockEdgeGeometry {
    private static let minimumSegmentLength: CGFloat = 1

    /// 计算所有屏的有效外边缘传感条（自动剔除与其他屏相接的共享边段 + 两端热角留白）
    public static func sensorStrips(
        displays: [DockDisplayRect],
        position: DockPosition,
        thickness: CGFloat = 2,
        cornerInset: CGFloat = 20,
        adjacencyTolerance: CGFloat = 2
    ) -> [DockSensorStrip] {
        guard thickness > 0 else { return [] }
        let inset = max(0, cornerInset)
        let tolerance = max(0, adjacencyTolerance)

        var strips: [DockSensorStrip] = []
        for (index, display) in displays.enumerated() {
            let frame = display.frame
            guard frame.width > 0, frame.height > 0 else { continue }

            let fullSpan: (CGFloat, CGFloat) = switch position {
            case .bottom: (frame.minX, frame.maxX)
            case .left, .right: (frame.minY, frame.maxY)
            }

            var exposedSegments: [(CGFloat, CGFloat)] = [fullSpan]
            for (otherIndex, other) in displays.enumerated() where otherIndex != index {
                guard let blocked = blockedSpan(
                    of: frame,
                    by: other.frame,
                    position: position,
                    tolerance: tolerance
                ) else { continue }
                exposedSegments = subtract(blocked, from: exposedSegments)
                if exposedSegments.isEmpty { break }
            }

            for (segStart, segEnd) in exposedSegments {
                let trimmedStart = segStart + inset
                let trimmedEnd = segEnd - inset
                guard trimmedEnd - trimmedStart >= minimumSegmentLength else { continue }

                let rect = stripRect(
                    frame: frame,
                    position: position,
                    spanStart: trimmedStart,
                    spanEnd: trimmedEnd,
                    thickness: thickness
                )
                strips.append(DockSensorStrip(displayID: display.id, rect: rect))
            }
        }
        return strips
    }

    /// 判断指针是否命中传感条（**闭区间 + 触发边外侧容差**）。
    ///
    /// 病例（2026-11-25 实机，右侧 Dock 贴边偶尔无反应并把原生 Dock 顶出）：
    /// CoreGraphics 的 `CGRect.contains(point)` 是左闭右开（`minX <= x < maxX`），
    /// `.left` / `.bottom` 的极值 `0.0` 落在闭端，而 `.right` 甩到最右侧时 `NSEvent.mouseLocation.x`
    /// 常精确等于 `screen.frame.maxX`（如 `1728.0`），被 `CGRect.contains` 直接判 `false` 漏检 ✗
    /// ⇒ 统一改用显式闭区间判据，并在触发边外侧留 `outerSlop = 1pt` 容差 ✓
    public static func contains(
        strip: DockSensorStrip,
        point: CGPoint,
        position: DockPosition,
        outerSlop: CGFloat = 1
    ) -> Bool {
        let r = strip.rect
        let slop = max(0, outerSlop)
        switch position {
        case .bottom:
            return point.x >= r.minX && point.x <= r.maxX
                && point.y >= r.minY - slop && point.y <= r.maxY
        case .left:
            return point.x >= r.minX - slop && point.x <= r.maxX
                && point.y >= r.minY && point.y <= r.maxY
        case .right:
            return point.x >= r.minX && point.x <= r.maxX + slop
                && point.y >= r.minY && point.y <= r.maxY
        }
    }

    private static func blockedSpan(
        of frame: CGRect,
        by other: CGRect,
        position: DockPosition,
        tolerance: CGFloat
    ) -> (CGFloat, CGFloat)? {
        guard other.width > 0, other.height > 0 else { return nil }
        switch position {
        case .bottom:
            guard other.minY < frame.minY, other.maxY >= frame.minY - tolerance else { return nil }
            return (other.minX, other.maxX)
        case .left:
            guard other.minX < frame.minX, other.maxX >= frame.minX - tolerance else { return nil }
            return (other.minY, other.maxY)
        case .right:
            guard other.maxX > frame.maxX, other.minX <= frame.maxX + tolerance else { return nil }
            return (other.minY, other.maxY)
        }
    }

    private static func subtract(
        _ blocked: (CGFloat, CGFloat),
        from segments: [(CGFloat, CGFloat)]
    ) -> [(CGFloat, CGFloat)] {
        let (bStart, bEnd) = blocked
        guard bEnd > bStart else { return segments }

        var result: [(CGFloat, CGFloat)] = []
        result.reserveCapacity(segments.count)
        for (s, e) in segments {
            if bEnd <= s || bStart >= e {
                result.append((s, e))
            } else {
                if bStart > s { result.append((s, bStart)) }
                if bEnd < e { result.append((bEnd, e)) }
            }
        }
        return result
    }

    private static func stripRect(
        frame: CGRect,
        position: DockPosition,
        spanStart: CGFloat,
        spanEnd: CGFloat,
        thickness: CGFloat
    ) -> CGRect {
        let length = spanEnd - spanStart
        switch position {
        case .bottom:
            let h = min(thickness, frame.height)
            return CGRect(x: spanStart, y: frame.minY, width: length, height: h)
        case .left:
            let w = min(thickness, frame.width)
            return CGRect(x: frame.minX, y: spanStart, width: w, height: length)
        case .right:
            let w = min(thickness, frame.width)
            return CGRect(x: frame.maxX - w, y: spanStart, width: w, height: length)
        }
    }
}
