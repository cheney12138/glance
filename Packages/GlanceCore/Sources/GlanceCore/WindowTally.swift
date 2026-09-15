import CoreGraphics

/// 窗数记账法(tally)+ 自适应收窄 —— 长条上"图标下缘那行记号"的全部裁量都在这里。
///
/// ## 为什么不是"每扇窗一粒点"
/// 每窗一粒点在窗口多时会**顶出格子**:实测(scale 1.2,格子 105.6pt,点 4.8 / 间距 3.6)
/// 13 粒就正好铺满,20 粒 = 164pt = 格子的 1.56 倍 → 相邻两格的点连成一片。
/// 而且同色点只能**逐个默数**,看不出"几扇"。
///
/// ## 记账法 = 圆点记 1、短横记 5(罗马数字 I/V 的那一套,也是中文「正」字的写法)
/// 5 进制分组,人眼天生能一眼看住成组;任何窗数的记号数都是 `⌊n/5⌋ + n%5`,上界很低:
/// 20 扇 → 4 个横 = 29.8pt(**比逐窗的 164pt 窄 5.5 倍**),25 扇 → 5 个横 ≈ 53pt。
/// 24→25 会因为进位**突然变短**(61pt → 38pt),这是记账制天生的跳变(罗马数字 IV→V 同理),
/// 特意不改 —— 换来的是"任何数量都读得出来"。
///
/// ## 自适应是**兜底**,不是主力
/// 记账法本身在现实窗数(<40)下已经不会溢出,自适应只在极端数量下接管:
/// 先按可用宽度等比缩小(有下限),还放不下就从**尾部摘掉圆点**(保留短横 = "多得多")。
/// 口径:窗数不是必须被 100% 解析的信息(用户 2026-09-15 定),所以宁可靠近"示意"也不要溢出。
public enum WindowTally {

    /// 一个记号。`dash` = 5 扇,`dot` = 1 扇
    public enum Mark: Equatable, Sendable {
        case dash
        case dot
    }

    /// 记号尺寸(宽度相关的那几个,高度由视图按 dot 的比例给)
    public struct Sizes: Equatable, Sendable {
        public var dot: CGFloat
        public var dashWidth: CGFloat
        public var gap: CGFloat
        /// 1 = 原始尺寸;小于 1 = 自适应收窄过
        public var scale: CGFloat
    }

    public struct Metrics: Equatable, Sendable {
        public var dot: CGFloat
        public var dashWidth: CGFloat
        public var gap: CGFloat
        /// 收窄下限(再小就看不清了)。到下限还放不下才摘点
        public var minDot: CGFloat
        public var minGap: CGFloat

        public init(dot: CGFloat, dashWidth: CGFloat, gap: CGFloat, minDot: CGFloat, minGap: CGFloat) {
            self.dot = dot
            self.dashWidth = dashWidth
            self.gap = gap
            self.minDot = minDot
            self.minGap = minGap
        }

        /// 下限对应的最小倍率(两个下限里更严的那个)
        public var minScale: CGFloat { min(1, min(minDot / dot, minGap / gap)) }
    }

    /// 记号序列:**短横在前、圆点在后**(与罗马数字同读法:XII = X + II)
    public static func marks(for windows: Int) -> [Mark] {
        guard windows > 0 else { return [] }
        return Array(repeating: .dash, count: windows / 5) + Array(repeating: .dot, count: windows % 5)
    }

    /// 一行记号在某个倍率下的宽度
    public static func rowWidth(_ marks: [Mark], metrics: Metrics, scale: CGFloat) -> CGFloat {
        guard !marks.isEmpty else { return 0 }
        let marksWidth = marks.reduce(CGFloat.zero) { $0 + ($1 == .dash ? metrics.dashWidth : metrics.dot) }
        return marksWidth * scale + CGFloat(marks.count - 1) * metrics.gap * scale
    }

    /// 布局裁决:给定窗数与可用宽度,给出记号序列 + 尺寸。
    ///
    /// 三步:① 取记号序列 ② 等比缩到能放下(不低于下限) ③ 到下限还放不下就**从尾部摘圆点**
    /// (摘的永远是"个位数"那一头,留下的是"几组 5",语义仍然是"很多")。
    public static func layout(windows: Int, available: CGFloat,
                              metrics: Metrics) -> (marks: [Mark], sizes: Sizes) {
        var marks = marks(for: windows)
        let base = Sizes(dot: metrics.dot, dashWidth: metrics.dashWidth, gap: metrics.gap, scale: 1)
        guard !marks.isEmpty, available > 0 else { return ([], base) }

        // ② 等比收窄
        let natural = rowWidth(marks, metrics: metrics, scale: 1)
        let scale = min(1, max(metrics.minScale, available / natural))
        // ③ 到下限还放不下:从**尾部**摘记号 —— 短横排在前面、圆点在尾部,
        //    所以这里天然是"先摘个位数、再摘整组 5",语义仍然是"很多"
        //    (第一次写成了 `marks.last == .dot` 才摘:999 扇是 199 个横,光摘 4 个点根本放不下 ✗,
        //     单测当场把它揭出来了)
        while marks.count > 1, rowWidth(marks, metrics: metrics, scale: scale) > available {
            marks.removeLast()
        }
        // 只剩 1 个记号还放不下就只能那样了 —— 现实中到不了(N=100 也才 24 个记号)
        let sizes = Sizes(dot: metrics.dot * scale, dashWidth: metrics.dashWidth * scale,
                          gap: metrics.gap * scale, scale: scale)
        return (marks, sizes)
    }
}
