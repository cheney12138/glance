import CoreGraphics
import Testing
@testable import GlanceCore

/// 布局数学的单测。**每条用例都对着一次真事故**（见各 test 的注释）——
/// 这些算式以前长在 2702 行的 `PanelController` 里，零测试；今天把它们钉住。
@Suite("布局数学（卡片尺寸 / 托盘排布 / 环几何）")
struct TrayAndCardLayoutTests {

    /// 一局的"尺子"（≈ 2026-09-21 真机：iconClearance=10 ⇒ 各项为缩放后的值）
    private let m = CardMetrics(shotH: 122, thumbMinW: 96, thumbMaxW: 264,
                                thumbGap: 12, trayPadX: 16,
                                trayPadTop: 14, trayPadBottom: 14, trayRowGap: 12)

    // MARK: 卡片尺寸 = min(真窗, 上限)

    @Test("大窗口 ⇒ 钉在上限（IDEA 那种）")
    func bigWindowClampsToCap() {
        // 1960×1260 的真窗：宽高都超上限 ⇒ 卡 = 上限
        let aspect = 1960.0 / 1260.0
        let s = CardSizing.size(real: CGSize(width: 1960, height: 1260), aspect: aspect, m)
        // 注意：`size` 会 **取整**（px 对齐），`capWidth` 不会 ⇒ 比的时候留 1pt 容差
        #expect(abs(s.width - CardSizing.capWidth(aspect: aspect, m)) <= 1)
        #expect(s.height == m.shotH)
        #expect(s.width <= m.thumbMaxW)
    }

    @Test("窗口本来就不大 ⇒ 卡与真窗一模一样（Sublime 那种“所见即真窗形状”，1:1 不缩放）")
    func smallWindowRendersOneToOne() {
        let real = CGSize(width: 200, height: 120)
        let s = CardSizing.size(real: real, aspect: real.width / real.height, m)
        #expect(s == real, "两个方向都在上限内 ⇒ 一个像素都不缩放")
    }

    @Test("宽而矮的窗口 ⇒ 由宽度上限接管（不是高度）")
    func wideShortWindowBindsOnWidth() {
        let real = CGSize(width: 900, height: 300)
        let s = CardSizing.size(real: real, aspect: real.width / real.height, m)
        #expect(s.width == m.thumbMaxW)          // 宽度钉死在上限
        #expect(s.height < m.shotH)              // 高度没到上限
        #expect(abs(s.width / s.height - real.width / real.height) < 0.02)  // 形状仍与真窗一致
    }

    @Test("真窗尺寸不合法（自绘窗/枚举失败）⇒ 退回上限，不许出现 0 或负数")
    func invalidWindowFallsBack() {
        for bad in [CGSize(width: 0, height: 0), CGSize(width: 1, height: 800), CGSize(width: -5, height: 100)] {
            let s = CardSizing.size(real: bad, aspect: 1.6, m)
            #expect(s.width > 0 && s.height > 0)
            #expect(s.height == m.shotH)
        }
    }

    @Test("极窄/极宽的窗口都被夹在上下限之间（防一行被撑爆或缩成纸条）")
    func extremeAspectsAreClamped() {
        #expect(CardSizing.capWidth(aspect: 0.05, m) == m.thumbMinW)   // 竖条
        #expect(CardSizing.capWidth(aspect: 12.0, m) == m.thumbMaxW)   // 横幅
        #expect(CardSizing.capWidth(aspect: 0, m) == m.thumbMinW)      // 除零保护
    }

    // MARK: 行排布

    @Test("8 扇窗取最少行数 ⇒ 4+4，不是贪心的 7+1")
    func eightWindowsBecomeFourPlusFour() {
        let widths = Array(repeating: CGFloat(200), count: 8)
        let (rows, cols) = TrayGrid.fitRows(widths: widths, gap: 12, padW: 20, roomW: 900, maxRows: 3)
        #expect(rows == 2)
        #expect(cols == 4)
    }

    @Test("★ 回归：15 窗 / 2 行、8 列正好放满 1464pt 时不许掉成 3 行（浮点容差 0.5）")
    func exactFitDoesNotJitterToOneMoreRow() {
        // 8 列 × 172 + 7 × 12 = 1460 ⇒ 加 padW 4 = 1464，与可用宽**恰好相等**
        let widths = Array(repeating: CGFloat(172), count: 15)
        let padW: CGFloat = 4
        let roomW: CGFloat = 8 * 172 + 7 * 12 + padW
        let (rows, cols) = TrayGrid.fitRows(widths: widths, gap: 12, padW: padW, roomW: roomW, maxRows: 3)
        #expect(rows == 2, "恰好放得下时必须稳定停在 2 行")
        #expect(cols == 8)
        // 容差不能被滥用：窄 1pt 就应老实排成 3 行
        let (rows2, _) = TrayGrid.fitRows(widths: widths, gap: 12, padW: padW, roomW: roomW - 2, maxRows: 3)
        #expect(rows2 == 3)
    }

    @Test("卡片大小不一 ⇒ 行高按每行最大卡高算（不是行数 × 常量）")
    func rowHeightsUsePerRowMax() {
        let sizes = [CGSize(width: 200, height: 122), CGSize(width: 120, height: 90),
                     CGSize(width: 200, height: 60), CGSize(width: 180, height: 118)]
        let h = TrayGrid.rowHeights(sizes, rows: 2, cols: 2)
        #expect(h == [122, 118])
    }

    @Test("末行不满时，宽度只算实际张数（含间隙的 n-1 份）")
    func lastRowWidthCountsActualCells() {
        let widths: [CGFloat] = [200, 200, 200, 150, 150]
        // 3+2 排布：最宽行 = 3×200 + 2×12 = 624 ✓ 命中真事（末行两张 150）
        #expect(TrayGrid.maxRowWidth(widths, rows: 2, cols: 3, gap: 12) == 624)
        // 1 行 5 张：3×200 + 2×150 + 4×12 = 948 ⇒ 比 3+2 宽 ⇒ max 取它
        #expect(TrayGrid.maxRowWidth(widths, rows: 1, cols: 5, gap: 12) == 948)
    }

    @Test("托盘内容尺寸 = 最宽行 + 左右内边；高度 = 各行最大卡高 + 行距 + 上下内边")
    func contentSizeMatchesParts() {
        let sizes = [CGSize(width: 200, height: 122), CGSize(width: 200, height: 122),
                     CGSize(width: 120, height: 90)]
        let widths = sizes.map(\.width)
        let size = TrayGrid.contentSize(widths: widths, sizes: sizes, rows: 2, cols: 2, m)
        #expect(size.width == 2 * 200 + 12 + m.trayPadX * 2)
        #expect(size.height == m.trayPadTop + (122 + 90) + m.trayRowGap + m.trayPadBottom)
    }

    @Test("等宽网格（启动环）：格距恒定 ⇒ 列数 × 格距")
    func launchGridUsesPitch() {
        let (rows, cols) = TrayGrid.fitRows(count: 7, cellPitch: 106, padW: 20, roomW: 800, maxRows: 3)
        #expect(rows == 1 && cols == 7)          // 7×106 + 20 = 762 ≤ 800
        let (rows2, cols2) = TrayGrid.fitRows(count: 8, cellPitch: 106, padW: 20, roomW: 800, maxRows: 3)
        #expect(rows2 == 2 && cols2 == 4)        // 8×106 + 20 = 868 > 800 ⇒ 分两行
    }

    @Test("空输入返回零尺寸/零行，不崩")
    func emptyInputsAreSafe() {
        #expect(TrayGrid.contentSize(widths: [], sizes: [], rows: 0, cols: 1, m) == .zero)
        #expect(TrayGrid.fitRows(widths: [], gap: 12, padW: 0, roomW: 100, maxRows: 3) == (0, 1))
        #expect(TrayGrid.fitRows(count: 0, cellPitch: 100, padW: 0, roomW: 100, maxRows: 3) == (0, 1))
    }

    // MARK: 环几何（"托底/命中/涟漪/锚点"必须同源）

    @Test("格距 = 图标 + 间隙；图标中心 = 内容居中 + i×格距 + 半格")
    func ringIdentity() {
        let icon: CGFloat = 88, gap: CGFloat = 18
        #expect(RingGrid.pitch(icon: icon, gap: gap) == CGFloat(106))
        let w: CGFloat = 1000
        // 5 个图标：条宽 = 5×88 + 4×18 = 512 ⇒ 左起偏移 = (1000-512)/2 = 244
        #expect(RingGrid.iconCenterX(appIndex: 0, appCount: 5, contentWidth: w, icon: icon, gap: gap) == CGFloat(288))
        #expect(RingGrid.iconCenterX(appIndex: 4, appCount: 5, contentWidth: w, icon: icon, gap: gap) == CGFloat(712))
    }

    @Test("★ 回归：托底与图标必须对齐（同一格距、同一原点）")
    func puckAlignsWithIcon() {
        let icon: CGFloat = 88, gap: CGFloat = 18
        for i in 0..<8 {
            let puckLeft = RingGrid.puckOffsetX(appIndex: i, icon: icon, gap: gap)
            let cellLeft = CGFloat(i) * RingGrid.pitch(icon: icon, gap: gap)
            #expect(puckLeft == cellLeft, "第 \(i) 格：托底左缘必须等于格左缘")
        }
    }

    @Test("指针 x ⇒ 格索引（格内任意位置都归这一格）")
    func hitTestIndex() {
        let icon: CGFloat = 88, gap: CGFloat = 18
        #expect(RingGrid.index(atX: 0, icon: icon, gap: gap) == 0)
        #expect(RingGrid.index(atX: 105.9, icon: icon, gap: gap) == 0)
        #expect(RingGrid.index(atX: 106, icon: icon, gap: gap) == 1)
        #expect(RingGrid.index(atX: 106 * 4 + 1, icon: icon, gap: gap) == 4)
    }
}
