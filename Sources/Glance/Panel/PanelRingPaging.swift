import AppKit
import GlanceCore
import SwiftUI

// ⚠️ 2026-10-16 重构清单第 9 条:从 PanelController.swift 平移而来 ✓
//   **纯代码搬移,零行为变化** ✓ —— 同类 extension,同层(Panel ✓)架构检查不变 ✓
//   存储属性已回迁主类(extensions 不能有存储属性 ✗)✓

extension PanelController {
    // MARK: - T91 换环(↓ / ↑)

    // MARK: - T91 换环(↓ / ↑)
    
    /// ↓:环里换成"未启动的 App"。
    ///
    /// 为什么复用 `entrySelected`:它本来就表达"这一局在看未启动的 App"(托盘切启动行、
    /// 确认即启动、`` ` `` 在启动项里循环 —— 下游全挂在它身上)。换的只是**画在哪**:
    /// 旧形态画在环尾那枚记号 + 托盘里;新形态把**环本身**换掉(用户:完全覆盖掉)。
    ///
    /// `launchIndex` 故意留 nil:只按一下 ↓ 就松手 = 没有可生效之物 ⇒ 什么都不启动,
    /// 面板照常散场(与旧的"只选中入口槽"同一个语义)。
    /// **触发层专用入口**(四指轻点)。
    ///
    /// 病例(2026-09-17,用户实报「四指没生效」——日志给出了铁证):
    /// ```
    /// [ 85309ms] [T91] 换环 → 未启动的 App(共 2 个)      ← 触发了
    /// [ 85354ms] [T6] 落点顺序 [Ghostty | 大象 | …]      ← 45ms 后新一局开始,把它抹掉
    /// ```
    /// 根因:`onFireFour` 在 `beginPinnedSession()` 之后**立刻**调 `enterLaunchRing()`,
    /// 而那一刻 `launchables` 里装的还是**上一局留下的名单**(非空)⇒ 守卫放行、当场换环;
    /// 紧接着新一局的 `finishBegin` 才跑,一句 `entrySelected = false` 把环换了回去。
    ///
    /// 所以触发层的入口**只记意图**:等本局的名单装好(finishBegin)再兑现 ——
    /// 与"四指那一发比枚举先到"是同一个道理,那条路本来就存在(pendingLaunchRing)。
    func requestLaunchRing() {
        guard !entrySelected else { return }
        pendingLaunchRing = true
        pendingLaunchAt = CFAbsoluteTimeGetCurrent()
        trace("[T91] 换环意图已记下(触发层:等本局的名单)")
    }

    func enterLaunchRing() {
        guard !entrySelected else { return }
        // ★ 病例(2026-09-17,用户实报「唤起的还是启动的环, 不是未启动的」):四指轻点那一发
        // 到得**比枚举早** —— `begin()` 把枚举丢进后台 Task(见那里的注释),名单是在
        // `finishBegin` 里才装上的。那时这里 isEmpty ⇒ 静默 return ⇒ 面板照常显示主环,
        // 用户读到的是"四指没生效"。症状像没接线,其实是**时序**。
        guard !launchables.isEmpty else {
            // ⚠️ 2026-09-17 修(用户实报「倒是展示了, 但是别给启动环同时唤起来了呀」)。
            // 这里**绝不能**再把意图置成 true —— 日志原样:
            //   兑现换环意图(等了 72ms,未启动的 App 共 0 个)
            //   换环意图已记下(名单还没到:枚举在后台跑)   ← 又武装一次 ⇒ 每局都会再来换环
            // 没有可换之物 ⇒ 意图到此为止:**消费掉**就走。
            pendingLaunchRing = false
            showHint("没有未启动的 App")
            trace("[T91] 没有未启动的 App ⇒ 不换环,芯片说一句就散场")
            return
        }
        // 名单连名字一起打:一句话分清"到底换没换、换成了谁"(用户报"还是唤起来了"时,
        // 只有"共 N 个"是分不清的 —— 这条让报告能对号入座)
        trace("[T91] 换环 → 未启动的 App(共 \(launchables.count) 个): \(launchables.map(\.name).joined(separator: " · "))")
        setSegment(true, travel: .forward, launchIndex: nil)   // ↓ = 向下一环(滑动方向:新内容从右进)
    }

    /// ↑:换回"已启动的 App 组"
    func leaveLaunchRing() {
        guard entrySelected else { return }
        trace("[T91] 换环 → 已启动的 App 组(共 \(groups.count) 个)")
        setSegment(false, travel: .direct, launchIndex: nil)
    }
    
    /// 尺寸与内容**同一拍**(实验台 ⑤)。
    ///
    /// 老病(T76 之前)是"内容先变、尺寸后到"—— 屏幕会闪一帧"内容在旧尺寸里"。所以顺序钉死:
    /// 算尺寸(此时 entrySelected 已改,`paddedSize()` 自然给出那一套)→ 同一拍 setFrame。
    /// 瞬时改尺寸(不补间):与"关闭要已经没了"同一条纪律,而且**不可能掉帧**。
    /// 将来若实测觉得"跳",再改 `animate: true`,并且**用 [帧] 探针量 P95 与长帧占比**,不靠感觉。
    ///
    /// 指针重定位:面板宽度变了 ⇒ 指针底下那块地砖可能已不是原来那一格,自己补判一次
    /// (SwiftUI 只在指针移动时发 hover)。
    /// 段切换的**行进方向**(PanelView 靠它选过渡的方向):
    /// `forward`/`backward` = Tab/⇧Tab 沿环走(内容横滑,行进感);`direct` = ↓/↑ 跳段(淡切)。
    enum SegmentTravel { case forward, backward, direct }

    /// 换环翻牌的**一半时长**(翻出去 / 翻进来各一半,合计 = `debug.ringFlipDurationMs` 默认 180ms ✓)
    private static var flipHalfSeconds: Double { max(0.03, Double(DebugFlags.ringFlipDurationMs) / 2000) }
    /// 整段时长(给"换环进行中"那个时间窗用 ✓)
    private static var flipSeconds: Double { 2 * flipHalfSeconds }

    private static func flipAnimation(_ full: Animation) -> Animation? {
        if DebugFlags.noSegmentAnim { return nil }        // 消元开关:关掉换环动效(当拍换)
        return MotionPolicy.animation(full, reduced: flipHalfSeconds)
    }

    /// **侧立那一拍**:换内容 + 换长度都放在这里(各只做一次 ✓)。
    ///
    /// 为什么必须挤在这一帧(两轮截图验过的两条硬约束):
    ///   ① 玻璃**不能转**(一转材质就掉 ✗);② 玻璃**不能逐帧 resize**(每帧改宽度同样掉材质 ✗)
    ///   ⇒ 唯一能改宽度的时刻:内容侧立(看不见)的那一帧 ✓ 长度差因此由"翻转中途顺手变短/变长"交代 ✓
    private func ringFlipSwitch(token: Int) {
        guard ringFlipToken == token, ringFlipMidDone != token else { return }
        ringFlipMidDone = token
        traceCost("翻牌换环那一帧") {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                entrySelected = ringFlipTarget
                // 反相:新环从**另一侧**翻进来(与旧 asymmetric transition 的方向一字不差 ✓)
                ringFlipAngle = ringFlipAngle > 0 ? -PanelMetrics.ringFlipLimit : PanelMetrics.ringFlipLimit
            }
            applyRingSwap(animated: false)      // 内容 + 宽度**同一拍**(实验台 ⑤)✓
        }
        trace("[翻牌] 换环那一帧 · 现在是\(entrySelected ? "未启动环" : "主环") · 玻璃宽 \(Int(contentSize().width))pt")
        withAnimation(Self.flipAnimation(.easeOut(duration: Self.flipHalfSeconds))) {
            ringFlipAngle = 0
        }
    }

    /// **翻牌还没落地就来新输入 ⇒ 先把这一发当拍收尾**,动作再照常执行 ✓
    ///   ① 不许吞输入(本仓纪律:"意图已被接受就必须执行" ✓);
    ///   ② 连按 ↓↑ 不会半路换错内容(收尾 + 随后开新一发;过期回调由 token 丢弃 ✓);
    ///   ③ 输入"先到"、画面"还没到"时,判定一律按**目标环**(按了 ↓ 就是想去未启动 ✓)
    func finishRingFlip() {
        guard ringFlipAngle != 0 else { return }
        ringFlipToken += 1
        ringFlipMidDone = ringFlipToken
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            entrySelected = ringFlipTarget
            ringWidthBlend = ringFlipTarget ? 1 : 0      // 长度当拍落到目标(与内容同一帧 ✓)
        }
        ringFlipAngle = 0
        applyRingSwap(animated: false)
    }

    /// 段切换的唯一入口。
    ///
    /// ★★ 2026-10-08 定版(**用户裁定 A**):**玻璃不参与翻转**。
    ///   硬约束:原生玻璃一旦被 3D 变换,材质就掉(变一块暗板,角度回 0 才长回来 ✗)——
    ///   SwiftUI 的 `.rotation3DEffect` 与"在 AppKit 层转整个窗口内容层"两种实现都验过,一样掉 ✗;
    ///   它由 WindowServer 按窗口几何合成,转出平面即失效 ✓
    ///   ⇒ "整条环翻过去"与"材质不掉"在这个材质上天然冲突 ⇒ 用户选 A:
    ///     翻的只有**环里的内容**(两块牌面同时演 ✓),玻璃只做**平滑变宽/变窄**,
    ///     两环长度差由玻璃自己交代 ✓ 材质全程完好 ✓
    ///   窗框仍然**一动不动**(一局的窗框按"两环更宽者"开 ✓)⇒ 没有双动画系统 ⇒ 不抖 ✓
    func setSegment(_ toLaunch: Bool, travel: SegmentTravel, launchIndex target: Int?) {
        segmentTravel = travel
        // 已经是那一环、也没有正翻着它 ⇒ 只更新段内选中,不翻牌 ✓
        if entrySelected == toLaunch, ringFlipTarget == toLaunch {
            if toLaunch, let t = target { launchIndex = t }
            return
        }
        ringFlipTarget = toLaunch
        if toLaunch, let t = target { launchIndex = t }    // 段内选中先记下(进段前不可见 ⇒ 无观感影响 ✓)
        ringFlipToken += 1
        let token = ringFlipToken
        // 托盘(窗口卡/启动行)在换环这一拍**当拍换** ⇒ 窗口窗开到整段翻完 ✓(见 isRingSwapInFlight)
        ringSwapUntil = CFAbsoluteTimeGetCurrent() + Self.flipSeconds + 0.2
        let sign: Double = (travel == .forward) ? 1 : -1   // ↓ 往上翻;↑/反向 ⇒ 反着翻 ✓
        trace("[翻牌] \(toLaunch ? "主环 → 未启动环" : "未启动环 → 主环") · 88°×2 · 每半 \(Int(Self.flipHalfSeconds * 1000))ms")
        // ① 环里那块容器翻出去(玻璃不动 ✓)
        withAnimation(Self.flipAnimation(.easeIn(duration: Self.flipHalfSeconds))) {
            ringFlipAngle = sign * PanelMetrics.ringFlipLimit
        }
        // ② 玻璃长度**整段平滑**过去(easeInOut 铺满翻转;用户在换环那一下看得出"顺手变短/变长" ✓)
        withAnimation(Self.flipAnimation(.easeInOut(duration: Self.flipSeconds))) {
            ringWidthBlend = toLaunch ? 1 : 0
        }
        // ② 侧立那一拍:换内容 + 换长度(看不见 ✓),再反相翻进来
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipHalfSeconds) { [weak self] in
            self?.ringFlipSwitch(token: token)
        }
    }

    private func applyRingSwap(animated: Bool = false) {
        // ★★ 铁律(用户 2026-09-17 明确):**不管在哪个环,面板一律相对当前屏幕居中** ——
        // 上下居中 + 左右居中。左缘**不许**钉偏移。
        //
        // 走错的弯路(记在这里,别再走):上一版为了"环不要右移"把左缘钉住了 —— 结果更糟:
        // ① 托盘是按面板 `midX` 定位的 ⇒ 面板一左偏,托盘跟着偏;
        // ② 屏幕上出现了"两套锚点"(面板看左缘、托盘看中线),对齐关系当场崩。
        // 环宽窄变化时的平移是**居中该有的样子**:向中线收缩,左右对称。
        //
        // 尺寸与内容同一拍(实验台 ⑤):算尺寸(此时 entrySelected 已改)→ 同一拍 setFrame。
        // 瞬时改尺寸(不补间):与"关闭要已经没了"同一条纪律,而且不可能掉帧。
        guard let panel else { updatePreview(); return }
        if let target = centerFrame(for: paddedSize()) {
            // ★★ 2026-09-22:这里原本是"AppKit 动窗框 + SwiftUI 动内容"**两个动画系统** ✗ ——
            //   双系统的相位差就是用户实报的"换环抖一下"。现在窗框**当拍**(而且它的尺寸本就是
            //   一局的不变量,见 `ringWindowWidth`)⇒ 只剩内容一个动画系统 ⇒ 抖从构造上不存在 ✓
            //   旧路留档,别再走:union 外框窗口(玻璃左锚定、从第一格向右长)/ 根部弹性 frame
            //   (Update Constraints 递归 FAULT,实机崩溃)。`animated` 形参只为调用点可读,窗框不补间 ✓
            _ = animated
            setFrameIfNeeded(panel, target)
        }
        resyncSelectionUnderPointer()
        updatePreview()
    }
    
    /// 启动行内 hover:只挪高亮(内容已在托盘里),不重排窗框
    /// 指针在启动行内的位置 → 格子下标。**由位置推导,不依赖 hover 事件**。
    ///
    /// 病例(2026-09-16 实机日志):hover 到网易云后再把指针移向微信,`[T6] 启动区 hover` 再也没有输出
    /// —— 事件根本没送达。这是本仓库记过的一类病(见 `resyncSelectionUnderPointer`):SwiftUI 的
    /// tracking area 在**视图于指针底下改变外观/重排**之后就哑了,不补发 hover。
    /// 当初那份补丁只覆盖了窗口卡,启动行是新代码、没继承到。
    ///
    /// `onContinuousHover` 不走 tracking area:指针只要在行内移动就持续回调**位置**,我们自己算格子,
    /// 因此不存在"事件丢失"。位置 → 下标是纯几何:x 按格距分列,y 按行高分行。
    func hoverLaunchAt(x: CGFloat, y: CGFloat, count: Int, cols: Int, rows: Int) {
        let pitch = PanelMetrics.pitch
        let rowH = PanelMetrics.icon + PanelMetrics.trayRowGap
        let c = max(0, min(cols - 1, Int(floor(x / pitch))))
        let r = max(0, min(max(rows - 1, 0), Int(floor(y / rowH))))
        let i = r * cols + c
        guard launchables.indices.contains(i) else { return }
        if !entrySelected { entrySelected = true }
        launchIndex = i
        trace("[T6] 启动区选中(位置推导): [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
    }

    func hoverLaunch(_ i: Int) {
        // hover 到启动行某一格,**本身就意味着**入口槽是选中的 —— 不能再要求 entrySelected 为真:
        // 指针从入口槽(面板)走到托盘是跨窗口的一段路,状态可能已被清掉,于是"鼠标再移动也选不中"
        // (用户实报)。这里直接把它补回来,而不是让 hover 去依赖一段可能丢失的记忆。
        guard hoverAllowedByGate(), launchables.indices.contains(i) else { return }
        // ★★ 2026-10-08 门口收口之二(同一病例):这个函数**只有托盘那一行**在调
        //   (环里的启动格走 `hoverApp` 的 entrySelected 分支 ✓),所以"指针真的在托盘的可见内容里"
        //   就是它的前提 ✓ —— 而托盘内容隐藏时 `previewContentRect()` 一律 nil ✓。
        //   病例:未启动环里托盘内容已隐藏(alpha 0),指针停在**面板之外**那扇隐藏托盘上,
        //   它的 tracking area 照样回调 `.onHover` ⇒ 这一发把 launchIndex 改掉了 ✗
        //   (真机日志:`[T6] 启动区 hover: [2/4] Pearcleaner`,而指针在面板之外 ✓)
        guard let tray = previewContentRect(), tray.contains(NSEvent.mouseLocation) else { return }
        entrySelected = true
        guard launchIndex != i else { return }
        trace("[T6] 启动区 hover: [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
        launchIndex = i
    }

    func hoverWindow(_ i: Int) {
        bumpIdle()
        guard i != winIndex else { return } // 同一格的重复 hover(指针每像素都发声)不进账
        // **到达**与**接受**分两行记:这一行证明"hover 事件到了",下一行证明"我们认了"。
        // 两行之间的时间差 = 我们这边的处理耗时;两行都晚 = 事件本身就投递晚了(窗口/层级/系统侧)
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] hover 到窗 [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)(闸:\(pointerMayTakeOver() ? "开" : "关"))")
        }
        guard hoverAllowedByGate() else { return }
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // ★ 悬停打点(量"含悬停那几拍")
        winIndex = i
        Haptics.fire(.hoverPreviewThumb)     // ★ 悬停触感:指针换到托盘里另一扇窗 ✓
        // ★ 2026-10-25:选中一变**立刻给这扇窗补一拍** —— 只拍缓存里没有的(onlyMissing)。
        //   账:live 首帧要 90-140ms,这期间卡上没有快照就只能挂图标兜底 ⇒
        //   「小图标 → 满卡」那一下 = 用户报的组内换窗跳变 ✗。补拍 ~20-40ms 就能填上。
        if WindowLayout.current == .rail, let g = currentGroup, g.windows.indices.contains(i) {
            Snapshotter.shared.precapture([g.windows[i]], maxAge: .infinity, onlyMissing: true)
        }
        if let g = currentGroup, g.windows.indices.contains(i) {
            trace("[T6] 窗口选中(指针): [\(i + 1)/\(g.windows.count)] \(g.appName) — \(g.windows[i].title)")
        }
    }

    /// **卡片行点击**(2026-09-19):行内任何位置都归属最近的一张卡(含卡片之间的空隙)。
    /// `localX` = 行坐标系横向位置(行原点 = 首卡左缘,宽度口径与 resync 完全同源)。
    /// 曾经行内空隙是命中空洞,点击穿透托盘落到长条上,什么都不发生
    /// (用户实报「多窗口 App 的第二张卡要点两遍」)。
    func cardTapped(localX: CGFloat) {
        guard let g = currentGroup, !g.windows.isEmpty else { return }
        var cum: CGFloat = 0
        var hit: Int?
        let sizes = Self.cardSizes(g.windows)
        for i in g.windows.indices {
            let cw = sizes[i].width                     // 卡有多宽就命中多宽(与视图同源)
            if localX < cum + cw { hit = i; break }
            cum += cw + PanelMetrics.thumbGap
        }
        guard let i = hit ?? g.windows.indices.last else { return }   // 行尾空隙 = 归最后一张
        bumpIdle()
        if winIndex != i {
            trace("[T6] 卡片点击(行级): [\(i + 1)/\(g.windows.count)] \(g.windows[i].title)")
            winIndex = i
        }
        confirmSelection()
    }

}
