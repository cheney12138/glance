import AppKit
import GlanceCore
import SwiftUI

// ⚠️ 2026-10-16 重构清单第 9 条:从 PanelController.swift 平移而来 ✓
//   **纯代码搬移,零行为变化** ✓ —— 同类 extension,同层(Panel ✓)架构检查不变 ✓
//   存储属性已回迁主类(extensions 不能有存储属性 ✗)✓

extension PanelController {
    // MARK: - 启动区(方案 E「入口槽」,T83)

    // MARK: 启动区(方案 E「入口槽」,T83;设计稿 design/启动区实验台.html,用户 2026-09-16 拍板)
    //
    // 未启动 App = Dock 常驻且没在跑的(「无窗应用」是**在跑没窗**,这是两个概念,别混)。
    // 它们不进主环 —— 主环是"切换的世界",一格 = 一个活跃 App;它们住在**入口槽后面的托盘里**:
    // 托盘本来就承载"选中格的内容"(活跃格 → 窗口卡,入口槽 → 启动图标行),零新增语法。
    // 常态下面板与今天一个像素不差(没有第二行);Tab 走到主环末尾再按一次 = 选中入口槽。
    /// Dock 常驻且未在跑的 App(每局 begin 时取一次,按 Dock 顺序)
    /// 入口槽被选中(托盘切到启动行)
    /// 启动行内的选中下标(nil = 入口槽选中但还没进到行内某格)
    /// T91:"换环到未启动"的意图(四指轻点专用)。
    /// 触发层那一发比后台枚举**先到**,名单还没装好 ⇒ 先记在这里,`finishBegin` 里兑现。
    /// 意图的**出生时刻**。给意图加寿命是结构性兜底:它只可能活在"触发层比枚举先到"的那一瞬。
    /// 病例(2026-09-17,用户实报「启动之后唤起了一次, 后面就变成启动环了」)—— 症状=意图活了不止一瞬。
    /// 与其猜是哪条路漏了清,不如让**过期本身就等于丢弃**:这样无论漏清在哪,幽灵都活不过 1.5s。
    static let pendingMaxAge: Double = 1.5

    /// **名单还没到、手已经松了**的那一次确认(2026-09-22 用户实报「快速 cmd tab 连续切换, 偶尔换不起来」)。
    ///
    /// 病例(日志铁证):
    /// ```text
    /// [2125575ms] [tap] flagsChanged kc=55 down=true  state=idle
    /// [2125620ms] [tap] hotkey forward pressed …      → emit begin
    /// [2125668ms] [tap] flagsChanged kc=55 down=false … → emit confirm
    /// [2125668ms] [T6] 确认(空列表):面板关闭           ← 枚举(46–69ms)还没回来 ⇒ 什么都没换 ✗
    /// ```
    /// 枚举在**后台**跑(2026-09-22 之前就是:为了不卡 tap 回调 ✓),而"按下→松开"只要 40–60ms
    /// ⇒ 快速 ⌘Tab 会跑在名单前面 ✗ ⇒ 确认时 `groups` 还是空的 ✓
    /// 口径:**意图已经被接受,就必须执行** —— 先记下来,等名单落地(`finishBegin`)当场兑现 ✓
    /// (与 `pendingLaunchRing` 同款:触发层比枚举先到的那一瞬,只记意图 ✓)
    ///
    /// ⚠️ 这里**不能**顺手 `dismiss()`:那会 `beginGeneration += 1` ⇒ 枚举回来直接被丢弃 ✗
    ///    (所以这一局要留着等名单;万一名单永远不来,有 `confirmWaitWork` 兜底 ✓)
    /// 本局名单是否已落地(区分"还没到"与"真的空")✓
    /// 等名单的兜底闹钟(见 `confirmBeforeList`)

    /// 段切换的行进方向(见 `SegmentTravel`)。PanelView 靠它挑过渡:
    /// 沿环走 = 内容横滑,↓/↑ 跳段 = 淡切

    /// **整条环的翻牌角度**(0 = 正对;±`PanelMetrics.ringFlipLimit` = 侧立)。
    ///
    /// ★ 2026-10-08 用户口径:「换环要**整条环**翻(玻璃 + 图标一起),不是只翻图标」+「先做 88°」。
    ///   为什么自己做而不用 `.transition`:系统「减弱动态效果」开着时 SwiftUI 会**自己**把过渡
    ///   降级成淡入淡出,而 `\.accessibilityReduceMotion` 是**只读**的、覆盖不了 ✗
    ///   ⇒ 用户实报「Glance 里开了强制完整动效,换环的翻牌还是只剩环变形」✗
    ///   ⇒ 改成参数驱动(与托底 PuckView 同一套哲学):**设置说什么就是什么** ✓

    /// 换环的**目标**环(连按时的意图)。与 `entrySelected` 分开存:
    /// "内容什么时候换"只看目标 ⇒ 翻牌中途改主意也不会半路换错 ✓

    /// **入场渐入的进度**(0 = 还没出现,1 = 落定)。
    ///
    /// ★ 2026-10-08:用户提「Spotlight 唤起有个 Q 弹的动效」⇒ 按 Apple 录屏**逐帧量**出来的参数实现:
    ///   起始比最终宽 ~7%、130ms 内 ease-out 收位、并快速淡入 ✓(与我第一版"从小涨大"的方向相反 ✓)
    /// ⚠️ 只作用于**环里那块内容**,不动玻璃 —— 原生玻璃不能被变换(材质会掉 ✗)
    /// ⚠️ 起跳**延后一拍**(见 showPanel):提前起跳会踩 AppKit 的"Update Constraints in Window pass"
    ///   递归 ⇒ 一唤起就 SIGABRT ✗(缩放/位移两版都验过;延后一拍是唯一活路 ✓)
    ///   渐入虽不动几何,这条**照旧保留** —— 它保护的是"上屏那一拍的布局",与动什么无关 ✓

    /// 入场渐入的总开关(设置 → 通用 →「唤起渐入」✓;键名仍是 `panel.summonPop`,不改 ✓)
    /// ⚠️ 老版这里还要求"起始倍率 != 1.0"才有意义 —— 渐入没有倍率了,那个条件随之作废 ✓
    var summonFadeEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.panelSummonPop) as? Bool ?? KeyDefaults.summonPop
    }

    /// **入场渐入的进度**(0 = 还没出现 · 1 = 落定)。视图拿它当 `.opacity` —— **不动任何几何** ✓
    ///
    /// 史(2026-10-08 一天之内):这里先后是「整块横向 1.04→1.00 的拉伸」→「带 duang 的弹簧」
    /// →「纯 transform 的横向橡皮筋」;用户三评之后定为**渐入**:
    ///   「要 fade 吧, 看起来是一个**渐入**的效果。**没有任何的弹动**呢, 比之前的两段弹簧要好」
    /// 换掉的**硬理由**(不是审美):动几何 ⇒ 命中区(用落定尺寸)与画面(被拉伸)**不一致** ✗
    ///   —— 9 个 App 那局最外侧那颗被推离 ≈22pt,而格距才 68pt ⇒ 想点的那颗可能正好在缝里 ✓
    ///   渐入没有这个病:从第一帧起"看到的就是点得到的" ✓

    /// **玻璃长度的插值**(0 = 主环那份宽,1 = 未启动环那份宽),与翻牌同拍。
    ///
    /// 用户口径(2026-10-08):「环长度变化那一下没有动画,直接缩短了」⇒ 要**平滑**过去 ✓
    /// ⚠️ 曾经以为"逐帧改玻璃宽度会掉材质" ✗ —— 那是**假结论**:当时容器层还挂着
    ///   `rotation3DEffect`,玻璃一直在被转 ✗(见 PanelView 尾部那段注释)。
    ///   残留删掉之后,逐帧改宽度是安全的 ✓
    /// ⚠️ 它只在翻牌期间有意义:`contentSize()` 在"角度为 0"时一律以 `entrySelected` 为准
    ///   (唯一真源 ⇒ 万一哪里漏了同步,静止态也自愈 ✓)

    /// 每次换环 +1;收尾回调靠它判过期(又按了一次 ⇒ 旧回调丢弃 ✓)
    /// 已经走完"侧立那一拍"的 token(兜底定时与完成回调谁先到都只算一次 ✓)

    /// "换环进行中"的窗口(2026-09-22):托盘内容在换环那一拍要**当拍**换(与环的翻牌同步 ✓),
    /// 而 hover 换组时要**滑**(用户实报「hover app 托盘只会闪现, 没有滑动了」✓)。
    /// 用时间窗而不是开关:换环是同步一瞬间的事,没有"结束"回调可挂 ✓

    /// 启动行 hover 的**帧拍兜底**(与 SheenOverlay 同一哲学:非 key 窗口的事件投递靠不住
    /// —— 先"哑"后"迟钝"两次实咬 —— 每帧问一次全局指针位置,自己算格子,事件丢了也有帧拍)。
    /// 几何与 `hoverLaunchAt` 同源;由 PreviewPanelView 里的 TimelineView 每帧驱动,
    /// 只在启动区活着时跑。与逐格 onHover 并存:两边写同一个 launchIndex,等值守卫不抖。
    ///
    /// ⚠️ 本函数运行在 Canvas 的**绘制闭包**里(视图更新中)——**不许在这里直接写 @Published**,
    /// 否则 Runtime 警告 "Publishing changes from within view updates" 并引发布局递归
    /// (2026-09-16 实机两连:警告 + `-layoutSubtreeIfNeeded` 递归)。算好下标,异步一跳再落账。
    func pollLaunchHover() {
        guard entrySelected, isVisible, !launchables.isEmpty,
              let previewPanel, previewPanel.isVisible, !previewPanel.ignoresMouseEvents,
              let glass = previewContentRect() else { return }
        let p = NSEvent.mouseLocation
        guard glass.contains(p) else { return }
        let (rows, cols) = launchLayout(count: launchables.count)
        let rowH = PanelMetrics.icon + PanelMetrics.trayRowGap
        // 玻璃 → 内容:水平从 trayPadX − iconGap/2 起算(行两端负 padding),纵向自玻璃下沿 + trayPadBottom
        let x = p.x - glass.minX - PanelMetrics.trayPadX + PanelMetrics.iconGap / 2
        let yUp = p.y - (glass.minY + PanelMetrics.trayPadBottom + PanelMetrics.trayBottomBreath)
        guard x >= 0, yUp >= 0 else { return }
        let c = max(0, min(cols - 1, RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap)))
        let r = max(0, min(max(rows - 1, 0), Int(yUp / rowH)))
        let i = r * cols + c
        guard launchables.indices.contains(i), i != launchIndex else { return }
        let hovered = i
        Task { @MainActor in
            // 异步一跳后核对:这一跳的间隙里可能已关面板/换局
            guard self.entrySelected, self.launchables.indices.contains(hovered) else { return }
            self.launchIndex = hovered
            trace("[T6] 启动区选中(帧拍): [\(hovered + 1)/\(self.launchables.count)] \(self.launchables[hovered].name)")
        }
    }
    /// 主环 hover 的**帧拍兜底**(与 pollLaunchHover / pollWindowHover 同一套哲学):非 key 窗口的
    /// 鼠标事件投递靠不住 —— 先"哑"后"迟钝"两次实咬,而主环此前只靠逐格 onHover,是三块里
    /// 唯一没有帧拍的。键盘操作必然让 strip 重渲染过,tracking area 哑掉,第一下 hover 被吞
    /// ⇒ 键盘→鼠标交接"慢半拍"(2026-09-18 用户实报)。每帧问一次全局指针位置、自己算格子:
    /// **指针动了 = 当帧接管**(事件一炮没到也接管);指针没动 = 闸还关着,键盘优先
    /// (见 panelOpenPoint —— 键盘唤起时鼠标恰好压在某格上,不许它抢选中)。
    /// 落账直接走 hoverApp(闸 / 等值守卫 / 拍图 / 托盘更新全在那边,不另立一本);
    /// 这里只做几何 + 等值预判 —— 每帧都进 hoverApp 会把 bumpIdle 的闲置计时天天清零,
    /// "指针停在面板上 = 永不闲置"是顺手改出来的语义,不是设计(见 bumpIdle)。
    func pollRingHover() {
        // ★ 换环翻牌期间指针轮询跳过:此刻"哪一环"还在切换中,算出来的格子属于旧环 ✗
        guard ringFlipAngle == 0 else { return }
        guard isVisible, hintText == nil,
              let panel, panel.isVisible, !panel.ignoresMouseEvents,
              let glass = panelContentRect() else { return }
        let p = samplePointer()   // 帧拍顺带采样指针位移(谁后动听谁的账本)
        guard glass.contains(p) else { return }
        // ★ **热区内缩**(2026-09-19 用户实报「碰到边边就选中」):hover 选中要求指针
        //   落在格子内缩后的中心区(见 pointerInRingHotZone);点按确认走点按手势不受影响。
        let x = p.x - glass.minX - ringContentLeftInset - PanelMetrics.rowPadX + PanelMetrics.iconGap / 2
        guard x >= 0 else { return }
        let i = RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap)
        guard pointerInRingHotZone(i) else { return }
        // 绘制闭包里**读**状态没问题(禁的是写),等值预判放同步侧:没变化连 Task 都不发
        let current = entrySelected ? (launchIndex ?? -1) : appIndex
        guard i != current else { return }
        let hovered = i
        Task { @MainActor in self.hoverApp(hovered, source: "帧拍 hover") }   // 异步一跳(病例见 pollLaunchHover 头注)
    }

    /// **指针帧拍的心跳**(2026-09-18 实测翻案):TimelineView(.animation) 在**静态窗口上不跳帧**
    /// —— macOS 不给静止的窗口排帧,所谓"每帧兜底"实际只在"有视图更新的那几拍"生效。
    /// 实测账:warp 挪指针后 300ms 内一次采样都没发生,直到下一次键盘动作触发重绘才补上
    /// —— 这就是"键盘操作完、鼠标接管慢半拍"的真身:兜底只在界面刚动过时活着,
    /// 而恰恰是"界面静止、指针开始动"的那一刻最需要它。
    /// 现在面板在台期间挂 60Hz 定时器,统一驱动主环与托盘的指针重定位;散场即停。

    /// 光晕要用的颜色 = **选中的那个 App 图标的主色**（2026-09-24 用户口径：
    /// 固定白高光 → 图标本色的晕染 ✓）。nil = 那枚图标基本是灰的 ⇒ 视图退回白色 ✓
    ///
    /// 视图每 30Hz 会问一次 ⇒ 必须便宜：`IconTint` 内部有缓存，这里是纯查表 ✓
    /// 未启动段里那些 App 没在跑（没有 pid）⇒ 用 `launch:<id>` 当缓存键 ✓
    /// 上面那个颜色属于哪个 App（**同一个源** ⇒ 日志与实际画出来的必然一致 ✓）
    var sheenTintOwner: String? {
        if entrySelected, let li = launchIndex, launchables.indices.contains(li) {
            return launchables[li].name
        }
        guard groups.indices.contains(appIndex) else { return nil }
        return groups[appIndex].appName
    }

    /// ★★ 2026-10-26(性能账):这个属性是**光晕**在 30Hz 里每帧问的(而且一帧问两次),
    ///   而它内部 `IconProvider.art(for:)` 即使命中缓存也要做一次
    ///   `NSRunningApplication(processIdentifier:)`(= 一次 LaunchServices XPC)⇒
    ///   面板开着时每秒 60 次同步 XPC ⇒ 掉帧 ✗
    ///   ⇒ 按"pid + bundle"记一次结果,只有换格/换 App 才重算 ✓(颜色本来就跟着选中走)
    private static var sheenTintMemo: (key: String, color: NSColor?)?
    var sheenTint: NSColor? {
        let key: String
        let color: NSColor?
        if entrySelected, let li = launchIndex, launchables.indices.contains(li) {
            let app = launchables[li]
            key = "launch:\(app.id)"
            color = IconTint.color(for: app.icon, key: key)
        } else {
            guard groups.indices.contains(appIndex) else { return nil }
            let g = groups[appIndex]
            key = "pid:\(g.pid):\(g.bundleID ?? "")"
            if let m = Self.sheenTintMemo, m.key == key { return m.color }
            color = IconTint.color(for: IconProvider.art(for: g.pid).image, key: key)
        }
        Self.sheenTintMemo = (key, color)
        return color
    }

    func startHoverPolling() {
        guard hoverPollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self, self.isVisible else { return }
            self.updateStripClickGate()   // Bug2:指针在托盘玻璃里就让长条对合成器隐身
            self.pollRingHover()
            self.resyncSelectionUnderPointer()
            // ★ 2026-09-24:未启动段那一行原本靠它自己视图里的 TimelineView 每帧轮询
            //   (而且那个 TimelineView **没有 paused**)現在三处 hover 轮询共用这一个定时器 ✓
            self.pollLaunchHover()
        }
        t.resume()
        hoverPollTimer = t
    }

    func stopHoverPolling() {
        hoverPollTimer?.cancel()
        hoverPollTimer = nil
    }

    /// 启动区这局关了(设置开关/名单为空)—— 视图与键盘路径都靠它短路

    /// **Tab 能不能进未启动段**(2026-09-18 用户要求,默认开)。关掉后 Tab/滚轮走到主环端点
    /// 就地折返(moveApp 的 else 分支照旧取模绕回),段只能靠 ↓/↑ 进出 —— 模型 C 的"逻辑一条环"
    /// 在这条开关下退化成"两条独立环"。滚轮走 handle(.next/.prev) 同路,自动跟着这个开关走
    var tabEntersLaunchSection: Bool {
        UserDefaults.standard.object(forKey: Keys.panelTabEntersLaunchSection) as? Bool ?? true
    }

    // (2026-09-19)「悬停回退单」机制整段退役 —— 病例:四指/键盘进段后,指针不在面板上,
    // 0.12s 后段被它静默收掉,白名单 App 还没确认就回到主环(用户实报「白名单的 App 没办法启动」,
    // 日志:段内选中 → 半分钟后主环选中 → 确认,中间无任何段操作)。回退单是"入口槽 +
    // 悬停预览"时代的语义(指针离开启动区 = 用户不要了);模型 C 里段只能由 ↓/四指/Tab
    // **主动**进入,指针在不在面板上与段的生死无关 —— 段保持粘性,由 ↑/Tab/Esc/闲置超时收场。
    /// 本局内被 H 隐藏的 App。为什么要记:
    /// 隐藏是**异步**的(0.2–0.3s 动画),这期间重枚举**还看得见它的窗** ——
    /// 不记住的话,卡片会在 0.18s 后闪回来(用户实报:「先是消失了,然后又出现了」)。

    /// 本局已被我们**退出**的 App(pid)。
    ///
    /// 和 hiddenPIDs 是**同一个病,换了个动作**:系统的 AX 窗口表在进程死透之前
    /// 那 0.2–0.3s 里仍然报得出它的窗,而 `mergeRefreshed` 对"重枚举里新出现的 App"
    /// 的处理是**挂到尾部**(不插队)—— 于是刚被处决的 App 在环尾复活。
    ///
    /// 病例(2026-09-16,用户实报):"cmd q 退出 app, 此时面板还没关闭, 就又出现在尾部了,
    /// 重新唤起面板后不再出现。" 日志一字不差:
    ///     [T12] 退出应用: zoom.us
    ///     [T12] 本地先摘: 8 个 App / 12 窗 → 7 个 App / 11 窗
    ///     [处决后] 7 个 App,选中 [2/7] 大象          ← 对了
    ///     [处决后] 8 个 App,选中 [2/8] 大象          ← 0.7s 后那次重枚举把它捞了回来
    ///     [T12] 处决后顺序 [… | DataGrip | zoom.us]   ← 复活的它挂在**末位**
    /// "重新唤起就没了"也对得上:新一局重新枚举,那时进程真的死透了 —— 所以这条记忆
    /// 只活一局(begin 里清空),不跨局。

    /// 本局已被我们**关掉/最小化**的窗(CGWindowID),等着复核。
    ///
    /// 病例(2026-09-17,用户实报):"点击关闭之后, 面板没关闭, 就又出现了."
    /// 日志一字不差:`[T12] 关闭窗口: DataGrip — Confirm Exit` → `本地先摘 17 窗 → 16 窗`
    /// → 0.2s 后 `[处决后顺序]` 它又回来了,来回三次。
    /// **那扇窗是 App 自己的确认框**(modal alert),AX 的 close 对它无效 —— 它压根关不掉。
    /// 所以"先摘"必须像 `verifyQuit` 一样**复核**:真没了才留摘除的样子,还在就**放回原位**。
    /// **本局被我们缩小(Cmd+M)过的窗与 App**(2026-09-22 用户实报)。
    ///
    /// 病例:「唤起面板的时候, cmd m 会缩小, 这时候面板上的 app 是没变化的, 松开之后会立马把缩小的窗口
    ///   又换起来」✗ —— 最小化窗本来就不在列表里(`optimisticRemoval(.minimize)` ✓),但**组还在环里** ✓
    ///   ⇒ 松开时走 `confirmSelection` 的"无窗应用 ⇒ 激活它"那条路 ✗ ⇒ 刚缩下去的窗又被抬起来 ✓
    /// 这与当初 `H` 那个 bug **是同一个病**(「松开 ⌥ 又把刚隐藏的 App 唤起来了」✓)⇒ 照它的先例办:
    ///   **本局不许再唤醒它** ✓;顺带把 App 标记上(用户第 2 条诉求:标记被缩小收纳的 app ✓)
    /// ⚠️ **跨局常驻**(2026-09-22 用户第 2 条修正:「角标要常驻」✗ 只活一局是错的):
    /// 一扇窗被收进 Dock 之后,**只要它还在 Dock 里就该有记号** ✓ —— 与"这一局"无关 ✓
    /// ⇒ 记 `wid → pid`(pid 用来在 App 退出后剪掉 ✓,wid 用来认"还是那一扇窗" ✓)
    /// 环上要打"已收纳"记号的 App(由上面那张表推出来 ✓ —— 单一源 ✓)
    /// 让 `minimizedWIDs` 的变化**一定会**触发重绘(它是普通字典,不会自己 publish ✗)
    /// 环上这枚图标该打什么记号 —— 判据在领域层(`PanelMarkPolicy` ✓),这里只喂两个事实 ✓
    ///
    /// ⚠️ 优先级 2026-09-22 反转过(用户:「又退回不可见的角标了, 不是遗照灰」✗):
    ///   原来"隐藏优先" ⇒ 一个 App 同时满足"有窗收在 Dock 里"与"系统说它 hidden"时,显示角标 ✗
    ///   而用户刚按的是 ⌘M,要看见的是"那扇窗收起来了" ⇒ **有收纳就显示灰** ✓
    func mark(for pid: pid_t) -> PanelMark? {
        PanelMarkPolicy.mark(hidden: hidingPIDs.contains(pid), tucked: minimizedPIDs.contains(pid))
    }

    /// **本局**被我们缩小过的 App —— 只给"松开时不许唤醒它"这条守卫用 ✓
    ///
    /// ⚠️ 它与上面那张**常驻**表是**两种寿命**,别混(2026-09-22 用户两条实报互相约束):
    ///   · ① 「cmd m 会缩小…松开之后会立马把缩小的窗口又换起来」✗ ⇒ 本局不许唤醒 ✓(否则那次缩小等于白按)
    ///   · ② 「关闭再唤起之后, 选中 app 拉不起窗口了」✗ ⇒ **另起一局**的确认必须能把它拉回来 ✓
    /// ⇒ 记号(视觉)常驻 ✓;守卫只活一局 ✓ —— 用户的手离开键盘之后再确认,就是"我要它回来" ✓

    /// 环上要打"已隐藏"记号的 App(**现读系统真实状态** ✓ ⇒ 只要还是 hide 就有记号 ✓,
    /// 自己从 Dock 点回来 ⇒ 记号自动消失 ✓ 不需要谁去清 ✗)

}
