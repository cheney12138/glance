import AppKit
import GlanceCore
import SwiftUI

// ⚠️ 2026-10-16 重构清单第 9 条:从 PanelController.swift 平移而来 ✓
//   **纯代码搬移,零行为变化** ✓ —— 同类 extension,同层(Panel ✓)架构检查不变 ✓
//   存储属性已回迁主类(extensions 不能有存储属性 ✗)✓

extension PanelController {
    // MARK: - 预览浮窗(分容器构型:与主面板同皮不同窗,中心正对选中 App 头顶)

    // MARK: - 预览浮窗(分容器构型:与主面板同皮不同窗,中心正对选中 App 头顶)

    func buildPreviewPanelIfNeeded() {
        guard previewPanel == nil else { return }
        previewPanel = makeChromePanel(keyable: false)
        if let previewPanel { trayChrome = ChromeWindow(previewPanel, role: "托") }
        // 托盘低一层:它向下的阴影尾会伸进长条的呼吸区,demo 里长条(后一个兄弟)盖住托盘阴影,
        // 托盘在上就会把那层灰纱糊到长条玻璃顶上——"黑影"换个地方复活
        // (2026-09-19 Bug2 期间做过"翻到长条前面"的判别实验,已还原:点击死区由
        // `updateStripClickGate` 的合成器闸解决,不需要动 z 序)
        previewPanel!.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        let hosting = ClickThroughHostingView(rootView: PreviewPanelView(controller: self, snapshotter: Snapshotter.shared))
        hosting.pad = PanelMetrics.shadowPadPop
        hosting.autoresizingMask = [.width, .height]
        previewPanel!.contentView = hosting
        previewHostingView = hosting
    }

    /// 托盘内容尺寸 = 题头行 + 一排 128 缩略图 + 内边(16/18/14)。
    /// 与 PreviewPanelView 的 .frame(previewContentSize) 同源。
    /// 带参数的版本给"本会期尺寸上限"用:它要量**所有组**里最宽的那个,而不是当前选中组。
    /// T88:卡宽随窗比例,尺寸按每张卡的实际宽算(不再有 count × 定尺的省事)
    func previewContentSize(for group: AppGroup?) -> NSSize {
        guard let group, !group.windows.isEmpty else { return .zero }
        // ★ 轨道版式(ADR-0017)有自己的尺寸账 —— 此前只有行算术 ⇒ 玻璃只包住卡,
        //   轨道悬在玻璃外;且窗框追内容连跳数帧 = 「小→大」阶梯(用户录屏逐帧实锤)✗
        if WindowLayout.current == .rail, group.windows.count > 1 {
            let sizes = Self.cardSizes(group.windows)
            // ★ 与视图同源:槽宽 = **选中卡宽**(2026-10-26,消掉卡与轨道之间那道缝 ✓)
            //   选中项不在这一组里(换组那一拍)⇒ 退回组内最宽卡(当拍的过渡值)
            let selIdx = min(max(winIndex, 0), max(group.windows.count - 1, 0))
            let selectedGroup = (currentGroup?.bundleID == group.bundleID)
            let slotW = (selectedGroup ? (sizes[selIdx].width) : (sizes.map(\.width).max() ?? 0))
            let cardH = (selectedGroup ? sizes[selIdx].height : (sizes.map(\.height).max() ?? 0))
            return NSSize(
                width: slotW + PanelMetrics.thumbGap + PanelMetrics.chipRailWidth + PanelMetrics.trayPadX * 2,
                height: PanelMetrics.trayPadTop + cardH + PanelMetrics.trayPadBottom + PanelMetrics.trayBottomBreath
            )
        }
        let sizes = Self.cardSizes(group.windows)
        // 一行里的卡**按各自的真实宽**(形状随窗,ADR-0014)⇒ 尺寸账/排布/命中是同一把尺子
        let widths = sizes.map(\.width)
        let (rows, cols) = trayLayout(widths: widths)
        // 高度 = 各行最大卡高之和 + 行距(卡片大小不一 ⇒ 不能用"行数 × 常量" ✗)
        let rowH = Self.rowHeights(sizes, rows: rows, cols: cols)
        return NSSize(
            width: Self.maxRowWidth(widths, rows: rows, cols: cols) + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop
                + rowH.reduce(0, +) + max(CGFloat(max(rows, 1)) - 1, 0) * PanelMetrics.trayRowGap
                + PanelMetrics.trayPadBottom
                // ★ 2026-10-13:容器与环之间那**固定的一段空气** ✓
                //   (内容贴底摆 ⇒ 不论几行,芯片到环的距离一样 ✓;它不进 `trayFitScale` ✓)
                + PanelMetrics.trayBottomBreath
        )
    }

    /// 启动行(方案 E v2)的托盘尺寸:**主环的图标节距**(icon + iconGap),不是窗口卡的壳 ——
    /// v1 借窗口卡壳被用户实评否决(「丑的要死」:一枚小图标浮在大灰卡上,空得难受)。
    /// v2 = 第二条主环,尺寸数学与主环同源
    func previewContentSize(launchCount n: Int) -> NSSize {
        guard n > 0 else { return .zero }
        let (rows, cols) = launchLayout(count: n)
        let c = CGFloat(cols)
        let r = CGFloat(max(rows, 1))
        return NSSize(
            width: c * PanelMetrics.pitch - PanelMetrics.iconGap
                + PanelMetrics.trayPadX * 2,
            height: PanelMetrics.trayPadTop + r * PanelMetrics.icon
                + max(r - 1, 0) * PanelMetrics.trayRowGap + PanelMetrics.trayPadBottom
                + PanelMetrics.trayBottomBreath
        )
    }

    /// 启动行的行 × 列:与 `trayLayout` 同一套"放得下的最少行数"逻辑,只是格距换成图标节距。
    /// (数学同源,不许各算各的 —— 同 trayLayout 头上的那条规矩)
    func launchLayout(count n: Int) -> (rows: Int, cols: Int) {
        TrayGrid.fitRows(count: n,
                         cellPitch: PanelMetrics.pitch,
                         padW: PanelMetrics.trayPadX * 2 - PanelMetrics.iconGap,
                         roomW: trayRoomW,
                         maxRows: PanelMetrics.trayMaxRows)
    }

    /// 当前托盘该显示的内容的尺寸(窗口卡 / 启动行,随选中格切换)
    func previewContentSize() -> NSSize {
        return entrySelected ? previewContentSize(launchCount: launchables.count) : previewContentSize(for: currentGroup)
    }

    /// 托盘窗几何的**唯一来源**(P0-2):尺寸与原点都在 `TrayGeometry` 里算,这里只负责喂输入。
    /// 原来这里有一份"窗口尺寸"的算法 —— 它与 `previewFrame()` 的 x、与视图的内容尺寸是三本账,
    /// 只要取整规则或取数来源差一点就互相改(实机:一局 100+ / 104 / 335 次重排)⇒ 已并入 TrayGeometry ✓。
    /// 面板**内容**(玻璃)在本屏坐标里的矩形。面板窗口 = 内容 + 四周 shadowPadStrip,所以窗口往内收
    /// 一圈就是玻璃。与 `previewContentRect()` 同一个口径(ADR-0006 的推论:凡判"指针/点击在不在"都用内容矩形)。
    func panelContentRect() -> NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.frame.insetBy(dx: PanelMetrics.shadowPadStrip, dy: PanelMetrics.shadowPadStrip)
    }

    /// 托盘**内容**(玻璃)在本屏坐标里的矩形。窗口可能比内容大,所以凡是判"托盘在哪"的地方
    /// (指针重定位、面板外点击)都必须用这个,不能用窗口 frame。
    func previewContentRect() -> NSRect? {
        guard let p = previewPanel, p.isVisible else { return nil }
        // ★★ 2026-10-08 病例(用户:「之前修复过的有个 bug 又出现了 —— 切换到未启动环,选中一个 app 之后,
        //   指针在**面板之外**移动 hover,也能做 app 选中」):
        //   未启动环里托盘**没有内容** ⇒ 走 `previewFrame() == nil` 那条路 ⇒ 内容隐藏
        //   (`alphaValue = 0` + `ignoresMouseEvents = true`,2026-09-21 为了省掉窗口排序而定 ✓)。
        //   但它的**窗口还留在台上** ⇒ `isVisible` 仍是 true ✗ ⇒ 这个函数照样吐出一块
        //   **看不见的地板**的矩形 ✗ ⇒ 三个消费者全中招:
        //     · `resyncSelectionUnderPointer()` ⇒ 指针在面板之外(那扇隐藏托盘的位置)照样改选中 ✗
        //     · 点击闸(`长条点击闸 开…点击让给托盘`)⇒ 点那块空地会把 app **启动**掉 ✗
        //     · 面板外点击判据 ⇒ 拿它当"点在托盘里" ⇒ 该收场时不收场 ✗
        //   真机复现(2026-10-08):托盘 window layer=100 **alpha=0.00**,日志却打
        //   `[T6] 视图挪位后指针重定位(启动区): [3/5] JetBrains Toolbox`,松手直接把它启动了 ✗
        //   ⇒ 收口收在**门口**(这个函数),而不是去每个调用方补一行 ——
        //     调用方以后还会加,门口的判据只有一个 ✓(同一课:见 previewFrame 头注的"守卫住在门口")
        if trayChrome?.isContentHidden ?? false { return nil }
        guard p.alphaValue > 0.01, !p.ignoresMouseEvents else { return nil }   // 双保险:与上面同源 ✓
        let c = previewContentSize()
        guard c.width > 0, c.height > 0 else { return nil }
        // 内容在窗口里:水平居中、**底部对齐**(与窗口等尺寸时 = 今天的布局,一个像素不差)
        return NSRect(x: p.frame.midX - c.width / 2,
                      y: p.frame.minY + PanelMetrics.shadowPadPop,
                      width: c.width, height: c.height)
    }

    /// 托盘出屏的兜底日志:一个会期只喊一次(见 `previewFrame`)
    /// 托盘本局是否已经上屏过(只为上面那行日志:区分"首次渐入"与"后续更新" ✓)

    /// 托盘正中 = 长条正中(demo 的 .switcher-wrap 是 column 居中,托盘不跟图标滑移);
    /// 超界时**只在玻璃层面**收进语境屏;视觉缝 = seam。
    ///
    /// ★ 2026-09-14 修「窗口一多,最左边那张预览卡被推出屏幕」:
    ///
    /// 旧写法是 `min(max(desired, area.minX + 12), area.maxX - size.width - 12)` —— 边界里的
    /// `size` 是**窗口**宽 = 玻璃 + 两侧 `shadowPadPop`(96pt)的**透明呼吸区**。透明区根本不渲染,
    /// 它越出屏幕什么也看不见,拿它算"放不放得下"是算错了对象;更要命的是**呼吸区一旦把可用宽吃穿,
    /// 两条边界就反向**(lo > hi),`min(max())` 静默退化成"把右缘钉在 area.maxX - 12":
    ///
    ///   实测(14" MBP,屏宽 1512,6 扇窗 → 会话上限把 scale 收到 113.5%):
    ///     玻璃 1464 + 呼吸区 192 = 窗口 1656  >  可用 1488
    ///     → 窗口 x = -156,玻璃左缘 **-60**,右缘 1404(离屏右还白空 108)
    ///     → 最左那张卡左缘 -35:卡被切掉 35pt,托盘的左圆角与左边距整片出屏,右侧却对着空气
    ///
    /// 现在把约束换成玻璃:只要玻璃放得下(会话上限保证了这一点),**一定居中且不出屏**。
    private func previewFrame() -> NSRect? {
        // 入口槽选中时托盘显示启动行,与"当前组有窗"互斥地撑起托盘 T91:换环后环里就是那些 App,托盘**收起**(它们没有窗可预览)。
        // ⚠️ 2026-09-17:说话时**不要**让托盘出现 —— 用户实拍「先出现了 2 个芯片」,
        // 而且托盘那本尺寸账与面板不同源 ⇒ 紧接着就是 Update Constraints 崩溃。
        // 芯片只由面板那一扇窗承担。
        //
        // ★ 守卫必须住在**这里**(2026-09-17 修「预览窗岿然不动」):说话局的 orderOut
        // 曾经写在 finishBegin 里,而 showPanel 末尾的 updatePreview() 会把它**再拉起来**
        // (托盘上屏的唯一入口就是 updatePreview → 这里)。补丁打在调用方 = 每个新调用点
        // 都会让 bug 复活;打在门口 = 谁来都出不去。
        // 🔬 调试键 debug.hideTray:整个托盘不出现(用来**单测纯环上浮**是否掉帧)。
        //   放在门口(与下面那批守卫同一处)—— 打在这里,任何调用方都绕不过去。
        //   `defaults write com.cheney12138.macswitcher debug.hideTray -bool true` / delete 即装回
        guard !DebugFlags.hideTray else { return nil }
        guard hintText == nil, !entrySelected, expandedCount > 0, let panel,
              let area = contextScreen?.visibleFrame else { return nil }
        // ★ P0-2:几何**只问一处**(TrayGeometry)。这里不再算尺寸/位置,也不做取整 ——
        //   取整规则(尺寸向上、原点向下)住在那个类型里,别处改了也不会分叉 ✓。
        // ★★ 2026-10-13 用户裁定(第三、四次明说):「变化的始终是容器的宽和高」——
        //   改前用 `trayMaxContentSize`(本局**所有组**里最大的那个内容)⇒ 容器/玻璃按本局最大撑开 ✗
        //   病例(用户实拍访达那组 8 窗):
        //   ```
        //   窗=2625x505 · 内容=285x184 · 本局max=2432x344
        //   ⇒ 玻璃比卡片宽出一大截 ⇒ 用户:「太宽了, 收窄一点」/「边距还是有问题」✓
        //   ```
        //   ⇒ 改成**跟着当前组**收(入口槽那扇也一样 ⇒ 用 `previewContentSize()` ✓,它已按选中状态分支 ✓)
        //   ⚠️ 代价(与旧 ADR-0006 相反,已请用户确认 ✓):换组时会**改一次窗框尺寸**
        //      ⇒ 实测这个动作用 0.1–0.4ms(主线程 ✓),且内容贴底 ⇒ 位置不动、只有玻璃左右收 ✓
        //     —— 即“旧口径:窗框是一局的不变量”改成了“窗框跟着当前组走” ✓
        // 删窗重排的那 ~0.34 秒:**窗框完全冻结**(返回上一帧的框)。
        //   卡片这时还画在旧位置上,窗一收就会把它们裁掉;而"按新内容重算"还会连带改位置/比例 ✗
        if CFAbsoluteTimeGetCurrent() < trayFrameHoldUntil, let held = heldTrayFrame { return held }
        let maxContent = previewContentSize()
        // 居中时按**整块屏幕**算(用户口径「相对整个屏幕」);常规会话仍用可见区 ✓
        let areaForTray = (windowsOnly ? (contextScreen?.frame ?? area) : area)
        let geo = TrayGeometry(maxContentSize: maxContent, panelFrame: panel.frame, screenArea: areaForTray,
                               centeredOnScreen: windowsOnly)
        if maxContent.width > area.width - PanelMetrics.screenMargin * 2, !trayOverflowLogged {
            trayOverflowLogged = true
            glog("[尺寸] 托盘玻璃 \(Int(maxContent.width))pt > 可用 \(Int(area.width - PanelMetrics.screenMargin * 2))pt,已居中(两端会被切)")
        }
        if windowsOnly, isTraceEnabled {
            let f = geo.frame
            let cf = areaForTray
            let pad = PanelMetrics.shadowPadPop
            // 只印**内容中心 vs 屏幕中心**(窗里含透明阴影 pad,那个不该参与视觉判断)
            let contentCenterY = f.minY + pad + maxContent.height / 2
            glog(String(format: "[居中] 屏=%.0fx%.0f@%.0f,%.0f 中心=(%.0f,%.0f) · 窗心=(%.0f,%.0f) · 差=(%.0f,%.0f)",
                        cf.width, cf.height, cf.minX, cf.minY, cf.midX, cf.midY,
                        f.midX, f.midY, f.midX - cf.midX, f.midY - cf.midY))
        }
        return geo.frame
    }


    func updatePreview() {
        // ★ 上屏前**先用池子里的上一帧垫上**(同一条管线 ⇒ 之后切到新的实时帧看不出变化)。
        //   病例(2026-10-20 用户实测):「一个一个切过去到 Sublime 正常,**直接跳过去**就闪」——
        //   直跳时新组的卡没有任何实时帧 ⇒ 只能先画静帧,首帧到了再切 ⇒ 半透明窗 alpha 差现形 ✗
        for w in (currentGroup?.windows ?? []) where LivePreviewPool.shared.box(for: w.wid).image == nil {
            if let cached = LivePreviewPool.shared.cachedFrame(for: w.wid) {
                LivePreviewPool.shared.box(for: w.wid).image = cached
            }
        }
        // 🔬 分段计时(2026-09-21):"指针换选中 13–30ms"到底花在哪一段 —— 只在总量 >3ms 时打一行。
        //   病例:托盘更新平时 0.30ms ✓,但 176 个样本里 13 个 ≥10ms ✗;两个图像缓存都没干掉它 ⇒ 拆段量。
        let __t0 = CFAbsoluteTimeGetCurrent()
        var __prev = __t0
        var __segs: [String] = []
        func __mark(_ s: String) {
            let n = CFAbsoluteTimeGetCurrent()
            __segs.append(String(format: "%@ %.1fms", s, (n - __prev) * 1000))
            __prev = n
        }
        // ★ S1 接线:把"当前该活的窗口"交给流池(它只管起流收帧,不参与绘制)。
        //   选这里是因为 updatePreview 是**唤起 + 每次换 app/换窗**的唯一公共出口。
        // 卡片底图预缩放到"卡片像素尺寸"⇒ 托盘重建时不再 decode/缩放(见 CardImageCache)。
        // 目标尺寸 = 卡片那套"不放大"的口径(与视图里的 imageBox 同一算法,免得预热出的图与绘制不一致)。
        // (「座」的模糊预热门已随座整体退役 —— 2026-09-24 深夜遮罩改成容器自己的静态雾檐,
        //   见 `PanelColors.thumbHaze`;垫图(S2'')同日退役 ⇒ live 开时快照**不采也不显示**,
        //   这条预热只在快照链(live 关)下有意义 ✓。)
        // ★ 顺带修一处笔误(2026-09-24):下面原来手算 `min(1, max(宽比, 高比))` ✗ ——
        //   "不放大"的口径是 **min**(CardSizing.size ✓);max 会把图预热到**超过卡片高**的尺寸
        //   ⇒ 渲染时键对不上 ⇒ 预热整批白算。直接调同一个函数,不再手抄公式 ✓。
        if !LivePreviewPool.enabled {
            let shots = groups.flatMap { $0.windows }.compactMap { w -> (wid: CGWindowID, source: NSImage, target: CGSize)? in
                guard let img = Snapshotter.shared.cache[w.wid] else { return nil }
                return (wid: w.wid, source: img,
                        target: PanelMetrics.thumbSize(real: w.bounds.size, aspect: w.aspect))
            }
            CardImageCache.shared.prewarm(shots)
        }
        __mark("预热")
        if !entrySelected {
            // ★★ 2026-09-21 修正(S1.2 → S1.3):**只预热"当前这一组"的窗口**,不再预热整个环。
            // 病历(用户实报「卡的,要死,不仅唤起切换不流畅,选中之后打开也会卡半秒」):
            //   预热整个环 ⇒ 一局起 **13 条**捕获会话 ✗ ⇒
            //     ① 开场:13×40ms 错峰起流 ≈ 520ms(唤起不流畅)
            //     ② 收场:13 条会话一起拆(系统级工作)⇒ **确认后卡半秒**(日志 `全部停流 … 共 13 条`)
            //     ③ 稳态:13 条在采 ⇒ 切换不流畅
            //   ⇒ 换来的只是"hover 到任意 app 都零延迟";而池本来就有 **5s keepAlive** ✓ ⇒
            //     在同一批 app 之间来回 hover 根本不会重启流 ✓ —— 那个收益**不需要**全环预热 ✓。
            //   代价:第一次进某个 app,卡片会先显示静默态(实测首帧 36–74ms)✓ 可接受。
            // ★ A 修(2026-09-24):盒子随名单一起交给池 —— 出流像素规格的**输入**与卡片盒
            //   同一份账(`record.bounds` ⇒ `PanelMetrics.thumbSize` ✓),池不再从 SCWindow.frame 重算 ✗
            let items = (currentGroup?.windows ?? []).map {
                (wid: $0.wid, aspect: $0.aspect,
                 box: PanelMetrics.thumbSize(real: $0.bounds.size, aspect: $0.aspect))
            }
            if items.isEmpty {
                LivePreviewPool.shared.stopAll(reason: "环里没有窗口")
            } else {
                // 选中的那一扇按用户档位,其余 5fps(成本 = 1×档位 + (N-1)×5fps)
            let sel = currentGroup?.windows.indices.contains(winIndex) == true
                ? currentGroup?.windows[winIndex].wid : nil
            // ★★ 2026-10-27(用户:「做了这个功能之后 snapshot → live 的闪动更明显了」):
            //   ⌘` 的"只有窗口"那一局**只用静帧、不起直播流** ——
            //   二分已证明闪来自实时层(关掉实时帧 ⇒ 闪消失),
            //   而这种局只活几百毫秒、用户就是瞄一眼再松手选窗,直播的收益为 0 ✓
            //   Q:为什么不在全局关掉?—— ⌘Tab 那一局时间长、看着像"活窗口",那边保留直播 ✓
            if windowsOnly {
                LivePreviewPool.shared.stopAll(reason: "窗口局只用静帧")
            } else {
                LivePreviewPool.shared.sync(items, selected: sel)
            }
            }
        } else {
            LivePreviewPool.shared.stopAll(reason: "入口槽选中(启停生活动)")
        }
        __mark("池")
        let __tf = CFAbsoluteTimeGetCurrent()
        guard let frame = previewFrame() else {
            // ★★ 2026-09-21 定版:**没内容也不要 orderOut**。
            //   病例(分段计时):`orderFront` 在 hover 途中被调用 **27/33 次** ✗,托盘窗重排 157 次 ✗
            //   —— 因为"没内容"(hover 到无窗应用 / 说话局)时我 orderOut 了它,下一个 app 又 orderFront ✗
            //   每次窗口排序 4–24ms,且都落在滑块弹簧正在跑的那一帧 ⇒ 掉帧。
            //   ⇒ 改用 **alpha 0 + 忽略鼠标**:窗口留在台上,显/隐只是图层属性(微秒级 ✓)。
            //   真正的 orderOut 只留在**整局收场**那一处(现在由 ChromeWindow 的 teardown 承担)。
            trayChrome?.setContentHidden(true)      // 内容隐藏 = 只改图层属性(不再收窗,见 ChromeWindow)
            return
        }
        __segs.append(String(format: "previewFrame %.1fms", (CFAbsoluteTimeGetCurrent() - __tf) * 1000))
        __prev = CFAbsoluteTimeGetCurrent()
        let __tb = CFAbsoluteTimeGetCurrent()
        buildPreviewPanelIfNeeded()
        __segs.append(String(format: "buildPanel %.1fms", (CFAbsoluteTimeGetCurrent() - __tb) * 1000))
        __prev = CFAbsoluteTimeGetCurrent()
        guard let previewPanel else { return }
        // 换组只换内容,窗不滑(demo 行为);入场由 SwiftUI 播放。
        // 帧一样就不 setFrame:hover 每格都来一次,白白发一轮窗口布局
        // ★ 2026-10-08 可观测:托盘上屏这一拍,人眼看到的"它是不是从淡到实"取决于
        //   ① 此刻入场进度(entryFadeProgress,0 = 全透明)② 它是不是第一次上屏。
        //   这两件事以前只能靠盯屏猜 ⇒ 打一行(只在**真正转场**时打,不是每帧 ✓)
        if isTraceEnabled, previewPanel.alphaValue < 0.5 || !trayShownOnce {
            glog(String(format: "[托盘] 上屏 · 入场进度 %.2f · 首次=%@(与环同一个源 ✓)",
                        entryFadeProgress, trayShownOnce ? "否" : "是"))
        }
        trayShownOnce = true
        previewPanel.alphaValue = 1
        let before = previewPanel.frame
        // 单独记账:换选中时托盘的**卡片数**变了 → 窗口尺寸跟着变 → `setFrame` 是**同步**的窗口布局
        // (整块 tray 内容重排 + 后备存储重分配)。实机日志里 `[工] 键盘换选中 主线程 13–26ms`
        // 基本都出在这里,这会直接吃掉 1–1.5 帧 —— 入场上浮时再按一下 Tab 就"顿"一下
        traceCost("托盘改尺寸") {
            setFrameIfNeeded(previewPanel, frame)
            // 🔬 临时探针(2026-10-10 · 修"关一扇窗就错位"用):**同一拍**把四个数并排打出来 ✓
            //   为什么需要它:读代码显示两侧本来已经分开(内容跟当前组 ✓ / 窗框跟一局 max ✓),
            //   可屏幕上确实是错的 ⇒ 中间还有一个我没看见的数在带偏它 ✗ ⇒ 先量,不猜 ✓
            if isTraceEnabled {
                let content = previewContentSize()
                let wins = currentGroup?.windows ?? []
                let (r, c) = trayLayout(widths: wins.map { PanelMetrics.thumbWidth(aspect: $0.aspect) })
                let pf = previewPanel.frame
                let w = String(format: "%.0fx%.0f@%.0f,%.0f", pf.width, pf.height, pf.minX, pf.minY)
                glog("[托] 窗=\(w) · 内容=\(Int(content.width))x\(Int(content.height)) · 网格=\(r)x\(c)"
                     + " · 组窗数=\(wins.count) · 本局max=\(Int(trayMaxContentSize.width))x\(Int(trayMaxContentSize.height))")
            }
        }
        __mark("setFrame")
        // ★★ 2026-10-26 换组残帧(用户实报的"坏电视色块"):换到另一个 App 的那一拍,
        //   窗口的 backing store 里还留着上一组的像素 ⇒ 闪一块彩色的乱码 ✗
        //   ⇒ 换组就**强制整窗重绘**(影子和内容一起):这是最便宜、且不依赖"猜是哪一层的"做法 ✓
        let thisBundle = currentGroup?.bundleID
        if thisBundle != lastPreviewBundleID {
            lastPreviewBundleID = thisBundle
            previewPanel.invalidateShadow()
            previewPanel.contentView?.needsDisplay = true
            if isTraceEnabled {
                glog("[残帧] 换组 ⇒ 整窗重绘 bundle=\(thisBundle ?? "-") "
                     + "窗=\(Int(previewPanel.frame.width))x\(Int(previewPanel.frame.height))")
            }
        }
        // ★★ 2026-09-21 真凶(分段计时抓到):`orderFrontRegardless()` 在**每次 hover 更新**都被调用 ✗
        //   ⇒ AppKit 窗口排序 4–35ms/次 ✗(日志:[工] 托盘分段 … **orderFront 34.8**)。
        //   病因:用 `previewPanel.isVisible` 当"已经在台上"的判据 —— 在这套
        //   borderless + nonactivatingPanel + level=.popUpMenu 的组合上它**不可靠**(常常报 false),
        //   于是每次更新都重排一次窗口。⇒ 改为**自己记账**:上屏一次就记下,只有 orderOut 才清掉。
        trayChrome?.place()                          // 一整局只 orderFront 一次(其余靠 alpha)
        __mark("orderFront")
        // 帧变了 = 卡片在指针底下挪了位,必须自己重判一次(见 resyncSelectionUnderPointer 的病例)
        let __tr = CFAbsoluteTimeGetCurrent()
        if previewPanel.frame != before { resyncSelectionUnderPointer() }
        __segs.append(String(format: "resync %.1fms(调用了: %@)",
                             (CFAbsoluteTimeGetCurrent() - __tr) * 1000,
                             previewPanel.frame != before ? "是" : "否"))
        __prev = CFAbsoluteTimeGetCurrent()
        __mark("尾")
        let __total = (CFAbsoluteTimeGetCurrent() - __t0) * 1000
        if __total > 3 {
            glog(String(format: "[工] 托盘分段 共 %.1fms | %@", __total, __segs.joined(separator: " · ")))
        }
    }

    /// 视图在指针底下**自己挪位**时,SwiftUI 不会补发 hover(它只在指针移动时发声)→
    /// 选中态停在旧位置,用户读作"指针移过去了但选中不跟,要等一下"。
    ///
    /// 病例(2026-09-14,用户报"⌘Tab 起来后选多窗口 App,再移向对应窗口约 0.5s 延迟"):
    /// 日志里每一对 `hover 到窗` → `窗口选中(指针)` 都相差 **0ms**,说明我们处理零延迟;
    /// 而托盘**换组会换宽度**(1 扇 288pt、2 扇 540pt,各自按长条中线居中)→
    /// 卡片整体平移 ~126pt,比一张卡还宽 —— 指针其实已经骑在另一张卡上,
    /// 却没有任何事件告诉我们(手还在动,但一直落在"同一张卡"里)。
    ///
    /// 所以:尺寸变了之后,**自己按指针位置重判一次**,不依赖 hover。
    /// 长条(图标)不走这条路:本局 App 数不变,长条宽度就是常量,图标不会在指针底下来回挪。
    ///
    /// ⚠️ 驱动方有**两处**(2026-09-18 起):① `updatePreview` 里窗框变化时补判一次(原有);
    /// ② PreviewPanelView thumbGrid 的**帧拍兜底**(与 pollLaunchHover 同一套 —— 托盘换内容后
    /// tracking area 哑掉、hover 事件丢失,正是用户实报「鼠标接管窗口选择慢半拍」的主因)。
    ///
    /// ⚠️ 2026-09-18 修**多行盲区**:原来 `y <= thumbH` 只认得第一行 —— 托盘两行以上时
    /// 第 2 行永远命不中。它以前只在窗框变化时被调一次、而 hover 事件平时兜着,所以没炸;
    /// 升级成每帧兜底后必须自己会走多行网格(行距 = 卡高 + 行隙,行内左对齐,
    /// 与 thumbGrid 的 VStack/HStack 同一分布)。
    func resyncSelectionUnderPointer() {
        // ★ 换环翻牌期间指针轮询跳过:此刻"哪一环"还在切换中,算出来的格子属于旧环 ✗
        guard ringFlipAngle == 0 else { return }
        guard isVisible else { return }
        samplePointer()                                        // 托盘帧拍每帧路过:顺手采样指针位移
        guard pointerMayTakeOver() else { return }             // 键盘后动中,指针停着不许抢(与 hover 同一道闸)
        // 托盘两种内容(窗口卡 / 启动图标行)共用同一套卡壳几何,只有名单不同 —— 几何算一份
        let count: Int; let names: [String]
        if entrySelected {
            count = launchables.count; names = launchables.map(\.name)
        } else if let g = currentGroup {
            count = g.windows.count; names = g.windows.map(\.title)
        } else { return }
        // 同上:只有一格时也要能选中它(循环才需要 > 1)
        guard count > 0 else { return }
        let p = NSEvent.mouseLocation
        // 窗框 ≠ 玻璃(窗口按整局最大布局开,内容底部居中)→ 必须用内容矩形
        guard let glass = previewContentRect(), glass.contains(p) else { return }
        // 玻璃 → 内容:视图是 .padding(top: trayPadTop, horizontal: trayPadX, bottom: trayPadBottom),
        // 卡片那一横条因此从玻璃下沿 + trayPadBottom 起算
        let x = p.x - glass.minX - PanelMetrics.trayPadX
        let yUp = p.y - glass.minY - PanelMetrics.trayPadBottom - PanelMetrics.trayBottomBreath
        guard x >= 0, yUp >= 0 else { return }
        if entrySelected {
            // 启动行:格距 = icon + iconGap,行距 = icon + trayRowGap(与 pollLaunchHover 同一套数学)
            let (rows, cols) = launchLayout(count: count)
            // 同一个颠倒(见窗口卡那段的病例):行号要从**顶**往下数 ✓
            let bandFromBottom2 = min(max(rows, 1) - 1, Int(yUp / (PanelMetrics.icon + PanelMetrics.trayRowGap)))
            let r = max(0, max(rows, 1) - 1 - bandFromBottom2)
            let i = r * cols + min(cols - 1, RingGrid.index(atX: x, icon: PanelMetrics.icon, gap: PanelMetrics.iconGap))
            guard launchables.indices.contains(i), i != launchIndex else { return }
            bumpIdle()   // 帧拍选中了新格子 = 用户在动它(hover 事件哑掉时,这是"活着"的唯一证据)
            launchIndex = i
            // ★ 悬停触感(2026-09-22 用户实报「预览容器的 hover 没做震感吗」):
            //   托盘**实际走的是帧拍这条路**(逐格 `.onHover` 早就"实测会哑" ⇒ 见 hoverWindow 的注释),
            //   第一版把触感挂在 `hoverWindow` 里 ⇒ 等于挂在了用不到的那条路上 ✗
            //   托盘两种内容(窗口卡 / 启动图标行)都算"预览容器" ⇒ 同一个事件 ✓
            Haptics.fire(.hoverPreviewThumb)
            trace("[T6] 视图挪位后指针重定位(启动区): [\(i + 1)/\(count)] \(names[i])")
        } else {
            // 窗口卡:T88 卡宽随窗比例,按**每张卡的实际宽**走查命中;
            // 行的分布与 thumbGrid 的 VStack/HStack 完全一致(按数量均分、末行左对齐)
            guard let g = currentGroup else { return }
            let sizes = Self.cardSizes(g.windows)
            let widths = sizes.map(\.width)            // 与视图/尺寸账同一把尺子(不再走槽宽)
            let (rows, cols) = trayLayout(widths: widths)
            // 行高是"逐行最大卡高"(卡片大小不一)⇒ 不能用常量行距去整除 y ✗
            // ★★ 2026-10-13 病例(用户实报:「鼠标在第一排第二个选不中, 选中的是第二排」✓):
            //   `yUp` 是**从内容底往上**量的,所以下面循环数出来的行号是**从下往上**的 ✗
            //   而视图(VStack)的行是**从上往下**排的 ⇒ 两排时整块**上下颠倒** ✗
            //   ⇒ 循环得到的是"离内容底第几条带",真正的行号 = rows − 1 − 带号 ✓
            var bandFromBottom = 0
            var rowTop: CGFloat = 0
            let rowH = Self.rowHeights(sizes, rows: rows, cols: cols)
            for k in 0..<max(rows, 1) where yUp >= rowTop + rowH[k] + PanelMetrics.trayRowGap {
                rowTop += rowH[k] + PanelMetrics.trayRowGap
                bandFromBottom = k + 1
            }
            let r = max(0, max(rows, 1) - 1 - min(max(rows, 1) - 1, bandFromBottom))
            let start = r * cols
            let end = min(start + cols, widths.count)
            guard start < end else { return }
            var cursor: CGFloat = 0
            var hit: Int?
            for j in start..<end {
                let w = widths[j]
                // ★★ 2026-10-13 病例(用户:「预览窗口边缘选中错位到相邻的这个问题还是存在」✓):
                //   卡片之间那道缝(thumbGap)原来**整条判给下一张** ✗
                //   ⇒ 在第一张卡的右侧边缘扫过时,高亮会跳到第二张 ✓(点击路径一直是"归最近那张" ✓
                //     见 thumbGrid 的"行级点击"注释 —— 两条路口径不一致本身就是病 ✗)
                //   ⇒ 缝以中线为界:左半归左边那张、右半归右边那张 ✓
                if x < cursor + w + PanelMetrics.thumbGap / 2 { hit = j; break }
                cursor += w + PanelMetrics.thumbGap
            }
            hit = hit ?? (end - 1)      // 行最右缘 ⇒ 归最后一张(也是"最近"的那张 ✓)
            // 卡片高亮已交回 `.onHover` ⇒ 这里只留"未命中"的日志(不再写 winIndex ✓)
            guard hit != nil else {
                // 玻璃内但没命中卡片(点在 padding/行间隙):节流打一行,给"点击吞没"定位用
                if CFAbsoluteTimeGetCurrent() - Self.lastCardMissLog > 0.5 {
                    Self.lastCardMissLog = CFAbsoluteTimeGetCurrent()
                    trace("[T6] 卡片未命中 (x=\(Int(x)) yUp=\(Int(yUp)) 行=\(r) start=\(start) end=\(end))")
                }
                return
            }
            // ★★ 2026-10-13 病例(用户第五次报,并红框标出范围:「指针移动到红框的范围内之后,
            //   就会选中到右边的卡片」✓):
            //   托盘卡片的高亮有**两个写入者** —— 视图的 `.onHover`(按卡片真实帧 ✓ 最准)
            //   与本函数(按指针坐标重算 ✗)。两者只要差几十 pt,就会在卡内偏右的地方先跳过去 ✗
            //   量过两次都对不上(2026-10-13 那两轮:视图行左缘 122.5 vs 命中假设 122.9 只差 0.4pt,
            //   但用户现场仍能稳定复现 ⇒ 说明差在**别处**(行内偏移/换组后的旧帧),而这条重算本来就
            //   是"内容在指针底下换了"的兜底 —— 为了兜一个罕见场景,天天让用户吃"选错卡"的亏 ✗
            //   ⇒ 卡片高亮**只认 `.onHover`**(用户眼睛看到的那张 ✓),本函数不再写它 ✓
            //   代价:换组后指针不动时,高亮会停在旧卡上,直到指针动一下 ✓(可接受 ✓ 点击路径不受影响 ✓)
        }
    }

    nonisolated(unsafe) static var lastCardMissLog: CFAbsoluteTime = 0

    /// 帧拍兜底入口(与 `pollLaunchHover` 并排):窗口卡网格的**每帧**指针重定位。
    /// 为什么只做异步一跳:本函数跑在 Canvas 的绘制闭包里(视图更新中)——
    /// **不许在这里直接写 @Published**,否则 Runtime 警告 + `-layoutSubtreeIfNeeded`
    /// 布局递归(2026-09-16 实机两连的病例,见 pollLaunchHover 头上的注释)。
    /// 落账在 `resyncSelectionUnderPointer`,它自己带全部门卫(在台上 / 指针挪过窝 / 等值守卫)。
}
