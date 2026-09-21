import CoreGraphics

/// ★ 布局数学的**输入参数快照**（纯值）。
///
/// 为什么要有这一层：这些量本来全是 `PanelMetrics` 里的静态计算属性 ——
/// 于是"卡片怎么定尺寸""几行几列""托盘多大"这些**纯算式**只能活在 App 里，
/// 想测就得先起 App、先有屏幕、先有窗口，等于测不了 ✗（2026-09-21 摸底：这些逻辑
/// 全在 2702 行的 `PanelController` 里，**零测试** ✗）。
///
/// 拆法：算式进 `GlanceCore`（本文件与同目录几个 `enum`），
/// 而"当前这一局的倍率/上限"由 App 侧在**调用前**打包成一个 `CardMetrics` 传进来。
/// 这样算式就是可枚举、可复现的纯函数；App 只负责"喂参数"。
public struct CardMetrics: Equatable, Sendable {
    /// 卡高上限（`PanelMetrics.shotH`），同时是"卡宽上限 = 高 × 比例"里的那个高
    public var shotH: CGFloat
    /// 卡宽下/上限（`PanelMetrics.thumbMinW` / `thumbMaxW`）
    public var thumbMinW: CGFloat
    public var thumbMaxW: CGFloat
    /// 卡间距、托盘内边距（横/上/下）、行距
    public var thumbGap: CGFloat
    public var trayPadX: CGFloat
    public var trayPadTop: CGFloat
    public var trayPadBottom: CGFloat
    public var trayRowGap: CGFloat

    public init(shotH: CGFloat, thumbMinW: CGFloat, thumbMaxW: CGFloat,
                thumbGap: CGFloat, trayPadX: CGFloat,
                trayPadTop: CGFloat, trayPadBottom: CGFloat, trayRowGap: CGFloat) {
        self.shotH = shotH
        self.thumbMinW = thumbMinW
        self.thumbMaxW = thumbMaxW
        self.thumbGap = thumbGap
        self.trayPadX = trayPadX
        self.trayPadTop = trayPadTop
        self.trayPadBottom = trayPadBottom
        self.trayRowGap = trayRowGap
    }
}

/// 卡片尺寸：**唯一来源** = `min(真实窗口尺寸, 设计上限)`。
///
/// 用户口径（2026-09-21，连着三张截图讲清楚）：
///   · IDEA 那种**大**窗口 ⇒ 卡钉在上限（"限制死了"）不许跟着变大；
///   · Sublime 那种**被缩小过**的窗口 ⇒ 卡跟着真窗缩（"跟真实窗口一样的形状，是 ok 的"）
///     ⇒ 渲染 1:1 ⇒ 既不放大也不裁；
///   · 大则又回到上限管着。
/// 推论：一行里的卡**可以大小不一**，因此行高/内容高/命中判定都必须按**每张卡的实际高度**算。
public enum CardSizing {
    /// 卡宽上限 = 高 × 窗口比例，再夹上下限。
    /// `122` 是 `shotH` 的**基准值**（同源，别处不许再写这个数）。
    public static func capWidth(aspect: CGFloat, _ m: CardMetrics) -> CGFloat {
        min(max(122 * max(aspect, 0.2), m.thumbMinW), m.thumbMaxW)
    }

    /// 只许缩小、不许放大。真窗尺寸不合法（≤1pt：自绘窗/枚举失败）时退回上限。
    ///
    /// 注意两个帽都从**调用方**传入（而不是在这里拿 `CardMetrics` 算）：
    /// 因为 `k()`（会话缩放）在原实现里是套在**夹限之后**的，若这里再算一次就会出现
    /// “先缩后夹”与“先夹后缩”两把尺子（数值会差一个 `k`）。传**已经缩过的**帽最安全。
    public static func size(real: CGSize, capWidth capW: CGFloat, capHeight capH: CGFloat) -> CGSize {
        guard real.width > 1, real.height > 1 else { return CGSize(width: capW, height: capH) }
        let s = min(1, capW / real.width, capH / real.height)
        return CGSize(width: (real.width * s).rounded(), height: (real.height * s).rounded())
    }

    /// 便捷：取帽再算。等价的写法是 `size(real:capWidth:capHeight:)`（帽已缩过时用那个）。
    public static func size(real: CGSize, aspect: CGFloat, _ m: CardMetrics, scale: CGFloat = 1) -> CGSize {
        size(real: real, capWidth: capWidth(aspect: aspect, m) * scale, capHeight: m.shotH * scale)
    }
}

/// 一行一行怎么排、托盘要多大。
///
/// 关键纪律（都是从事故里来的）：
///   · **尺寸账 / 排布 / 命中三处共用同一套数** —— 各算各的必然漂，上次漂的代价是"托盘出屏"；
///   · "放得下的**最少**行数"（不是一行塞满）：8 扇窗贪心会排 **7 + 1**，最少行数是 **4 + 4**；
///   · `+0.5` 是**容差**不是凑数：上限本来就是按"刚好放满"解出来的，纯浮点下会随机掉一格
///     （15 窗 / 2 行：8 列正好 1464.0pt，算出 7 列 ⇒ 行数 2 变 3 ⇒ 托盘竖向溢出）。
public enum TrayGrid {
    /// 该分布下最宽那行的宽度（含行内间隙，不含托盘内边）
    public static func maxRowWidth(_ widths: [CGFloat], rows: Int, cols: Int, gap: CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        for r in 0..<rows {
            let start = r * cols
            let end = min(start + cols, widths.count)
            guard start < end else { continue }
            let w = widths[start..<end].reduce(0, +) + CGFloat(end - start - 1) * gap
            widest = max(widest, w)
        }
        return widest
    }

    /// 每行的最大卡高（卡片大小不一 ⇒ 不能用"行数 × 常量"）
    public static func rowHeights(_ sizes: [CGSize], rows: Int, cols: Int) -> [CGFloat] {
        (0..<rows).map { r in
            let start = r * cols
            let end = min(start + cols, sizes.count)
            guard start < end else { return 0 }
            return sizes[start..<end].map(\.height).max() ?? 0
        }
    }

    /// 取“放得下的最少行数”。`widths` 是**该分布下每张卡占的宽**（按顺序，末行左对齐）。
    public static func fitRows(widths: [CGFloat], gap: CGFloat, padW: CGFloat, roomW: CGFloat, maxRows: Int) -> (rows: Int, cols: Int) {
        let n = widths.count
        guard n > 0 else { return (0, 1) }
        for r in 1...min(n, maxRows) {
            let c = (n + r - 1) / r
            if maxRowWidth(widths, rows: r, cols: c, gap: gap) + padW <= roomW + 0.5 {
                return (r, c)
            }
        }
        // 病理兜底：几十扇窗时行数顶穿上限 ⇒ 宁可宽度溢出（调用方按“内容居中 + 两端对称切”兜底）
        let r = min(n, maxRows)
        return (r, (n + r - 1) / r)
    }

    /// 等宽网格（启动环那种"格距恒定"的场景）的行列。
    public static func fitRows(count n: Int, cellPitch: CGFloat, padW: CGFloat, roomW: CGFloat, maxRows: Int) -> (rows: Int, cols: Int) {
        guard n > 0 else { return (0, 1) }
        for r in 1...min(n, maxRows) {
            let c = (n + r - 1) / r
            if CGFloat(c) * cellPitch + padW <= roomW + 0.5 { return (r, c) }
        }
        let r = min(n, maxRows)
        return (r, (n + r - 1) / r)
    }

    /// 托盘内容尺寸。宽度取最宽那行；高度 = 各行最大卡高之和 + 行距 + 上下边距。
    public static func contentSize(widths: [CGFloat], sizes: [CGSize], rows: Int, cols: Int, _ m: CardMetrics) -> CGSize {
        guard !widths.isEmpty else { return .zero }
        let rh = rowHeights(sizes, rows: rows, cols: cols)
        return CGSize(
            width: maxRowWidth(widths, rows: rows, cols: cols, gap: m.thumbGap) + m.trayPadX * 2,
            height: m.trayPadTop + rh.reduce(0, +)
                + max(CGFloat(max(rows, 1)) - 1, 0) * m.trayRowGap + m.trayPadBottom
        )
    }

    /// 内部用：（已删除“隐式间隙”的版本 —— 那种写法会把间隙放进可变全局，
    /// 正是本次重构要消灭的东西）

}

/// 环（App 图标圈）的几何：格距、格中心、命中索引、托底位移。
///
/// 纪律：这四个量必须**同源**。改前"格距"被手算 12 次 —— 谁少加一次 =
/// 肉眼几乎看不出、但**一直歪着**的错位（历史上"托底不跟图标对齐""hover 选错格"都是这一族）。
public enum RingGrid {
    /// 格距 = 图标边长 + 格间隙
    public static func pitch(icon: CGFloat, gap: CGFloat) -> CGFloat { icon + gap }

    /// 第 `appIndex` 个图标格的**中心 X**（长条**内容**坐标系）。
    /// 唯一来源：确认涟漪的圆心、指针高光要挖的洞、托盘横向锚点都取它。
    public static func iconCenterX(appIndex: Int, appCount: Int, contentWidth: CGFloat,
                                   icon: CGFloat, gap: CGFloat) -> CGFloat {
        let n = CGFloat(max(appCount, 1))
        let stripW = n * icon + max(n - 1, 0) * gap
        return (contentWidth - stripW) / 2 + CGFloat(max(appIndex, 0)) * (icon + gap) + icon / 2
    }

    /// 指针 x ⇒ 第几格（不含"热区内缩"的门禁，那只决定**要不要**选中，不决定**选中谁**）
    public static func index(atX x: CGFloat, icon: CGFloat, gap: CGFloat) -> Int {
        Int(x / (icon + gap))
    }

    /// 选中托底的位移：托底宽 = 图标宽，挂在内容左缘。
    /// 图标在格里居中，而"App 区"首尾各收回半个间隙 ⇒ 两者正好对齐（静态位置是准的）。
    public static func puckOffsetX(appIndex: Int, icon: CGFloat, gap: CGFloat) -> CGFloat {
        CGFloat(max(appIndex, 0)) * (icon + gap)
    }
}
