import AppKit
import GlanceCore
import SwiftUI

// ⚠️ 2026-10-16 重构清单第 9 条:从 PanelController.swift 平移而来 ✓
//   **纯代码搬移,零行为变化** ✓ —— 同类 extension,同层(Panel ✓)架构检查不变 ✓
//   存储属性已回迁主类(extensions 不能有存储属性 ✗)✓

extension PanelController {
    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    // MARK: - 选中移动(键盘与 hover 共写同一状态,谁后动谁说了算)

    /// 滚轮 / 双指滑动 = 面板里的「Tab」。事件由 **navTap** 转来(会话期才存在的那个 tap,
    /// 它把滚动吞掉,所以底下的 App 收不到),动作仍走 Tab 那条路(`handle(.next/.prev)`)。
    /// 节流间隔**由设置里的"速度(次/秒)"算出**:interval = 1 / speed。
    /// 滑杆线性映射的是**速度**而不是间隔 —— 否则慢端几乎不动(两者是倒数关系)。
    /// 默认 10 次/秒 = 原来的 0.10s,升级后手感不变。
    private var scrollInterval: TimeInterval {
        let speed = UserDefaults.standard.object(forKey: Keys.panelScrollSpeed) as? Double ?? 10
        return 1.0 / max(3, min(20, speed))
    }

    /// 两条细节照抄 LumaRing 实测经验:惯性滚动不算一次操作;节流(一次滑动会送几十个事件)。
    /// 吞事件的部分在 navTap —— 这里只管"要不要动选中"。
    func handleScrollEvent(_ e: NSEvent) {
        bumpIdle()
        guard panel?.isVisible == true else { return }   // 双保险:面板不在就什么都不做
        // 设置开关(默认开)。用 object(forKey:) 取,而不是 bool(forKey:) —— 后者的
        // "没写过"和"写成 false"是同一个值,默认值就没法表达(与 switch.advanceOnOpen 同一处理)。
        guard UserDefaults.standard.object(forKey: Keys.switchScrollMovesSelection) as? Bool ?? true else { return }
        guard e.momentumPhase == [] else { return }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let d = abs(dy) >= abs(dx) ? dy : dx
        guard abs(d) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollAt > scrollInterval else { return }
        lastScrollAt = now
        trace("[T6] 选中(滚轮/双指滑): dx=\(Int(dx)) dy=\(Int(dy)) → \(d < 0 ? "下一组" : "上一组")")
        handle(d < 0 ? .next : .prev)
    }

    func moveApp(_ delta: Int) {
        guard !groups.isEmpty else { return }
        // ★ 键盘换选中也要打"选中变更"点(2026-09-21 修):原来只有指针 hover 会打 ⇒
        //   用户实报的复现是**「tab 切到大象那一拍掉帧」**,而这条路径**从不打点** ✗
        //   ⇒ 我们前几轮量到的长帧全是指针那一路的,压根没量到用户报的那一下 ✗✗
        FrameProbe.lastHoverMark = CACurrentMediaTime()
        traceCost("键盘换选中") {
            // 模型 C(ADR-0013):**逻辑上只有一条环** —— 主环走完 `Tab` 自然进入未启动段,
            // 未启动段走完接回主环;`⇧Tab` 反向对称。两条旧裁定(2026-09-16「不经 Tab 到达」、
            // spec 落地清单 #4)已随入口槽的死一起翻案,全程见 ADR-0013。
            // 段切换 = entrySelected 翻转 + applyRingSwap(尺寸/内容同一拍,实验台 ⑤);
            // 段内移动不碰窗框(与主环同一条纪律)。
            let backward = delta < 0
            if entrySelected {
                let n = launchables.count
                guard n > 0 else {              // 局中名单清空(最后一个也启动完了):段没了
                    appIndex = min(appIndex, groups.count - 1); winIndex = 0
                    setSegment(false, travel: .backward, launchIndex: nil)  // ↑ = 向上一环(反向滑)
                    trace("[T91] 段切换: 未启动名单已空 → 主环 [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
                    return
                }
                // launchIndex == nil(↓/四指刚进段还没选)时,nil 的语义是"站在段门口":
                // 正向 Tab 从第一格进,反向 ⇧Tab 从最后一格进 —— 而不是从段尾绕回主环!
                // 病例(2026-09-19):↓ 进段后按 Tab 被 cur = n-1 的兜底直接推出段,
                // 白名单 App 用键盘永远选不中 ⇒「没办法启动」。
                let cur = launchIndex ?? (backward ? n : -1)
                let next = cur + delta
                if next < 0 {                   // 段头反向
                    if tabEntersLaunchSection { // 设置开着 ⇒ 跨回主环最后一格 ✓
                        appIndex = groups.count - 1; winIndex = 0
                        setSegment(false, travel: .backward, launchIndex: nil)
                        trace("[T91] 段切换(⇧Tab): 未启动 → 主环 [\(groups.count)/\(groups.count)] \(groups[appIndex].appName)")
                    } else {                    // ★ 设置关着 ⇒ 不跨段,在**段内绕回**末格(与主环绕回同一种手感 ✓)
                        launchIndex = n - 1
                        trace("[T6] 选中(键盘 Tab): 未启动 [\(n)/\(n)] \(launchables[n - 1].name)(段内绕回)")
                    }
                } else if next >= n {           // 段尾正向
                    if tabEntersLaunchSection { // 设置开着 ⇒ 跨回主环第一格(绕环不断)✓
                        appIndex = 0; winIndex = 0
                        setSegment(false, travel: .forward, launchIndex: nil)
                        trace("[T91] 段切换(Tab): 未启动 → 主环 [1/\(groups.count)] \(groups[appIndex].appName)")
                    } else {                    // ★ 设置关着 ⇒ 段内绕回首格 ✓
                        launchIndex = 0
                        trace("[T6] 选中(键盘 Tab): 未启动 [1/\(n)] \(launchables[0].name)(段内绕回)")
                    }
                } else {
                    launchIndex = next
                    trace("[T6] 选中(键盘 Tab): 未启动 [\(next + 1)/\(n)] \(launchables[next].name)")
                }
            // ★ 2026-09-22 修「回得来、去不了」:门禁要**对称** ——
            //   用户口径:设置关着时 Tab **两个方向都不该跨段**(进出口交给 ↑/↓ 与四指 ✓)。
            //   而当时只有这一边挂了门禁、另一边从来没挂 ⇒ 才出现"去不了、回得来" ✗
            } else if !backward, appIndex == groups.count - 1, launchSectionEnabled, tabEntersLaunchSection {
                setSegment(true, travel: .forward, launchIndex: 0)
                trace("[T91] 段切换(Tab): 主环 → 未启动(选中 [1/\(launchables.count)] \(launchables[0].name))")
            } else if backward, appIndex == 0, launchSectionEnabled, tabEntersLaunchSection {
                setSegment(true, travel: .backward, launchIndex: launchables.count - 1)
                trace("[T91] 段切换(⇧Tab): 主环 → 未启动(选中 [\(launchables.count)/\(launchables.count)] \(launchables[launchables.count - 1].name))")
            } else {
                winIndex = 0   // 先落:appIndex 的 didSet 会同步重建托盘(见那里的病例)
                appIndex = (appIndex + delta + groups.count) % groups.count
                // 不动窗框:面板尺寸只跟 App 数量有关,选中移动不改尺寸(旧病见 setFrameIfNeeded)
                trace("[T6] 选中(键盘 Tab): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)(共 \(groups[appIndex].windows.count) 窗)")
                traceCost("  ↳拍图") { refreshSnapshotForSelection() }
                traceCost("  ↳托盘更新") { updatePreview() }
            }
        }
    }

    /// 主线程耗时记账(GLANCE_TRACE=1)。与 FrameProbe 分工:这里量的是"同步阻塞了多久",
    /// 那里量的是"帧间隔有没有崩" —— 两者对上就是结论
    private static let traceOn = isTraceEnabled

    /// trace 灰度里的行也带毫秒时间戳(原来它用裸 print,复盘时对不上别的时间)
    func trace(_ line: String) {
        guard Self.traceOn else { return }
        glog(line)
    }

    /// 主线程耗时记账。**两道阈值,平时也开着**(2026-09-15 改,借 AltTab `MainThreadStall` 的口径):
    ///   · trace 全开(诊断中)→ 超过 **2ms** 就报,细到能做对照;
    ///   · 平时 → 超过 **16ms(一帧)** 才报 —— 那才是"用户看得见"的门槛。
    ///
    /// 为什么平时也要开:以前它是 trace 灰度的,于是**只有我在调的时候才有账**,用户平时卡了没记录;
    /// 更要命的是"关掉 trace 之后到底还卡不卡"这件事**测不出来**(量尺跟着一起关了)。
    /// 代价:每次调用两次取表(约几十纳秒),不超阈值不打印。
    /// 计时括号。**认父子关系**(2026-09-15 修):子账由父账自己汇总在一行里打出来。
    ///
    /// 为什么必须这样:上一版靠"日志里谁挨着谁"来配对父子 —— 而同一个标签(`指针换选中`)
    /// 在**三条路径**里都用了,于是解析时把 Tab 的子账配到了 hover 的外账上,得出"外层 12ms、
    /// 三笔子账加起来 0.2ms"这种自相矛盾的结论 ✗。现在子账挂在父账身上,顺序无关。
    private final class CostNode {
        let label: String
        let t0 = CFAbsoluteTimeGetCurrent()
        var children: [(String, Double)] = []
        init(_ label: String) { self.label = label }
    }
    nonisolated(unsafe) private static var costStack: [CostNode] = []   // 只在主线程用

    func traceCost(_ label: String, _ body: () -> Void) {
        let node = CostNode(label)
        Self.costStack.append(node)
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - node.t0) * 1000
        Self.costStack.removeLast()
        if let parent = Self.costStack.indices.last {
            Self.costStack[parent].children.append((label.trimmingCharacters(in: .whitespaces), ms))
        }
        let isSub = label.hasPrefix("  ↳")
        if isSub { guard isTraceEnabled, !node.children.isEmpty || ms > 2 else { return } }
        else { guard ms > (Self.traceOn ? 2.0 : 16.0) else { return } }
        // 子账**并进父账同一行** —— 一次选中只占一行日志,而不是四行
        let kids = node.children.isEmpty ? ""
            : "(" + node.children.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: " · ") + ")"
        glog(String(format: "[工] %@ 主线程 %.1fms%@", label.trimmingCharacters(in: .whitespaces), ms, kids))
    }


    /// ←/→ = **跳到当前段最左 / 最右的一格**(用户 2026-09-15 重新设计,2026-09-18 推广到两段)。
    /// 为什么改:原来的 ←/→ 是"在当前 App 的窗口间移动",而这正是 ` 的职责 —— 功能重复;
    /// 走组的职责在 Tab。把 ←/→ 换成"跳到两端",是最便宜的一条效率提升(H/M/L 的心智)。
    func jumpToGroupEdge(_ target: Int) {
        // ★ ←/→ 的语义对两段一视同仁(用户 2026-09-18:「左右的语义不要只服务启动环」):
        //   跳的就是**当前正在看的那一段**的两端 —— 主环里跳最左/最右 App,
        //   未启动段里跳行内最左/最右。曾经的实现让段内的 ←/→ 出段回主环,已经推翻。
        if entrySelected {
            // 段内跳:只挪高亮、不换窗框(与段内 Tab 同一条纪律)。
            //   ⚠️ 不能像旧版那样直接写 entrySelected = false 出段 —— 内容当帧换回主环、
            //   窗框还停在段的短尺寸上,整条环被挤在半截窗里(2026-09-18 用户实报)。
            let n = launchables.count
            guard n > 0 else { return }
            let targetIndex = target == 0 ? 0 : n - 1
            guard launchIndex != targetIndex else { return }   // 已在那一端 = 夹住,不环绕
            launchIndex = targetIndex
            trace("[T6] 选中(键盘 " + (target == 0 ? "←=最左" : "→=最右") + "): 未启动 [\(targetIndex + 1)/\(n)] \(launchables[targetIndex].name)")
            return
        }
        guard groups.indices.contains(target), target != appIndex else { return }   // 两端 = 夹住,不环绕
        launchIndex = nil
        appIndex = target
        winIndex = 0                       // 落到目标 App 的第一扇窗,可预测
        trace("[T6] 选中(键盘 " + (target == 0 ? "←=最左" : "→=最右") + "): [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
        // ★★ 2026-10-08 病例(用户实报「通过左右移动到头尾这种方式, 选中的 App **没有 live**、
        //   不会主动接入;指针 hover 选中之后 live 才正常」):
        //   真因:选中一变必须跟的**两笔**在这里漏了 ✗ —— `Tab`(moveApp)/指针(hoverApp)/
        //   换窗口(moveWindow)三条路都有 `refreshSnapshotForSelection()` + `updatePreview()`,
        //   **只有 ←/→ 这条路没有** ⇒ 静默图不换、`LivePreviewPool.sync` 不跑
        //   ⇒ 那一组窗的**流从来没起过**(hover 那一路会补上,所以"hover 一下就好了" ✓)
        //   ⇒ 补齐这两笔(与另外三条路同一个写法、同一本账 ✓ 以后加新的选中路径照抄这里 ✓)
        traceCost("  ↳拍图") { refreshSnapshotForSelection() }
        traceCost("  ↳托盘更新") { updatePreview() }
    }

    func moveWindow(_ delta: Int) {
        // 权责冻结(用户拍板):App 移动归 Tab 与指针,←→ 只管展开层的窗;
        // 组内 ≤1 窗时 ←→ 无语义,静默吞掉
        let n = expandedCount
        // 启动行有它自己的"窗"序列:` = 行内循环(与主环的 ` 同一个心智:在当前位置前后挪一格)。
        // 用户实报「未启动的app不能用`切换选中」—— 启动行的成员本来就是**它自己的内容**,
        // 拿"它不是窗"把它挡掉是把代码的分类当成了用户的分类。
        if entrySelected {
            let m = launchables.count
            // ⚠️ 不能写 m > 1:只剩一个待启动 App 时(用户实报),` 会被直接 return 掉,
            // launchIndex 永远停在 nil ⇒ 那一格**无法被选中**。循环需要 2 个以上,
            // 但"选中"只需要 1 个 —— 这两件事不是同一件。
            guard m > 0 else { return }
            if m == 1 { launchIndex = 0; trace("[T6] 启动行选中(`): [1/1] \(launchables[0].name)"); return }
            // launchIndex == nil(只在入口槽、还没进到行里)时,第一下 ` 落到第一格;
            // 否则按 delta 在行内循环,两个方向都取正模
            let cur = launchIndex
            let next = cur == nil ? 0 : (((cur! + delta) % m) + m) % m
            launchIndex = next
            trace("[T6] 启动行选中(`): [\(next + 1)/\(m)] \(launchables[next].name)")
            return
        }
        guard n > 1 else { return }
        // 补记账(2026-09-15):日志里出现过一局 `长帧 4(6%)`,全部落在连按 ←→ 的那 3 秒里 ——
        // 而这条路径一直没有括号,是个黑盒。和 `键盘换选中` 同一口径,方便直接比。
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // 同"键盘换选中":选中一变就打点
        traceCost("窗口选中") {
            winIndex = (winIndex + delta + n) % n
            // ★★ 2026-10-19(用户实报:「键盘切换时,窗口和芯片变成一个整体在动」):
            //   这里原本还多做两件事 —— `updatePreview()`(**重摆托盘窗口** setFrame + 重排 + 换流)
            //   和 `refreshSnapshotForSelection()`(重拍)。鼠标 hover 那条路(`hoverWindow`)
            //   **只改 winIndex**,什么都不重排 —— 而用户要的正是那条路的观感 ✓
            //   ⇒ 键盘换窗与指针换窗**收敛到同一条路径**:只改状态,让视图自己动 ✓
        }
        trace("[T6] 窗口选中(键盘 ←→): \(groups[appIndex].windows[winIndex].title)")
    }

    /// T11 选中项现拍:选中移到哪个组,就把那组窗重截一遍——触发瞬间的截图在
    /// 钉住浏览几秒后已是旧图。异步不阻塞导航;同 wid 后到覆盖先到,天然取新。
    /// 防抖:同一组 0.5s 内不重复拍(横扫面板时边缘组会被扫过多次)

    private func refreshSnapshotForSelection() {
        guard let g = currentGroup else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastRefreshAt[g.pid], now - last < 0.5 { return }
        lastRefreshAt[g.pid] = now
        // 拍图全程在后台(见 Snapshotter 头注):这里只递一批目标,不发任务、不等结果
        // **选中即重拍**(force):应用内部的画面变化系统不发事件,只有"被显示"这一刻能抓住它
        Snapshotter.shared.precapture(g.windows, force: true)
        // (这里不再另打一行账:与 Snapshotter 的 `[T5]` 重复,而 print 自己就吃主线程时间)
    }

    /// **谁后动听谁**的仲裁账本(2026-09-18 用户口径:「就看谁在活跃」):
    ///   · `lastKeyAt` = 键盘最近一次发言(唤起 + 每个导航动作);
    ///   · `lastPointerMoveAt` = 指针最近一次**真实位移**;
    ///   · `lastPointerSample` = 上一帧指针位(采位移用)。
    /// 指针可否接管 = 指针比键盘后动。曾经口径是"指针自面板出现起挪没挪过窝"
    /// (panelOpenPoint + 1pt 阈值),有两个结构性缺陷,都被实机咬到:
    ///   ① 阈值太脆,亚像素抖动就能把闸**永久**打开 —— 之后键盘连按 Tab,指针杵着
    ///      照样抢选中(实测:Tab 后 11ms 帧拍把选中抢回指针压着的格子);
    ///   ② 只有"开/关"两态,表达不了"指针动过、又停下、键盘接着操作"的交替 ——
    ///      键盘操作完,指针想接管还得靠"它恰好没在面板出现时压在玻璃上"这个运气。
    /// 位移阈值 2pt:手搭在鼠标上的传感器抖动远低于此,真实的"动一下"远高于此
    private static let pointerMoveThreshold: CGFloat = 2
    /// "hover 被闸掉"这行账每局只打一次(见 hoverAllowedByGate)

    /// 每帧采一次指针位移,返回当前位置。位移过门槛 = 指针"发言"了(拿到接管权)。
    /// 采样点:主环帧拍 + 托盘指针重定位 —— 两条帧拍路各 60Hz,足够密
    @discardableResult
    func samplePointer() -> CGPoint {
        let p = NSEvent.mouseLocation
        if let s = lastPointerSample,
           abs(p.x - s.x) > Self.pointerMoveThreshold || abs(p.y - s.y) > Self.pointerMoveThreshold {
            lastPointerMoveAt = CFAbsoluteTimeGetCurrent()
            if isTraceEnabled {
                glog(String(format: "[闸] 指针位移 → 发言(%.0f,%.0f)", p.x, p.y))
            }
        }
        lastPointerSample = p
        return p
    }

    /// 键盘发言:唤起与每个导航动作都算。键盘刚动过 ⇒ 指针此前的位移不再有优先权
    func noteKeyboardAction() {
        lastKeyAt = CFAbsoluteTimeGetCurrent()
    }

    /// 鼠标**点击**也是指针发言(点格选中/确认不走位移采样 —— 点击本身没有位移)
    func notePointerClick() {
        lastPointerMoveAt = CFAbsoluteTimeGetCurrent()
    }

    /// 指针此刻可否接管选中 = **指针比键盘后动**。
    /// 面板开在停着的指针下方:键盘(唤起)必然后动 ⇒ 闸关着,指针不许抢(⌘Tab 移得动);
    /// 指针一动 ⇒ 指针后动 ⇒ 当帧接管 ——「但凡鼠标动了,就必须要立马响应」
    func pointerMayTakeOver() -> Bool {
        lastPointerMoveAt >= lastKeyAt
    }

    /// 同一道闸,但**被闸掉时记一笔**(每局一次)。
    ///
    /// 2026-09-14 病例:用户报"多窗口 App 的卡片,指针移上去焦点不跟随、点不动,得等一会"。
    /// 那种描述有两种完全不同的病因,而日志里当时只有"没反应"——
    ///   · hover 事件**根本没到**(窗口/层级/事件投递问题);
    ///   · 事件到了但**被这道闸吃了**(面板恰好开在指针下方)。
    /// 有了这一行,下次一看就知道是哪一种,不用猜(本仓库的老规矩:先让它可观测,再改)。
    func hoverAllowedByGate() -> Bool {
        if pointerMayTakeOver() { return true }
        if !gateBlockedLogged {
            gateBlockedLogged = true
            trace("[T6] 指针 hover 被闸掉(键盘比指针后动 —— 指针停着,不许抢选中)")
        }
        return false
    }

    /// hover 从 SwiftUI 直接进来;与键盘共写 appIndex/winIndex,天然"谁后动听谁的"。
    /// `source` 区分来路(事件 / 帧拍)—— 两条路在这行账里长得一样就永远查不清"刚才谁选的"
    /// 指针是否落在第 i 格的 **hover 热区**(格子内缩后的中心区,见 PanelMetrics.hoverInset*)
    /// 几何与 iconStrip 同源:首格左缘 = 玻璃左 + rowPadX − iconGap/2,格宽 = icon + iconGap
    func pointerInRingHotZone(_ i: Int) -> Bool {
        guard let glass = panelContentRect() else { return false }
        let pitch = PanelMetrics.pitch
        let tileLeft = glass.minX + ringContentLeftInset + PanelMetrics.rowPadX - PanelMetrics.iconGap / 2 + CGFloat(i) * pitch
        let rect = CGRect(
            x: tileLeft + PanelMetrics.hoverInsetX,
            y: glass.minY + PanelMetrics.rowPadY + PanelMetrics.hoverInsetY,
            width: pitch - PanelMetrics.hoverInsetX * 2,
            height: PanelMetrics.icon - PanelMetrics.hoverInsetY * 2)
        return rect.contains(NSEvent.mouseLocation)
    }

    func hoverApp(_ i: Int, source: String = "指针 hover", strict: Bool = true) {
        DispatchQueue.main.async { [weak self] in self?.logRowAlignment("换组") }
        FrameProbe.lastHoverMark = CACurrentMediaTime()   // ★ 换 app 打点
        // ★ 热区内缩:指针只蹭到格子边缘 = "路过",不算选中(2026-09-19 用户裁定)。
        //   点按路径传 strict:false —— 点击目标仍是整格,精度要求不同
        if strict && !pointerInRingHotZone(i) { return }
        bumpIdle()
        // T91:换环后 strip 里装的是"未启动的 App" —— 同一格上的 hover 归 launchIndex,
        // 不能落到主环的 appIndex 上(那会把一套看不见的选中改掉)
        if entrySelected {
            guard hoverAllowedByGate(), launchables.indices.contains(i), i != launchIndex else { return }
            launchIndex = i
            Haptics.fire(.hoverAppRow)       // ★ 悬停触感(设置里可关;策略层已把"只保留 hover"写死 ✓)
            trace("[T91] 启动选中(\(source)): [\(i + 1)/\(launchables.count)] \(launchables[i].name)")
            return
        }
        // 选中没变 = 同块地砖上挪指针,免工——onHover 每像素都发声,不设闸就是现拍风暴
        // (实机现形:日志被系统 QUARANTINED 截流)
        // entrySelected 也要放行:指针从启动区挪回主环,等于选回主环
        guard hoverAllowedByGate(), groups.indices.contains(i), i != appIndex || entrySelected else { return }
        // ★ 悬停触感:指针**换到另一个 App 格**上时震一下(用户 2026-09-22 要求 ✓)
        //   放在这道闸之后 ⇒ 每像素发声的 onHover 不会变成震动风暴 ✓(同格重复不进账 ✓)
        Haptics.fire(.hoverAppRow)
        traceCost("指针换选中") {
            // App 层原来没有这行账(窗口层一直有),于是"指针选中"和"键盘 Tab"在日志里长得一样——
            // 查"指针到底有没有动"时只能猜。口径与窗口层拉齐:括号里写明来源
            trace("[T6] 选中(\(source)): [\(i + 1)/\(groups.count)] \(groups[i].appName)"
                  + "(共 \(groups[i].windows.count) 窗)")
            // 拆账(2026-09-15):`指针换选中` 中位 12ms × 123 次,是现在最大的主线程开销 ✗。
            // 第一轮只拆了"拍图 / 托盘更新",结果**两笔都没超过 2ms** —— 说明钱不在这两处 ✗,
            // 于是把仅剩的候选(两个 @Published 写入,会同步惊动整棵观察者)也单独记一笔。
            // ⚠️ 顺序要紧:`winIndex` 必须**先**落 —— `appIndex` 的 didSet 会同步重建托盘,
            //   那一刻若 winIndex 还是旧组的,整块卡会按"未选中"画一帧(闪一下)✗
            traceCost("  ↳写状态") { entrySelected = false; launchIndex = nil; winIndex = 0; appIndex = i }
            traceCost("  ↳拍图") { refreshSnapshotForSelection() }
            traceCost("  ↳托盘更新") { updatePreview() }
        }
    }

}
