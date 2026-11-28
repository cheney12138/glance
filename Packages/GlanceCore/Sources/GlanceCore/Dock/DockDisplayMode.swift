import CoreGraphics
import Foundation

/// Glance Dock 的显示方式(ADR-0018 常驻模式,方案 A:悬浮常驻 + 全屏自动避让)。
///
/// 两种语义:
///   · `autoHide` —— 老行为:平时收进屏边,鼠标贴边才浮出 ✓
///   · `alwaysOn` —— 常驻:条带一直停在屏边,但**全屏应用时自动避让**(不能盖住用户的
///     全屏视频 / 演示 / 游戏 ✓)。避让不等于卸载:托盘/预览照常可用,只是条带收起来 ✓
///
/// 为什么做成"纯值 + 纯函数":这一层的所有判断(该不该显示条带、窗口是不是铺满了屏、
/// ⌘Tab 时要收哪些东西)都可以 100% 单测覆盖 —— 真正的窗口读写留在 App 层 ✓
public enum DockDisplayMode: String, CaseIterable, Codable, Sendable, Equatable {
    case autoHide
    case alwaysOn

    public var label: String { self == .autoHide ? "自动隐藏" : "常驻显示" }
}

/// 常驻模式的**全部判定逻辑**(纯函数,无 AppKit/SwiftUI,可 100% 单测)。
///
/// 为什么单独立一个命名空间:这些判断夹在"窗口该不该显示"和"什么时候收"之间,
/// 一旦写进 App 层的窗口控制器里,就再也测不到 —— 而它们恰恰是常驻模式最容易
/// 出错的地方(全屏避让漏判 ⇒ 盖住别人的全屏;⌘Tab 误收条带 ⇒ 常驻看起来"掉了")✓
public enum DockAlwaysOnPolicy {

    /// 条带是否应**常驻在屏边**。
    ///
    /// 只有两件事同时成立才常驻:`mode == .alwaysOn` **且** 当前屏不是全屏。
    /// 全屏 ⇒ 让位(方案 A 的核心约束)✓
    public static func shouldShowPersistentStrip(mode: DockDisplayMode, isScreenFullscreen: Bool) -> Bool {
        mode == .alwaysOn && !isScreenFullscreen
    }

    /// 某个窗口是否**铺满了整块屏**(即:它是一扇全屏窗)。
    ///
    /// 判据取"尺寸不小于屏幕(容差内)+ 中心点对齐(容差内)"两条同时成立 ——
    /// 只看尺寸会把"比屏幕还宽的普通窗"误判成全屏;只看位置又太松 ✓
    /// `tolerance` 默认 2pt:窗口尺寸与屏幕之间常有亚像素/圆角造成的 1px 级差异 ✓
    public static func coversScreen(windowFrame: CGRect, screenFrame: CGRect, tolerance: CGFloat = 2) -> Bool {
        windowFrame.width >= screenFrame.width - tolerance
            && windowFrame.height >= screenFrame.height - tolerance
            && abs(windowFrame.midX - screenFrame.midX) <= tolerance
            && abs(windowFrame.midY - screenFrame.midY) <= tolerance
    }

    /// 唤起 ⌘Tab / 三指切换器时,**条带是否该收起来**。
    ///
    /// 关键语义(方案 A 不可让渡的一条):**正常常驻态按下 ⌘Tab,条带不收起** ——
    /// 切 App 的人不该看到"我的程序坞突然消失了又回来";只收托盘(托盘由调用方负责)✓
    /// 两种情形才收条带:
    ///   · `autoHide`(老行为,没有常驻条带可言)✓
    ///   · 已经因全屏避让而收起(`isHiddenForFullscreen`):彻底让出屏幕 ✓
    public static func shouldDismissStripForSwitcher(mode: DockDisplayMode, isHiddenForFullscreen: Bool) -> Bool {
        mode == .autoHide || isHiddenForFullscreen
    }

    // MARK: - 多屏常驻：跨屏停边时长

    /// 常驻条带**停在别的屏上**时,本屏贴边所需的停留时长。
    ///
    /// 为什么不是 0.18s 那种贴边即开:多屏用户把指针划过另一块屏的下缘是**家常便饭**
    /// (拖窗口、切 Space、去另一屏点东西)⇒ 沿用自动隐藏的短 dwell 会让条带在
    /// 「用户根本没想叫它」的时候弹出来 ✗。3s 是「真的停在这儿了」与「路过」的分界 ✓
    public static let crossDisplaySwitchDwellSeconds: Double = 3.0

    /// 本屏贴边唤起时,实际该等多久。
    ///
    /// 条带常驻在**另一块屏**上 ⇒ 用跨屏的保守时长;条带就在本屏(或自动隐藏模式)⇒
    /// 用调用方配置的 `autoHideDwellSeconds`(负数一律夹到 0,防止上游算出负时长
    /// 让状态机把「立刻开」和「永远不开」搞混)✓
    public static func effectiveEdgeDwellDuration(
        isAlwaysOnHostedOnAnotherDisplay: Bool,
        autoHideDwellSeconds: Double
    ) -> Double {
        isAlwaysOnHostedOnAnotherDisplay
            ? crossDisplaySwitchDwellSeconds
            : max(0, autoHideDwellSeconds)
    }

    // MARK: - 常驻模式稳定顺序

    /// 把「上一轮的顺序」与「这一轮扫到的集合」合并成**不跳变**的稳定顺序。
    ///
    /// 常驻条带的图标位置每隔几秒就可能被刷新一次(激活 App / 换屏 / 启退通知都能触发)✓
    /// 如果每次都按新扫描结果重排,用户会看到图标自己挪位置 ✗ ⇒ 规则是「**老的相对顺序
    /// 尽量留着**,退出的移除,新开的追加到末尾」✓
    ///
    /// - 参数 `existingIDs`:上一轮展示的顺序(可能含重复,按第一次出现算)
    /// - 参数 `freshIDs`:这一轮扫到的集合(重复项只算一次)
    /// - 返回:`freshIDs ∩ existingIDs` 按 `existingIDs` 的相对顺序,其后接 `freshIDs`
    ///   里尚未出现的项(按 `freshIDs` 的顺序)。`existingIDs` 为空时即 `freshIDs` 去重后原样 ✓
    public static func mergeStableOrder<ID: Hashable>(existingIDs: [ID], freshIDs: [ID]) -> [ID] {
        var freshSeen = Set<ID>()
        var freshUnique: [ID] = []
        freshUnique.reserveCapacity(freshIDs.count)
        for id in freshIDs where freshSeen.insert(id).inserted {
            freshUnique.append(id)
        }

        var result: [ID] = []
        result.reserveCapacity(freshUnique.count)
        var resultSeen = Set<ID>()

        // ① 老项:仍在 fresh 里的,保持原有相对顺序(防重:同一个 id 只放一次)
        for id in existingIDs where freshSeen.contains(id) {
            if resultSeen.insert(id).inserted {
                result.append(id)
            }
        }

        // ② 新项:尚未落到结果里的,按 fresh 的顺序追加到末尾
        for id in freshUnique where resultSeen.insert(id).inserted {
            result.append(id)
        }

        return result
    }

    // MARK: - 单屏常驻：窗口边界避让几何

    /// 扣除常驻条带占位厚度之后,**这一屏真正可以放窗口**的矩形。
    ///
    /// 全程 Quartz 全局坐标系(原点在主屏左上角,Y 轴向下递增,与 AX / CGWindowList
    /// 同系)—— 因为调用方拿到的一律是 Quartz frame,换成 AppKit 坐标只会多一层
    /// 需要验证的翻转 ✗
    ///
    /// 两条纪律:① 结果**始终在 `visibleFrame` 内部**(不动菜单栏 / 不越屏);
    /// ② 宽度与高度**永不小于 0**(否则 CGRect 语义会变成 `.null` 之类的怪东西,
    /// 下游比较全跟着错)✓
    public static func usableFrame(
        visibleFrame: CGRect,
        screenFrame: CGRect,
        position: DockPosition,
        reservedThickness: CGFloat
    ) -> CGRect {
        let thickness = max(0, reservedThickness)

        switch position {
        case .bottom:
            let maxY = min(visibleFrame.maxY, screenFrame.maxY - thickness)
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: max(0, visibleFrame.width),
                height: max(0, maxY - visibleFrame.minY)
            )
        case .left:
            let minX = max(visibleFrame.minX, screenFrame.minX + thickness)
            return CGRect(
                x: minX,
                y: visibleFrame.minY,
                width: max(0, visibleFrame.maxX - minX),
                height: max(0, visibleFrame.height)
            )
        case .right:
            let maxX = min(visibleFrame.maxX, screenFrame.maxX - thickness)
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: max(0, maxX - visibleFrame.minX),
                height: max(0, visibleFrame.height)
            )
        }
    }

    /// 常驻屏上一扇窗口**要不要裁一下**以避开常驻条带。
    ///
    /// 返回 `nil` 的语义是「不要动它」—— 这是绝大多数窗口的答案 ✓ 返回非 `nil` 是一份
    /// 已经算好的 Quartz 目标 frame(调用方直接 `setFrame`,不要自己再夹一次)✓
    ///
    /// 误伤比漏判代价大得多:动错了用户会看见自己的窗口莫名缩了一截 ✗ ⇒ 三道教条:
    ///   ① **全屏窗绝对不许碰**(全屏是用户明确要「只看这一个」的姿态)✓
    ///   ② **轻度遮挡的小窗口也不许碰**(它只是恰好压在条带上,用户马上会挪走)✓
    ///   ③ 只命中「**铺满 / 贴边撑满并侵入保留带**」的那一类(双击标题栏铺满、Zoom、
    ///      Fill、左右分屏、上下分屏、最大化)—— 这些正是被条带啃掉一块的受害者 ✓
    public static func clampedFrameIfNeeded(
        windowFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        position: DockPosition,
        reservedThickness: CGFloat,
        tolerance: CGFloat = 2
    ) -> CGRect? {
        // ① 基本过滤:小窗口(提示框/浮层)与「没有常驻占位」两种情况一律不动
        guard windowFrame.width > 60, windowFrame.height > 60 else { return nil }
        guard reservedThickness > 0 else { return nil }

        // ② 归属当前屏:交集面积不足窗口一半 ⇒ 它是隔壁屏的窗口,不归这里管
        let winArea = windowFrame.width * windowFrame.height
        guard winArea > 0 else { return nil }
        let intersection = windowFrame.intersection(screenFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        let interArea = intersection.width * intersection.height
        guard interArea / winArea >= 0.5 else { return nil }

        // ③ 全屏免疫(1):尺寸与中心都对上整块屏 ⇒ 这是全屏窗
        if coversScreen(windowFrame: windowFrame, screenFrame: screenFrame, tolerance: tolerance) {
            return nil
        }

        // ③ 全屏免疫(2):顶边盖进菜单栏且高度接近整屏 —— 覆盖「绿色按钮进入的全屏」
        //    之外的另一种满屏窗(有些 App 的全屏窗比 screenFrame 略小,尺寸判据抓不住)✓
        let hasMenuBar = visibleFrame.minY > screenFrame.minY + 4
        if hasMenuBar,
           windowFrame.minY < visibleFrame.minY - tolerance,
           windowFrame.height >= screenFrame.height - 16 {
            return nil
        }

        // ④ 可用区太小(条带几乎吃掉半屏)⇒ 裁了也没意义,宁可不动
        let usable = usableFrame(
            visibleFrame: visibleFrame,
            screenFrame: screenFrame,
            position: position,
            reservedThickness: reservedThickness
        )
        guard usable.width >= 120, usable.height >= 120 else { return nil }

        // 边缘贴边阈值:「贴到屏幕上/下/左/右缘」算作铺满的一种
        let edgeSnapTolerance: CGFloat = 12

        var target: CGRect

        switch position {
        case .bottom:
            // 必须真的侵入底带(否则这扇窗跟条带没冲突)
            guard windowFrame.maxY > usable.maxY + tolerance else { return nil }
            // 且得是「铺满 / 贴底撑满」那一类
            let looksFullHeight = windowFrame.maxY >= visibleFrame.maxY - edgeSnapTolerance
                || windowFrame.height > usable.height + tolerance
                || windowFrame.minY <= visibleFrame.minY + edgeSnapTolerance
            guard looksFullHeight else { return nil }

            var y: CGFloat
            var h: CGFloat
            if windowFrame.height > usable.height || windowFrame.minY < usable.minY {
                y = max(usable.minY, min(windowFrame.minY, usable.maxY - 120))
                h = usable.maxY - y
            } else {
                y = windowFrame.minY
                h = usable.maxY - y
            }
            if h < 120 {
                // 上面按顶边算出来太矮(窗口顶边被别的屏/菜单栏挤住)⇒ 改成贴着可用区底边往上取
                y = max(usable.minY, usable.maxY - min(windowFrame.height, usable.height))
                h = usable.maxY - y
            }
            if h < 120 { return nil }
            target = CGRect(x: windowFrame.minX, y: y, width: windowFrame.width, height: h)

        case .left:
            guard windowFrame.minX < usable.minX - tolerance else { return nil }
            let looksFullWidth = windowFrame.minX <= visibleFrame.minX + edgeSnapTolerance
                || windowFrame.width > usable.width + tolerance
                || windowFrame.maxX >= visibleFrame.maxX - edgeSnapTolerance
            guard looksFullWidth else { return nil }

            let x = usable.minX
            var w = min(usable.maxX - x, max(0, windowFrame.maxX - x))
            if w < 120 {
                // 右边缘离条带太近 ⇒ 改为「保持宽度、整体右推」(用户分了左右屏时常见)
                w = min(windowFrame.width, usable.width)
            }
            if w < 120 { return nil }
            target = CGRect(x: x, y: windowFrame.minY, width: w, height: windowFrame.height)

        case .right:
            guard windowFrame.maxX > usable.maxX + tolerance else { return nil }
            let looksFullWidth = windowFrame.maxX >= visibleFrame.maxX - edgeSnapTolerance
                || windowFrame.width > usable.width + tolerance
                || windowFrame.minX <= visibleFrame.minX + edgeSnapTolerance
            guard looksFullWidth else { return nil }

            var x = max(usable.minX, windowFrame.minX)
            var w = usable.maxX - x
            if w < 120 {
                x = max(usable.minX, usable.maxX - min(windowFrame.width, usable.width))
                w = usable.maxX - x
            }
            if w < 120 { return nil }
            target = CGRect(x: x, y: windowFrame.minY, width: w, height: windowFrame.height)
        }

        // ⑤ 最后复核:四边差值全在 1pt 以内 ⇒ 实际没变,别白跑一次 setFrame
        let unchanged = abs(target.minX - windowFrame.minX) <= 1
            && abs(target.minY - windowFrame.minY) <= 1
            && abs(target.maxX - windowFrame.maxX) <= 1
            && abs(target.maxY - windowFrame.maxY) <= 1
        return unchanged ? nil : target
    }
}
