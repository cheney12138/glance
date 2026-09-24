import CoreGraphics

/// 把一扇窗**搬到另一块屏**时的落点计算（纯函数，可单测）。
///
/// 用户口径（2026-09-22）：「在当前落焦的 app 上使用快捷键之后，直接移动到另一块屏幕」——
/// 所以这是**脱面板的全局动作**，与选中的是哪一格无关 ✓
///
/// 三条口径：
///  1. **尺寸不变**（pt 原样搬 ✓）。按目标屏比例缩放读起来像"窗口变了" ✗
///  2. **位置**由 `Landing` 决定，默认 `.relative`（源屏上的相对位置等比映射 ✓，
///     与用鼠标把窗口拖到另一块屏时 macOS 的表现一致 ✓）。想改成"落在那块屏正中" ⇒ 改一行 ✓
///  3. **夹紧**：放得下就完全放进目标矩形 ✓；放不下（窗比那块屏还大）⇒ 保证**上沿与左沿**可见
///     （Quartz 坐标里 y 越小越靠上 ⇒ 保住 `minY = target.minY` ✓）—— 标题栏在那一侧 ✓
///
/// ⚠️ 坐标系：**不在这里换算**。调用方给的三个矩形必须在**同一套坐标**里
///   （本仓统一用 Quartz 全局坐标 —— `WindowRecord.bounds` 与 `WindowEnumerator.quartzFrame(of:)`
///   都是这一套 ✓）。换算属于基础设施层，塞进纯函数就是下一次错位的温床 ✗
public enum ScreenMovePolicy {

    public enum Landing: String, CaseIterable {
        /// 保持它在源屏上的**相对位置**（等比映射）—— 默认 ✓
        case relative
        /// 落在那块屏的**正中** ✓
        case center

        public var displayName: String {
            switch self {
            case .relative: return "按相对位置"
            case .center: return "落在屏幕正中"
            }
        }
    }

    /// **搬过去之后要不要改尺寸**（2026-09-22 用户口径:「移动过去之后能默认撑满整个屏幕吗, 不是全屏」）
    public enum Placement: String, CaseIterable {
        /// **撑满目标屏的可见区** —— 默认 ✓。注意它是"铺满",**不是 macOS 全屏**:
        /// 不进独立 Space、不播全屏动画、也不改窗口的"全屏"状态 ✓
        /// (全屏是系统概念,要走 `AXFullScreen`;用户明确说了「不是全屏」✗)
        case fillScreen
        /// 保留原来的 pt 尺寸,只挪位置 ✓（第一版的默认;留着,一行就能切回来）
        case keepSize

        public var displayName: String {
            switch self {
            case .fillScreen: return "撑满屏幕"
            case .keepSize: return "保持原尺寸"
            }
        }
    }

    public static let defaultLanding: Landing = .relative
    /// 默认**撑满** ✓（用户 2026-09-22 裁定）
    public static let defaultPlacement: Placement = .fillScreen

    /// 目标 frame：
    ///  · `.fillScreen` ⇒ **就是目标矩形本身**（可见区 ⇒ 自动避开菜单栏与 Dock ✓；位置与源尺寸无关 ✓）
    ///  · `.keepSize`   ⇒ 尺寸不变，位置按 `landing` 算，再夹紧 ✓
    public static func targetFrame(current: CGRect, source: CGRect, target: CGRect,
                                   placement: Placement = defaultPlacement,
                                   landing: Landing = defaultLanding) -> CGRect {
        if placement == .fillScreen { return target }
        let size = current.size
        var origin: CGPoint
        switch landing {
        case .relative:
            let rx = source.width > 0 ? (current.minX - source.minX) / source.width : 0
            let ry = source.height > 0 ? (current.minY - source.minY) / source.height : 0
            origin = CGPoint(x: target.minX + rx * target.width, y: target.minY + ry * target.height)
        case .center:
            origin = CGPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
        }
        return clamp(CGRect(origin: origin, size: size), into: target)
    }

    /// 夹进目标矩形（见文件头第 3 条 ✓）
    public static func clamp(_ rect: CGRect, into target: CGRect) -> CGRect {
        var r = rect
        if r.width <= target.width {
            r.origin.x = min(max(r.minX, target.minX), target.maxX - r.width)
        } else {
            r.origin.x = target.minX
        }
        if r.height <= target.height {
            r.origin.y = min(max(r.minY, target.minY), target.maxY - r.height)
        } else {
            r.origin.y = target.minY       // 太高 ⇒ 保住**上沿**（标题栏那一侧 ✓）
        }
        return r
    }

    /// **塞不下时长出来的那一截切哪边**(2026-09-24 用户实报后加)。
    ///
    /// 病例(用户原话):「窗口移动有点问题, datagrip 从外接移动到内建之后, 全屏的尺寸有点问题, 最右边跑出去了」
    /// 日志:
    /// ```text
    /// [T33] 搬窗: DataGrip … → 请求 -1728,33 1728x1084(含尺寸) · 实得 -1728,33 **1752x1084** ⚠️ 未达预期
    /// ```
    /// ⇒ 要的是内建屏可见区 **1728** 宽,而 DataGrip 只肯给 **1752**(= 这扇窗自己的**最小宽度**
    ///   比那块屏还宽 ✗)。左缘已钉在可见区左沿 ⇒ 多出来的 **24pt 必然跑出右沿** ✓
    /// ⇒ 24pt 是切定了,唯一能选的是**切哪边**。按本仓"锚定只能用固定边 / 或居中"的口径,给三档 ✓
    ///
    /// ⚠️ 这是个**视觉决定**,所以做成可试档位、默认 = 现状(切右边)✓ —— 由用户看过再定 ✓
    public enum OverflowRule: String, CaseIterable {
        /// **保住左沿**(现状 ✓ = 左边不切,右边超出去)。macOS 的红绿灯在左边 ⇒ 这一档不碰它们 ✓
        case keepLeft
        /// **居中**:两边各切一半(本例各 12pt)—— 读起来像"故意的" ✓
        case center
        /// **保住右沿**:左边切 24pt(可能碰到红绿灯 ✗,留给"右侧内容更重要"的人 ✓)
        case keepRight

        public var displayName: String {
            switch self {
            case .keepLeft:  return "保住左沿(右边超出)"
            case .center:    return "居中(两边各切一半)"
            case .keepRight: return "保住右沿(左边被切)"
            }
        }
    }

    /// **窗口自己的最小尺寸大于目标矩形时,按实测尺寸重新对位**(纯函数 ✓)
    ///
    /// 只在"实测尺寸 > 目标尺寸"时有意义(否则窗户完全放得下,原样即可 ✓)。
    /// 高度同理:太高就保住**上沿**(标题栏那一侧 ✓,与 `clamp` 同一条口径 ✓)。
    public static func anchorOversized(achieved: CGSize, in target: CGRect,
                                       rule: OverflowRule) -> CGPoint {
        var x = target.minX
        if achieved.width > target.width {
            switch rule {
            case .keepLeft:  x = target.minX
            case .center:    x = target.midX - achieved.width / 2
            case .keepRight: x = target.maxX - achieved.width
            }
        }
        let y = achieved.height > target.height ? target.minY : target.minY
        return CGPoint(x: x, y: y)
    }

    /// 下一块屏（多屏循环 ✓；只有一块屏 ⇒ nil ⇒ 调用方什么都不做 ✓）
    public static func nextScreenIndex(current: Int, count: Int) -> Int? {
        guard count > 1, current >= 0, current < count else { return nil }
        return (current + 1) % count
    }
}
