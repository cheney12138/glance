import AppKit
import GlanceCore
import SwiftUI

// MARK: - T12 破坏性键盘操作(CONTEXT.md「破坏性键盘操作」:有键无钮)
//
// ⚠️ 2026-10-16 从 PanelController.swift 平移而来(重构清单第 9 条 ✓):
//   **纯代码搬移,零行为变化** ✓ —— 同类 extension,同一层(Panel ✓)架构检查不变 ✓
//   可访问性:块内原 `private` 成员改为内部(同模块 ✓,见各处标注 ✓)

extension PanelController {
    // MARK: - T12 破坏性键盘操作(CONTEXT.md「破坏性键盘操作」:有键无钮)

    /// 名字是历史(最早只有退出/关窗/最小化):它实际管的是「面板里**直接对窗或 App 生效**的动作」。
    /// 后来进来的 zoom / fullscreen / hide 都**不改列表语义**,只是窗或 App 的状态变了 ——
    /// 所以它们统一走这条"动作 → 重枚举 → 留在原地"的路(Snapshotter.prune 只剪被处决的那扇)。
    enum DestructiveOp { case quit, close, minimize, zoom, fullscreen, hide }

    /// 红绿灯按钮入口(T14):wid 反查组内位置后,走破坏性操作同一闸
    func closeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .close) }
    func minimizeWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .minimize) }
    func zoomWindowClicked(_ wid: CGWindowID) { trafficOp(wid, .zoom) }

    /// **乐观本地摘除** —— 这一条是病例逼出来的,别删:
    ///
    /// 病例(2026-09-14,用户报 H):"隐藏之后 App 还在 Switcher 栏上,松开 ⌥ 就把选中那个又唤起来了"。
    /// 根因不在 H 的语义,而在**时间**:`NSRunningApplication.hide()` / AX 的关闭、最小化都是
    /// **异步**的(隐藏与最小化都有 0.2–0.3s 动画,App 忙时更久),而 `refreshAfterAction()` 只等 0.18s
    /// 重新枚举 —— 那一瞬间系统里那扇窗**还看得见**,分组没变、选中还停在它上面,
    /// 于是松开 ⌥ 走 SLPS 前置,又把刚隐藏的 App 唤起来了(它只是"被隐藏",并没有消失)。
    ///
    /// 所以:发完动作**立刻**按我们已知的结果改本地列表(面板当帧就对上,选中当场被钳走),
    /// 真数据 0.18s 后再来核对。**只摘确定的**:zoom/fullscreen 不摘 ——
    /// 全屏是进出 Space(进入会离开本列表,退出又会回来),猜错方向反而会把窗摘没了。
    private func optimisticRemoval(_ op: DestructiveOp, in g: AppGroup, resizeWindow: Bool = true) {
        // 注意 H **不走这里**(见 .hide:它只清窗、不摘组)
        var next: [AppGroup] = []
        for group in groups {
            guard group.pid == g.pid else { next.append(group); continue }
            switch op {
            case .quit:
                continue // 整组离开:App 真的没了
            case .hide:
                continue // 理论到不了(H 自己处理),留着只为穷尽枚举
            case .close, .minimize:
                // 关掉 / 最小化的那扇窗离开列表(最小化窗我们本来就不列)。
                // ★ 组空了**不再摘组**(2026-09-20 用户:「cmd w 只是关闭窗口,不需要从环里
                //   杀掉」):进程还在 = 无窗应用(T15),原地保留、只清窗卡 —— 与 H 的
                //   "位置不变,只是窗口消失"同一语义。App 若因关末窗自动退出,下一次
                //   重枚举自然摘它(进程不在了)
                let keep = group.windows.enumerated().filter { $0.offset != winIndex }.map(\.element)
                if !keep.isEmpty {
                    next.append(AppGroup(pid: group.pid, appName: group.appName,
                                         bundleID: group.bundleID, windows: keep))
                } else if NSRunningApplication(processIdentifier: group.pid)?.isTerminated == false {
                    next.append(AppGroup(pid: group.pid, appName: group.appName,
                                         bundleID: group.bundleID, windows: []))
                }
            case .zoom, .fullscreen:
                next.append(group) // 不摘(见上面的理由),等核对
            }
        }
        let before = groups.reduce(0) { $0 + $1.windows.count }
        let after = next.reduce(0) { $0 + $1.windows.count }
        guard next.count != groups.count || after != before else { return } // zoom/fullscreen:没摘,不必走这一趟
        trace("[T12] 本地先摘: \(groups.count) 个 App / \(before) 窗 → "
              + "\(next.count) 个 App / \(after) 窗")
        applyRefreshed(next, keepPID: nil, keepWin: winIndex, resizeWindow: resizeWindow)
    }

    private func trafficOp(_ wid: CGWindowID, _ op: DestructiveOp) {
        for (ai, g) in groups.enumerated() {
            guard let wi = g.windows.firstIndex(where: { $0.wid == wid }) else { continue }
            appIndex = ai
            winIndex = wi
            destructive(op)
            return
        }
    }

    /// 处决类操作(Q/W/M 与红绿灯共走这里)。
    ///
    /// 2026-09-14 用户改判:处决之后**留在原地**。原语义是"处决三段 = 本轮事务死透"
    /// (避免"走了还是只关窗"的歧义),但实际用起来:关一扇窗、最小化一扇窗之后往往还想接着动
    /// 别的窗 —— 面板一消失,每动一次就要重新 ⌘Tab 开一局。现在动作做完就重枚举刷新,面板不散。
    func destructive(_ op: DestructiveOp) {
        // 启动区里处决键无对象:appIndex 停在上一个活跃 App,动它 = 误杀,静默吞掉
        guard !entrySelected, groups.indices.contains(appIndex) else { return }
        let g = groups[appIndex]
        // **自保**(2026-09-18 用户裁定):Q(退出)与 H(隐藏)对 Glance 本体 = **按了没反应**。
        // 杀了切换器当场陪葬;H 更糟 —— LSUIElement 没有 Dock 图标,藏了就无处可捞。
        // 不弹提示不说话(v2 裁定:「应该是 cmd q 按了没反应而已」),日志记一笔即可
        if (op == .quit || op == .hide), g.pid == ProcessInfo.processInfo.processIdentifier {
            glog("[T12] 自保:\(g.appName) 不接受 \(op == .quit ? "Q(退出)" : "H(隐藏)"),静默忽略")
            return
        }
        switch op {
        case .quit:
            glog("[T12] 退出应用: \(g.appName)")
            quitPIDs.insert(g.pid) // 先记后杀:0.18s 后那次重枚举不许把它捞回来(见 quitPIDs 的病例)
            WindowFocuser.quitApp(pid: g.pid)
            // ★ 立即摘组(不再"留空位再补"):留位那版实测读起来是
            //   「App 已经没了 → 等一下 → 环才变形」,中间那段空档用户直接点了出来
            //   (「到环缩短动效有个间隔,间隔有点长了,杀掉 app 消失同步去变形」)。
            //   ⇒ 退出与变形**同一拍**:摘组 + `resizeWindow: false`(窗框不动 ⇒ 玻璃靠
            //     SwiftUI 的宽度动画平滑收窄,图标跟着缓缓左移 ✓ 不碰 AppKit 的窗口 resize ✓)
            optimisticRemoval(op, in: g, resizeWindow: false)
            refreshAfterAction()
            verifyQuit(pid: g.pid, name: g.appName, group: g, restoreAt: appIndex) // 0.9s 后问进程:真死了没?
        case .close:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 关闭窗口: \(g.appName) — \(w.title)")
            WindowFocuser.close(window: w)
            purgedWIDs.insert(w.wid) // 先记后摘:复核之前不许它"诈尸"回来
            verifyPurged(wid: w.wid, name: g.appName, group: g)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .minimize:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T12] 最小化: \(g.appName) — \(w.title)")
            // ★★ **先记后做**(与 purgedWIDs/quitPIDs 同一套 ✓)——
            //    用户 2026-09-22:「遗照灰的渲染有点延迟. 是在确认窗口真的缩小了吗」
            //    ⇒ **是**,原来就是:我把"记下已收纳"写在 AX 调用**之后** ✗,而
            //      `AXUIElementSetAttributeValue` 是**同步跨进程调用**(要等 App 真缩下去才返回 ✓)
            //      ⇒ 图只能等 App 缩完才变灰 ✓(实测那点延迟就是目标 App 自己的最小化耗时 ✓)
            //    ⇒ 改成乐观:图**当帧**就变灰 ✓;AX 被拒了再回滚 ✓(不许留假状态 ✓)
            purgedWIDs.insert(w.wid)          // 先记后摘:复核之前不许它"诈尸"回来
            minimizedWIDs[w.wid] = g.pid      // 常驻:环上的"已收纳"记号 ✓
            sessionMinimizedPIDs.insert(g.pid) // 本局:松开时不许唤醒它 ✓
            marksRevision &+= 1               // ⇒ 当帧重绘(不等 AX ✓)
            glog("[记号] 记下已收纳(先记后做):窗 \(w.wid) @ \(g.appName)")
            let accepted = WindowFocuser.minimize(window: w)
            if !accepted {
                // 系统没受理(取不到 AX 窗 / 被拒)⇒ **把乐观记的账全撤掉** ✓ 不许留假灰 ✗
                minimizedWIDs.removeValue(forKey: w.wid)
                sessionMinimizedPIDs.remove(g.pid)
                purgedWIDs.remove(w.wid)   // 窗还在屏幕上 ⇒ 别让"复核期"把它按掉 ✗(0.18s 后它会自己回来 ✓)
                marksRevision &+= 1
                glog("[记号] 回滚已收纳:窗 \(w.wid) 最小化未被受理")
            }
            verifyPurged(wid: w.wid, name: g.appName, group: g)
            optimisticRemoval(op, in: g)
            refreshAfterAction()
        case .fullscreen:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            glog("[T29] 全屏切换(F): \(g.appName) — \(w.title)")
            WindowFocuser.toggleFullscreen(window: w)
            // 全屏会**进出独立 Space**:窗可能整扇离开当前语境屏 → 必须重枚举(与 Z 不同)
            refreshAfterAction()
        case .hide:
            let ok = WindowFocuser.hideApp(pid: g.pid)
            hiddenPIDs.insert(g.pid)
            glog("[T29] 隐藏 App(H): \(g.appName) → hide()=\(ok ? "已受理" : "被拒绝")")
            // **不摘组**:图标留在原位,只把它的窗清空 —— 用户实报的首版做法(摘整组)会让整条栏
            // 重排两次("乱跳"),而他期望的是"位置不变,只是窗口消失了"。
            // 系统那边隐藏完之前,枚举仍会报出它的窗,所以 hiddenPIDs 还要压住这一段(见 mergeRefreshed)
            var next = groups
            if let i = next.firstIndex(where: { $0.pid == g.pid }) {
                let keep = next[i]
                next[i] = AppGroup(pid: keep.pid, appName: keep.appName,
                                   bundleID: keep.bundleID, windows: [])
            }
            applyList(next, keepPID: g.pid, keepWin: 0)
            refreshAfterAction()
        case .zoom:
            guard g.windows.indices.contains(winIndex) else { return }
            let w = g.windows[winIndex]
            print("[T12] 缩放(Z): \(g.appName) — \(w.title)")
            WindowFocuser.zoom(window: w)
            // 缩放不改列表:窗还在同一格,只是尺寸剧变 —— 不重枚举,面板继续陪
        }
    }

    /// 退出的**复核**(2026-09-17 初版"放回被拒者"的语义已被 09-18 三修取代 ——
    /// 终案「Q 过的本局不回」与完整三轮弯路记录见函数体内的注释):
    /// 0.9s 后问一次进程死活,只打日志、不再放回;`quitPIDs` 压住本局直到散场。
    ///
    /// 关窗/最小化的**复核**(2026-09-17,与 `verifyQuit` 成对但语义**不同**——
    /// 关窗没有"慢死"问题:窗关就是关,`optionOnScreenOnly` 里报的窗就是真还在的窗;
    /// App 的确认框(modal alert)根本关不掉,摘了会变成"消失又回来"的来回跳。
    /// 0.9s 后重枚举一次:真没了 ⇒ 摘除成立;还在 ⇒ 撤回(放回**原位**,并且保持选中)。
    private func verifyPurged(wid: CGWindowID, name: String, group: AppGroup) {
        let generation = beginGeneration
        let restoreAt = appIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.beginGeneration == generation else { return }
            guard self.purgedWIDs.contains(wid) else { return }
            self.purgedWIDs.remove(wid)   // 复核这次之后,真相由系统说了算
            guard self.isVisible, let screen = self.contextScreen else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.isVisible, self.beginGeneration == generation else { return }
                    let stillThere = raw.contains { $0.windows.contains { $0.wid == wid } }
                    if stillThere {
                        glog("[T12] 关闭被拒(窗还在): \(name) → 放回列表")
                        var next = self.groups
                        if !next.contains(where: { $0.pid == group.pid }) {
                            next.insert(group, at: min(max(0, restoreAt), next.count))
                            self.applyList(next, keepPID: group.pid, keepWin: 0)
                        } else {
                            self.applyRefreshed(raw, keepPID: group.pid, keepWin: 0)
                        }
                    }
                }
            }
        }
    }

    private func verifyQuit(pid: pid_t, name: String, group: AppGroup, restoreAt index: Int) {
        // ★ 2026-09-18 三修(用户拍板「**Q 过的本局不回**」)—— 三轮修到这里才对,把两条弯路记全:
        //   · 一修(quitPIDs,09-17)治了"尾部复活" ✓,但放回逻辑还在;
        //   · 二修(「有窗才放回」,今天上午)被 zoom 实锤误伤 —— 日志:`[510178ms] 退出被拒(窗还在)
        //     → 放回列表` + `[T5] 预截 要拍 1 窗`(连它那扇正在关的窗的图都拍到了)。
        //     **正在关闭动画里的窗**与**确认框**在单一时点的窗口表里长得一模一样,
        //     任何固定时限的复核都是在赌 zoom 们窗消失的时机 —— 赌输一次症状就回来一次。
        //   · 终案语义(用户裁定):**面板反映用户的意图,屏幕反映现实** ——
        //     Q 过的 App 本局绝不自动放回;真被拒的确认框用户在屏幕上自己看得见,
        //     新一局 begin 重枚举,真相自然恢复。zoom 窗拖 1s 还是 10s 都不再有变量。
        //   (放回逻辑随二修撤销;`group`/`index` 参数保留以免动调用方,已无用处。
        //    本函数此后只负责打日志;记忆的最终清账交给 begin —— 下一局以系统真实状态为准。)
        let generation = beginGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.beginGeneration == generation else { return }
            let app = NSRunningApplication(processIdentifier: pid)
            guard app != nil, app?.isTerminated == false else {
                glog("[T12] 退出完成: \(name)")
                self.quitPIDs.remove(pid) // 死透了;撤掉只是账面干净(下一局 begin 反正会清)
                return
            }
            // 还活着:本局绝不放回。再问一句窗口表,把"正在死"与"疑似被拒"在日志里分清 ——
            // 今天的误伤就是靠这一行定位的,复盘时对得上账
            guard let screen = self.contextScreen else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.beginGeneration == generation else { return }
                    let windows = raw.first { $0.pid == pid }?.windows ?? []
                    if windows.isEmpty {
                        glog("[T12] 退出中(进程在、窗已空): \(name) → 本局不放回")
                    } else {
                        glog("[T12] 疑似被拒(窗还在,可能是确认框): \(name) → 本局不放回,弹窗由用户处理")
                    }
                    // quitPIDs **故意不撤**:本局后续任何重枚举都不许它回来(「Q 过的本局不回」)
                }
            }
        }
    }

    /// 处决后的就地刷新:重枚举 + **尽量保住原来的选中**(按 pid 认 App,窗位夹紧)。
    ///
    /// 为什么要延迟一下:AX 的关闭/最小化是**异步生效**的,立刻枚举会把刚处决的那扇窗
    /// 又枚举回来(于是它在面板里"诈尸"一下再消失)。
    private func refreshAfterAction() {
        guard let screen = contextScreen else { return }
        let generation = beginGeneration
        let keepPID = groups.indices.contains(appIndex) ? groups[appIndex].pid : nil
        let keepWin = winIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.isVisible, self.beginGeneration == generation else { return }
            Task.detached(priority: .userInitiated) {
                let raw = WindowEnumerator.rawGroups(on: screen)
                await MainActor.run {
                    guard self.isVisible, self.beginGeneration == generation else { return }
                    self.applyRefreshed(raw, keepPID: keepPID, keepWin: keepWin)
                }
            }
        }
    }

    /// "已收纳"记号的自愈(每次重枚举后跑一遍,很便宜 ✓):
    ///   · 那扇窗**回到屏幕上了**(从 Dock 点回来 / 别的路还原了)⇒ 它不再"在 Dock 里" ⇒ 剪掉 ✓
    ///   · 它的 App 已经不在了 ⇒ 剪掉 ✓(wid 会被系统复用,必须靠 pid 判断,不能只认 wid ✓)
    /// 隐藏标记同理:现读 `isHidden` ⇒ 只有"还藏着"的才留 ✓
    func reconcileMinimizedMarks(_ raw: [AppGroup]) {
        let before = minimizedWIDs.count
        var onScreen = Set<CGWindowID>()
        for g in raw { for w in g.windows { onScreen.insert(w.wid) } }
        // 每个被标记的 App 问一次 AX 真相(只有 1–2 个 App ✓;问不到就 nil ⇒ 不据此下结论 ✓)
        var axTucked: [pid_t: Bool?] = [:]
        for pid in Set(minimizedWIDs.values) where axTucked[pid] == nil {
            axTucked[pid] = WindowFocuser.hasMinimizedWindow(ofPID: pid)
        }
        minimizedWIDs = minimizedWIDs.filter { wid, pid in
            // ⚠️ **不许拿 purgedWIDs 里的窗当"回来了"** ✗
            //    病例(2026-09-22 用户实报:「没有常驻, 只出现了一下就消失了」):
            //    缩下去之后 0.18s 那次重枚举**还会把它报回来**(本仓早就记过这个"诈尸" ✓
            //    见 purgedWIDs 的注释 ✓),我这里却当场把记号剪掉了 ✗ ⇒ 记号一闪就没 ✓
            //    ⇒ 按 purgedWIDs 的老规矩:复核期(0.9s)内**不算数** ✓
            guard !purgedWIDs.contains(wid) else { return true }              // 复核期内:不动它 ✓
            if onScreen.contains(wid) {                                       // ① 真的回到屏上了 ✓
                glog("[记号] 摘掉已收纳:窗 \(wid) 回到屏上了")
                return false
            }
            // ② AX 说这个 App 已经一扇缩着的窗都没有了 ⇒ 记号失效 ✓
            //    ★ 这条才治得住"还原之后 window id 变了"的 App(见 hasMinimizedWindow 的注释 ✓)
            if let stillTucked = axTucked[pid], stillTucked == false {
                glog("[记号] 摘掉已收纳:App \(pid) 已经没有缩着的窗了")
                return false
            }
            return NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        }
        refreshHidingMarks()
        if minimizedWIDs.count != before { marksRevision &+= 1 }   // 表变了 ⇒ 保证重绘一次 ✓
    }

    /// 重算"哪些 App 现在藏着" —— 角标 `eye.slash` 的唯一数据源 ✓
    ///
    /// ⚠️ 2026-09-22 用户问:「刚才怎么还偶然看到了一个闭眼不可见的角标…是写在哪了, 什么状态下会出现」
    ///   —— 他之所以是"偶然看到",就是因为这里**原来只在**重枚举时才算(唤起 / 我们自己动作之后)
    ///   ⇒ 面板**开着**的时候,别处把 App 藏了/放出来了,角标都要等到下一次刷才跟上 ✗
    /// ⇒ 现在多两个触发源:`NSWorkspace` 的 hide / unhide 通知(见 `observeHidingChanges`)✓
    private func refreshHidingMarks() {
        // ★★ 2026-09-22 修正:`isHidden == true` **不等于**"用户按过 ⌘H" ✗
        //   用户实报:「还是有啊, 是不是之前的状态还在, 所以有残留」⇒ 当场量了系统(只读):
        //   ```
        //   常规 App 共 14 个;其中 isHidden=true 的只有: 文枢(com.meituan.EncryptionBox)
        //   ```
        //   ⇒ 他的截图里那枚角标**不是残留** ✓ —— 是那个 App**自己**报的 hidden ✓
        //      (窗口关掉的工具类 App / 常驻辅助型,没有可见窗口时就会这样 ✗)
        //   ⇒ 上一轮我写的"口径是系统事实"是**错的** ✗ ⇒ 现在:只认**我们按过 ⌘H 的** App ✓
        //      再与系统对一次账 ⇒ "只要还是 hide 就一直有"仍然成立 ✓,但不再给局外 App 乱打 ✓
        //   代价(说清楚):用别的工具隐藏的 App(⌥⌘H"隐藏其他"等)不会有角标 ✓
        let stillHidden = hiddenPIDs.filter {
            NSRunningApplication(processIdentifier: $0)?.isHidden == true
        }
        // 自己从 Dock / 别处放回来了 ⇒ 记号的依据没了 ⇒ 顺手把这笔账也清了 ✓(自愈 ✓)
        if Set(stillHidden) != hiddenPIDs { hiddenPIDs = Set(stillHidden) }
        var hiding = Set<pid_t>()
        for g in groups where hiddenPIDs.contains(g.pid) {
            hiding.insert(g.pid)
        }
        if hiding != hidingPIDs {
            if isTraceEnabled {
                // 谁被判定成 hidden —— 2026-09-22 病例(⌘M 之后冒出"隐藏"角标 ✗)需要这行才能定案:
                // 到底是系统把"窗都收走的 App"报成了 hidden,还是别处动了它 ✓
                let names = hiding.subtracting(hidingPIDs).map {
                    NSRunningApplication(processIdentifier: $0)?.localizedName ?? "\($0)"
                }
                let gone = hidingPIDs.subtracting(hiding).map {
                    NSRunningApplication(processIdentifier: $0)?.localizedName ?? "\($0)"
                }
                if !names.isEmpty { glog("[记号] 系统报告这些 App 变成隐藏: \(names.joined(separator: " · "))") }
                if !gone.isEmpty { glog("[记号] 这些 App 不再隐藏: \(gone.joined(separator: " · "))") }
            }
            hidingPIDs = hiding
        }
    }

    /// 系统的"某个 App 被藏了 / 被放出来了"通知 ⇒ 立刻跟上(全局只装一次 ✓)
    ///
    /// 注意口径:这里认的是**系统事实**(`isHidden`),不是"我们按过 ⌘H" ✓
    /// ⇒ 别的工具 / "隐藏其他(⌥⌘H)" / App 自己藏的,都会让这枚角标出现 ✓ 这是有意的 ✓
    func observeHidingChanges() {
        guard !didObserveHiding else { return }
        didObserveHiding = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` 是**我们的事实**,但编译器不认 ⇒ 显式说明它 ✓
                // (不写它会有三条 warning:读 isVisible / 调 refreshAfterAction 都算跨隔离 ✗
                //   —— 别用"消音"绕过:那会把真正的主线程假设藏起来 ✓)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 在台上就顺手重枚举一次:被藏起来的 App,它的窗**还在列表里**(枚举要到下一次
                    // 重枚举才把它们除掉)⇒ 光改角标会留下几张"已经看不见的卡" ✗
                    if self.isVisible { self.refreshAfterAction() } else { self.refreshHidingMarks() }
                }
            }
        }
    }

    /// - Parameter forceReshoot: true = 显示组强制重拍(处决等真变化);
    ///   false = 只补缺图 —— 「陈旧名单 → 新鲜枚举」那一趟用它,免得在入场那几帧里重拍已有的图
    func applyRefreshed(_ raw: [AppGroup], keepPID: pid_t?, keepWin: Int,
                        forceReshoot: Bool = true, resizeWindow: Bool = true) {
        reconcileMinimizedMarks(raw)
        applyList(mergeRefreshed(raw), keepPID: keepPID, keepWin: keepWin,
                  forceReshoot: forceReshoot, resizeWindow: resizeWindow)
    }

    /// 一局之内**顺序冻结**:本局的 App 顺序在开局那一刻定下(开局那次才走 MRU 排序),
    /// 中途任何动作都只改"窗",不改"位"。
    ///
    /// 病例(2026-09-14 用户实报):H 之后图标先消失又出现,整条栏跟着重排 ——「乱跳」,
    /// 期望是「位置不变,只是窗口消失了」。根因就是重枚举后又**按 MRU 排了一遍**,
    /// 而动过手之后 MRU 必然变(刚碰过的 App 排到最前)。
    /// macOS 自己的行为也是这样:按住 ⌘ 期间顺序是死的,MRU 只在**开局**那一刻起作用。
    private func mergeRefreshed(_ raw: [AppGroup]) -> [AppGroup] {
        // 只用来决定"本局中途新冒出来的 App"排哪 ⇒ 同样按本局的屏 ✓
        let fresh = WindowEnumerator.orderByMRU(raw, on: contextScreen ?? NSScreen.main ?? NSScreen.screens[0])
        var byPID: [pid_t: AppGroup] = [:]
        for g in fresh { byPID[g.pid] = g }
        var merged: [AppGroup] = []
        var seen = Set<pid_t>()
        for old in groups {
            seen.insert(old.pid)
            if hiddenPIDs.contains(old.pid) {
                // 被我们隐藏:窗当帧就没了,但系统那边的重枚举这 0.2–0.3s 还在骗我们
                merged.append(AppGroup(pid: old.pid, appName: old.appName,
                                       bundleID: old.bundleID, windows: []))
            } else if let f = byPID[old.pid] {
                // 位置不动,只换内容(窗多了少了都还在这格)。但**我们刚摘掉的窗**要按住,
                // 否则 0.2s 后它诈尸回来一次(见 purgedWIDs 的病例)
                let kept = f.windows.filter { !purgedWIDs.contains($0.wid) }
                if kept.isEmpty {
                    // ★ **窗全没了 ≠ App 没了**(2026-09-20 用户:「cmd w 只是关闭窗口,
                    //    不需要从环里杀掉」):W 关掉最后一扇窗后,进程还活着 —— 它是
                    //    无窗应用(T15),**原地保留**(顺序冻结,不挪窝),只清空窗卡。
                    //    App 真死了的话(有的 App 关末窗即退出),下一次重枚举自然摘它
                    if NSRunningApplication(processIdentifier: old.pid)?.isTerminated == false {
                        merged.append(AppGroup(pid: old.pid, appName: old.appName,
                                               bundleID: old.bundleID, windows: []))
                    }
                } else {
                    merged.append(kept.count == f.windows.count ? f
                                  : AppGroup(pid: f.pid, appName: f.appName,
                                             bundleID: f.bundleID, windows: kept))
                }
            }
            // 不在 fresh 里 = 这个 App 真的没了(退出)→ 丢掉
        }
        for g in fresh where !seen.contains(g.pid)
            && !hiddenPIDs.contains(g.pid) && !quitPIDs.contains(g.pid) {
            // ★ 无窗条目(T15)照样收 —— 原来的 `guard !kept.isEmpty` 把它拦掉了,
            //   W 之后 0.18s 的重枚举明明带回了它,却没请回环里(用户实报"被杀")
            let kept = g.windows.filter { !purgedWIDs.contains($0.wid) }
            guard !kept.isEmpty || g.windows.isEmpty else { continue }
            // 本局中途新出现的 App 挂到**尾部**:不插队,免得又跳一次
            merged.append(kept.count == g.windows.count ? g
                          : AppGroup(pid: g.pid, appName: g.appName, bundleID: g.bundleID, windows: kept))
        }
        return merged
    }

    /// 列表落地(内容 → 屏幕):钳选中、剪缓存、重拍、重排长条与托盘。
    private func applyList(_ fresh: [AppGroup], keepPID: pid_t?, keepWin: Int,
                           forceReshoot: Bool = true, resizeWindow: Bool = true) {
        guard !fresh.isEmpty else {
            dismiss(reason: "处决后无窗可切")
            return
        }
        groups = fresh
        if let keepPID, let ai = fresh.firstIndex(where: { $0.pid == keepPID }) {
            appIndex = ai
        } else {
            appIndex = min(appIndex, fresh.count - 1)
        }
        let windowCount = fresh[appIndex].windows.count
        winIndex = min(keepWin, max(windowCount - 1, 0))
        // ⚠️ 2026-10-20 崩过一次,别再这么写:把这几笔包进 `withAnimation` 会让
        //   "列表变化 + 选中变化 + 同一拍里的 setFrame(35ms)"一起进显示刷新 ⇒ AppKit 在
        //   `__NSWindowGetDisplayCycleObserverForLayout` 里 abort:
        //   "The window has been marked as needing another Update Constraints in Window pass…"
        //   ⇒ 想给 ⌘Q 做"滑块滑过去"的动效,只能动**纯绘制**的东西(puck 的 offset),
        //     不许动列表/窗口尺寸 ✗
        // 列表变了 → 截图重拍。同样**剪枝不清场**:别的窗的图还有效,只有被处决那扇会被剪掉
        // (T87 v3 起交给 `reapAlive()`:后台全量保活,被处决的窗在系统清单里消失即被 reap)
        Snapshotter.shared.reapAlive()
        let shown = groups.first?.windows ?? []
        let shownIDs = Set(shown.map(\.wid))
        Snapshotter.shared.precapture(shown, force: forceReshoot)
        Snapshotter.shared.precapture(groups.flatMap { $0.windows }.filter { !shownIDs.contains($0.wid) })
        // ★★ 2026-09-25 病例(用户实报「面板偶发超长,伸到屏幕外面去了」):
        //   sessionCap 原来只在 finishBegin 按**当时的 App 数**算一次,而这里每次刷新都按
        //   paddedSize() 重开窗框 —— 局中 App **变多**(「陈旧名单先上屏」⇒ 枚举带回更多;
        //   钉住期间新 App 冒头)⇒ 窗框按旧 cap 一路撑出屏外 ✗
        //   ⇒ 局中**只收紧、不放松**:重算一次,更紧才采纳(变少 ⇒ 保持原档,
        //     图标不当着用户的面跳大;trayMaxContentSize 的"整局不变"也一并守住 ✓)
        let savedCap = PanelMetrics.sessionCap
        let savedTrayCap = PanelMetrics.trayCap
        let savedTrayMax = trayMaxContentSize
        recomputeSessionFit(on: contextScreen)
        if PanelMetrics.sessionCap >= savedCap {
            PanelMetrics.sessionCap = savedCap
            trayMaxContentSize = savedTrayMax
        } else {
            trace(String(format: "[尺寸] 局中名单变多 ⇒ 收紧 %.2f → %.2f(玻璃不超屏)",
                         savedCap == .greatestFiniteMagnitude ? -1 : savedCap, PanelMetrics.sessionCap))
        }
        // ★ 托盘那把尺子同上:**只收紧、不放松**(卡片不当着用户的面变大 ✓)
        if PanelMetrics.trayCap >= savedTrayCap { PanelMetrics.trayCap = savedTrayCap }
        // App 数可能变了 → 长条尺寸变、托盘内容也换;两窗各自就位(banner 不滑)
        // ★ 环变短这一拍**可以不动窗框**(2026-10-20 用户:「环的长度缩短没有动画,是直接生硬地缩短」):
        //   窗框保持不变 ⇒ 玻璃在窗里居中、按 SwiftUI 动画**平滑收窄** ⇒ 有动画、又碰不到
        //   AppKit 的窗口 resize(那一族正是 Update Constraints 崩溃的来源 ✗)。下一局开局再按新尺寸就位 ✓
        if resizeWindow, let panel, let target = centerFrame(for: paddedSize()) {
            setFrameIfNeeded(panel, target)
        }
        updatePreview()
        lastSessionGroups = groups   // 名单已刷新 ⇒ 陈旧副本跟上(否则下一局先上屏的是更旧的 ✓)
        print("[处决后] \(groups.count) 个 App,选中 [\(appIndex + 1)/\(groups.count)] \(groups[appIndex].appName)")
        trace("[T12] 处决后顺序 [\(groups.map(\.appName).joined(separator: " | "))]")
    }

    /// 确认 = 唯一的"生效"动作:聚焦选中的那一扇窗(CONTEXT.md「确认」)。
    /// 到达路径:未钉住时松 ⌥;钉住时 Enter。
    /// 点启动行某一格 = 启动它并散场。
    ///
    /// **刻意不走 hoverLaunch/confirmSelection**:指针要从面板的入口槽挪到托盘(另一个窗口),
    /// 中间会经过"离开面板"的一段,`entrySelected` 可能已被复位 ⇒ `hoverLaunch` 的
    /// `guard entrySelected` 挡下 ⇒ `launchIndex` 留不下来 ⇒ `confirmSelection` 静默 no-op。
    /// 用户实报「那俩 app 也点不了」就是这么来的 —— 点击必须自带它的对象,不靠 hover 的记忆。
    func launchAt(_ i: Int) {
        guard launchables.indices.contains(i) else { return }
        let app = launchables[i]
        glog("[T83] 启动未启动 App: \(app.name)(\(app.path))")
        dismiss(reason: "确认(启动 \(app.name))")                  // ★ 先收面板 ✓
        DockAppsProvider.launch(at: app.path)
    }

    /// ## ⚡ 关闭顺序:**先收面板,再聚焦**(2026-09-22 用户实报「关闭不干脆, 慢一拍 / 像有残留」)
    ///
    /// 旧顺序是 `WindowFocuser.focus(...)` 然后 `dismiss(...)` ✗ —— 而聚焦要等一次**激活往返**
    /// (实测 30–51ms:`→ emit confirm` 到 `[T7] 已聚焦`),这期间面板还挂在屏幕上 ✗
    /// ⇒ 观感就是"松手了, 面板还赖着" ✓(而且目标 App 已经在往前台动画,面板浮在上面更像残留 ✓)
    /// 新顺序:先 `orderOut`(啪一下就没 —— 与"取消淡出"那次的用户口径一致 ✓),**之后再聚焦** ✓
    /// 代价:旧 App 会露出来几十毫秒 —— 那正是原生切换器的观感,也是用户要的"跟手" ✓
    func confirmSelection() {
        finishRingFlip()   // 同上:点击/回车都可能在翻牌途中到(判定按目标环 ✓)
        // 启动区(方案 E):入口槽选中 = 没有可生效之物(它在等用户进到某格),no-op;
        // 启动图标选中 = **启动并激活**,面板即关(与「确认」的"生效即散场"同款)。
        // 启动失败的兜底在 DockAppsProvider.launch 的日志里 —— 面板已经关了,不回头等
        if entrySelected {
            // ⚠️ 这里**不能**裸 return:用户实报「选中这个之后, 松手, 不消失了」。
            // 松开触发键 = 本局结束 ⇒ **所有**确认路径都必须散场(生效即散场)。
            // 只选中入口槽、还没进到某格 = 没有可生效之物,但面板照样要关。
            guard let j = launchIndex, launchables.indices.contains(j) else {
                dismiss(reason: "确认(入口槽,未进到某格)")
                return
            }
            let app = launchables[j]
            glog("[T83] 启动未启动 App: \(app.name)(\(app.path))")
            dismiss(reason: "确认(启动 \(app.name))")              // ★ 先收面板 ✓(启动要等几百 ms ✗)
            DockAppsProvider.launch(at: app.path)
            return
        }
        guard listReady else {
            // 名单还在后台枚举 ⇒ **记下意图**,等 finishBegin 兑现 ✓
            confirmBeforeList = true
            let gen = beginGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.beginGeneration, self.confirmBeforeList else { return }
                self.confirmBeforeList = false
                self.dismiss(reason: "确认(等名单超时 0.6s)")
            }
            confirmWaitWork?.cancel()
            confirmWaitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            trace("[T6] 确认(名单未到 ⇒ 记下意图,等枚举落地就兑现)")
            return
        }
        guard groups.indices.contains(appIndex) else {
            dismiss(reason: "确认(空列表)")
            return
        }
        let g = groups[appIndex]
        // 被 H 隐藏的组:**不许**落到下面那条"无窗应用 = 激活"上 ——
        // 那正是用户实报的原 bug(松开 ⌥ 又把刚隐藏的 App 唤起来了)。本轮到此结束,什么都不动。
        if hiddenPIDs.contains(g.pid) {
            glog("[T29] 选中的组已被隐藏:本轮结束,不唤起它")
            dismiss(reason: "确认(已隐藏)")
            return
        }
        // ★ 本局**被我们缩小过的** App:松开时**什么都不做**(照 H 的先例 ✓)
        //   病例(2026-09-22 用户实报):「cmd m 会缩小…松开之后会立马把缩小的窗口又换起来」✗
        //   ⇒ 它此刻是"无窗应用"(窗都收进 Dock 了 ✓),而下面那条会把 App 激活 ⇒ 系统把窗抬回来 ✗
        //   判据:该 App **在本局**被我们缩小过 ∧ 它在本屏已经没有可选的窗 ✓(还有别的窗就照常切 ✓)
        //   ⚠️ 必须用**会话账**(`sessionMinimizedPIDs`)而不是常驻的记号表 ✗ ——
        //     2026-09-22 用户第二条实报:「关闭再唤起之后, 选中 app 拉不起窗口了」✗
        //     就是拿常驻表当守卫的后果:另起一局再确认也什么都不做 ✗
        //     ⇒ **本局不唤醒**(那次缩小不算白按 ✓)、**下一局能唤醒**(用户的手已离开键盘 ✓)
        if sessionMinimizedPIDs.contains(g.pid), g.windows.isEmpty {
            dismiss(reason: "确认(刚被缩小收纳 ⇒ 不唤醒它)")
            return
        }
        // 无窗应用(T15)不是"空列表"——确认 = 激活(App 自己处理开窗与还原)
        if !g.windows.indices.contains(winIndex) {
            dismiss(reason: "确认(无窗应用)")                       // ★ 先收面板 ✓
            WindowFocuser.focusWindowlessApp(pid: g.pid, contextScreen: contextScreen)
            return
        }
        let w = g.windows[winIndex]
        dismiss(reason: "确认")                                     // ★ 先收面板 ✓
        WindowFocuser.focus(window: w)
    }


    /// 面板外点击 = 放弃(CONTEXT.md)。钉住模式下不装——要的就是能切出去截图
    ///
    /// **两个监听都要装**(2026-09-15 病例:"点面板周围的空白区域不关闭"):
    /// - **全局**监听收"落到别的 App / 桌面"的点击;
    /// - **本地**监听收"落在我们**自己**窗口里"的点击 —— 透明呼吸区只是
    ///   `ClickThroughHostingView.hitTest` 返回 nil(不吃点击),但 AppKit 里这**不会**把事件转给下层
    ///   的 App ✗;面板又是 nonactivating,事件也不进任何 view ✗。于是这一格点击既不属于"别的 App"
    ///   (全局监听收不到),也没人处理 —— 直接掉在地上,用户看到的是"点空白处没反应"。
    /// 两者共用同一条判据 `OutsideClickRule`(纯核 + 单测)。
    func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // 本地:自己窗口的点击(**能吞**)——点空白就是关面板,不该顺手把下层那个 App 也点开。
        // 同时它也是仲裁账本的采样点:**点击 = 指针发言**(点格选中/点红绿灯必须能立即接管,
        // 哪怕之前一直是键盘在操作)。同步记账 —— 手势处理在同一轮事件里紧随其后,异步就输了
        // ⚠️ 2026-09-19:长条→托盘的点击矛盾不用事件转交解(试过 `sendEvent` 重投 —— 合成事件
        // 进了托盘但 SwiftUI 手势不认,down/up 双双无声)。改用**合成器闸**(见 updateStripClickGate):
        // 指针进托盘玻璃时长条对 WindowServer 隐身,点击由系统直接送托盘 —— 全程真实事件。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if isTraceEnabled {
                let inTray = self.previewContentRect()?.contains(NSEvent.mouseLocation) ?? false
                let inStrip = self.panelContentRect()?.contains(NSEvent.mouseLocation) ?? false
                let m = NSEvent.mouseLocation
                let pf = self.previewPanel?.frame ?? .zero
                glog("[T6] 本地点击 全局=(\(Int(m.x)),\(Int(m.y))) win=\(event.windowNumber) [长=\(self.panel?.windowNumber ?? -1) 托=\(self.previewPanel?.windowNumber ?? -1) 托可见=\(self.previewPanel?.isVisible ?? false) 托框=\(Int(pf.minX)),\(Int(pf.minY)),\(Int(pf.maxX)),\(Int(pf.maxY))] 托盘内=\(inTray ? "是" : "否") 长条内=\(inStrip ? "是" : "否") 长闸=\(self.panel?.ignoresMouseEvents ?? false)")
            }
            self.notePointerClick()
            return self.dismissIfClickOutside() ? nil : event
        }
        if pinPanel { return }

        // 全局:别人的点击,吞不掉(全局监听没有返回值的权力)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dismissIfClickOutside()
            }
        }
    }

    /// 判"这一下点击在不在面板外";在的话关面板并返回 true。判据见 `OutsideClickRule`:
    /// **判玻璃,不判窗口** —— 窗口比玻璃大(透明呼吸区),而托盘还可能按整局最大布局开得更大
    /// (以前把托盘的呼吸区当成"里",点红绿灯就被误关,2026-09-14 实机现形)。
    @discardableResult
    private func dismissIfClickOutside() -> Bool {
        guard let panel, isVisible else { return false }
        let point = NSEvent.mouseLocation
        let panelRect = panel.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
        guard OutsideClickRule.isOutside(point: point, panelContent: panelRect,
                                         trayContent: previewContentRect()) else { return false }
        dismiss(reason: "面板外点击,放弃")
        return true
    }

    /// **长条→托盘的合成器闸**(2026-09-19,Bug2 终审):
    /// 托盘被故意压一层(popUpMenu - 1,demo 让长条盖住托盘的阴影尾 —— 黑影防线),而长条
    /// 整窗框带 108pt 呼吸区、与托盘玻璃大幅重叠(实测盖进下排卡片 ~185pt)。落在这条带里的
    /// 点击被 WindowServer 送给长条;长条 hitTest 在呼吸区返回 nil,**事件就地落地** ——
    /// 一锤定音账:`z序=长前托后 长hit=nil 托hit=ClickThroughHostingView`。
    /// 单行托盘的卡片在带外(一直好使),多窗口 App 撑出两行 → 下排整排在死区
    /// —— 用户实报「多窗口 App 的第二张卡要点两遍」,实为**永远点不着**。
    ///
    /// 修法:指针进托盘玻璃时把长条 `ignoresMouseEvents = true`(WindowServer 整窗跳过,
    /// 点击落到下层唯一的自家窗 = 托盘,**真实事件原路进 SwiftUI**);离开玻璃就还回来。
    /// 两扇窗的视觉 z 序一字不动,黑影防线保留。副作用审视:
    ///   · 闸开期间长条收不到任何鼠标事件 —— 指针在托盘玻璃里,本来就轮不到长条,无损;
    ///   · 翻闸有 ≤16ms 帧拍延迟 —— 极快的"划出即点"可能吞一下长条点击,点击先要有
    ///     位移、位移先被帧拍看到,实测窗口足够大;
    ///   · hover 不受影响(长条/托盘的选中都是帧拍几何算的,不靠事件)。
    /// 事件转交方案(重建 NSEvent 重投 `sendEvent`)实测无效 —— 合成事件进了托盘但
    /// SwiftUI 手势不认,down/up 双双无声 —— 别再走回头路。
    func updateStripClickGate() {
        let shouldGate = isVisible
            && previewPanel?.isVisible == true
            && (previewContentRect()?.contains(NSEvent.mouseLocation) ?? false)
        guard shouldGate != stripClickGateOn else { return }
        stripClickGateOn = shouldGate
        panel?.ignoresMouseEvents = shouldGate
        if isTraceEnabled {
            glog("[T6] 长条点击闸 \(shouldGate ? "开(指针在托盘玻璃,点击让给托盘)" : "关")")
        }
    }

    func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        localClickMonitor = nil
    }
}
