import SwiftUI
import ImageIO
import VideoToolbox
import AppKit
import CoreImage
import ScreenCaptureKit
import GlanceCore

/// 窗口预览托盘 —— 施工契约 = 最新设计 demo 的 `.preview-tray`。
///
/// 构型变了:托盘住在长条**头顶**,由「App 名 · N 个窗口」一行题头 + 一排 128px 缩略图组成。
/// demo 里的 `.win-chrome`(三粒装饰点 + 64px 渐变块)是给没有真截图的 HTML 用的假窗皮——
/// 原生这边截图本身就是真窗口,所以缩略图 = 截图 + 下方标题条两段,不再叠装饰点。
struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter
    // (S2.1)托盘**不再**观察整个池:每张卡各自观察自己那一个帧盒子 ⇒ 只重绘那一张卡 ✓
    /// 光效总闸(与主环 IconCell 同一个 key):启动行的提亮/压暗跟着一起开一起关
    @AppStorage("panel.sheen") private var glow = true

    private var windows: [WindowRecord] { controller.currentGroup?.windows ?? [] }

    var body: some View {
        // **没有题头行**(2026-09-14 用户口径:"你把额头去掉我看看效果"):
        // App 名已由长条里选中的那个图标承担、窗口数由卡片张数承担 —— 那行只是把两件已知的事各写一遍,
        // 还占掉托盘顶部一整条高度。去掉后托盘 = 卡片 + 芯片
        //
        // 托盘的**双内容**(方案 E):它承载"选中格的内容" —— 活跃格 → 窗口卡;入口槽 → 启动图标行。
        // 两种内容共用同一套玻璃/卡壳/动效,切换是内容级的事,窗口与玻璃纹丝不动
        Group {
            // T91 表三:文案**不走托盘**(那是第二枚芯片 + 尺寸账不同源 ⇒ 崩溃)。
            // 芯片由面板那一扇窗承担,见 PanelView / PanelController.contentSize。
            if controller.entrySelected { launchGrid } else { thumbGrid }
        }
        .padding(.top, PanelMetrics.trayPadTop)
        .padding(.horizontal, PanelMetrics.trayPadX)
        .padding(.bottom, PanelMetrics.trayPadBottom)
        .frame(width: controller.previewContentSize().width, height: controller.previewContentSize().height)
        // ★★ 2026-09-21 用户裁定:「任何场景下都不要这个动效」。
        // 病例(3 个窗口时左右两边各自滑进来):换段走的是 `withAnimation(segmentAnimation) { … }`
        //   (PanelController:1954),而托盘内容依赖 currentGroup ⇒ 它跟着那次事务**一起重排** ✗
        //   ⇒ 卡片被"动画地"挪到各自新位置(视觉上就是从两边滑入)。
        //   性能那批把托盘**窗口**改成整局不动之后,原本被窗口位移掩盖的内容重排动画就露出来了 ✓
        // ⇒ 托盘内容**不参与任何外层动画**:换 app 是"当场换成新内容"(与"内容本身变化"这件事无关)。
        .transaction { $0.animation = nil }
        // ★★ 2026-09-21 用户裁定:「把背景的圆角矩形撤掉 —— 就是最外面那一层,只要单个卡片容器和下面的芯片」
        // 原状:托盘 = 一大块圆角玻璃(GlassBackground + 圆角裁剪 + 受光边/内阴影 + tray 阴影),
        //   卡片与芯片都画在这块玻璃上 ⇒ 换组时"玻璃不动、里面的东西动"看得特别清楚 ✗
        //   (用户原话:"不是窗框移动,是里面的快照移动了" ✓)
        // 现在:最外层玻璃整层撤掉 ⇒ 可见元素只剩**每张卡自己的容器**与**芯片** ⇒
        //   换组的位移只可能来自卡片自己 ⇒ 而卡已经改成固定槽位(方案 A)⇒ 看得见的东西不再动 ✓
        // 几何仍按原口径算(`previewContentSize` 的 trayPad 等在位)—— 只撤视觉层,不动尺寸账 ✓
        // **入场上浮**:整块托盘(玻璃 + 卡片)从"原位置再低一小截"浮到该在的位置。
        // 与长条里**选中格 + 托底**用的是同一个值、同一次 withAnimation —— 所以这两边永远同步上浮,
        // 其余图标不动(2026-09-15 用户口径:"他们俩直接从原位置开始上浮")。
        // 退场仍不做动效(2026-09-14 砍的:用户实评"拖沓"),窗口由控制器直接 orderOut
        .offset(y: controller.contentEntryRise)
        // 几何仍按原口径留出阴影留白(与 `previewContentSize`/`TrayGeometry` 一致 ✓)
        // —— 只撤**视觉层**,不动尺寸账 ⇒ 窗口大小/位置与之前完全一致 ✓
        .padding(PanelMetrics.shadowPadPop)
        // 托盘窗口按**整局最大布局**开(见 PanelController.trayMaxContentSize):本组摆得小时,
        // 玻璃要**贴着窗口底边**(= 与今天等尺寸时的位置完全一致),水平居中由默认对齐负责。
        // 不这么摆的话内容会在更大的窗口里垂直居中 → 玻璃整体上浮一截,和长条之间的缝就变了
        // ★ 2026-09-21 用户实评:「你先这样固定完之后, 比如 DataGrip, 容器跟 App 的位置错了十万八千里」✗
        //   ⇒ 左端锚定的代价被亲眼看到:托盘窗宽 = **本局最大行宽** ⇒ 单个窗口的 App(行宽 268 vs 窗口 838)
        //     被钉在窗口最左边 ⇒ 卡片飘在远处、跟底部选中的图标**毫无视觉关系** ✗
        //   ⇒ 回到**居中**:卡片始终落在托盘中轴附近 ✓(与图标圈的语义关联靠高亮承担 ✓);
        //     代价是换组时整排平移 —— 这一条用户已明确接受(「保留形状,接受位移」✓ ADR-0014)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(controller.isVisible ? 1 : 0)
    }

    /// 卡片网格。一行摆得下就是一行(与旧版完全一样),摆不下才换行 ——
    /// 换行是"托盘不再替长条压尺寸"的另一半(见 `PanelController.applySessionScaleCap`)。
    ///
    /// 行数由 `trayLayout` 取"放得下的最少行数",所以各行是**均衡**的(8 扇窗 = 4+4,
    /// 不是 7+1);末行少几张时**左对齐留空**,不拉伸、不居中 —— 居中的话卡片间距会随
    /// 末行张数变,左右扫视时每一行的节凑都不一样。
    private var thumbGrid: some View {
        // 卡宽随窗比例(T88):布局按每张卡的实际宽算,不再假定定尺
        // ★ 方案 A:布局一律走槽宽(本局最宽卡)⇒ 与控制器尺寸账/命中同源
        // ★★ 2026-09-21 最终裁定(用户):**保留卡片形状,接受换组时的位移**。
        // 理由(也写进 docs):行是**紧排序列** ⇒ 第 k 张卡的 x = 前 k-1 张宽度之和 ⇒
        //   换组时窗口宽度变了 ⇒ 位置必然变 ✗。"位置不动" ⟺ "每张卡占的宽度固定";
        //   "形状跟真窗走" ⟺ "占的宽度 = 它自己的窗口宽" ⇒ 这两句**逻辑互斥** ✓
        //   (统一卡面/固定槽位都能治抖,但一个留白 ✗ 一个太宽 ✗ —— 用户两次实评都不要 ✓)
        let widths = windows.map { PanelMetrics.thumbWidth(aspect: $0.aspect) }
        let (rows, cols) = controller.trayLayout(widths: widths)
        let rowsSafe = max(rows, 1)
        let colsSafe = max(cols, 1)
        return VStack(spacing: PanelMetrics.trayRowGap) {
            ForEach(0..<rowsSafe, id: \.self) { r in
                HStack(spacing: PanelMetrics.thumbGap) {
                    ForEach(r * colsSafe..<min(r * colsSafe + colsSafe, windows.count), id: \.self) { i in
                        thumb(at: i)   // 紧排(卡宽随真窗 ⇒ 用户要的形状 ✓)
                    }
                }
                // ★ **行级点击**(2026-09-19,用户实报「第二张卡要点两遍」):卡片之间的
                //   空隙曾是命中空洞 —— 点击穿透托盘落到下层长条上,什么都不会发生。
                //   现在行内任何位置都归属最近的一张卡(首行原点 = 首卡左缘),一点即达;
                //   卡身上的红绿灯是 Button(子级优先),不受影响。落账见 PanelController.cardTapped
                .gesture(SpatialTapGesture().onEnded { value in
                    controller.cardTapped(localX: value.location.x)
                })
            }
        }
        // **帧拍兜底**(与 launchGrid 同一套、同一哲学):Tab 换组后托盘整块换内容、
        // 卡片在指针脚下重排 —— tracking area 在"视图于指针底下重排之后就哑了,不补发 hover"
        // (本仓库实咬两次的病)。表现就是用户实报的「键盘选完组、鼠标去接管,慢半拍」。
        // 每帧问一次全局指针位置、自己算格子,事件丢了也有帧拍;
        // 落账走 pollWindowHover 的异步一跳(不许在视图更新中直接写 @Published,见那边病例)。
        // paused 跟着面板在不在台上走(与 SheenOverlay 同一省电纪律:不台上就一帧都不跑)。
        .background(alignment: .topLeading) {
            TimelineView(.animation(paused: !controller.isVisible)) { _ in
                Canvas { _, _ in controller.pollWindowHover() }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func thumb(at i: Int) -> some View {
        let w = windows[i]
        // 🔬 一次性账:卡片把窗口放大/裁掉了多少(判定"截图比真窗还大"这一族问题)
        let box = PanelMetrics.thumbSize(real: w.bounds.size, aspect: w.aspect)
        _ = CardSizeLog.once(record: w, cardW: box.width, cardH: box.height)
        CardSizeLog.changed(record: w, cardW: box.width, cardH: box.height)   // 🔬 只在"变了"时报
        // 🔬 量两把尺子(源 / 图比例 / 盒子比例 / 快照比例)
        let liveFrame = LivePreviewPool.shared.box(for: w.wid).image
        let shot = snapshotter.cache[w.wid]
        let liveAspect = liveFrame.map { CGFloat($0.width) / CGFloat($0.height) }
        let shotAspect = shot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { CGFloat($0.width) / CGFloat($0.height) }
        if UserDefaults.standard.bool(forKey: "debug.dumpSources") {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            SourceDump.dump(key: "shot-\(w.wid)", shot?.cgImage(forProposedRect: nil, context: nil, hints: nil), dir)
            SourceDump.dump(key: "live-\(w.wid)", liveFrame, dir)
        }
        CardRulerLog.check(wid: w.wid,
                           source: liveFrame != nil ? "live" : (shot != nil ? "快照" : "静默"),
                           box: box, imageAspect: liveAspect ?? shotAspect, shotAspect: shotAspect)
        return WindowThumb(
            record: w,
            bundleID: controller.currentGroup?.bundleID,
            image: snapshotter.cache[w.wid],
            // 卡面 = 按真窗比例(用户的原始设计 ✓);换组位移已知并接受 ✓
            face: nil,
            liveBox: LivePreviewPool.shared.box(for: w.wid),
            selected: i == controller.winIndex, // 换窗即接力:弹簧打断保速
            traffic: {
                // 三粒灯的动作 T14 就实现了(WindowFocuser.close/minimize/zoom),
                // T15 换卡片样式时把 UI 丢了 —— 2026-09-14 用户要求恢复
                TrafficLights(
                    wid: w.wid,
                    close: { controller.closeWindowClicked(w.wid) },
                    minimize: { controller.minimizeWindowClicked(w.wid) },
                    zoom: { controller.zoomWindowClicked(w.wid) },
                    dimmed: !(i == controller.winIndex),
                    closeDisabled: w.pid == ProcessInfo.processInfo.processIdentifier
                )
            },
            // ★★ 2026-09-21 用户裁定「任何场景下都不要这个动效」:
            //   原来是 `.animation(_:value: selected)` 用的 motion —— 它的语义是
            //   "**selected 变时,给这棵子树的所有变化**加动画" ✗ ⇒ hover 换 app 时多张卡的 selected
            //   同时翻转,而同一拍里整行的**重新居中**也在发生 ⇒ 卡片自己的**位置变化**被吃进这行动画
            //   ⇒ 视觉上"从左右两边各自滑到新位置" ✓。⇒ 传 nil:卡片不再自己播任何动效(位移是"当场"的)。
            motion: nil
        )
        .onHover { inside in if inside { controller.hoverWindow(i) } }
        // (点击已由**行级手势**接管:cardTapped 把行内空隙也归属最近卡片,见 thumbGrid)
    }

    // MARK: - 启动行(方案 E v2:第二条主环)

    /// 启动行 v2 —— v1 借了窗口卡的壳,被用户实评否决(「丑的要死」:196×122 的大灰卡
    /// 里浮一枚小图标,空得难受)。v2 **整行复用主环的视觉语言**:同一图标尺寸、同一格距、
    /// 同一枚托底胶囊、同一套选中态(放大 + 上浮 + 提亮)—— 托盘在这里就是第二条主环,
    /// 割裂感从根上消掉。名字不显示(Dock 心智:认图标就够)
    private var launchGrid: some View {
        let (rows, cols) = controller.launchLayout(count: controller.launchables.count)
        let rowsSafe = max(rows, 1)
        let colsSafe = max(cols, 1)
        return VStack(spacing: PanelMetrics.trayRowGap) {
            ForEach(0..<rowsSafe, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(r * colsSafe..<min(r * colsSafe + colsSafe, controller.launchables.count), id: \.self) { i in
                        launchCell(i)
                    }
                }
            }
        }
        // **不靠 .onHover**(实测会哑,见 controller.hoverLaunchAt 的病例):
        // 与主环 IconCell **同一套**:每格一个 .onHover(见 launchCell)。
        // (2026-09-16 两次更正:我先把"hover 会哑"误诊成 tracking area 的毛病、换成了
        //  onContinuousHover;真凶其实是窗口不能成为 key(AppKit 只把鼠标事件派给 key window),
        //  外加上我在 onContinuousHover 里挂的 NSLog 每秒上百次。两处都清楚了 ⇒ 回到与主环一致。)
        // 与主环 iconStrip 同一手法:spacing 归零、格子自带间隙、两端负 padding 收回
        .padding(.horizontal, -PanelMetrics.iconGap / 2)
        .frame(maxWidth: .infinity)
        // **帧拍兜底**(与 SheenOverlay 同一哲学):非 key 窗口的 hover 事件投递已经被实咬两次
        // (先「哑」后「迟钝」),这里每帧问一次全局指针位置、自己算格子 —— 事件丢了也有帧拍。
        // 只在启动行活着时存在(TimelineView 随本视图挂载/卸载);与逐格 onHover 并存,
        // 两边写同一个 launchIndex,等值守卫保证不抖
        .background(alignment: .topLeading) {
            TimelineView(.animation) { _ in
                Canvas { _, _ in controller.pollLaunchHover() }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func launchCell(_ i: Int) -> some View {
        let app = controller.launchables[i]
        let selected = i == controller.launchIndex
        return ZStack {
            // **幽灵贴座位**(T84):未启动图标不再裸坐 —— 与主环入口槽的空壳是同一枚贴。
            // 一致性从这条韵脚来:入口槽 = "还没装图的壳",启动行 = "装了图的壳";
            // 图标收到壳的 76%,壳露出一圈才读得出"座位"
            GhostTile()
                .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            Image(nsImage: app.icon)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: PanelMetrics.icon * 0.76, height: PanelMetrics.icon * 0.76)
                .saturation(glow ? (selected ? 1.15 : 0.92) : 1)
                .brightness(glow ? (selected ? 0.05 : -0.04) : 0)
        }
        .scaleEffect(selected ? PanelMetrics.iconScale : 1)
        .offset(y: selected ? -PanelMetrics.iconLift : 0)
            .elevation(.icon, active: selected)   // 帧率优先:只有选中的那颗有投影(与主环同款)
            .frame(width: PanelMetrics.icon + PanelMetrics.iconGap, height: PanelMetrics.icon)
            // **不要托底了**(用户 2026-09-16 裁定):启动行只要"上浮"这一层反馈。
            // 托盘里本来就是"悬停才展开的大预览",再加一枚托底 = 两套选中语言打在一起。
            // (launchPuck 保留未用:它是"每格一枚"的旧方案,若将来又要,别再从零写)
            .contentShape(Rectangle())
            // 点 = 确认:启动并激活,面板即关(与主环"点一下 = 确认"同一手势)
            // 点 = 启动这一格。**不经过 hoverLaunch** —— 见 controller.launchAt 的注释:
            // 指针从入口槽(面板)走到托盘(另一个窗口)会把 entrySelected 清掉,
            // 依赖 hover 记忆的点击会静默失灵(用户实报「那俩app也点不了」)。
            // 与主环同一套:指针进格就选中(hoverLaunch 不再要求 entrySelected ——
            // 指针跨窗口那一段会把它清掉,所以由 hover 自己把它补回来)
            .onHover { inside in if inside { controller.hoverLaunch(i) } }
            .onTapGesture { controller.launchAt(i) }
            // **弹簧用托盘的 thumb(0.20/0.9),不用主环的 select(0.32/0.55)** ——
            // 病例(2026-09-16 用户实评):横跨两格时 select 的回弹要 ~300ms 才落定,
            // 读起来就是「切换选中很迟钝,不是立马选中的」。托盘内的选中一律 thumb 档
            .animation(MotionPolicy.animation(PanelMotion.thumb), value: selected)
    }

    /// 启动行的托底胶囊:与主环 `puck` 同色同圆角同尺寸。每个格子自带一枚(选中显形),
    /// 不做跨格滑动的单枚 puck —— 托盘会换行,跨行滑动没有可读的轨迹;入场/出场用同一条弹簧
    @ViewBuilder
    private func launchPuck(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                .fill(PanelColors.puck)
                .overlay(
                    RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                        .strokeBorder(PanelColors.puckLip, lineWidth: 1)
                        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                )
                .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
                .elevation(.puck)
        }
    }
}

// MARK: - 缩略图(截图 + 标题条;选中 = 1.045 放大 + 内圈聚焦光 + 阴影升档)

/// 预览卡上的三粒红绿灯(功能早就在,UI 是 2026-09-14 恢复的)。
///
/// 尺寸与间距是 **UI 规格、不随卡片缩放**:卡片里放的是缩小过的截图,
/// 真窗上的 12pt 按比例缩下来只剩 2~3pt,得按自己的可点尺寸画。
///
/// 悬停行为与 macOS 对齐(用户实评"hover的时候跟 macOS 保持一致"):
/// 悬停**整组**三粒一起显出符号(✕ / − / ⤢),直接踩到的那一粒再略微放大。
/// 不悬停时只剩纯色圆点 —— 这正是系统窗口上的样子。
private struct WindowThumb<Overlay: View>: View {
    let record: WindowRecord
    /// 决定标题显示什么:终端要 tab 名、编辑器要工程名(见 `GlanceCore.WindowTitle`)
    let bundleID: String?
    let image: NSImage?
    /// ★ C′(2026-09-21 用户裁定):**统一卡面尺寸**(一局一个,= 本局最大卡)。
    /// 为什么:方案 A 用"槽位"保证位置不动 ⇒ 窄卡两侧留下显眼空档 ✗(用户实报:"中间这个左右这么宽是你设计的?")。
    /// C′ = 卡面统一 ⇒ **卡与卡紧挨着、没有空档 ✓ 且位置不动 ✓**;窗口形状改由**卡内的图**体现
    /// (图按 `fit` 居中 ⇒ 窄窗两侧在**卡内**留一点边 ✓ 不显眼 ✓)。这也是 AltTab / DockDoor 的做法 ✓
    let face: CGSize?
    /// 这一扇窗的**帧盒子**(只观察它自己 ⇒ 别的窗口来帧不会重绘本卡 ✓)
    @ObservedObject var liveBox: LiveFrameBox
    let selected: Bool
    /// 卡片的浮层(红绿灯):泛型入参,免得把面板控制器的依赖引进来
    @ViewBuilder let traffic: () -> Overlay
    let motion: Animation?

    /// 芯片上那一行字:编辑器家族抽工程名,其余原样;宽度不够时先截文字再截宽度
    private var displayTitle: String {
        PanelLayout.title(WindowTitle.display(raw: record.title, bundleID: bundleID))
    }

    /// 本卡的宽度:随窗比例自适应(T88,见 `PanelMetrics.thumbWidth`)。
    /// 卡片、模糊层、芯片、文字截断宽全走这一个值 —— 一卡一宽,不许各算各的。
    /// 优先用**截图自己的比例**:透明衬边裁切(T88 v2)后内容会比窗框瘦一圈,
    /// 所见即所得;无图(占位中)退回窗框比例,图落地那一刻宽度微调一次,与图同帧出现
    /// 图与「座」的**绘制尺寸**(pt)—— 唯一来源。
    ///
    /// 口径(用户 2026-09-21 拍板,方案 A「不放大」):
    ///   · 真窗**比卡片大** ⇒ 按 `.fill` 缩到填满(超出的部分由卡片 `clipped()` 裁掉)—— 与以前一致 ✓;
    ///   · 真窗**比卡片小** ⇒ 缩放**封顶 1.0** ⇒ 按真实大小居中,四周露卡片底色 ✓。
    /// 病例:`[卡尺寸] 真窗 320x210pt / 卡片 207x146pt ⇒ 缩放 1.10x` —— 原来 `.fill` 会把小窗**放大**塞满,
    /// 用户看着"截图比我的窗口还大" ✗;而"最大卡片尺寸"(thumbMaxW/thumbMaxAspect)只封了**上限**,
    /// 没封"不要放大" ✗ ⇒ 在这里补上。live 帧走的是同一条铺法 ⇒ 两条路一起受益 ✓(与数据源无关)。
    /// 卡面尺寸:**统一卡面(C′)优先**,否则退回"按真窗比例"(旧口径,留给别处调用)
    private var box: CGSize {
        face ?? PanelMetrics.thumbSize(real: record.bounds.size, aspect: record.aspect)
    }

    private var imageBox: CGSize {
        // 卡片尺寸 = min(真窗, 上限)(见 PanelMetrics.thumbSize 的用户口径)
        PanelMetrics.thumbSize(real: record.bounds.size, aspect: record.aspect)
    }

    private var cardW: CGFloat {
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return PanelMetrics.thumbWidth(aspect: CGFloat(cg.width) / CGFloat(cg.height))
        }
        return PanelMetrics.thumbWidth(aspect: record.aspect)
    }

    var body: some View {
        // 卡片与芯片**分离**:环、浮起、阴影都只长在卡片上,芯片是卡片之外的一枚胶囊
        // (用户口径:"不跟预览窗耦合" —— 所以选中态的各种形变不会拖着芯片一起动)
        VStack(spacing: PanelMetrics.chipGap) {
            card
            chip
        }
        // 卡片 + 芯片的总高 = 卡片实际高 + 芯片那一段(芯片段高度 = thumbH − shotH,是本局的常量)
        .frame(width: box.width,
               height: box.height + (PanelMetrics.thumbH - PanelMetrics.shotH))
    }

    /// 预览卡本体:**只有截图**(顶边毛玻璃 + 红绿灯 + 选中环都长在它身上)
    private var card: some View {
        ZStack {
            // ★ 分支条件必须是"有**任何一种**图":只看 image 会在"有实时帧、还没截图"时掉进静默态 ✗
            //   (S3 摘掉截图之后,那种情况就是常态 ✓)
            if liveBox.image != nil || image != nil {
                // **fill 定版**(2026-09-14 试过 fit,退回):
                // fit 虽然不裁内容,但卡片是**定尺**的窗口卡,而红绿灯锚在卡片左上角 ——
                // 宽窗(终端 1.83)被 fit 上下留出"信纸边"后,三粒灯就落在浅色空边上,
                // 用户实评"加歪了"。fill 只裁两侧几个点,内容仍是满幅,灯稳稳落在画面里。
                // ★ 2026-09-21:底图走**缓存**(已按卡片像素尺寸缩放过)。
                //   病灶:`Image(nsImage:)` 每次重建都要 decode + 把 720px 缩到卡片尺寸 ✗
                //   ⇒ 实机:托盘更新平时 0.1–0.3ms,一换 app 就 10–27ms(滑块那一帧掉帧)。
                //   没缩好时先用原图,下一次渲染就走缓存 ✓
                Group {
                    if let liveFrame = liveBox.image {
                        // ★ S2:实时帧优先。池的缓冲按"卡片上限高 × 窗口比例"出图 ⇒ 与 imageBox 同比例
                        //   ⇒ 既不放大也不裁边(与截图那条**同一把尺子**)✓
                        Image(decorative: liveFrame, scale: 1).resizable()
                    } else if let image,
                              let prepared = CardImageCache.shared.image(wid: record.wid, source: image,
                                                                        target: imageBox) {
                        Image(decorative: prepared.cg, scale: prepared.scale).resizable()
                    } else if let image {
                        Image(nsImage: image).resizable()
                    }
                }
                    // 定尺 = 这张卡自己的 box ⇒ 图与卡面同比例(既不拉伸也不留白 ✓)
                    .frame(width: box.width, height: box.height)
                    // 压到 30%,统一底色(`PanelColors.thumbBg`)接管卡面 —— 一排过去不再深浅乱跳;
                    // 选中/悬停的那张恢复原样。压色量挂在卡片末尾同一条
                    // `.animation(motion, value: selected)` 上,换选中是"底色涨上来/退下去",不是跳变
                    .opacity(selected ? 1 : PanelMetrics.thumbWash)
            } else {
                // ★ 静默态(2026-09-21 定版):**该窗所属 App 的淡图标**。
                //   为什么不是深色块:用户实报"像没加载出来/黑窗" ✗;为什么不是"截图中…":那是 loading 文案 ✗。
                //   淡图标自解释"这是谁的窗",而且它是**静默**的(不闪、不变、没有进度感)✓。
                //   出现时机:本次运行里这扇窗还没有过任何一帧(实测 ≈40–150ms)⇒ 一闪而过。
                ZStack {
                    Rectangle().fill(PanelColors.thumbBg)
                    if let icon = AppIconCache.icon(pid: record.pid) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: box.height * 0.34, height: box.height * 0.34)
                            .opacity(0.35)
                    }
                }
            }
        }
        .frame(width: box.width, height: box.height)
        .clipped()
        // 「座」= **毛玻璃的渐变**:把这张截图自己再画一份、模糊掉,再用纵向渐变遮成"上糊下清"。
        // 三版才走到这里,记下来免得重走:
        //   · 径向暗斑   → 用户:"阴影做的太捞了"(浅色截图上就是一块脏印);
        //   · 整条暗渐变 → 用户:"不是黑的一团,是**毛玻璃**的效果"(而且要和长条的模糊一致);
        //   · 现在这版   → 不加任何暗色,只是把画面自己糊掉,再用渐变过渡回清晰。
        // 几何必须与底图**逐像素对齐**(同样的 frame + .fill + clipped),否则模糊层会与底图错位。
        .overlay {
            // ★ 2026-09-21:**模糊只在"每扇窗第一次"算一次**(缓存)。原来 .blur 写在渲染路径里
            //   ⇒ 卡片每次重绘都重算一次高斯模糊 ✗ ⇒ 实机:指针换选中 主线程 12–24ms(托盘更新占 98%)✗
            //   ⇒ 滑块弹簧动画当帧掉帧(用户实报"划过去不流畅")。模糊结果与内容一样是**静态**的,
            //   没有理由每帧重算。几何与底图逐像素对齐(frame + .fill + clipped 保持一致)。
            if let image, let seat = SeatImageCache.shared.seat(wid: record.wid, source: image) {
                Image(decorative: seat, scale: 1)
                    .resizable()
                    // 座与底图**同一把尺子**(box):错一像素就露馅(见上面座的三版病历)
                    .frame(width: box.width, height: box.height)
                    // 毛玻璃条随底图一起压色:它就是这张截图自己,底图压了它不压,顶部会浮出一截"实"的
                    .opacity(selected ? 1 : PanelMetrics.thumbWash)
                    .mask(alignment: .top) {
                        LinearGradient(
                              stops: [
                                  .init(color: .black, location: 0.00),
                                  .init(color: .black, location: 0.22),
                                  .init(color: .black.opacity(0.55), location: 0.50),
                                  .init(color: .black.opacity(0.22), location: 0.74),
                                  .init(color: .clear, location: 1.00),
                              ],
                              startPoint: .top, endPoint: .bottom)
                            .frame(height: PanelMetrics.lightsFade)
                    }
                    .allowsHitTesting(false)
            }
        }
        // 三粒灯压在最上面。点它们不会关面板:点击落在面板内,不触发"面板外点击 = 放弃"那套判定
        .overlay(alignment: .topLeading) { traffic().padding(9) }
        .background(PanelColors.thumbBg)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous)
                .strokeBorder(PanelColors.thumbBorder, lineWidth: PanelMetrics.hairline)
        )
        .overlay(
            // demo .win-thumb.active 的 inset 0 0 0 2px:聚焦光走内圈,不抢玻璃亮边
            RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous)
                .strokeBorder(PanelColors.thumbFocus, lineWidth: selected ? 2 : 0)
        )
        .scaleEffect(selected ? 1.045 : 1)
        .elevation(selected ? .thumbActive : .thumb)
        .animation(motion, value: selected)
    }

    /// 窗口名**芯片**:卡片之外、按卡片居中;长了先截文字(不是截胶囊),绝不超过卡片宽
    private var chip: some View {
        HStack(spacing: 5) {
            // 选中圆点:占位永远在(避免文字跳),只有选中那一枚亮成系统强调色
            Circle()
                .fill(selected ? PanelColors.chipDotOn : PanelColors.chipDotOff)
                .frame(width: PanelMetrics.chipDot, height: PanelMetrics.chipDot)
            // ★ 方案 1:这枚小图标 = **这张卡属于哪个 App**(归属写在卡片自己身上 ✓)
            //   取 `AppIconCache`(按 pid 缓存 ✓ 不进渲染路径的重活 ✗)
            if let appIcon = AppIconCache.icon(pid: record.pid) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: PanelMetrics.chipIcon, height: PanelMetrics.chipIcon)
            }
            Text(displayTitle)
                // regular 而不是 medium:芯片要"轻",字重是最直接的一档(题头那边用 medium 是因为它是标题)
                .font(.system(size: PanelMetrics.titleSize, weight: .regular))
                .foregroundStyle(PanelColors.thumbTitle)
                .lineLimit(1)
                // 中段:芯片宽度不够时保头保尾(尾部才是文件名/工程的区分位)
                .truncationMode(.middle)
        }
            // 文字宽度上限里要扣掉圆点与间距,否则整枚芯片会超出卡片宽
            .frame(maxWidth: box.width - 18 - PanelMetrics.chipDot - PanelMetrics.chipIcon - 10)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
            // ★ 2026-09-21:外层玻璃撤掉后,芯片浮在任何背景上 ⇒ 补一层**极淡投影**,
            //   纯白背景上也能读出一块(与加深后的 chipBg 互补,不是替代)
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            .overlay(Capsule(style: .continuous)
                .strokeBorder(PanelColors.chipBorder, lineWidth: PanelMetrics.hairline))
            // **没有高光唇**(2026-09-14 深夜删掉的那一段,别加回来):
            // 这里原本有一条"上缘受光唇"—— 沿胶囊弧走、往下收干的一道亮边,理由是"深色里靠受光边
            // 交代我是一块玻璃"。但用户看到的是另一种东西:"像是零几年的 macOS 那种玻璃质感,太过时了"。
            // 这个判断是对的:上缘高光 + 亮描边就是 Aqua 时代那对"会反光的玻璃胶囊"的签名,
            // 而现在的 macOS 早就不用它了(浅色那格当年也没这道唇,它返回的是全透明)。
            // 芯片要的"清透"由**底的半透**承担(透过它看到的是已毛玻璃化的画面),不再由受光边承担。
            .frame(height: PanelMetrics.chipH)
    }
}

// MARK: - 实时预览 · 流池【S1.1:只起流收帧,不参与绘制】

/// 「一扇窗一条流、一扇窗一张帧」的对象池。
///
/// 施工契约:`docs/live-preview-设计.md`(先读它 —— 里面是 16 条实机病例)。
/// S1.1 修正(用户实报"hover 过 app 掉帧很严重"):
///   · **一个批次只枚举一次** `SCShareableContent` —— 那是几十毫秒的全局调用,
///     原来每条流各调一次 ⇒ 跨 5 个 app 就是 5 次 ⇒ hover 一顿一顿的;
///   · **跨组保留流**(TTL 5s + 上限 12 的 LRU)—— 原来组一变就把上一组全停、下一组全起,
///     hover 跨 app = 一整轮起停风暴;
///   · **无变化不同步** —— 同一组内换窗口不触发任何流操作。
///
/// 三条不变量:
///   I2 每扇窗**自带一帧**(不共享可变渲染资源 —— 病例 A1:共享 CALayer ⇒ 串台 79 次);
///   I3 出图规格**首启冻结**(病例 A3/B5:局中重算 ⇒ 画面忽然缩放);
///   I7 日志带时间轴(`glog`)。
final class LivePreviewPool: ObservableObject {
    static let shared = LivePreviewPool()

    private init() {
        // 显示配置变化(接屏/拔屏/改分辨率/换主屏)⇒ 整局作废(见 screenConfigChanged 的病例)
        screenWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.screenConfigChanged() }
    }

    /// 帧率档位 = 设置里的「实时预览」。**"0" = 关**(默认)。S4 起会分成"选中/其余"两档。
    static var tierFps: Int { max(0, Int(UserDefaults.standard.string(forKey: "live.previewTier") ?? "0") ?? 0) }
    static var enabled: Bool { tierFps > 0 }
    /// 流数上限(LRU 淘汰)
    /// 流数上限:**必须 ≥ 环里的窗口数**(实测环里 ~14 窗)⇒ 给 24 是防呆,不是节流阀。
    /// 教训(2026-09-21):上限小于环的规模 ⇒ LRU 永远在互相淘汰 ⇒ 同一窗口被反复起停 21 次 ⇒ hover 卡死。
    /// 成本由**帧率**控制(S4 分档),不由"砍流数"控制。
    /// **非选中**窗口的帧率(分档,S4 核心)。
    /// 依据(实测):13 条流全按用户档位(10fps)= ~26% CPU ✗,而鼠标只看得到**一张卡**在动。
    /// 5fps 的依据:缩略图尺寸下"有动静"就够(用户看的是选中那张);再低(2fps)会像卡住。
    static let lowFps = 5
    static let maxStreams = 24
    /// 闲置多久才停:局内**不靠它节流**(环里的窗口全程保留),它只回收"已经不在环里"的窗口。
    static let keepAlive: Double = 5.0

    /// **每扇窗一个可观察帧**(替代原来的 `@Published frames`)。
    /// 两个理由,一个比一个重要:
    ///   ① **崩溃**(2026-09-21 实测 SIGABRT):原来 `frames`/`wanted`/`frameOrder` 被
    ///      「池的串行队列」与「ingest 的主队列回调」同时读写 ⇒ Dictionary 被写坏 ⇒
    ///      崩溃栈 `doesNotRecognizeSelector ← Dictionary._Variant.lookup ← LivePreviewPool.ingest` ✓。
    ///      ⇒ 现在:**可变账本只归池的队列**,主线程只**接收一张图**(写进 box)✓ 两个线程不共享容器 ✓;
    ///   ② **性能**:原来任何一扇窗来帧 ⇒ 整个托盘(观察者)重建 ⇒ 13 条流时 70 次/秒 × N 张卡 ✗。
    ///      ⇒ 现在每张卡**只观察自己那一个 box** ⇒ 只重绘那一张卡 ✓(DockDoor 同款结构 ✓)。
    private var boxes: [CGWindowID: LiveFrameBox] = [:]      // 只在主线程碰
    /// 池队列独占:最新一帧与淘汰顺序(主线程不读它)
    private var latest: [CGWindowID: CGImage] = [:]
    private var latestOrder: [CGWindowID] = []

    /// 主线程:取这一扇窗的帧盒子(没有就建一个,身份稳定 ⇒ 卡片用它当 @ObservedObject)
    @MainActor
    func box(for wid: CGWindowID) -> LiveFrameBox {
        if let b = boxes[wid] { return b }
        let b = LiveFrameBox()
        boxes[wid] = b
        return b
    }

    private struct Handle {
        let gen: Int
        let fps: Int
        let stream: SCStream
        let output: LiveOutput
    }

    private let queue = DispatchQueue(label: "glance.livepool")
    private var handles: [CGWindowID: Handle] = [:]
    private var wanted: Set<CGWindowID> = []
    private var idleSince: [CGWindowID: CFAbsoluteTime] = [:]
    private var pending: Set<CGWindowID> = []
    /// 推迟起流的定时器(hover 稳定 150ms 后才真起)
    private var startDebounce: DispatchWorkItem?          // 正在起(错峰排队中)
    private var activeGens: Set<Int> = []
    private var gen = 0
    private var startedAt: [CGWindowID: CFAbsoluteTime] = [:]
    private var firstFrameLogged: Set<CGWindowID> = []
    /// 起流时冻结的**像素规格**。⚠️ 只写不清是不行的(2026-09-21 病例):
    /// 它是按"当时那块屏"的像素尺寸算的 ⇒ 接拔外接屏/改分辨率后**全部过期** ✗
    /// ⇒ 见 `screenConfigChanged()`:显示配置一变,整本作废 ✓
    private var frozenSize: [CGWindowID: CGSize] = [:]
    private var screenWatch: NSObjectProtocol?
    private var frameOrder: [CGWindowID] = []
    /// 窗口枚举缓存:一个批次共用一次(短 TTL)
    private var winCache: [CGWindowID: SCWindow] = [:]
    private var winCacheAt: CFAbsoluteTime = 0
    private var sweepScheduled = false

    /// 把"当前界面上该活的窗口"交给池。池负责开/停到一致(对象池 reconcile)。
    func sync(_ items: [(wid: CGWindowID, aspect: CGFloat)], selected: CGWindowID?) {
        guard Self.enabled else { return }
        let wids = items.map { $0.wid }
        queue.async { [weak self] in
            guard let self else { return }
            // 无变化 ⇒ 什么都不做(同组换窗口、重复调用都不该碰流)
            if Set(wids) == self.wanted, self.pending.isEmpty { return }
            self.wanted = Set(wids)
            for w in wids { self.idleSince[w] = nil }
            // ★ 先把"停"做完(停是便宜的、而且必须立刻做),**"起"推迟 150ms**。
            // 病例(2026-09-21,日志实证):hover 到"还没起过流的窗口"时,
            //   `SCStream` 创建(几十毫秒的系统级工作)正好压在 hover 那一拍上 ⇒ 丢 1 拍 ✗
            //   · 36977ms hover 到 Ghostty(冷)
            //   · 37001ms [悬停拍] +24.3ms ✗(下一拍 +8.9ms ⇒ 24.3+8.9 = 2 拍)
            //   · 37021ms [直播] 首帧 44ms wid=161378 ⇒ 流就是 36977ms 那一刻开始建的
            //   · 37293ms 再次 hover 到它(已热)⇒ **+18.1ms 正常,不丢拍** ✓
            // ⇒ 判据:丢拍**只在"要新建流"时发生** ✓
            // 修法:hover 稳定 150ms 之后才起 ⇒ 用户看到的是**静默态(淡 App 图标)约 200ms**
            //      而不是"卡一下" ✓ 换档(重启两条)同理,一起推迟 ✓
            self.reconcile(items, selected: selected, starts: false)
            self.scheduleSweep()
            self.startDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, Set(wids) == self.wanted else { return }   // 又变了 ⇒ 这轮作废
                self.reconcile(items, selected: selected, starts: true)
            }
            self.startDebounce = work
            self.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// 面板收场:停掉全部流。**帧保留**(跨会话复用 ⇒ 下一次唤起第一眼就是活画面)。
    /// **显示配置变化**(接屏/拔屏/改分辨率/换主屏)⇒ 整局作废。
    ///
    /// 病例(用户实报,2026-09-21):「接上外接屏之后,每个 app 都'错位'了一下」——
    ///   真因:`frozenSize` 按**起流那一刻那块屏**的像素尺寸冻结 ⇒ 显示配置一变换屏,
    ///   规格全部过期 ✗;而此前**没有任何人**监听 `didChangeScreenParametersNotification`
    ///   ⇒ 会一直错到 App 重启 ✗(用户那次"重启后就不复现"正是因为重启 ✓)。
    /// 口径:窗口尺寸是"一局的不变量"(ADR-0006)⇒ **换屏就是换了一局** ⇒ 全停 + 清规格 + 清图缓存 ✓
    func screenConfigChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            glog("[直播] 显示配置变化 ⇒ 整局作废(停流 + 清冻结规格 + 清图缓存)")
            CardImageCache.shared.reset()
            SeatImageCache.shared.reset()
            self.stopAll(reason: "显示配置变化")
        }
    }

    func stopAll(reason: String) {
        startDebounce?.cancel(); startDebounce = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.frozenSize.removeAll()          // ★ 规格必须跟着清(否则下一次起流仍用旧屏的像素尺寸 ✗)
            let n = self.handles.count
            for (_, h) in self.handles { Task { try? await h.stream.stopCapture() } }
            self.handles.removeAll(); self.wanted.removeAll(); self.activeGens.removeAll()
            self.startedAt.removeAll(); self.firstFrameLogged.removeAll()
            self.idleSince.removeAll(); self.pending.removeAll()
            glog("[直播] 全部停流(\(reason)) 共 \(n) 条 · 帧保留 \(self.latest.count) 张")
        }
    }

    /// 定时清扫:闲置超时的流**不等下一次 sync** 就回收。
    /// (病例:用户 hover 扫过 5 个 app 后停手 —— 若只在 sync 里扫,那 6 条流会一直出帧。)
    private func scheduleSweep() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.sweepScheduled = false
            let now = CFAbsoluteTimeGetCurrent()
            for (wid, since) in self.idleSince where now - since > Self.keepAlive {
                self.stopStream(wid, why: "闲置 \(Int(now - since))s")
            }
            if !self.handles.isEmpty { self.scheduleSweep() }   // 还有流就继续守着
        }
    }

    /// - Parameter starts: `false` = **这一轮只停/不启**。用于把"起流"挪出 hover 那一拍
    ///   (病例:`SCStream` 创建是系统级重活 ⇒ 放在 hover 路径上会丢 1 拍 ✗,见 sync 的头注)。
    private func reconcile(_ items: [(wid: CGWindowID, aspect: CGFloat)], selected: CGWindowID?,
                           starts: Bool = true) {
        // ① 记闲置时间(不再立刻停流 —— 见 keepAlive)
        let now = CFAbsoluteTimeGetCurrent()
        for wid in handles.keys where !wanted.contains(wid) {
            if idleSince[wid] == nil { idleSince[wid] = now }
        }
        // ② 停:只停"确实不在环里"的窗口(闲置=它已经不在 wanted 集合里)。
        //   局内**不做上限淘汰** —— 上限只是为了防呆,不是节流阀(见 maxStreams 的教训)。
        for (wid, since) in idleSince where now - since > Self.keepAlive {
            stopStream(wid, why: "已不在环内 \(Int(now - since))s")
        }
        // ③ 起:错峰 40ms(避免向 WindowServer 打并发 —— AltTab issue #5861)
        // ★ 分档:选中 = 用户档位,其余 = lowFps。帧率变了就重启**那一条**(帧保留 ⇒ 不闪)✓
        if starts {
            for item in items.prefix(Self.maxStreams) {
                let want = (item.wid == selected) ? Self.tierFps : Self.lowFps
                if let h = handles[item.wid], h.fps != want {
                    stopStream(item.wid, why: "换档 \(h.fps)->\(want)fps")
                }
            }
        }
        guard starts else { return }
        var delay = 0.0
        for item in items.prefix(Self.maxStreams) where handles[item.wid] == nil && !pending.contains(item.wid) {
            pending.insert(item.wid)
            let d = delay; delay += 0.04
            queue.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self else { return }
                self.pending.remove(item.wid)
                guard self.wanted.contains(item.wid), self.handles[item.wid] == nil else { return }
                let want = (item.wid == selected) ? Self.tierFps : Self.lowFps
                self.start(item.wid, aspect: item.aspect, fps: want)
            }
        }
    }

    private func stopStream(_ wid: CGWindowID, why: String) {
        guard let h = handles[wid] else { return }
        Task { try? await h.stream.stopCapture() }
        activeGens.remove(h.gen)
        handles[wid] = nil; startedAt[wid] = nil; firstFrameLogged.remove(wid); idleSince[wid] = nil
        glog("[直播] 停流 wid=\(wid)(\(why))")
    }

    /// 批量枚举(一个批次共用一次)。SCShareableContent 是几十毫秒的全局调用,不能每条流各来一次。
    private func window(_ wid: CGWindowID) async -> SCWindow? {
        if CFAbsoluteTimeGetCurrent() - winCacheAt < 2.0, let w = winCache[wid] { return w }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        winCacheAt = CFAbsoluteTimeGetCurrent()
        for w in content.windows { winCache[w.windowID] = w }
        return winCache[wid]
    }

    private func start(_ wid: CGWindowID, aspect: CGFloat, fps: Int) {
        gen += 1
        let g = gen
        activeGens.insert(g)
        Task { [weak self] in
            guard let self else { return }
            guard let win = await self.window(wid) else {
                glog("[直播] 找不到窗口 wid=\(wid)"); return
            }
            let cfg = SCStreamConfiguration()
            // I3:尺寸**首启冻结** —— 窗口后来变形也不改(改了就是"画面忽然缩放",病例 A3)
            let size: CGSize
            if let f = self.frozenSize[wid] {
                size = f
            } else {
                let scale = PanelScreen.scale
                let h = (PanelMetrics.shotH * scale).rounded()
                let a = win.frame.height > 0 ? win.frame.width / win.frame.height : aspect
                size = CGSize(width: (h * max(0.3, min(4.0, a))).rounded(), height: h)
                self.frozenSize[wid] = size
            }
            cfg.width = max(2, Int(size.width)); cfg.height = max(2, Int(size.height))
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, fps)))
            cfg.queueDepth = 3; cfg.showsCursor = false; cfg.capturesAudio = false
            cfg.scalesToFit = false
            cfg.ignoreShadowsSingleWindow = true     // 与快照链一致(病例 B6:内容框也要同源)
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            let out = LiveOutput(wid: wid) { [weak self] sb in self?.ingest(sb, wid: wid, gen: g) }
            do {
                try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: self.queue)
                self.queue.async {
                    self.handles[wid] = Handle(gen: g, fps: fps, stream: s, output: out)
                    self.startedAt[wid] = CFAbsoluteTimeGetCurrent()
                }
                try await s.startCapture()
                glog(String(format: "[直播] 起流池 += wid=%d %dx%d @%dfps 池内=%d",
                            wid, Int(size.width), Int(size.height), fps, self.handles.count))
            } catch {
                glog("[直播] 起流失败 wid=\(wid): \(error.localizedDescription)")
            }
        }
    }

    fileprivate func ingest(_ sb: CMSampleBuffer, wid: CGWindowID, gen g: Int) {
        guard activeGens.contains(g) else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var raw: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &raw)
        guard let img = raw else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // ★ 账本更新**就地在池队列上做**(不碰主线程状态 ⇒ 不会再和主线程抢 Dictionary ✓)
        if let t0 = startedAt[wid], !firstFrameLogged.contains(wid) {
            firstFrameLogged.insert(wid)
            glog(String(format: "[直播] 首帧 %.0fms wid=%d", (now - t0) * 1000, wid))
        }
        if latest[wid] == nil { latestOrder.append(wid) }
        latest[wid] = img
        while latestOrder.count > 10 {
            let old = latestOrder.removeFirst()
            if !wanted.contains(old) { latest[old] = nil }
        }
        // 只把这一张图交给主线程 ⇒ 每张卡各自重绘(不重建整个托盘 ✓)
        DispatchQueue.main.async { [weak self] in
            self?.boxes[wid]?.image = img
        }
    }
}

/// 一扇窗的"最新一帧盒子" —— 卡片 `@ObservedObject` 它,只在自己这扇窗来帧时重绘 ✓
final class LiveFrameBox: ObservableObject {
    @Published var image: CGImage?
}

/// 一条流的输出口(自带 wid ⇒ 归属不靠共享标量,病例 A1)。
final class LiveOutput: NSObject, SCStreamOutput {
    private let wid: CGWindowID
    private let onFrame: (CMSampleBuffer) -> Void
    init(wid: CGWindowID, onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.wid = wid; self.onFrame = onFrame
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        onFrame(sb)
    }
}

// MARK: - 「座」的模糊缓存(每扇窗只算一次)

/// 「座」= 把卡片自己糊掉再渐变遮掉下半 —— 结果**与内容无关、与时间无关**,所以只该算一次。
/// 病例(2026-09-21):`.blur()` 写在渲染路径里 ⇒ 指针每换一次选中就重算一次高斯模糊
/// ⇒ 主线程 12–24ms 卡顿(200 个样本里 30 个 ≥10ms)⇒ 滑块弹簧在那一帧掉帧。
/// 现在:后台算 + 缓存;没算好就这一层不画(底图仍是清晰的截图,不闪)。
final class SeatImageCache {
    /// 换屏/显示配置变化时清空(图是按当时那块的 scale 缩过的 ✗ 不能跨屏复用)
    func reset() { queue.async { [weak self] in self?.store.removeAll(); self?.inFlight.removeAll() } }

    static let shared = SeatImageCache()
    private let lock = NSLock()
    private var store: [CGWindowID: CGImage] = [:]
    private var inFlight: Set<CGWindowID> = []
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "glance.seat", qos: .utility)

    /// 取"座"图;没有就返回 nil(并顺手后台算一张)
    func seat(wid: CGWindowID, source: NSImage) -> CGImage? {
        lock.lock()
        if let c = store[wid] { lock.unlock(); return c }
        let busy = inFlight.contains(wid)
        if !busy { inFlight.insert(wid) }
        lock.unlock()
        guard !busy else { return nil }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let radius = PanelMetrics.lightsBlur * PanelScreen.scale
        queue.async { [weak self] in
            guard let self else { return }
            let out = Self.blur(cg, radius: radius, ctx: self.ctx)
            self.lock.lock()
            if let out { self.store[wid] = out }
            self.inFlight.remove(wid)
            self.lock.unlock()
        }
        return nil
    }

    /// 预热(面板打开时后台把整个环的窗都算一遍 ⇒ hover 时一次都不用算)
    func prewarm(_ items: [(wid: CGWindowID, source: NSImage)]) {
        for it in items { _ = seat(wid: it.wid, source: it.source) }
    }

    private static func blur(_ src: CGImage, radius: CGFloat, ctx: CIContext) -> CGImage? {
        let ext = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        let input = CIImage(cgImage: src)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage else { return nil }
        return ctx.createCGImage(out, from: ext)   // 裁回原尺寸(避免边缘变暗)
    }
}

// MARK: - 卡片底图的缩放缓存(每扇窗只 decode + 缩放一次)

/// 卡片只有 ~207×122pt,而快照是 720px 宽 ⇒ 每次重建都要 decode + 缩放(主线程 ✗)。
/// 病例(2026-09-21):托盘更新平时 0.1–0.3ms,一换 app 就 **10–27ms** ⇒ 同帧滑块弹簧掉帧。
/// 现在:后台按**卡片设备像素尺寸**缩放一次并缓存;顺带与实时帧同一规格(1:1)。
/// App 图标缓存(按 pid)—— 静默态用。
/// 为什么缓存:`NSRunningApplication(processIdentifier:)` 是系统查询,不该在渲染路径里反复问 ✗
private enum AppIconCache {
    private static let lock = NSLock()
    private static var store: [pid_t: NSImage] = [:]
    static func icon(pid: pid_t) -> NSImage? {
        lock.lock()
        if let i = store[pid] { lock.unlock(); return i }
        lock.unlock()
        guard let i = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        lock.lock(); store[pid] = i; lock.unlock()
        return i
    }
}

/// 卡片尺寸 vs 真实窗口尺寸的**一次性账**(每扇窗一条) —— 用来判定"卡片把窗口放大了多少"。
/// 🔬 量"两把尺子"差多少(2026-09-21,查"换 app 时卡里的内容缩一下"):
/// 卡片里所有东西都画进同一个盒子 ✓(容器不动 ✓,这点已经量过),
/// 但图片那行是 `.resizable().frame(box)` = **拉伸填满** ✗ ⇒ 只要
/// 「图的宽高比」≠「盒子的宽高比(= 真窗比例)」,内容就会被压扁/拉高 ✗。
/// 三条源的比例本来就可能不一样:静默图标(方) · 预截快照(裁过透明边 ✗) · live 帧(起流时冻结 ✗)。
/// 这一支只在**换源或比例变化**时报一行 ⇒ 一眼看出是谁在胀缩。
private enum CardRulerLog {
    static var last: [CGWindowID: String] = [:]
    static func check(wid: CGWindowID, source: String, box: CGSize,
                      imageAspect: CGFloat?, shotAspect: CGFloat?) {
        let boxA = box.height > 0 ? box.width / box.height : 0
        let a = imageAspect.map { String(format: "%.2f", $0) } ?? "-"
        let s = shotAspect.map { String(format: "%.2f", $0) } ?? "-"
        let key = "\(source)|\(a)|\(s)|" + String(format: "%.2f", boxA)
        guard last[wid] != key else { return }
        last[wid] = key
        func d(_ x: CGFloat?) -> String {
            guard let x, boxA > 0 else { return "  -" }
            return String(format: "%+.0f%%", (x / boxA - 1) * 100)
        }
        glog(String(format: "[尺子] wid=%d 源=%@ · 盒 %.0fx%.0f(%.2f) · 图 %@%@ · 快照 %@%@",
                    wid, source, box.width, box.height, boxA, a, d(imageAspect), s, d(shotAspect)))
    }
}

/// **面板所在屏的 scale —— 这三处用量的唯一来源**(2026-09-21 修,ADR-0008「按屏归属」)。
///
/// 病例(用户实报,且**只有接外接屏时复现**):
///   三处像素换算原来都写 `NSScreen.main?.backingScaleFactor ?? 2` ✗ ——
///   而 `NSScreen.main` = **有 key window 的那块屏**,我们的面板是 nonactivating、**永不成为 key** ✗
///   ⇒ 双屏(内建 2x / 外接 1x)时,三处拿到的是**另一块屏**的比例(差一倍 ✗)
///   ⇒ 起流的像素规格(live 帧)、卡片图的缩放、红灯模糊半径全部按错的比例出 ✗
///   ⇒ 现象:换 app 时"卡里的画面**移了一下/错位**"(用户原话:不是窗框移动,是里面的快照移动了)
///   ⇒ 单用内建屏时只有一块屏,main 就是它 ⇒ **不复现** ✓(和用户观察一致)
enum PanelScreen {
    /// 由 `PanelController.showPanel` 在每次上屏时写入(归语境屏)
    static var scale: CGFloat = 2
    static func update(_ screen: NSScreen?) {
        scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let vf = screen?.visibleFrame ?? .zero
        let ff = screen?.frame ?? .zero
        glog(String(format: "[屏] 面板屏=%@ scale=%.1f fps=%d 全屏 %.0fx%.0f 可见区 %.0fx%.0f @%.0f,%.0f",
                    screen?.localizedName ?? "?", scale,
                    screen?.maximumFramesPerSecond ?? 60,
                    ff.width, ff.height, vf.width, vf.height, vf.minX, vf.minY))
    }
}

/// 🔬 把两条链的图**同时导出来**(2026-09-21,查"卡里那幅图的内容换源时移了一下"):
/// 用户描述"不是窗框移动,是里面的快照移动了" ⇒ 卡片外框与行都稳定 ✓(已量),
/// 那动的是**图的内容位置** ✗ —— 而两条链对"裁切原点"处理不同:
///   · 快照:走 `Snapshotter.transparentTrimRect` **裁掉透明衬边** ⇒ 内容填满整幅 ✓
///   · live:SCStream 按**窗口框**抓 ⇒ 不裁 ✗
/// 导出两份原始图 ⇒ 直接肉眼对比"内容在画幅里的位置/大小" ✓
enum SourceDump {
    static var dumped: Set<String> = []
    static func dump(key: String, _ img: CGImage?, _ dir: URL) {
        guard let img, !dumped.contains(key) else { return }
        dumped.insert(key)
        let url = dir.appendingPathComponent("glance-\(key).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        if CGImageDestinationFinalize(dest) {
            glog("[导图] \(key) \(img.width)x\(img.height) → \(url.path)")
        }
    }
}

private enum CardSizeLog {
    static var seen: Set<CGWindowID> = []
    /// 🔬 "卡片尺寸变了"专用(2026-09-21,查"换 app 时卡片缩一下"):
    /// `once` 每个窗口只报一次 ⇒ **看不到抖动** ✗。这一支只在尺寸**发生变化**时报一行,
    /// 用来分清两件事:
    ///   · 同一个 wid **反复变**(缩了又涨)⇒ 真抖动 ✗(bounds 中途取值不稳 / 规格冻结 / 重枚举);
    ///   · 每个 wid **只报一次、且各不相同** ⇒ 只是"新 app 的窗口本来就窄" ✓(设计如此)。
    static var lastSize: [CGWindowID: CGSize] = [:]
    static func changed(record: WindowRecord, cardW: CGFloat, cardH: CGFloat) {
        let now = CGSize(width: cardW, height: cardH)
        if let old = lastSize[record.wid], abs(old.width - now.width) < 0.5,
           abs(old.height - now.height) < 0.5 { return }
        let old = lastSize[record.wid]
        lastSize[record.wid] = now
        glog(String(format: "[卡变] wid=%d 卡片 %.0fx%.0f → %.0fx%.0f (真窗 %.0fx%.0f)",
                    record.wid, old?.width ?? -1, old?.height ?? -1, cardW, cardH,
                    record.bounds.width, record.bounds.height))
    }
    @discardableResult
    static func once(record: WindowRecord, cardW: CGFloat, cardH: CGFloat) -> Bool {
        guard !seen.contains(record.wid) else { return false }
        seen.insert(record.wid)
        let win = record.bounds.size            // 真实窗口尺寸(pt)
        guard win.width > 1, win.height > 1 else { return false }
        let s = max(cardW / win.width, cardH / win.height)   // .fill 的缩放倍数(>1 = 放大 ✗)
        let cropW = (win.width * s - cardW) / max(1, win.width * s)
        let cropH = (win.height * s - cardH) / max(1, win.height * s)
        glog(String(format: "[卡尺寸] wid=%d 真窗 %.0fx%.0fpt / 卡片 %.0fx%.0fpt ⇒ **缩放 %.2fx** 裁掉 %.0f%%x%.0f%%",
                    record.wid, win.width, win.height, cardW, cardH, s, cropW * 100, cropH * 100))
        return true
    }
}

final class CardImageCache {
    /// 换屏/显示配置变化时清空(图是按当时那块的 scale 缩过的 ✗ 不能跨屏复用)
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.store.removeAll(); self.inFlight.removeAll()
        }
    }

    struct Prepared { let cg: CGImage; let scale: CGFloat }
    static let shared = CardImageCache()
    private let lock = NSLock()
    private var store: [CGWindowID: Prepared] = [:]
    private var inFlight: Set<CGWindowID> = []
    private let queue = DispatchQueue(label: "glance.cardimg", qos: .utility)

    func image(wid: CGWindowID, source: NSImage, target: CGSize) -> Prepared? {
        lock.lock()
        if let p = store[wid] { lock.unlock(); return p }
        let busy = inFlight.contains(wid)
        if !busy { inFlight.insert(wid) }
        lock.unlock()
        guard !busy else { return nil }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = PanelScreen.scale
        // 目标尺寸由调用方给(方案 A:小窗不放大 ⇒ 目标可能小于卡片框)
        let pxW = max(2, Int((target.width * scale).rounded()))
        let pxH = max(2, Int((target.height * scale).rounded()))
        queue.async { [weak self] in
            guard let self else { return }
            var out: CGImage?
            if let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx.interpolationQuality = .high
                // **按 .fill 的中心裁剪**(不能直接铺满:那会拉伸变形 ✗)
                let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
                let k = max(CGFloat(pxW) / sw, CGFloat(pxH) / sh)
                let srcRect = CGRect(x: (sw - CGFloat(pxW) / k) / 2, y: (sh - CGFloat(pxH) / k) / 2,
                                     width: CGFloat(pxW) / k, height: CGFloat(pxH) / k)
                if let cropped = cg.cropping(to: srcRect) {
                    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
                }
                out = ctx.makeImage()
            }
            self.lock.lock()
            if let out { self.store[wid] = Prepared(cg: out, scale: scale) }
            self.inFlight.remove(wid)
            self.lock.unlock()
        }
        return nil
    }

    func prewarm(_ items: [(wid: CGWindowID, source: NSImage, target: CGSize)]) {
        for it in items { _ = image(wid: it.wid, source: it.source, target: it.target) }
    }

}
