import SwiftUI
import ImageIO
import VideoToolbox
import AppKit
import CoreImage
// ⚠️ `@preconcurrency`:`SCStream`/`SCStreamOutput` 这套 API 的 Sendable 标注还没跟上,
// 不声明的话每处回调都要报一串 warning(而我们本来就用主线程串行化 ✓)
@preconcurrency import ScreenCaptureKit
import GlanceCore

/// 窗口预览托盘 —— 施工契约 = 最新设计 demo 的 `.preview-tray`。
///
/// 构型变了:托盘住在长条**头顶**,由「App 名 · N 个窗口」一行题头 + 一排 128px 缩略图组成。
/// demo 里的 `.win-chrome`(三粒装饰点 + 64px 渐变块)是给没有真截图的 HTML 用的假窗皮——
/// 原生这边截图本身就是真窗口,所以缩略图 = 截图 + 下方标题条两段,不再叠装饰点。
/// 每张卡在**托盘坐标系**里的位置 —— 用来做"删窗后重排"的 FLIP(见 `handleCardFrames`)
private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [CGWindowID: CGRect] = [:]
    static func reduce(value: inout [CGWindowID: CGRect], nextValue: () -> [CGWindowID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { a, _ in a })
    }
}

/// 被删掉那张卡的**退场影子**:原位置放一张快照,0.12s 缩到 0.92 + 淡出 ✓
private struct GhostCard: Identifiable {
    let id = UUID()
    let wid: CGWindowID
    let rect: CGRect
    let image: NSImage?
    let width: CGFloat
}

/// 退场影子:原位置的一张快照,0.12s 内缩到 0.92 + 淡出(`handleCardFrames` 的 ①)
private struct GhostThumb: View {
    let ghost: GhostCard
    @State private var gone = false

    var body: some View {
        Group {
            if let image = ghost.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Rectangle().fill(PanelColors.thumbBg)
            }
        }
        .frame(width: ghost.width, height: ghost.rect.height)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous))
        .scaleEffect(gone ? 0.92 : 1)
        .opacity(gone ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.12)) { gone = true }
        }
    }
}

struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter
    // (S2.1)托盘**不再**观察整个池:每张卡各自观察自己那一个帧盒子 ⇒ 只重绘那一张卡 ✓
    /// 光效总闸(与主环 IconCell 同一个 key):启动行的提亮/压暗跟着一起开一起关
    @AppStorage(Keys.panelSheen) private var glow = KeyDefaults.sheen

    // MARK: - 删窗后的重排(FLIP)

    /// 上一帧每张卡的位置(托盘坐标系)
    @State private var cardFrames: [CGWindowID: CGRect] = [:]
    /// 这一轮 FLIP 的起始位移:先画回旧位置,再动画化到 0
    @State private var flipOffset: [CGWindowID: CGSize] = [:]
    /// 正在退场的影子卡
    @State private var ghosts: [GhostCard] = []

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
        // ★〔2026-10-25 撤〕换组落位(面板 .95→1):用户终审「把窗口上的动效全部去掉」✗
        //   无动效版本先在实机上认可,再按需往回加。
        .padding(.top, PanelMetrics.trayPadTop)
        .padding(.horizontal, PanelMetrics.trayPadX)
        .padding(.bottom, PanelMetrics.trayPadBottom + PanelMetrics.trayBottomBreath)
        .frame(width: controller.previewContentSize().width, height: controller.previewContentSize().height)
        // ★★ 2026-10-13 病例(用户两张对比图 + 他的方案:「是不是要给一个容器, 固定这个容器跟环的边距,
        //   然后 resize 在这个容器里做会比较好呀」—— **他这套是对的** ✓):
        //   探针量到的事实(同一局内):
        //   ```
        //   1 排:窗高 537 · 内容高 184 ⇒ 内容底边到窗底 **353pt** ✓（舒服的那档）
        //   2 排:窗高 537 · 内容高 344 ⇒ 只剩 **193pt** ✗ ⇒ 芯片贴上环 ✓（用户:「变近了」）
        //   ```
        //   机理:内容**顶对齐**画在固定尺寸的容器里 ✗ ⇒ 内容越高、底部空当越小 ✓
        //   ⇒ 口径(用户方案):**容器(托盘窗)位置与尺寸都不动** ✓,只把内容**贴容器底 + 固定内边距** ✓
        //     ⇒ 不论几排,芯片到环的距离**恒定** ✓（先做过一版"抬窗口"✗:内容跟着一起飞
        //       —— 用户当场回「这对吗, 跑哪去了 大哥」✓ 那条已回退 ✓)
        //   ★ 2026-10-13 第二步(用户:「你给一个固定的上下边距让它在这个尺寸里自己计算」✓):
        //     那段恒定值 = `trayBottomBreath`(容器多给的一段固定空气 ✓,150pt 基准),
        //     它加在**容器尺寸**里、**不进** `trayFitScale` ⇒ 不会把卡片缩小 ✓
        //     同时环/玻璃/卡片改成两把尺子(见 PanelTokens 那两条记账 ✓)⇒ 环不再被托盘拖着缩 ✓
        // ★★ 2026-10-13 定稿:贴底**不靠对齐语义**(它没生效 ✗),靠**窗高 = 内容 + 底部内缩** ✓
        //   ⇒ 就算内容贴顶,它的下沿也必然落在"窗底 + 内缩" = 与内容高度**无关** ✓
        .frame(maxHeight: .infinity, alignment: .bottom)
        // ★★ 2026-09-21 用户裁定:「任何场景下都不要这个动效」。
        // 病例(3 个窗口时左右两边各自滑进来):换段走的是 `withAnimation(segmentAnimation) { … }`
        //   (PanelController:1954),而托盘内容依赖 currentGroup ⇒ 它跟着那次事务**一起重排** ✗
        //   ⇒ 卡片被"动画地"挪到各自新位置(视觉上就是从两边滑入)。
        //   性能那批把托盘**窗口**改成整局不动之后,原本被窗口位移掩盖的内容重排动画就露出来了 ✓
        // ⇒ 托盘内容**不参与任何外层动画**:换 app 是"当场换成新内容"(与"内容本身变化"这件事无关)。
        // ★ 2026-09-22 用户实报:「现在托盘的动画被你砍掉了, hover app 托盘只会闪现, 没有滑动了」
        //   —— 9-21 这里一刀切 `animation = nil`(当时是为了治"换组时卡片从两边滑入" ✗)⇒
        //   代价是**hover 换组时托盘内容瞬间跳**(闪现 ✗)。现在收窄:只挡**换环**(↓/↑/Tab 跨段)那一拍,
        //   hover 换组仍用短弹簧滑动 ✓(用户要的手感 ✓)
        .transaction { t in
            // 换环(↓/↑/Tab 跨段)那一拍 ⇒ 托盘内容**当拍**换(与环的翻牌同步 ✓)
            // 其余(hover 换组 / 键盘换格)⇒ 保留短弹簧 ⇒ 内容**滑**过去而不是闪现 ✓
            // ★ 2026-10-19:不只换环 —— **任何换组**(含指针悬停换组、⌘Tab)都要当拍换。
            //   漏了这条的后果(用户实报):换组那一拍整行被外层 withAnimation 重排,
            //   选中环跟着旧布局走一帧 = 「窗口四周一条白线闪一下」✗
            if controller.isRingSwapInFlight || controller.isContentSwapInFlight { t.animation = nil }
        }
        // ★★ 2026-10-08(用户:「**预览容器没有渐入**, 跟环有点脱节, 稍微一点点」):
        //   环在入场时是整块渐入(`PanelController.entryFade` ⇒ PanelView 的 `.opacity`)✓,
        //   而托盘是**另一扇窗**,它上屏时直接 `alphaValue = 1` ⇒ 内容"啪"一下就到位 ✗
        //   ⇒ 让它跟环用**同一个进度**(不是各写一套时长:同一个源 ⇒ 永远同步 ✓)
        //   两个窗,一个源 —— 这是"两套东西必须同源"的老规矩在这条路上的又一次应用 ✓
        .opacity(controller.entryFade)
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
    /// **删窗后的重排**(2026-10-19 用户实拍:"删一扇窗,托盘突然少一张,很生硬"):
    /// 两拍,与 `window-remove-reflow.html` 预览一致:
    ///   ① 0–0.12s 被删那张**缩小 + 淡出**(用影子画在它原来的位置上,因为模型已经把它摘掉了)
    ///   ② 0.12–0.34s 剩下的卡**同时**滑到新位置(FLIP:先 offset 回旧位置,再动画化到 0)
    /// 只在"窗口**变少**"时触发 —— 换组(内容整套换)和新增窗都不掺和(那两条各有各的路径)✓
    private func handleCardFrames(_ new: [CGWindowID: CGRect]) {
        let old = cardFrames
        cardFrames = new
        guard !old.isEmpty, !new.isEmpty else { return }
        // 换组 / 换环那一拍:整块换内容,不是"少了一张" ⇒ 不参与(否则整排卡会飞)✗
        guard !controller.isContentSwapInFlight, !controller.isRingSwapInFlight else { return }
        let gone = old.filter { new[$0.key] == nil }
        guard !gone.isEmpty else { return }
        // 托盘窗先别收:卡片还要在旧位置停 0.12s + 滑 0.22s,窗先收会把它们裁掉 ✗
        controller.holdTrayFrame(seconds: 0.24)
        // ① 退场影子
        for (wid, rect) in gone {
            ghosts.append(GhostCard(wid: wid, rect: rect,
                                    image: snapshotter.cache[wid], width: rect.width))
        }
        // ② **位置变了的卡**从**右侧滑入**(2026-10-19 第四版):
        //   用户:「从左下飞出来的效果我不喜欢,改成从右边滑动入场」
        //   ⇒ 不再用"旧位置 → 新位置"的位移(v1 斜跨 / v2 两段都被否),
        //     而是**在新位置上先右移 64pt**,再滑回 0 —— 读作"新卡片从右边滑进来" ✓
        //   (只给真的换了位置的卡;没动的那几张保持不动 ✓)
        var offs: [CGWindowID: CGSize] = [:]
        for (wid, now) in new {
            guard let was = old[wid] else { continue }
            if abs(was.minX - now.minX) > 0.5 || abs(was.minY - now.minY) > 0.5 {
                offs[wid] = CGSize(width: 64, height: 0)
            }
        }
        guard !offs.isEmpty else { return }
        // ★★ 2026-10-19 第三版(用户:「都很怪,不统一,也不优雅」):
        //   v1 = 斜跨(不像话) · v2 = 先垂直后水平(三段,读起来碎)
        //   ⇒ 现在:**新位置 + 右侧 64pt 起步 → 滑回**;与影子淡出同时开始、同一时长 0.20s ✓
        //     托盘窗框在动画期间冻结(不然会裁掉还在旧位置的卡),结束后立刻按新内容收 ✓
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { flipOffset = offs }
        withAnimation(.easeInOut(duration: 0.20)) { flipOffset = [:] }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { ghosts = [] }
    }

    /// 组内窗口的**呈现方式**(ADR-0017):`row` = 卡片行(现行)、`rail` = 芯片轨道(新)。
    /// ★ 两条路径**完全隔离**:rail 只复用"卡片本身"(`thumb(at:showsChip:)`),排布/芯片/滚动全在新文件里 ✓
    /// ★ 开关默认 `row` ⇒ 关掉时走的还是原来的 `cardRowGrid`,一个字都不变 ✓
    private var thumbGrid: some View {
        contentGrid
            .coordinateSpace(name: "glance.tray")
            .onPreferenceChange(CardFrameKey.self) { handleCardFrames($0) }
            .overlay(alignment: .topLeading) {
                ForEach(ghosts) { ghost in
                    GhostThumb(ghost: ghost)
                        .position(x: ghost.rect.midX, y: ghost.rect.midY)
                        .allowsHitTesting(false)
                }
            }
    }

    /// 本组是否用「芯片轨道」版式(单一判据 —— 两个分支不许各写一份 ✗)
    private var useRail: Bool { WindowLayout.current == .rail && windows.count > 1 }

    @ViewBuilder private var contentGrid: some View {
        if useRail {
            // ★ 卡宽随真窗变,但**轨道的位置不许跟着动**(用户口径)⇒
            //   卡放进一个**固定宽度的槽**(= 本组最宽卡),槽内居中;轨道永远贴着槽的右缘 ⇒ 一个像素都不动 ✓
            let slotW = windows.map { PanelMetrics.thumbWidth(aspect: $0.aspect) }.max() ?? 0
            // ★ 卡盒恒定 = 本组最大卡(2026-10-25 日志铁证):IDEA 的"4 窗同尺寸"实为
            //   1728x1084 / 920x492 / 1204x1084 / 1728x1050(有一扇是弹窗)⇒ 卡跟选中走 =
            //   每次组内换选中卡都变尺寸 = 用户说的"落位"✗ ⇒ 卡盒 = 组内最大卡,恒定;
            //   换选中只剩内容直换;小窗内容在盒内 aspect-fit ✓
            let slotH = windows.map { PanelMetrics.thumbSize(real: $0.bounds.size,
                                                            aspect: $0.aspect).height }.max() ?? 0
            ChipRailGroup(windows: windows,
                          selected: selIndex,
                          bundleID: controller.currentGroup?.bundleID,
                          card: AnyView(thumb(at: selIndex, showsChip: false,
                                              face: CGSize(width: slotW, height: slotH))
                              // 居中(2026-10-25 用户终审:贴左时小窗离轨道太远「看着怪怪的」✗)
                              .frame(width: slotW, alignment: .center)
                              // ★〔2026-10-25 撤〕曾在此挂 .animation(value: wid) 做卡形变:
                              //   它包住**整张卡**,内容三层降级(图标→静帧→live)的换源也被裹进
                              //   同一事务 ⇒ 同尺寸窗口(IDEA)也"先缩后放"(用户录屏逐帧实锤)✗
                              //   ⇒ 摘掉:换窗 = 内容一帧直换、无任何动画;尺寸形变等"只对几何
                              //      生效的窄动画"(face 驱动)验证后再上,不再让动效沾内容 ✓
                              .onTapGesture { controller.cardTapped(localX: 0) }),
                          // 轨道高 = 组内最大卡高(与卡盒同源,恒定)✓
                          railHeight: slotH,
                          onSelect: { controller.hoverWindow($0) },
                          onTap: { i in controller.hoverWindow(i); controller.cardTapped(localX: 0) })
        } else {
            cardRowGrid
        }
    }

    private var cardRowGrid: some View {
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
                        // 单窗口放宽一档(见 `PanelMetrics.soloWiden`)
                        // ★ 放宽**只属于芯片轨道样式**(用户口径:「普通窗口还是原来的尺寸」)——
                        //   两套版式的度量必须完全隔离,row 一个像素都不许跟着变 ✓
                        thumb(at: i, face: (useRail && windows.count == 1)
                              ? PanelMetrics.thumbSize(real: windows[i].bounds.size,
                                                       aspect: windows[i].aspect,
                                                       widen: PanelMetrics.soloWiden)
                              : nil)
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
        // ★ 2026-09-24 **删掉这里的帧拍 TimelineView** —— 它是**重复劳动**:
        //   它每帧调的 `pollWindowHover()` 所做的全部事情就是
        //   `Task { @MainActor in resyncSelectionUnderPointer() }`,
        //   而**同一个函数**已经由 `PanelController` 那个 60Hz 定时器每 16ms 直接调一次
        //   (`startHoverPolling` → `resyncSelectionUnderPointer` ✓)。
        //   ⇒ 面板在台上时每帧白做一遍(还多一次 `Task{}` 跳 + 一次视图更新)✗
        //   实测:面板在台上、指针不动 = **8.2% 一个核**(关着 0.6%)—— 这一处是其中一份 ✓
        //   删掉之后 hover 行为一个字不变(定时器照旧每 16ms 做同一件事),少一层视图刷新 ✓
    }

    /// 当前"应该被选中"的窗下标 —— **永远合法**(见 `selected:` 那条的病例)
    private var selIndex: Int {
        guard !windows.isEmpty else { return 0 }
        return min(max(controller.winIndex, 0), windows.count - 1)
    }

    private func thumb(at i: Int, showsChip: Bool = true, face: CGSize? = nil) -> some View {
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
        if DebugFlags.dumpSources {
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
            // ★★ 2026-10-14 **三层降级重新接线**(用户定稿的架构:「app图标兜底 → 快照 → live,
            //   层层降级,任何场景都不显示异常」✓):
            //   快照必须喂给卡片 —— 否则 2026-09-24 那个「image: nil」就是**把第 2 层整层禁用**:
            //   live 开着时卡片只剩 live 帧 和 App 图标两级 ✗,保温拍了也白拍(卡片根本不读它)✓
            //   (日志铁证:启动首扫 20 窗全拍了,8 张卡在 8.3s 仍 [缺图] ✓)
            //   当年否掉垫图的位移病根已被 de9bf1c 治了:静帧与 live 同一个 SCContentFilter/配置 ✓;
            //   且 Snapshotter 现在 ignoreShadows=true + 不拍子窗 ⇒ trimTransparentEdges 对普通窗
            //   是空操作,比例与真窗一致 ✓(真有透明衬边的自绘窗:换源那一下轻微移动,量尺
            //   CardRulerLog 会报,先接受 —— 比 App 图标好一个量级 ✓)。
            //   显示顺序不变:liveFrame 优先,快照只在 live 还没到的 ~30–100ms 里顶上 ✓。
            //
            // 〔史·同日已撤〕曾试过"开实时预览时不垫快照"(为了让源切换消失)⇒ 冷启动露 App 图标 ✗
            //   抽帧量到"快照 → live"那一拍亮度掉 8%(192.8 → 177.8),`[源比]` 查到只有
            //   **半透明窗口**有这个差,而且三个通道**同比例**:
            //     ```
            //     Sublime   live 47.5/73.2/92.7 · 快照 53.6/83.0/103.7  → 0.886/0.882/0.894
            //     Chrome    live 237.7/238.2/238.5 · 快照 237.2/237.8/238.2 → 相等
            //     ```
            //   同比例 = **alpha**,不是 gamma/色彩空间:Sublime 的窗是半透明的 ⇒
            //   快照是"合成完的桌面"(不透明、亮),live 帧是"带 alpha 的原窗"(叠在卡片深色底上 ⇒ 暗)✗
            //   ⇒ 这两张图**本质上不可能一样**(一个是合成结果、一个是带通道的原料),
            //     所有"让它俩看起来一样"的路都走不通(色彩空间已对齐、逐帧对比确认)。
            //   ⇒ 干脆**不垫快照**:有缓存帧就直接出图(跨会话保留 ⇒ 绝大多数卡开面板即有图),
            //     没有就先显示静默图标,首帧到了直接出 —— 只发生一次"从无到有",不再有两次切换 ✓
            //   (关掉实时预览时快照仍是主力,那条路不变 ✓)
            // ⚠️ 2026-10-20 撤:上一版为了绕开"半透明窗的 alpha 差"把垫图关了,结果冷启动时
            //   卡片只能先显示 App 图标(用户:「第一次开始出现 app 图标了…别越改越坏了」)✗
            //   ⇒ 垫图留在原位。半透明窗(`[源比]` 里那个 0.886 的 alpha)那一下还没治好,
            //     但**宁可一次小闪,也不要一张空卡** ✓
            image: snapshotter.cache[w.wid],
            // 卡面 = 按真窗比例(用户的原始设计 ✓);换组位移已知并接受 ✓
            // 单窗口时由调用方给一张"放宽过的脸"(见 `PanelMetrics.soloWiden`)✓
            face: face,
            liveBox: LivePreviewPool.shared.box(for: w.wid),
            // ★★ 2026-10-20 病例(用户:「切换到 app 之后卡片出现,闪烁就跟着来了」):
            //   换组那一拍 `winIndex` 可能还停在旧组的值上(比如旧组有 2 窗、选的是第 2 窗,
            //   而新组只有 1 窗)⇒ `i == winIndex` 一张都不成立 ⇒ **整块卡按"未选中"(0.72)
            //   画了一帧**,下一刻又补上选中 ⇒ 一次亮度突变 = 闪 ✗
            //   ⇒ **结构上**掐死这一类:`selIndex` 永远夹在窗口数之内 ⇒ 任何一帧都恰好有一张是选中的 ✓
            selected: i == selIndex, // 换窗即接力:弹簧打断保速
            // 落位 = **row 版式专属**(按版式判,不按卡判):
            // 轨道模式下连单窗特例(卡+底芯片,走 row 网格)也不落位 ——
            // 用户实报(2026-10-25):「IDEA 窗口一样大也有先缩后放的动效」✗
            // 病根:单窗组走 row 网格,onAppear 每次换组都落位 ✗
            settlesOnSwap: WindowLayout.current == .row,
            showsChip: showsChip,
            // 换环(↓/↑/Tab 跨段)那一拍:卡片的选中动画一律不给(否则换组时整行重排被动画化 ⇒ 从左边浮出来)
            motionSuppressed: controller.isRingSwapInFlight || controller.isContentSwapInFlight,
            ringSelectMotion: controller.selectionAnimation(PanelMotion.select),
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
        )
        .onHover { inside in if inside { controller.hoverWindow(i) } }
        // 量出自己在托盘坐标系里的位置(**放在 offset 之前**:offset 只是绘制位移,
        // 量到的必须是布局位置,否则下一轮 FLIP 会把自己上一轮的位移再算一遍 ✗)
        .background(GeometryReader { g in
            Color.clear.preference(key: CardFrameKey.self,
                                   value: [w.wid: g.frame(in: .named("glance.tray"))])
        })
        // 删窗重排:先补回旧位置(`flipOffset`),再动画化到 0
        .offset(flipOffset[w.wid] ?? .zero)
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
        // ★ 2026-09-24 **帧拍从视图挪进定时器**(与托盘同一刀):
        //   原来这里挂着一个**没有 paused 的** `TimelineView(.animation)`(面板不在台上也照跑 ✗),
        //   每帧只为调一次 `pollLaunchHover()`。现在它与主环、托盘**共用那一个 60Hz 定时器**
        //   (`startHoverPolling` ✓)—— 一份账、一处节拍,视图这边一拍都不刷 ✓
        //   `pollLaunchHover()` 自带全部守卫(entrySelected / 托盘在台上 / 指针落在玻璃里 ✓),
        //   每拍调用很便宜 ✓
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
            .frame(width: PanelMetrics.pitch, height: PanelMetrics.icon)
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
    /// 同一格子换成另一扇窗时,要不要"落位"一次(实验台 v4 定稿:轨道版式**不落位** ——
    /// 换窗唯一的动作 = 卡形变;落位只属于唤起那一刻的默认窗)。row 版式保持 true ✓
    var settlesOnSwap: Bool = true
    /// **是否在卡片下方画芯片**(2026-10-25,ADR-0017):轨道模式下由右侧轨道承担芯片 ⇒ 卡片不带 ✓
    var showsChip: Bool = true
    /// 卡片的浮层(红绿灯):泛型入参,免得把面板控制器的依赖引进来
    /// **换组那一拍为 true** ⇒ 卡片自己的选中动画一律不给(见下面 `selMotion` 的病例)
    let motionSuppressed: Bool
    /// 环里"选中一颗 App"那条动画(`controller.selectionAnimation(PanelMotion.select)`)——
    /// 卡片**共用同一个源**,速率自然一致 ✓
    let ringSelectMotion: Animation?
    @ViewBuilder let traffic: () -> Overlay
    /// demo `.win:hover` —— **只点灯,不动几何**(2026-10-19)
    @State private var hovered = false

    /// 卡片选中动效的统一开关。
    ///
    /// ★★ 2026-10-19 病例(用户稳定复现:「切到 Sublime 第二个窗口,再切到 IDEA,
    ///   IDEA 的卡从左边浮出来」):
    ///   行里的 `ForEach` 用的是**索引 id** ⇒ 换组时同一批视图实例被复用 ⇒ `selected`
    ///   在这一拍翻转 ⇒ `.animation(value: selected)` 生效;而**同一拍整行也在重排**
    ///   (新组的卡宽度不同 ⇒ 每张卡的 x 变了)⇒ 这些位移被一起动画化
    ///   ⇒ 视觉上就是"卡片从左边浮出来"✗。
    ///   托盘层早就有这条守卫(`.transaction { if isRingSwapInFlight { t.animation = nil } }`),
    ///   但 `.animation(_:value:)` 会**自己造一个事务**,把外层的 nil 覆盖掉 ⇒ 必须在卡片自己也守一道 ✓
    /// 卡片的"明暗"过渡:**永远有**(不受换组抑制) —— 见 `opacity` 那条的病例。
    private var fadeMotion: Animation? {
        WindowLayout.current == .rail ? nil : .easeOut(duration: 0.16)
    }
    /// "落位"的缩放(平时恒为 1)。见 `settleIn` 的病例。
    @State private var entrySettle: CGFloat = 1
    /// 落位动画的令牌(新的一次开始 ⇒ 上一次的步进自己退出 ✓)
    @State private var settleToken = 0

    /// 一张卡**从无到有出现**时落位一次(2026-10-23 用户口径:
    /// 「app 切换也算入场 —— 只要卡片窗口是从 0 出现在这个屏幕上」)。
    /// 触发点只有两个:① 视图首次出现 ② 这个格子里换成了**另一扇窗**(`record.wid` 变了)。
    /// 同一组内只换选中(winIndex 变)⇒ 不动 —— 那才叫"效率" ✓
    /// 明暗/糊化**当拍落**,且走禁动画事务 —— 祖先任何 `.animation(value: wid)`
    /// 都带不动它(2026-10-25 用户实报「换窗还有闪动」:dim 修正被形变动画播成
    /// 0.16s 渐变 = 闪 ✗)。明暗是"状态落定",不是动效 ✓
    private func landDim() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            dim = dimTarget
            blurFade = blurFadeTarget
        }
    }

    private func settleIn() {
        // ★★ 2026-10-23 用户裁定:「只针对默认选中的窗口,再加强幅度」+「时有时没有」。
        //   "时有时没有" = **时序问题**(靠 `async`/16ms 猜帧,猜中才动,没猜中就被合并成一帧)✗
        //   ⇒ 改成**自己按帧推**(与窗口淡入 `fadeInWindow` 同一套):每 8ms 一步,
        //     首帧画起始值、后续每步都是一次真实提交 ⇒ 稳定可见 ✓
        guard selected else { entrySettle = 1; return }
        let start = (UserDefaults.standard.object(forKey: Keys.debugCardSettleScale) as? NSNumber)?
            .doubleValue ?? 0.90
        entrySettle = CGFloat(start)
        settleToken += 1
        let token = settleToken
        let t0 = CACurrentMediaTime()
        let dur = 0.20
        if isTraceEnabled { glog("[落位] wid=\(record.wid) start=\(start)") }
        func step() {
            guard token == settleToken else { return }
            let t = min(1, (CACurrentMediaTime() - t0) / dur)
            let e = 1 - pow(1 - t, 3)                       // easeOut
            let bump = 0.012 * sin(Double.pi * t)           // 一点回弹(峰值 +1.2%;0.02 被评"有点重"✗)
            entrySettle = CGFloat(start + (1 - start) * e + (1 - start) * bump)
            if t < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: step)
            } else {
                entrySettle = 1
            }
        }
        step()
    }

    /// 卡片的明暗(0.72 = 未选中)。**必须单独一个标量**:直接拿 `.animation(_:value:)` 挂
    /// opacity 会把同一拍的布局变化一起动画化 ⇒ 卡片从左边滑进来 ✗(见 `opacity` 那条)
    @State private var dim: Double = 1
    /// 磨砂层的透明度(1 = 全糊,0 = 清晰)。切换选中时与 `dim` 同一套时机推进 ⇒ 两条过渡永远同拍 ✓
    @State private var blurFade: Double = 0
    private var blurFadeTarget: Double { selected ? 0 : 1 }
    /// **最新那一帧的磨砂版**(非选中卡用它;选中期间在后台按 ≤5fps 重算)
    @State private var blurredLive: CGImage?
    @State private var blurBusy = false
    @State private var lastBlurAt: CFAbsoluteTime = 0


    /// 在**后台**把一帧糊掉(主线程只贴图)。
    /// ★ 为什么不预烘焙:实时帧一直在变 ⇒ 只能"跟到最近一帧";代价是每张卡最多 5 次/秒的小图卷积,
    ///   在后台队列上(不在渲染路径)⇒ 看不出来 ✓
    private func refreshBlurredLive() {
        guard !blurBusy, let frame = liveBox.image else { return }
        blurBusy = true
        let radius = PanelColors.cardBlur
        CardBlur.queue.async {
            let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let out: CGImage? = {
                let ci = CIImage(cgImage: frame).clampedToExtent()
                guard let f = CIFilter(name: "CIGaussianBlur",
                                       parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: radius * 2]),
                      let img = f.outputImage?.cropped(to: rect) else { return nil }
                return CardBlur.context.createCGImage(img, from: rect)
            }()
            DispatchQueue.main.async {
                if let out { self.blurredLive = out }
                self.blurBusy = false
            }
        }
    }
    /// ★★★ 2026-10-25 第三次改(用户实录:非选中卡的"模糊玻璃像是追加上去的,有一种动效后渲染的感觉"):
    ///   真凶不是模糊,而是**模糊 + 整卡 0.72 不透明度**叠出来的奶白感 ——
    ///   72% 的卡压在面板底色上,再糊一层,读起来就是"贴了张半透明的纸" ✗
    ///   `0.72` 是"未选中卡还是清晰图"时代的口径(那时靠压暗表达非选中);
    ///   现在**磨砂已经把内容弱化掉了** ⇒ 再压暗是双份,而且压暗本身让"底下有东西"这件事变假 ✗
    ///   ⇒ 非选中**不再压透明度**(1.0),深浅只由磨砂负责 ✓
    ///   (要更强区分的话:动 `PanelColors.cardBlur`(模糊半径),不要回到透明度 ✗)
    private var dimTarget: Double { 1 }
    private var dimTargetIsOn: Bool { selected }

    private var selMotion: Animation? {
        // ★ 2026-10-25 用户口径:「针对这个样式,把现在窗口上的动效全部先去掉」
        //   ⇒ 轨道样式**一律无动画**(选中缩放/上浮/阴影/明暗全部当拍落)。
        //   等"无动效版本"先在实机上认可,再逐个往回加。
        if WindowLayout.current == .rail { return nil }
        // 🧪 2026-10-20 A/B 结论:把这条动画关掉后**照样闪** ⇒ 与动画无关,已恢复。
        return motionSuppressed ? nil : ringSelectMotion
    }

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
        // 卡片尺寸 = min(真窗, 上限)(见 PanelMetrics.thumbSize 的用户口径);
        // 给了 `face`(单窗口放宽 / 统一卡面)时以它为准 —— 否则图会按旧上限缩、卡里留边 ✗
        face ?? PanelMetrics.thumbSize(real: record.bounds.size, aspect: record.aspect)
    }

    private var cardW: CGFloat {
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return PanelMetrics.thumbWidth(aspect: CGFloat(cg.width) / CGFloat(cg.height))
        }
        return PanelMetrics.thumbWidth(aspect: record.aspect)
    }

    /// 卡面的优先源:live 开 ⇒ live 帧(**关掉后 boxes 里还留着旧帧** —— 显示层也要跟着关门,
    /// 不然关了还显示冻结帧 ✗);live 关 ⇒ nil,快照照常当主力。
    /// ★★★ 2026-10-25 第二次修(用户实录:「我切到 VPN 的开启窗口之后,蒙层下面的画面明显还是
    ///   上一次的快照,没有更新」):
    ///   第一版把非选中的实时帧直接关掉 ⇒ 非选中卡显示的是**旧快照**,选中卡显示的是**最后一帧流**
    ///   ⇒ 一切换就"内容跳一下"✗。用户的预期很朴素:
    ///   「整个操作过程中我根本没有切换窗口 ⇒ 选中卡片时,它应该只是蒙层的玻璃变化,内容确实是在的」
    ///   ⇒ 底图**永远是最后那一帧流**(不分选中),非选中只是把**这一帧**糊掉 ⇒ 内容连续 ✓
    private var liveFrame: CGImage? {
        LivePreviewPool.enabled ? liveBox.image : nil
    }

    var body: some View {
        // 卡片与芯片**分离**:环、浮起、阴影都只长在卡片上,芯片是卡片之外的一枚胶囊
        // (用户口径:"不跟预览窗耦合" —— 所以选中态的各种形变不会拖着芯片一起动)
        VStack(spacing: PanelMetrics.chipGap) {
            card
            if showsChip { chip }
        }
        // 卡片 + 芯片的总高 = 卡片实际高 + 芯片那一段(芯片段高度 = thumbH − shotH,是本局的常量)
        .frame(width: box.width,
               height: box.height + (PanelMetrics.thumbH - PanelMetrics.shotH))
        // demo `.win:hover` 的唯一作用:**点灯**(三粒灯浮现),几何一动不动 ✓
        .onHover { hovered = $0 }
        // 明暗:换组那一拍当拍落(与几何一致),其余时候 0.16s 过渡
        .onAppear {
            landDim()
            // 轨道卡:settlesOnSwap=false ⇒ 永不落位 —— 换窗在 SwiftUI 侧是"新实例"
            //(onAppear 会重跑),只堵 onChange 堵不住;落位是 row 专属 ✓
            if settlesOnSwap { settleIn() } else { entrySettle = 1 }
        }
        .onChange(of: selected) { _, _ in
            // ★ 换组那一拍:当拍落(与几何一致)。
            //   其余时候**推迟一拍**再改 `dim` —— 让"明暗"落在**另一个事务**里。
            //   踩过的两次:① `.animation(v, value: selected)` 把同一拍的布局一起动画化 ⇒ 左滑入场 ✗
            //            ② `withAnimation { dim = … }` 和布局更新挤在同一拍 ⇒ 同样左滑 ✗
            if motionSuppressed {
                landDim()
            } else {
                DispatchQueue.main.async {
                    // 这一拍里选中又变了(连按 Tab)⇒ 以最新的为准,别把旧值写回去
                    guard selected == dimTargetIsOn else { return }
                    dim = dimTarget
                    blurFade = blurFadeTarget
                }
            }
        }
        // 同一个格子里换了另一扇窗(ForEach 是索引 id ⇒ 视图实例会被复用)⇒
        // 明暗重置,并且**这一张是新出现的** ⇒ 落位一次 ✓
        // 每来一帧(过渡期也来)⇒ 最多 5 次/秒重算磨砂(§见 `refreshBlurredLive`)
        .onChange(of: liveBox.image.map { ObjectIdentifier($0) }) { _, _ in
            guard !selected else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastBlurAt < 0.2 { return }
            lastBlurAt = now
            refreshBlurredLive()
        }
        .onChange(of: selected) { _, nowSel in
            // 刚变成非选中:立刻把"最后那一帧"糊一次(宽限期内流还在跑,后面会继续跟)
            if !nowSel { lastBlurAt = 0; refreshBlurredLive() }
        }
        .onChange(of: record.wid) { _, _ in
            landDim()
            if settlesOnSwap { settleIn() }   // 轨道版式:false ⇒ 换窗只形变,不落位 ✓
        }
    }

    /// 预览卡本体:**只有截图**(顶边毛玻璃 + 红绿灯 + 选中环都长在它身上)
    private var card: some View {
        ZStack {
            // ★ 分支条件必须是"有**任何一种**图":只看 image 会在"有实时帧、还没截图"时掉进静默态 ✗
            //   (S3 摘掉截图之后,live 开时那种情况就是常态 ✓)
            if liveFrame != nil || image != nil {
                // **fill 定版**(2026-09-14 试过 fit,退回):
                // fit 虽然不裁内容,但卡片是**定尺**的窗口卡,而红绿灯锚在卡片左上角 ——
                // 宽窗(终端 1.83)被 fit 上下留出"信纸边"后,三粒灯就落在浅色空边上,
                // 用户实评"加歪了"。fill 只裁两侧几个点,内容仍是满幅,灯稳稳落在画面里。
                // ★ 2026-09-21:底图走**缓存**(已按卡片像素尺寸缩放过)。
                //   病灶:`Image(nsImage:)` 每次重建都要 decode + 把 720px 缩到卡片尺寸 ✗
                //   ⇒ 实机:托盘更新平时 0.1–0.3ms,一换 app 就 10–27ms(滑块那一帧掉帧)。
                //   没缩好时先用原图,下一次渲染就走缓存 ✓
                // ★★★ 2026-10-20 定版(第五次,这次是"结构"而不是"调参"):
                //   **静帧永远垫在最底下,实时帧叠在它上面** —— 不是"二选一"。
                //   为什么这才对(病历):半透明窗口(用户的 Sublime,alpha≈0.886)那两张图
                //   **本质不同**:
                //     · 静帧 `SCScreenshotManager` = 已合成的**成品**(桌面透出来的样子,不透明)
                //     · 实时帧 `SCStream` = 带 alpha 的**原料**(叠在卡片深色底上 ⇒ 暗 12%)
                //   "二选一"式的切换 ⇒ 无论怎么调都一样跳 ✗(色彩空间/缩放/初帧都排查过,均不是)
                //   ⇒ 改成**叠放**:不透明窗口被实时帧 100% 盖住(切换零感知 ✓);
                //     半透明区域实时帧与静帧混合 ⇒ 样子与静帧一致 ⇒ 切换也看不见 ✓✓
                ZStack {
                    if let image,
                       let prepared = CardImageCache.shared.image(wid: record.wid, source: image,
                                                                 target: imageBox) {
                        Image(decorative: prepared.cg, scale: prepared.scale).resizable()
                    } else if let image {
                        Image(nsImage: image).resizable()
                    }
                    // ★★★ 2026-10-25:非选中卡盖一层**烘焙好的磨砂**(见 `CardImageCache.blurredImage`)。
                    //   ① 让"有流/没流"在视觉上不存在 ⇒ 只给选中那张起流(22 条 → 1 条)✓
                    //   ② 交接走 **0.16s 的"对焦"**(磨砂层淡出/淡入),不是硬切:
                    //      同一张图的模糊↔清晰,不是"两个时刻的鬼影"⇒ 不会重演 dissolve 那条禁令 ✓
                    if let liveFrame {
                        // ★ S2:实时帧优先(现在**不分选中** —— 见 `liveFrame` 的病例)。池的缓冲按"卡片上限高 × 窗口比例"出图 ⇒ 与 imageBox 同比例
                        //   ⇒ 既不放大也不裁边(与截图那条**同一把尺子**)✓
                        Image(decorative: liveFrame, scale: 1).resizable()
                    }
                    // ★★★ 磨砂层**盖在最上面**(它必须糊住"最新的那一帧"):
                    //   · 优先用**实时帧的磨砂版**(选中期间一直在后台按 ≤5fps 重算)⇒ 内容是新的 ✓
                    //   · 还没有过任何实时帧(本次运行从没选中过它)⇒ 退回**快照的磨砂版** ✓
                    if !selected {
                        if let b = blurredLive {
                            Image(decorative: b, scale: 1).resizable().opacity(blurFade)
                        } else if let image,
                                  let blurred = CardImageCache.shared.blurredImage(
                                    wid: record.wid, source: image, target: imageBox,
                                    radius: PanelColors.cardBlur) {
                            Image(decorative: blurred.cg, scale: blurred.scale).resizable()
                                .opacity(blurFade)
                        }
                    }
                }
                    // ⚠️⚠️ 交接**不做溶解**(2026-10-20 第二次实测定案,别再试 ✗):
                    //   70ms 短溶解也被读成闪,抽帧量出原因 —— 两端亮度**完全一致**、
                    //   只有中间那 1–2 帧更亮 5%:
                    //     224-226 RGB 45.1(快照) → 228-230 RGB 47.4(混合) → 232+ RGB 45.1(实时)
                    //   两张图来自**同一条管线**(SCScreenshotManager + 同一个 filter/cfg ⇒ 几何、
                    //   色彩都对得上),差的是**时刻**:光标、字符抗锯齿、终端输出都在变 ⇒
                    //   叠起来是"两个时刻的鬼影",不是亮度差 ⇒ 任何 dissolve 都会闪 ✓
                    //   ⇒ **硬切**。要让它真的看不出来,只能让两帧是同一个时刻 —— 做不到 ✓
                    // 定尺 = 这张卡自己的 box ⇒ 图与卡面同比例(既不拉伸也不留白 ✓)
                    // ★ 2026-10-19:内容**向外多画 1pt**(超扫)——
                    //   卡片图层边缘有 1–2px 缝:实测换组时那里会露出 2px 纯黑(2,2,2) 或近白,
                    //   缝里透的是别层(底面/邻层)✗ ⇒ 超扫后被 `clipped()+clipShape` 裁掉,
                    //   缝里看到的永远是卡片自己的内容 ✓
                    // 向外多画 3pt(不是 1pt):除了盖图层缝,**还把窗口截图自带的 1px 白边挤到卡片外**
                    //   (用户:「白边也不要了」—— 那圈 1px 近白 (216,219,222) 量过,正是截图边缘)
                    .frame(width: box.width + 6, height: box.height + 6)
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
        // ★ demo `.win:not(.sel) .thumb{filter:brightness(.72) saturate(.88)}`(2026-10-19)
        //   旧口径是"整卡压到 30% 不透明度"—— 未选中的卡几乎塌成一块灰,用户读作
        //   「缩小的时候先下沉了」✗。demo 的压色**保形保色**,只是暗下去一档 ✓
        // ★★★ 2026-10-20 定版(踩过两次的坑):
        //   ① 闪的最后一层 = 换组那一拍 `selMotion` 为 nil,把**明暗**也一起关掉了
        //      ⇒ 旧卡一帧掉到 0.72、新卡一帧亮起来 = 亮度突变 ✗
        //   ② 第一次修:`.animation(fadeMotion, value: selected)` —— **左滑入场又回来了** ✗
        //      因为 `.animation(_:value:)` 的事务会**往上带走布局**:换组那一拍整行重排
        //      (新组的卡位置不同)被一起动画化 ⇒ 卡片从左边滑进来 ✗
        //   ⇒ 现在:只动一个**标量** `dim`(布局完全不依赖它),用 `withAnimation` 单独改它 ✓
        //     几何(缩放/上浮/阴影)继续听 `selMotion`,换组时照样当拍 ✓
        .opacity(dim)
        .animation(fadeMotion, value: dim)   // ★ 只认 `dim`(布局完全不依赖它)⇒ 不会带走布局 ✓
        // 「对焦」:只认 `blurFade`(布局完全不依赖它 ✓)⇒ 0.16s 磨砂淡出/淡入
        .animation(fadeMotion, value: blurFade)
        .saturation(selected ? 1 : 0.88)
        .clipped()
        // ★★ 雾檐(2026-09-24 深夜,用户拍板「遮罩改到容器顶部,不坐在画面上」):
        //   原来的「座」= 把这扇窗的画面自己糊一份叠上去 —— **图像派生** ⇒ 要等图、要后台算、
        //   换屏要作废 ⇒ "卡面先到、檐后浮"治不干净(前两轮预热只把它缩短,没消灭 ✗)。
        //   檐现在长在**容器自己身上**:静态雾条(`PanelColors.thumbHaze`),首帧就在、
        //   不依赖任何源、无异步 ⇒ 没有后置渲染 ✓。三版座的历史留在案底,免得重走:
        //     · 径向暗斑 → "阴影做的太捞了";· 整条暗渐变 → "要毛玻璃";· 画面自糊(座)→ 后浮 ✗。
        //   形状对齐 demo `.wframe::before`:**单线性** color→clear、只盖过灯胶囊(可读性主力
        //   是灯的胶囊座,这条雾退为兜底 ⇒ 短而淡);单一支线性到 clear ⇒ 没有截断底边 ✓
        // ★ 2026-10-19:**雾檐整条撤掉**(用户:「雾蒙蒙的,不好看。要不就去掉吧」✓)
        //   当年它的职责是"保证红绿灯在浅色画面上可读";但红绿灯现在有自己的**胶囊座**
        //   (半透明底 + hairline + 投影,见 `TrafficLights`),可读性由座承担 ⇒ 雾是重复投保 ✗
        //   而代价是**整条横幅压在画面上** = 为了左上角三粒灯糊掉大半张卡 ✗
        //   ⇒ 真遇到纯白窗口看不清灯,应当加强**灯座**(局部 60pt 宽),不是给整卡盖雾 ✓
        // 三粒灯压在最上面(落位对齐 demo `.lights`:top 8 / left 9)。
        // 点它们不会关面板:点击落在面板内,不触发"面板外点击 = 放弃"那套判定
        .overlay(alignment: .topLeading) {
            if box.width >= PanelMetrics.thumbLightsMinW, box.height >= PanelMetrics.thumbLightsMinH {
                traffic()
                    .padding(.top, 8).padding(.leading, 9)
                    // demo `.lights{opacity:0;translateY(-5px)}` → `.win:hover/.sel .lights{opacity:1;none}`
                    .opacity(hovered || selected ? 1 : 0)
                    // ⚡ 2026-10-19:**去掉上下位移**(用户:「红绿灯还是掉下来的」):
                    //   demo 的 `translateY(-5px)→0` 在这个场景里只有副作用 ——
                    //   换组时卡片视图被复用,新组的灯是"从隐藏态浮现",那条上落动画照样会播 ⇒ 掉下来 ✗
                    //   灯只做**淡入淡出** ⇒ 无论从哪条路径出现,都不会有竖直位移 ✓
                    // 藏着的时候不吃点击(不然点在卡顶会误触红绿灯)
                    .allowsHitTesting(hovered || selected)
                    // ★★ 2026-10-19 定版(用户:「正常单窗口是没有淡入淡出的,不一致了」):
                    //   灯**一律不做过渡** —— 要么在、要么不在,与单窗口时的观感完全一致 ✓
                    //   走过的弯路都在这里,别再捡回来:
                    //     · `offset(y:-5→0)` 上落 ⇒ 换组时被读成「红绿灯跟蜘蛛一样从上面掉下来」✗
                    //     · 只守换组那一拍 ⇒ 灯常在守卫窗口之后才浮现,拦不住 ✗
                    //     · 改为纯淡入淡出 ⇒ 与单窗口(直接亮)不一致 ✗
                    //   ⇒ 无过渡 = 唯一与"正常情况"一致的做法 ✓
                    // ⚠️ 但**光删自己的 `.animation` 没用**:卡片末尾那条
                    //   `.animation(selMotion, value: selected)` 会给整棵子树加动画(灯的 opacity 也在里面)✗
                    //   ⇒ 必须在这里**断掉继承的动画事务** ✓
                    .transaction { $0.animation = nil }
            }
        }
        .background(PanelColors.thumbBg)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous))
        // ★★ 2026-10-20(用户:「卡片有点太单薄了,加点阴影,显得有厚度」):两层影子,挂在**一块
        //   不变的形状**上,而不是挂在内容上 ——
        //   ⚠️ 中途试过"深色受光边"(顶亮→底隐的 1pt 渐变):实机读成**一圈亮描边**(还带蓝),
        //      用户评「有点丑,而且没什么感知强化的作用」⇒ 撤掉。深色下的厚度只能靠影子本身,
        //      亮线一画就是"框"(那个旋钮此路不通,别再试 ✗)
        //   ① 内容 = 20fps 的实时预览,影子若包着它,每来一帧都要把整卡重新离屏糊一次(贵);
        //      单独一块等尺寸的圆角矩形是静态的,系统的光栅化结果能复用 ✓
        //   ② 影子**只留一层**:试过加"贴身接触影"做厚度,实机评「意义不大」⇒ 撤 ✓
        //      卡片想要"厚",在深色下不是靠影子层数(用户已连否三条:亮描边/接触影/加重散影)
        .background {
            RoundedRectangle(cornerRadius: PanelMetrics.rThumb, style: .continuous)
                .fill(PanelColors.thumbBg)
                .elevation(selected ? .thumbLift : .thumb)
        }
        // ⚠️ 2026-10-19:这里曾有一层"向外 1pt 的卡片底色"(给图层缝做双保险)——
        //   它比卡片大一圈、又是深色 ⇒ 在深色模式下等于给卡片**描了一道 1pt 暗边** ✗
        //   (用户实拍「深色模式下卡片怎么还有边框」;实测边缘正是 2px 的 (33,38,43))
        //   缝已由截图超扫盖住(见上面 `box.width + 6`)⇒ 这层保险撤掉 ✓
        .animation(selMotion, value: selected)
        // ★ 选中 = **阴影强化**(2026-10-19 用户:「不要这个环了,demo 好像是用阴影强化表达的」✓)
        //   旧病:换成 `thumbActive`(y 8→10 / r 9→11)在芯片背后变浓 ⇒ 读作"芯片被按了一下"✗
        //   ⇒ 新档 `thumbLift`:**大 blur(34)+ 远 y(18)** ⇒ 影子散开、边界糊 ⇒ 只读"抬起来",
        //     透出半透明芯片时也是渐变而非硬边 ✓
        .animation(selMotion, value: selected)
        // ★ demo `.win:not(.sel) .thumb{scale(.94)}` / `.win.sel .thumb{scale(1.05)}`
        //   缩放**只作用在卡片上,芯片一动不动**(2026-10-19 用户第三次裁定:
        //   「不能固定吗?只动窗口」—— 之前把整体一起缩,芯片跟着上下浮 = 打地鼠 ✗)
        //   hover 不参与(否则指针扫过整排集体伸缩 = 太空漫步机 ✗)
        //   锚点 = **底边中心**:卡片的下缘钉在芯片上方不动 ⇒ 卡片与芯片的间距恒定,
        //   芯片永远不会"被落下"(2026-10-19 用户:「芯片又跟着下沉了」✗ —— 中心锚点缩小时
        //   卡片下缘上移,间距被撑大,读起来就是芯片下沉)
        // 🔬 2026-10-19 实验结论:缩放置 1.0 时右缘那条线**照样闪** ⇒ 与缩放无关,已恢复
        // ★★★ 2026-10-23(用户选的 A 方案,口径:「只在入场的时候做, 别的场景都不需要」):
        //   入场时卡片**落位**:0.985 → 1(120ms easeOut),选中那张带一点回弹(180ms)。
        //   · 只动 `scaleEffect`(纯绘制,不碰布局)⇒ 不会重演"卡片从左边滑进来"✗
        //   · 触发点 = 这张卡**从无到有**(首次出现 / 格里换成另一扇窗);只换选中不动 ✓
        .scaleEffect((selected ? 1.05 : 0.94) * entrySettle, anchor: .bottom)
        // ⚡ 不用 demo 那条带过冲的 ease-spring(2026-10-19 用户:「切换的话,有那个弹簧效果」✗):
        //   连按 Tab 换选中时几次过冲叠在一起 = 弹跳感;鼠标一格一格挪时看不出来
        //   ⇒ 与环/阴影同一条 easeOut 0.3s ⇒ 键盘与鼠标**完全同一种动效** ✓
        .animation(selMotion, value: selected)
    }

    /// 窗口名**芯片**(2026-09-24 按「预览容器整体设计 Demo」重塑):
    /// 胶囊**与卡片同宽** —— 左起:圆角方形小图标(这张卡属于哪个 App,方案 1「身份自带」✓)
    /// + 标题(中段截断)+ 右端:选中圆点。圆点语义不变(亮 = **系统强调色**,demo 那颗绿点
    /// 我们不用绿 —— 用户口径"依旧保持跟随系统色" ✓),只是从标题前面挪到胶囊右端。
    private var chip: some View {
        HStack(spacing: 5) {
            // 取 `AppIconCache`(按 pid 缓存 ✓ 不进渲染路径的重活 ✗)
            if let appIcon = AppIconCache.icon(pid: record.pid) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: PanelMetrics.chipIcon, height: PanelMetrics.chipIcon)
                    // demo:图标是 6px 圆角方形(6/20 = 0.30,不是 emoji 风格)⇒ 收一道小圆角
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.chipIcon * 0.30,
                                                style: .continuous))
                    // ★ 2026-10-25(V3,用户从实验台里挑的):未选中**只去饱和**,不动透明度 ——
                    //   整排图标安静下来,字却一个像素不变 ⇒ 可读性零风险 ✓
                    .saturation(selected ? 1 : 0.35)
            }
            Text(displayTitle)
                // regular 而不是 medium:芯片要"轻",字重是最直接的一档(题头那边用 medium 是因为它是标题)
                .font(.system(size: PanelMetrics.titleSize, weight: .regular))
                .foregroundStyle(PanelColors.thumbTitle)
                .lineLimit(1)
                // 中段:芯片宽度不够时保头保尾(尾部才是文件名/工程的区分位)
                .truncationMode(.middle)
                // 占满中段 ⇒ 圆点被顶到胶囊右端(demo 的 flex:1 同手法)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 选中圆点:占位永远在(避免文字跳),只有选中那一枚亮成系统强调色
            // V3:未选中那枚改成**空心**(实心点会抢注意力;空心只交代"位子在这")
            Circle()
                .fill(selected ? PanelColors.chipDotOn : Color.clear)
                .frame(width: PanelMetrics.chipDot, height: PanelMetrics.chipDot)
                .overlay(Circle()
                    .strokeBorder(PanelColors.chipDotOff, lineWidth: PanelMetrics.hairline)
                    .opacity(selected ? 0 : 1))
        }
            // 内边:图标侧紧、圆点侧松(demo `.wtag` 的 6/12 语言;芯片 2026-09-25 放大后同步抬)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
            // ★ 2026-09-21:外层玻璃撤掉后,芯片浮在任何背景上 ⇒ 补一层**极淡投影**,
            //   纯白背景上也能读出一块(与加深后的 chipBg 互补,不是替代)
            // V3:未选中**不投影**(影子是"浮起来"的语言,不属于非选中)⇒ 只留选中那枚的影子
            .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 3, y: 1)
            .overlay(Capsule(style: .continuous)
                .strokeBorder(selected ? PanelColors.chipBorder : PanelColors.chipBorderOff,
                              lineWidth: PanelMetrics.hairline))
            // **没有高光唇**(2026-09-14 深夜删掉的那一段,别加回来):
            // 这里原本有一条"上缘受光唇"—— 沿胶囊弧走、往下收干的一道亮边,理由是"深色里靠受光边
            // 交代我是一块玻璃"。但用户看到的是另一种东西:"像是零几年的 macOS 那种玻璃质感,太过时了"。
            // 这个判断是对的:上缘高光 + 亮描边就是 Aqua 时代那对"会反光的玻璃胶囊"的签名,
            // 而现在的 macOS 早就不用它了(浅色那格当年也没这道唇,它返回的是全透明)。
            // 芯片要的"清透"由**底的半透**承担(透过它看到的是已毛玻璃化的画面),不再由受光边承担。
            // 与卡片同宽(demo:胶囊贴着卡片左右缘),高度仍是 chipH —— 尺寸账一个数没变 ✓
            .frame(width: box.width, height: PanelMetrics.chipH)
            // demo `.win.sel .chip{transition:... .2s}` —— 圆点换色不再硬切
            // ⚡ 换组那一拍**同样不给动画**(2026-10-19 用户:「芯片从左下角出现」✗):
            //   新组卡宽不同 ⇒ 芯片的 frame 宽度也在那一拍变 ⇒ 被这条动画一吃,
            //   芯片就是从旧宽度/旧位置"长"出来的 ✗
            .animation(motionSuppressed ? nil
                       : ringSelectMotion, value: selected)
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
/// `@unchecked Sendable` 的理由:它的状态**只在自己的 `queue` 上碰** ✓(回调里跨队列只传值),
/// 编译器看不到这层约定,只好显式声明 ✓
final class LivePreviewPool: ObservableObject, @unchecked Sendable {
    static let shared = LivePreviewPool()

    private init() {
        // 显示配置变化(接屏/拔屏/改分辨率/换主屏)⇒ 整局作废(见 screenConfigChanged 的病例)
        screenWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.screenConfigChanged() }
    }

    /// 帧率档位 = 设置里的「实时预览」。**"0" = 关**(默认)。S4 起会分成"选中/其余"两档。
    static var tierFps: Int { max(0, Int(UserDefaults.standard.string(forKey: Keys.livePreviewTier) ?? "0") ?? 0) }

    /// **实时预览档位的梯子(唯一一把)** —— 2026-09-22:
    /// 设置面板里是**滑杆**(连续量 ✓)、菜单栏「快速设置」里是**子菜单勾选**(菜单没有滑杆 ✗),
    /// 两种控件必须同梯子 ⇒ 值与文案都只在这里写一次 ✓
    /// (0 = 关:关掉之后不取流,卡片退回静默图标/快照 ✓)
    static let tiers = [0, 5, 10, 15, 20, 25, 30]

    /// 档位 → 人话(0 说"关",不说"0 fps" ✓)
    static func tierLabel(_ v: Int) -> String { v == 0 ? "关" : "\(v) fps" }
    static var enabled: Bool { tierFps > 0 }
    /// 流数上限(LRU 淘汰)
    /// 流数上限:**必须 ≥ 环里的窗口数**(实测环里 ~14 窗)⇒ 给 24 是防呆,不是节流阀。
    /// 教训(2026-09-21):上限小于环的规模 ⇒ LRU 永远在互相淘汰 ⇒ 同一窗口被反复起停 21 次 ⇒ hover 卡死。
    /// 成本由**帧率**控制(S4 分档),不由"砍流数"控制。
    /// **非选中**窗口的帧率(分档,S4 核心)。
    /// 依据(实测):13 条流全按用户档位(10fps)= ~26% CPU ✗,而鼠标只看得到**一张卡**在动。
    /// 5fps 的依据:缩略图尺寸下"有动静"就够(用户看的是选中那张);再低(2fps)会像卡住。
    static let lowFps = 5
    /// 同时开几条直播流。原值 24 的注释写"上限只为防呆,不是节流阀" ✗ —— 实测它**就是**节流阀:
    /// 用户实报「疯狂掉帧…就是刚操作的」,日志铁证:
    /// ```
    /// [直播] 起流池 += … **池内=11** ✗        ← 悬停扫过 12 个 App ⇒ 12 条 SCStream 全留着
    /// [直播] 首帧 P50 45ms · max 99ms          ← 每条起流本身也是 45–99ms 的系统级重活
    /// ```
    /// 而**真正需要"活着"的只有托盘里正被看的那几张**(当前组 ≤3 窗 ✓);
    /// 其余 App 的卡在没被悬停前只是一张静帧 ⇒ 给它留一条流是白付抓屏钱 ✗
    /// (从"冷"到"热"的代价:`首帧 P50 45ms` ⇒ 悬停那一拍内就能补上 ✓ 用户看不见)
    /// ⇒ 收到 6(当前组最常见的 1–4 窗 + 一点余量 ✓)。
    ///
    /// ★★ 2026-10-14 用户实报「有两个 window live 没接入」(那组 8 扇窗 ✓)——
    ///   根因就是这里:6 是**按"最常见的 1–4 窗"估的**,而节流阀管错了地方 ✗
    ///   ⇒ 该节流的是**帧率**(非 hover 的流本来就只给 `lowFps`=5fps ✓),不是**数量** ✗
    ///   ⇒ 改成:上限 = **当前要接的条数**(你看到几张卡就有几张 live ✓)
    ///     硬上限 12 兜住病态情况(几十扇窗时不能无限起流 ✓)
    ///   为什么敢松开:8 条 5fps = 40 帧/秒,比当年那次 11 条 20fps 小一个量级 ✓
    static func maxStreams(_ count: Int) -> Int { min(12, max(6, count)) }
    /// 旧口径的底线(1–4 窗那档别再往下压 ✓)
    static let maxStreamsFloor = 6
    /// 闲置多久才停:局内**不靠它节流**(环里的窗口全程保留),它只回收"已经不在环里"的窗口。
    static let keepAlive: Double = 5.0
    /// "只给选中起流"模式下,旧选中那一条的宽限(2026-10-25)。
    /// 1.5s 的依据:连按 Tab 走一张一张会回到同一扇窗时,它还在 ⇒ 不用重建流(重建 = 45–99ms 系统级重活);
    /// 再长就是白付抓屏钱(那条流人已经看不见了)。
    static let keepAliveSelectedOnly: Double = 1.5

    /// **每扇窗一个可观察帧**(替代原来的 `@Published frames`)。
    /// 两个理由,一个比一个重要:
    ///   ① **崩溃**(2026-09-21 实测 SIGABRT):原来 `frames`/`wanted`/`frameOrder` 被
    ///      「池的串行队列」与「ingest 的主队列回调」同时读写 ⇒ Dictionary 被写坏 ⇒
    ///      崩溃栈 `doesNotRecognizeSelector ← Dictionary._Variant.lookup ← LivePreviewPool.ingest` ✓。
    ///      ⇒ 现在:**可变账本只归池的队列**,主线程只**接收一张图**(写进 box)✓ 两个线程不共享容器 ✓;
    ///   ② **性能**:原来任何一扇窗来帧 ⇒ 整个托盘(观察者)重建 ⇒ 13 条流时 70 次/秒 × N 张卡 ✗。
    ///      ⇒ 现在每张卡**只观察自己那一个 box** ⇒ 只重绘那一张卡 ✓(DockDoor 同款结构 ✓)。
    private var boxes: [CGWindowID: LiveFrameBox] = [:]      // 只在主线程碰
    /// 诊断归因:自上次被探针取走以来,有多少张 live 帧落到了主线程(只在主线程读写)
    @MainActor private(set) var ingestedSinceProbe = 0
    /// 探针取走并清零(主线程调用)
    @MainActor func takeIngested() -> Int {
        defer { ingestedSinceProbe = 0 }
        return ingestedSinceProbe
    }
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
    /// 最后一次 `sync` 的输入(窗口 + 选中)—— 给"档位被改了 ⇒ 立刻重排"用 ✓
    private var lastItems: [(wid: CGWindowID, aspect: CGFloat, box: CGSize)] = []
    private var lastSelected: CGWindowID?
    private var winCacheAt: CFAbsoluteTime = 0
    private var sweepScheduled = false

    /// 把"当前界面上该活的窗口"交给池。池负责开/停到一致(对象池 reconcile)。
    /// - Parameter items: 每扇窗带**卡片盒**(pt,`PanelMetrics.thumbSize(real:aspect:)`,与视图里
    ///   `thumb(at:)` 的 `box` **同一份账**)—— A 修(2026-09-24):出流像素规格的输入也从这里走,
    ///   不许池再从 `SCWindow.frame`(SCK 口径)自己重算一遍 ✗(B5 的另一半:20b3253 只把**公式**
    ///   对齐了,输入还各算各的 ⇒ 同一扇窗两个源仍差 ~1% ⇒ 换源轻微重排)。
    /// 面板在台上吗 —— **关掉之后拒绝再起流**。
    /// ★★ 2026-10-19 病例(用户:「我又没换窗口,一直在共享是为什么呢」):
    ///   关面板那一拍先 `stopAll`,但**同一拍排队的 `sync()`**(来自 `updatePreview`)随后又起了一条流 ✗
    ///   日志铁证:
    ///   ```
    ///   [1050386] 全部停流(面板关闭) 共 1 条
    ///   [1050389] 起流池 += wid=173329 @20fps 池内=0     ← 停完 3ms 又开
    ///   [1164117] 全部停流(环里没有窗口)                  ← 107 秒后才停住
    ///   ```
    ///   ⇒ 那 107 秒里系统一直显示"屏幕共享中"(SCStream 活着)✗
    ///   ⇒ 闸门放在**池子门口**(而不是每个调用方):只要不在台上,谁都起不来 ✓
    /// ⚠️ 闸门**必须同步落**,不许 `queue.async`(2026-10-20 第二次漏:
    ///   日志里 `停流` 之后 136ms 又起了一条,跑满 40.8 秒:
    ///   ```
    ///   [1337745] 全部停流(面板关闭) 共 0 条
    ///   [1337881] 起流池 += wid=18397 @20fps      ← 闸门还没落到,它已经排到门口了
    ///   [1378740] 全部停流(面板关闭)
    ///   ```
    ///   原因:`sync()` 在**关面板之前**就排进队了,而我把 `accepting = false` 也排成一队,
    ///   于是"先排队的那条 sync"先跑、读到还是 true ⇒ 闸门形同虚设 ✗
    ///   ⇒ 用锁,**当场**落闸;`sync` 的执行体里在**运行时**读 ✓
    /// 线程安全的"最新一帧"缓存(主线程可读) —— 用于**上屏前垫图**。
    /// ★ 2026-10-20(用户实测:「一个一个切过去到 Sublime 正常,直接跳过去就闪」):
    ///   直跳时新组的卡片没有实时帧 ⇒ 先画静帧、首帧到了再切 ⇒ 半透明窗那 12% 的 alpha 差就现形 ✗
    ///   ⇒ 上屏前先用**同一个池子里上次的实时帧**顶上(同一条管线 ⇒ 换源看不出来)✓
    private var cachedFrames: [CGWindowID: CGImage] = [:]

    func cachedFrame(for wid: CGWindowID) -> CGImage? {
        let v: CGImage?
        gateLock.lock(); v = cachedFrames[wid]; gateLock.unlock()
        return v
    }

    private let gateLock = NSLock()
    private var acceptingFlag = false
    private func withLock<T>(_ body: () -> T) -> T {
        gateLock.lock(); defer { gateLock.unlock() }; return body()
    }

    private var isAccepting: Bool {
        get { gateLock.lock(); defer { gateLock.unlock() }; return acceptingFlag }
        set { gateLock.lock(); acceptingFlag = newValue; gateLock.unlock() }
    }

    /// 面板上屏 / 散场时由 `PanelController` 调用(同步生效,见上面那条病例)
    ///
    /// ★★ 2026-10-23(用户:「怎么又在不停地监控我的 APP 呀?又在不停地共享」):
    ///   账:71 分钟里起流 **181 次**、关面板 96 次,其中 **60 次是不到 1.5 秒的快速 ⌘Tab** ✗
    ///   每次开面板都先起一条 SCStream ⇒ 系统的"屏幕共享"指示灯跟着亮一下 ⇒ 快速连按就像"一直在共享"。
    ///   而那么短的一瞬,用户看到的是快照/上一帧,**根本没看到动图** ⇒ 这条流纯属白开 ✗
    ///   ⇒ 面板开了之后先等 `streamGateDelay` 再允许起流;真停留下来才起 ✓
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self, !self.isAccepting, !self.handles.isEmpty else { return }
            let wids = self.handles.keys.map(String.init).joined(separator: ",")
            glog("[直播] ⚠️ 面板不在台上却还有 \(self.handles.count) 条流(wid=\(wids)) ⇒ 强制停掉(看门狗)")
            for (_, h) in self.handles { Task { try? await h.stream.stopCapture() } }
            self.handles.removeAll(); self.wanted.removeAll(); self.activeGens.removeAll()
        }
        t.resume()
        watchdog = t
    }

    func setAccepting(_ on: Bool) {
        startWatchdog()
        isAccepting = on
        if on {
            gateLock.lock()
            streamGateOpenAt = CFAbsoluteTimeGetCurrent() + Self.streamGateDelay
            gateLock.unlock()
        }
    }

    /// 面板开着的头这么久**不起流**(快照照常显示;只挡掉"瞄一眼就走"的那些)
    /// ★★ 2026-10-25 第二次调(用户:「打开面板的时候…大概要等一秒它才会把流接上,这个能优化吗」):
    ///   1.2 → **0.2**:1.2 秒是"每局要起 22 条流"那会儿定的;现在**每局只起 1 条**(只给选中那张),
    ///   代价小了两个数量级 ⇒ 让位给"唤起就有活画面" ✓
    ///   0.2 仍然挡得住"误触/连按 ⌘Tab 一闪而过"(那种局本来就 <0.2s,起流纯属白付)✓
    static let streamGateDelay: CFTimeInterval = 0.2
    private var streamGateOpenAt: CFAbsoluteTime = 0
    private var gateRetryScheduled = false
    /// 看门狗(2026-10-23):面板不在台上、池子里却还有流 ⇒ 记一行 + 立刻停。
    /// 用户实报「没有唤起面板怎么还在持续抓」时,这一行就是判据:
    ///   · 有这行 ⇒ 真漏了(带上 wid 与起流时刻,能直接定位)
    ///   · 没这行 ⇒ Glance 没抓,系统那个"正在共享"是它自己的指示(主体写的是 SystemUIServer)
    private var watchdog: DispatchSourceTimer?

    /// - Parameter force: **跳过"名单没变就返回"那条短路** —— 只给"闸到点后的补一次"用。
    ///   ★★ 2026-10-25 用户录屏实证:面板开了 **5.3 秒**,日志里**一条流都没起** ✗
    ///   根因就是闸的重试回头调 `sync(...)`,而那一刻名单/选中都没变 ⇒ 被短路直接返回 ⇒ 永远起不了流 ✗
    func sync(_ items: [(wid: CGWindowID, aspect: CGFloat, box: CGSize)], selected: CGWindowID?,
              force: Bool = false) {
        guard Self.enabled else { return }
        let wids = items.map { $0.wid }
        queue.async { [weak self] in
            guard let self else { return }
            // 面板不在台上 ⇒ **一条都不许起**(见 `isAccepting` 的病例)
            guard self.isAccepting else { return }
            // 面板刚开:先别起流(见 `streamGateDelay` 的病例);到点了带 `force` 再补一次进来
            let openAt = withLock { self.streamGateOpenAt }
            let now0 = CFAbsoluteTimeGetCurrent()
            if !force, now0 < openAt {
                // 闸期间也要**把最新的名单/选中记下来** —— 否则到点补的那一次会拿着进入闸之前的旧值
                // (选中在闸期间可能已经换过:面板开着的前 1.2 秒用户完全可能按 Tab ✓)
                self.lastItems = items
                self.lastSelected = selected
                self.queue.asyncAfter(deadline: .now() + (openAt - now0) + 0.02) { [weak self] in
                    guard let self, self.isAccepting else { return }
                    self.sync(self.lastItems, selected: self.lastSelected, force: true)
                }
                return
            }
            // 无变化 ⇒ 什么都不做(同组换窗口、重复调用都不该碰流)
            // ★ 但**窗口变形**算变化(2026-09-25 用户实报「调整窗口尺寸后再唤起,卡片有黑边」):
            //   出流规格首启冻结(I3)⇒ 窗被拉高/压扁后,流仍按旧规格要帧,SCK 把变小了的窗口
            //   铺进旧缓冲 ⇒ 空出的部分就是黑边 ✗。名单没变、盒子变了 ⇒ 放行去 reconcile 重启。
            // ★★ 2026-10-25 用户实报「展示出来的还是我之前切换的那个旧聊天窗口,而不是我新的这个群聊画面」:
            //   根因是这条"无变化就直接返回"——它只比**窗口集合**,不比**选中是谁** ✗
            //   以前没关系(所有卡都有流);改成"只给选中起流"之后,
            //   **换选中 = 名单没变但该起流的那扇换了** ⇒ 这里提前返回 ⇒ 新选中那张永远拿不到流 ✗
            //   ⇒ 选中变了也算变化(照常走 150ms 防抖,起流不能压在 hover 那一拍 ✓)
            if !force, Set(wids) == self.wanted, selected == self.lastSelected, self.pending.isEmpty {
                let resized = items.contains { it in
                    guard let old = self.lastItems.first(where: { $0.wid == it.wid })?.box else { return false }
                    return abs(old.width - it.box.width) > 1 || abs(old.height - it.box.height) > 1
                }
                if !resized { return }
            }
            self.lastItems = items
            self.lastSelected = selected
            let added = Set(wids).subtracting(self.wanted)   // 刚变可见的那几张(下面补帧用)
            self.wanted = Set(wids)
            for w in wids { self.idleSince[w] = nil }
            // ★ 补帧:上面那条门禁会拦住"不可见时"的派发 ⇒ 换回来时如果池里已有最新帧,
            //   立刻补上(不然卡片要等下一拍才亮 ⇒ 静默态多显示约 100ms ✗)
            for w in added {
                guard let img = self.latest[w] else { continue }
                DispatchQueue.main.async { [weak self] in self?.boxes[w]?.image = img }
            }
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
            // ★★ 2026-10-14 用户:「live 上屏的延迟…虽然有一个 app 样式兜底, 但是延迟加载的体验真的有点影响」✓
            //   机理(那段 150ms 推迟本来就是为治"hover 那一拍丢帧" ✓):
            //     · 面板**刚打开**时池里一条流都没有(会话收场时全停 ✓ 帧保留 ✓)
            //       ⇒ 起流的几十毫秒正好藏在入场动画/落位那一拍里,用户看不见 ✓
            //     · 而推迟 150ms 的代价是**先看到 App 图标兜底, 200ms 后才换成真图** ✗
            //   ⇒ 首屏这一轮(池里**既无已有流、也无在排队的** ✓)**不推迟, 立刻起** ✓
            //     会话中段 hover 换窗**仍然推迟 150ms** ✓(2026-09-21 那条丢帧病例没变 ✓)
            // ⚠️ 第一版写成"整个池子空" ✗ ⇒ 实测几乎不触发(收场时**帧保留**、常留下一条流 ✓)
            //   ⇒ 判据改成:**当前这几张卡一张流都没有**(pending 也算"有" ✓)= 这一屏的第一次填充 ✓
            let coldOpen = items.allSatisfy {
                self.handles[$0.wid] == nil && !self.pending.contains($0.wid)
            }
            // ★ 轨道版式:整池只有 1 条流(选中那张)⇒ 换选中**立即起流**,
            //   不付 150ms 推迟的代价 —— 那 150ms 里卡在图标兜底,
            //   live 首帧(134-177ms 实测)一到就"小图标→满卡"跳一下 = 用户说的落位形变 ✗
            //   row 版式维持 150ms(2026-09-21 hover 丢帧病例没变)✓
            let startDelay = (coldOpen || WindowLayout.current == .rail) ? 0.01 : 0.15
            self.queue.asyncAfter(deadline: .now() + startDelay, execute: work)
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
            self.stopAll(reason: "显示配置变化")
        }
    }

    /// **档位被改了** ⇒ 立刻按新档重排(不必等下一次 `sync`)。
    ///
    /// 病例(2026-09-22,用户要求"你要保证跟代码是联动、是生效的"):
    ///   档位确实是**现读**的 ✓,但 `reconcile` 只在**窗口集合变化**时才跑 ✗
    ///   ⇒ 面板开着的时候从菜单/设置里改档位,那几条流会一直用旧档跑 —— 用户看到的是"改了没反应" ✗
    /// 口径:档位改成 0 ⇒ **全停**(不建流);其余 ⇒ 按新档重排(会走策略的"换档 ⇒ 停+按新档重建" ✓,
    /// 帧保留 ⇒ 不闪 ✓)。错峰 40ms 仍在执行那一侧 ⇒ 不会一次打一堆流 ✓
    func tierChanged() {
        queue.async { [weak self] in
            guard let self, !self.lastItems.isEmpty else { return }
            if !Self.enabled {                       // 档位 = 关
                self.stopAll(reason: "档位改为关")
                return
            }
            // 面板可能是在"档位 = 关"的时候开的(那时 wanted 是空的)⇒ 这里补上名单 ✓
            self.wanted = Set(self.lastItems.map(\.wid))
            for w in self.wanted { self.idleSince[w] = nil }
            self.reconcile(self.lastItems, selected: self.lastSelected, starts: true)
        }
    }

    /// 散场代数:`stopAll` 一次 +1。
    /// ★★ 2026-10-20 第三次漏(日志实证):
    ///   ```
    ///   [57135] 全部停流(面板关闭) 共 2 条     ← 池子清空
    ///   [57186] 起流池 += wid=134602          ← 一条 51ms 前就出发的起流,此刻才走完
    ///   ```
    ///   `stopAll` 只停**当前 handles 里**的流;而这条起流还在 `await window(wid)` 里,
    ///   回来时池子已经清空 ⇒ 它把 handle 注册进空池 ⇒ 成了孤儿,一直采到下次关面板 ✗
    ///   ⇒ 起流带着"出发时的代数",回来发现代数变了 ⇒ 自己停掉/不注册 ✓
    private var epoch = 0

    func stopAll(reason: String) {
        isAccepting = false        // ★ 当场落闸:**在**任何排队工作之前(见 isAccepting 的病例)
        gateLock.lock(); epoch += 1; gateLock.unlock()   // ★ 代数 +1:路上那些起流一律作废
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
            // 决策同样交给策略(单测覆盖"扫到了谁、为什么" ✓)
            for req in LivePreviewPolicy.sweepPlan(now: now, running: self.handles.mapValues(\.fps),
                                                  idleSince: self.idleSince,
                                                  keepAlive: Self.keepAliveSelectedOnly) {
                self.stopStream(req.wid, why: req.reason.logText)
            }
            if !self.handles.isEmpty { self.scheduleSweep() }   // 还有流就继续守着
        }
    }

    /// - Parameter starts: `false` = **这一轮只停/不启**。用于把"起流"挪出 hover 那一拍
    ///   (病例:`SCStream` 创建是系统级重活 ⇒ 放在 hover 路径上会丢 1 拍 ✗,见 sync 的头注)。
    private func reconcile(_ items: [(wid: CGWindowID, aspect: CGFloat, box: CGSize)], selected: CGWindowID?,
                           starts: Bool = true) {
        // ═══ 决策全部交给 `GlanceCore.LivePreviewPolicy`(纯函数、可单测)═══
        // 原先这四段(记闲置 / 回收 / 换档 / 起流)是命令式的,长在这个类里 ⇒ 判断写漏了没人抓得住 ✗
        // (2026-09-22:抽出后第一条单测就抓出"换档后没重建"的漏 ✗)。**执行**留在这里 ✓
        let now = CFAbsoluteTimeGetCurrent()
        // ★★★ 2026-10-25(用户:「气流…不会有人一直把面板开着去查看实时流的情况」
        //   「未选中的卡直接加磨砂玻璃,选中的时候再把流接过来」):
        //   实测账(上一局日志):**峰值并发流 22 条** · 409 次/秒的窗口捕获 · 每局平均起 12.4 条。
        //   而其中**只有选中的那一张**在视觉上需要"动"—— 其余卡改成磨砂静帧后,
        //   流有没有跑**人眼分不出来** ⇒ 只给选中的那张起流:22 → **1 条** ✓
        //   · 旧选中那张仍由 `keepAlive`(这里收到 1.5s)养着 ⇒ 连按 Tab 来回不看不会重启流 ✓
        //   · 起流仍走原来的 150ms 防抖与首屏不推迟 ✓
        let liveItems = items.filter { $0.wid == selected }
        let plan = LivePreviewPolicy.plan(now: now,
                                          items: liveItems.map { ($0.wid, $0.aspect) },
                                          selected: selected,
                                          running: handles.mapValues(\.fps),
                                          pending: pending,
                                          idleSince: idleSince,
                                          tierFps: Self.tierFps,
                                          lowFps: Self.lowFps,
                                          // ★ 上限必须 ≥ 1 + 宽限条数:第一版写成 `max(1, count)`
                                          //   ⇒ 策略的"超限淘汰"每拍把上一条宽限流抢跑掉 ⇒ 宽限形同虚设,
                                          //   每次换选中都重起流(日志实证:同一 wid 反复起停,首帧 72–171ms ✗)
                                          maxStreams: max(1, liveItems.count) + 3,
                                          keepAlive: Self.keepAliveSelectedOnly,
                                          allowStart: starts)
        // ① 记闲置(不立刻停 —— 见 keepAlive)
        for wid in plan.markIdle { idleSince[wid] = now }
        // ②③ 停:回收 + 换档(顺序 = 策略给的顺序,日志文案照旧 ✓)
        for req in plan.stop { stopStream(req.wid, why: req.reason.logText) }
        // ★ 断言"只有该跑的窗才有流"(2026-09-22 `guard wanted.contains(wid)` 那一刀的病根)——
        //   真事故:看不见的卡也在换图(白帧)⇒ 掉帧,而且**没人断言**过 ✗
        //   running = 已建流 ∪ 正在建;keepAlive 豁免 = 刚离开环、还在养着的那几条 ✓
        //   ⚠️ 只算**已建流**:正在排队(pending)的那几条还没起,起流那一拍会再查一次 `wanted` ✓
        //      ⇒ 把它们算进来会误报(冒烟二轮实测:"窗口 88 有流在跑"✗,其实它只是排着队 ✓)
        for viol in SessionInvariants.streamViolations(running: Array(handles.keys),
                                                      wanted: wanted, keepAlive: Set(idleSince.keys)) {
            glog("[不变量] ⚠️ \(viol)")
        }
        // ④ 起:错峰 40ms(避免向 WindowServer 打并发 —— AltTab issue #5861)
        guard starts else { return }
        // ★ ④½ 窗口变形 ⇒ 重启那一条(2026-09-25,黑边病例):出流规格首启冻结(I3),
        //   冻结之后窗口被拉高/压扁 ⇒ SCK 把变了形的窗口铺进旧缓冲 ⇒ 黑边/拉伸 ✗
        //   重启与换档同一手法:**帧保留**(latest/boxes 不动)⇒ 不闪 ✓;
        //   新建流是系统级重活,所以只放在 starts=true 这一轮(hover 防抖同一道闸 ✓)
        for it in items {
            guard handles[it.wid] != nil, let old = frozenSize[it.wid] else { continue }
            let scale = PanelScreen.scale
            let want = CGSize(width: (it.box.width * scale).rounded(),
                              height: (it.box.height * scale).rounded())
            guard abs(old.width - want.width) > 2 || abs(old.height - want.height) > 2 else { continue }
            glog(String(format: "[直播] 窗口变形 ⇒ 重启流 wid=%u %.0fx%.0f → %.0fx%.0f(帧保留)",
                        it.wid, old.width, old.height, want.width, want.height))
            stopStream(it.wid, why: "窗口变形")
            frozenSize[it.wid] = nil
            start(it.wid, box: it.box, fps: it.wid == selected ? Self.tierFps : Self.lowFps)
        }
        var delay = 0.0
        for req in plan.start {
            pending.insert(req.wid)
            let d = delay; delay += 0.04
            let cardBox = items.first { $0.wid == req.wid }?.box
            queue.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self else { return }
                self.pending.remove(req.wid)
                guard self.wanted.contains(req.wid), self.handles[req.wid] == nil else { return }
                self.start(req.wid, box: cardBox, fps: req.fps)
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
        // ⚠️ `winCache/winCacheAt` 也住在池队列上(2026-10-09 那条崩溃的同一类 ✗):
        //    本函数由 `Task`(协作线程)调用 ⇒ 读写都圈进队列;**`await` 留在圈外** ✓
        let cached: SCWindow? = queue.sync {
            CFAbsoluteTimeGetCurrent() - winCacheAt < 2.0 ? winCache[wid] : nil
        }
        if let cached { return cached }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        var hit: SCWindow?
        queue.sync {
            winCacheAt = CFAbsoluteTimeGetCurrent()
            for w in content.windows { winCache[w.windowID] = w }
            hit = winCache[wid]
        }
        return hit
    }

    private func start(_ wid: CGWindowID, box cardBox: CGSize?, fps: Int) {
        // ★ 最后一道:**起流那一刻**再验一次闸门。
        //   `sync` 的执行体可能已经在路上(过闸、正在 reconcile),这中间面板被关掉 ⇒
        //   不验就会"关完照样起一条"✗(2026-10-20 第二次漏的同一族)
        guard isAccepting else { return }
        let myEpoch = withLock { epoch }
        gen += 1
        let g = gen
        activeGens.insert(g)
        Task { [weak self] in
            guard let self else { return }
            guard let win = await self.window(wid) else {
                glog("[直播] 找不到窗口 wid=\(wid)"); return
            }
            let cfg = SCStreamConfiguration()
            // ★ 与快照同一个坑(SDK 文档:child windows are included by default ✓)——
            //   实时帧若不关,同一个 App 的进度窗/面板窗会**叠到这张卡里** ✗
            //   (2026-09-22 用户实报的"两块内容挤在一张卡 + 一块黑"就是它 ⇒ 两条路一起关 ✓)
            if #available(macOS 14.2, *) { cfg.includeChildWindows = false }
            // I3:尺寸**首启冻结** —— 窗口后来变形也不改(改了就是"画面忽然缩放",病例 A3)
            // ⚠️⚠️ 2026-10-09 崩溃病例(用户报「闪退了」· 报告 `Glance-2026-10-09-123701.ips`):
            //   `frozenSize` 原来就在这里**直接读写** ✗ —— 而这段跑在 `Task {}` 的**协作线程**上
            //   ( `start` 是在**池队列**上调的 ✓ —— 这块的老规矩就是"共享字典只在池队列上动" ✓
            //     `handles` 就是这么处理的 ✓,唯独漏了它 ✗)。
            //   触发:两个窗口的流一起起(日志:`起流池 += … 池内=5`)⇒ 两条协作线程同时写同一个字典 ✗
            //   ⇒ 崩溃报告铁证:线程 13(`com.apple.root.user-initiated-qos.cooperative`)
            //     `Dictionary.subscript.setter → _NativeDictionary.setValue → _copyOrMoveAndResize`
            //     ⇒ `EXC_BAD_ACCESS / SIGSEGV`(pointer authentication failure)✓
            //   ⇒ 把它也圈进池队列:`queue.sync` **只包读写、不包 await** ✓
            let size: CGSize = self.queue.sync {
                if let f = self.frozenSize[wid] { return f }
                let scale = PanelScreen.scale
                // ★★ 2026-09-24 A 修:「同一把尺子」要连**输入**一起同源 ——
                //   盒子由调用方按 `record.bounds`(CGWindowList 口径,与卡片盒同一份账 ✓)算好传入;
                //   不再从 `SCWindow.frame`(SCK 口径)重算 ✗。B5 的另一半:20b3253 只对齐了公式,
                //   输入仍各算各的 ⇒ 同一扇窗两个源差 ~1% ⇒ 图"拉伸到 imageBox"铺 ⇒ 换源轻微重排 ✓
                //   (兜底:调用方没给盒子时不至于起不了流 —— 按窗口自己的比例退回同一函数 ✓)
                let pt = cardBox ?? PanelMetrics.thumbSize(
                    real: win.frame.size,
                    aspect: win.frame.width / max(win.frame.height, 1))
                let v = CGSize(width: (pt.width * scale).rounded(),
                               height: (pt.height * scale).rounded())
                self.frozenSize[wid] = v
                return v
            }
            cfg.width = max(2, Int(size.width)); cfg.height = max(2, Int(size.height))
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, fps)))
            cfg.queueDepth = 3; cfg.showsCursor = false; cfg.capturesAudio = false
            cfg.scalesToFit = false
            cfg.ignoreShadowsSingleWindow = true     // 与快照链一致(病例 B6:内容框也要同源)
            let filter = SCContentFilter(desktopIndependentWindow: win)
            // ★★ 2026-10-14 静帧占位(用户:「打开即有真图」✓;当年错位的病根 = **两个图源两把尺子** ✗)
            //   当年:`CGWindowListCreateImage` 自己算取景/缩放 ✗ ⇒ 与 live 差一点点像素
            //        ⇒ 切流那一刻看起来"轻微位移"(用户为它调了很久 ✓)
            //   ⇒ 现在改用 **SCScreenshotManager + 同一个 `filter` / 同一份 `cfg`** ✓
            //     ⇒ 取景与缩放的**来源唯一** ⇒ 与 live **逐像素对齐**(不是凑出来的 ✓)
            //   时机:与起流**并行**发出(不 await 到流之前 ✗,否则白等一次静帧的时间 ✓)
            Task { [weak self] in
                guard let self else { return }
                // ★ 26+ 必须走 captureScreenshot ✗(2026-10-15 事故:captureImage 在 26 上
                //   每次 anew 一个短命 stream ✗ = 「绕过选择器」权限弹窗瀑布 ✗✗
                //   同一把尺子 = 同一套参数,不是同一个函数 ✗)
                var cg: CGImage?
                if #available(macOS 26.0, *) {
                    let sc = SCScreenshotConfiguration()
                    sc.width = cfg.width; sc.height = cfg.height
                    sc.showsCursor = false
                    sc.ignoreShadows = true
                    sc.includeChildWindows = false
                    let out = try await SCScreenshotManager.captureScreenshot(
                        contentFilter: filter, configuration: sc)
                    cg = out.sdrImage
                } else {
                    cg = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: cfg)
                }
                guard let cg else { return }
                // ★★ 2026-10-20 定案(日志实测,别再猜):
                //   ```
                //   [源比] wid=49934 live 47.5/73.2/92.7 **kCGColorSpaceSRGB**
                //                    快照 53.6/83.0/103.7 **nil**
                //   [源比] wid=120   live 42.2/45.4/51.6 **nil**   快照 42.2/45.4/51.6 **nil**
                //   ```
                //   ⇒ 两张图**像素本身一致**;差的只有**色彩空间标签**:SCK 的实时帧带 sRGB 标签,
                //     而 SCScreenshotManager 给的静帧**没有标签**(= 未管理 ⇒ 合成器按显示器空间直出)
                //     ⇒ 同一块像素被两条路解释了两次 ⇒ 切的那一下亮度跳 ~10%(用户读作"高亮闪一下")✗
                //   ⇒ 把静帧**真正转换**到 sRGB 再进管线(只做一次/窗口,不在每帧路径上 ✓)
                let converted = ColorNormalize.toSRGB(cg) ?? cg
                self.queue.async { self.deliver(converted, wid: wid) }   // 与直播帧同一条上屏路 ✓
            }
            // 出发时的代数变了(散场过)⇒ 这条不许起
            guard self.withLock({ self.epoch }) == myEpoch else { return }
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            let out = LiveOutput(wid: wid) { [weak self] sb in self?.ingest(sb, wid: wid, gen: g) }
            do {
                try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: self.queue)
                self.queue.async {
                    self.handles[wid] = Handle(gen: g, fps: fps, stream: s, output: out)
                    self.startedAt[wid] = CFAbsoluteTimeGetCurrent()
                }
                try await s.startCapture()
                // ★ 起完之后再验一次:**已经开始采**的流,如果这期间散场了,必须立刻自杀,
                //   否则它不在 handles 里 ⇒ 没人停得掉 ✗(上面那条 51ms 的孤儿就是它)
                if self.withLock({ self.epoch }) != myEpoch {
                    try? await s.stopCapture()
                    self.queue.async { self.handles.removeValue(forKey: wid) }
                    glog("[直播] 起流途中散场 ⇒ 当场停掉 wid=\(wid)")
                    return
                }
                // ⚠️ 读 `handles` 也要在池队列上(与上面那条同一个病例 ✓ 2026-10-09)
                let poolCount = self.queue.sync { self.handles.count }
                glog(String(format: "[直播] 起流池 += wid=%u %dx%d @%dfps 池内=%d",
                            wid, Int(size.width), Int(size.height), fps, poolCount))
            } catch {
                glog("[直播] 起流失败 wid=\(wid): \(error.localizedDescription)")
            }
        }
    }

    /// 这扇窗的帧是不是**带透明**(窗口半透明)。每扇窗只判一次(16×16 采样)。
    private var translucentWIDs: Set<CGWindowID> = []
    private var translucentLogged: Set<CGWindowID> = []
    private func isTranslucent(_ img: CGImage, wid: CGWindowID) -> Bool {
        if translucentWIDs.contains(wid) { return true }
        let side = 16
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return false }
        // ★★ 2026-10-20 修正(用户实报「访达预览卡片出现了 app 图标」):
        //   上一版用 `min(alpha) < 220` 判半透明 —— **每个窗口的圆角都是透明的** ⇒ alpha 到处是 0
        //   ⇒ **所有窗口都被判成半透明** ⇒ 一条实时帧都不接 ⇒ 没有静帧的窗口(访达)直接露出 App 图标 ✗
        //   ⇒ 改成看**占比**:半透明窗是"大面积的 0.886",圆角只占 1~2% ✓
        var translucent = 0
        for i in stride(from: 3, to: buf.count, by: 4) where Int(buf[i]) < 240 { translucent += 1 }
        let ratio = Double(translucent) / Double(side * side)
        if ratio > 0.20 { translucentWIDs.insert(wid); return true }
        return false
    }

    fileprivate func ingest(_ sb: CMSampleBuffer, wid: CGWindowID, gen g: Int) {
        guard activeGens.contains(g) else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var raw: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &raw)
        guard let img = raw else { return }
        // ★★ 2026-10-20:**半透明窗口不接实时帧**(只用静帧)。
        //   病例(用户:「Sublime … 那一小下还是能看见」):这类窗的实时帧带 alpha(实测 ≈0.886),
        //   静帧是**已合成**的成品(不透明)⇒ 同一扇窗的两张图本质不同,任何切换都能被看见 ✗
        //   它们很少见(Sublime 开了窗口透明度这类),静帧完全够用 ⇒ 判定一次,这类窗不起流 ✓
        if isTranslucent(img, wid: wid) {
            if !translucentLogged.contains(wid) {
                translucentLogged.insert(wid)
                glog("[直播] 半透明窗口 ⇒ 不接实时帧(用静帧) wid=\(wid)")
            }
            return
        }
        // ★ 标签对齐(2026-10-20,与 `CardImageCache` 那条同一个病例):
        //   SCK 的帧**有时带 sRGB 标签、有时不带**(日志里两种都出现过)⇒ 不带的那条会被
        //   合成器按显示器空间直出,与静帧/带标签的帧都不一样 ⇒ 切源时亮度跳。
        //   这里给**没标签的**补上 sRGB(只改标签、不动像素;SCK 的缓冲本来就是 sRGB ✓)
        let tagged: CGImage = img.colorSpace == nil
            ? (CGColorSpace(name: CGColorSpace.sRGB).flatMap { img.copy(colorSpace: $0) } ?? img)
            : img
        let now = CFAbsoluteTimeGetCurrent()
        // ★ 账本更新**就地在池队列上做**(不碰主线程状态 ⇒ 不会再和主线程抢 Dictionary ✓)
        if let t0 = startedAt[wid], !firstFrameLogged.contains(wid) {
            firstFrameLogged.insert(wid)
            glog(String(format: "[直播] 首帧 %.0fms wid=%u", (now - t0) * 1000, wid))
        }
        deliver(tagged, wid: wid)
    }

    /// 一张图**上屏**(直播帧与静帧共用 ✓ —— 两条路各写一份必然漂 ✗,这是本仓的老规矩)
    /// ⚠️ 只在**池队列**上调用(账本 `latest`/`latestOrder`/`wanted` 全是池队列状态 ✓)
    fileprivate func deliver(_ img: CGImage, wid: CGWindowID) {
        if latest[wid] == nil { latestOrder.append(wid) }
        latest[wid] = img
        gateLock.lock(); cachedFrames[wid] = img; gateLock.unlock()
        while latestOrder.count > 10 {
            let old = latestOrder.removeFirst()
            if !wanted.contains(old) {
                latest[old] = nil
                gateLock.lock(); if cachedFrames[old] != nil { cachedFrames[old] = nil }; gateLock.unlock()
            }
        }
        // ★ 只把"**当前显示组**"的帧交给主线程(2026-09-21,归因量出来的账)。
        //   池的 keepAlive=5s ⇒ 换组之后旧的那几条流**还在跑**(为了换回来是热的 ✓),
        //   而它们仍然会被派给主线程 ⇒ 但那些卡**这一刻根本不在屏幕上** ✗
        //   ⇒ 白换一次图 + 白触发一次重绘。实测:悬停长帧里 **2/3** 都带"直播新帧 ≥1"。
        //   现在:帧照样收进 `latest`(换回来立刻有 ✓),但**不派** ⇒ 主线程零工作 ✓
        //   注意:`wanted` 与这里都在**池队列**上 ⇒ 不跨线程读 ✓(那条崩溃纪律不破)
        guard wanted.contains(wid) else { return }
        // 只把这一张图交给主线程 ⇒ 每张卡各自重绘(不重建整个托盘 ✓)
        DispatchQueue.main.async { [weak self] in
            self?.boxes[wid]?.image = img
            // 归因用计数(只在主线程读写 ⇒ 不需要锁):探针拿它回答
            // "这一拍的长帧是不是刚好有 live 帧到货" —— 不然只能猜到渲染/起流头上
            self?.ingestedSinceProbe = (self?.ingestedSinceProbe ?? 0) + 1
        }
    }
}

/// 一扇窗的"最新一帧盒子" —— 卡片 `@ObservedObject` 它,只在自己这扇窗来帧时重绘 ✓
final class LiveFrameBox: ObservableObject {
    @Published var image: CGImage?
}

/// 一条流的输出口(自带 wid ⇒ 归属不靠共享标量,病例 A1)。
/// 同上:回调只在 `LivePreviewPool.queue` 上跑 ⇒ 显式声明 ✓
final class LiveOutput: NSObject, SCStreamOutput, @unchecked Sendable {
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
        glog(String(format: "[尺子] wid=%u 源=%@ · 盒 %.0fx%.0f(%.2f) · 图 %@%@ · 快照 %@%@",
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
/// 把静帧真实转换到 sRGB(与 SCK 实时帧的标签一致)。
///
/// 为什么不是 `copy(colorSpace:)`:那只是**改标签**、不动像素 ⇒ 颜色会被解释错。
/// 这里走一次 CGContext 重绘 ⇒ 真正做一次色彩转换(每扇窗一次,不在每帧路径上)✓
enum ColorNormalize {
    static func toSRGB(_ img: CGImage) -> CGImage? {
        guard img.colorSpace?.name != CGColorSpace.sRGB else { return img }   // 已是 sRGB:原样
        let w = img.width, h = img.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

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
        glog(String(format: "[卡变] wid=%u 卡片 %.0fx%.0f → %.0fx%.0f (真窗 %.0fx%.0f)",
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
        glog(String(format: "[卡尺寸] wid=%u 真窗 %.0fx%.0fpt / 卡片 %.0fx%.0fpt ⇒ **缩放 %.2fx** 裁掉 %.0f%%x%.0f%%",
                    record.wid, win.width, win.height, cardW, cardH, s, cropW * 100, cropH * 100))
        return true
    }
}

/// 卡片磨砂的后台计算工具(`WindowThumb` 是泛型结构体 ⇒ 不能放 static 存储属性)
enum CardBlur {
    static let queue = DispatchQueue(label: "glance.cardblur", qos: .userInitiated)
    static let context = CIContext(options: [.workingColorSpace: NSNull()])
}

final class CardImageCache {
    struct Prepared { let cg: CGImage; let scale: CGFloat }
    static let shared = CardImageCache()

    /// 与 `Design/ImageCache.swift` 同一本账(2026-09-22 合并自两份同形状的代码;座的缓存随
    /// 「座」整体退役 —— 遮罩改成了容器自己的静态雾檐,见 `PanelColors.thumbHaze` ✓)——
    /// 于是**同一个"卡在 inFlight"的 bug 被抄了两遍** ✗
    /// ⚠️ 键是 **(窗 id + 像素尺寸)**，不是"只有窗 id" —— 病例见 `GlanceCore/ImageCacheKey.swift`:
    /// 键只看 id 时，卡片尺寸上限/缩放一变就**永远命中旧尺寸那张图** ✗
    private let cache = ImageCache<ImageCacheKey.Card, Prepared>(label: "glance.cardimg")
    /// ★ 磨砂**烘焙**而不是在视图里 `.blur()`:未选中卡可能有十几张,
    ///   每帧跑十几遍高斯比原来更贵 ✗ ⇒ 一张只算一次,之后就是贴图 ✓
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// 换屏/显示配置变化时清空(图是按当时那块的 scale 缩过的 ✗ 不能跨屏复用)
    func reset() { cache.reset(); blurStore.removeAll() }

    /// 磨砂版(非选中卡用)。**与锐版同一把尺子**(同裁剪、同像素尺寸)⇒ 交接时几何不变 ✓
    ///
    /// ★★ 2026-10-25 用户实报「相当于是两份快照,就很怪」—— 根因在这一行:
    ///   缓存 key 里**没有"这是第几版快照"** ⇒ 保温拍了新图之后,锐图已经换成新的、
    ///   磨砂还是上一版 ⇒ 选中那一刻"糊的"和"清的"根本是两张不同的画面 ✗
    ///   ⇒ key 里带上**源图身份**(`ObjectIdentifier`)—— `image` 换了实例就必然 miss 重算 ✓
    ///   (用一本手写字典而不是 `ImageCache`:键是动态身份的,旧条目要能被清掉)
    func blurredImage(wid: CGWindowID, source: NSImage, target: CGSize,
                      radius: CGFloat) -> Prepared? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = PanelScreen.scale
        let key = ImageCacheKey.card(windowID: wid, target: target, scale: scale)
        let pxW = key.pixelWidth, pxH = key.pixelHeight
        let srcID = ObjectIdentifier(source).hashValue
        let k = "\(wid)-\(srcID)-\(pxW)x\(pxH)-\(Int(radius))"
        if let hit = blurStore[k] { return hit }
        if blurStore.count > 48 { blurStore.removeAll() }
        let out: Prepared? = {
            guard let sharp = Self.draw(cg, pxW: pxW, pxH: pxH) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
            let input = CIImage(cgImage: sharp).clampedToExtent()
            guard let f = CIFilter(name: "CIGaussianBlur",
                                   parameters: [kCIInputImageKey: input,
                                                kCIInputRadiusKey: radius * scale]),
                  let out = f.outputImage?.cropped(to: rect),
                  let cgOut = self.ciContext.createCGImage(out, from: rect,
                                                           format: .BGRA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            else { return nil }
            return Prepared(cg: cgOut, scale: scale)
        }()
        blurStore[k] = out
        return out
    }

    /// 磨砂版的手写账(见 `blurredImage` 的病例:键必须带源图身份)
    private var blurStore: [String: Prepared] = [:]

    /// 把源图按 **.fill 中心裁剪**画进 sRGB 定尺位图(锐/磨砂两条路共用 ⇒ 几何不会各算一套 ✓)
    private static func draw(_ cg: CGImage, pxW: Int, pxH: Int) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let k = max(CGFloat(pxW) / sw, CGFloat(pxH) / sh)
        let srcRect = CGRect(x: (sw - CGFloat(pxW) / k) / 2, y: (sh - CGFloat(pxH) / k) / 2,
                             width: CGFloat(pxW) / k, height: CGFloat(pxH) / k)
        guard let cropped = cg.cropping(to: srcRect) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        return ctx.makeImage()
    }

    func image(wid: CGWindowID, source: NSImage, target: CGSize) -> Prepared? {
        // 老代码在主线程做这一步 ⇒ 保持不变 ✓(而且它在登记之前 ⇒ 失败不占账 ✓)
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = PanelScreen.scale                                    // 主线程取 ✓
        // 目标尺寸由调用方给(方案 A:小窗不放大 ⇒ 目标可能小于卡片框)
        // 像素尺寸与"钥匙"都由纯函数算 ⇒ 两者不会各算一套(那是这类 bug 的温床 ✗)
        let key = ImageCacheKey.card(windowID: wid, target: target, scale: scale)
        let pxW = key.pixelWidth, pxH = key.pixelHeight
        return cache.image(for: key) {
            var out: CGImage?
            // ★★ 2026-10-20 定案(日志实证):
            //   `SCScreenshotManager` 回来的静帧**没有色彩空间标签**(nil),而 SCK 实时帧带 sRGB
            //   ⇒ 同一扇窗的两张图被合成器解释两次 ⇒ 切源那一下亮度跳 ~10%(用户:「从第一张
            //   往后依次闪」—— 每张卡切源时刻不同,所以是**接力**闪)✗
            //   ⇒ 这里重绘时**直接画进 sRGB**(顺带就是一次真实的色彩转换,不是只改标签),
            //     于是卡片上的静帧与实时帧标签一致 ⇒ 切源看不出来 ✓
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: srgb,
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
            return out.map { Prepared(cg: $0, scale: scale) }
        }
    }

    func prewarm(_ items: [(wid: CGWindowID, source: NSImage, target: CGSize)]) {
        for it in items { _ = image(wid: it.wid, source: it.source, target: it.target) }
    }

}

// ═══════════════════════════════════════════════════════════════════
// 芯片轨道(ADR-0017)—— 与上面的「卡片行」完全隔离的一支
// ═══════════════════════════════════════════════════════════════════

/// **芯片轨道**(ADR-0017)—— 与现行「卡片行」完全隔离的第二套组内呈现。
///
/// 什么时候用:设置里 `panel.windowLayout == .rail`,且这一组**多于 1 扇窗**
/// (单窗口仍走老路,那是特例,用户明确"以后再优化")。
///
/// 版式(参数全部来自实验台定稿,见 ADR-0017):
/// ```
/// [ 预览卡(只有选中那扇) ]  14pt  [ 轨道:全部窗口的芯片,一列 ]
///                                      宽 164 · 高 = 卡高 · 无底无框
/// ```
/// 规则:
///   · 选中那枚芯片是**原色**(彩色 App 图标 + 淡胶囊 + 强调色圆点),其余**灰调**(去饱和、无底)
///   · 滚动只为"选中出视口"服务:一次一枚,0.42s easeOut;**选中本身永不滚动**
///   · **无极**:芯片渲染三份、视口停在中间那份 ⇒ 走到最后继续走就是接着滚第一枚,
///     不会反向跳(用户:「第 6 个再滚一次就回到第 1 个」)
///   · 遮罩**有方向**:上面还有内容才渐隐顶部,下面还有内容才渐隐底部;装得下 ⇒ 两侧都不糊
struct ChipRailGroup: View {
    let windows: [WindowRecord]
    let selected: Int
    let bundleID: String?
    let card: AnyView
    /// 轨道高度 = **这张卡的实际高度**(不是上限 shotH)——
    /// 宽窗的卡比 shotH 矮,若按 shotH 排芯片就会顶出卡的上下边(用户实报「芯片位置怎么能比窗口高」)✗
    let railHeight: CGFloat
    /// 选中变化(hover 芯片)
    let onSelect: (Int) -> Void
    /// 点芯片 = 选中并确认
    let onTap: (Int) -> Void

    /// 一屏放几枚(按卡高算,见 `slotCount`)
    private var slotCount: Int {
        max(1, Int((railHeight + PanelMetrics.chipRailGap) / PanelMetrics.chipRailStep))
    }
    /// 首尾**断开**(用户实测:莫比乌斯环会"一直滚下去,有点搞笑"✗)——
    /// Tab 越界时由选中跳变(尾→头/头→尾),视口老老实实夹在 [0, count-slot] ✓
    private var copies: Int { 1 }

    /// 连续坐标:选中在第几枚(可正可负 ⇒ 首尾靠它环绕)
    @State private var selPos: Int = 0
    /// 视口顶端的连续坐标
    @State private var viewPos: Int = 0

    var body: some View {
        HStack(alignment: .center, spacing: PanelMetrics.thumbGap) {
            card
            rail
        }
        .onAppear { selPos = selected; viewPos = selected }
        .onChange(of: selected) { _, new in selPos = new }
    }

    /// 装得下 ⇒ 整列垂直居中、不滚;装不下 ⇒ 才有滚动这回事
    private var fits: Bool {
        CGFloat(windows.count) * PanelMetrics.chipRailStep <= railHeight
    }

    private var rail: some View {
        let lane = PanelMetrics.chipRailWidth
        let height = railHeight
        let step = PanelMetrics.chipRailStep

        // 视口:装得下 ⇒ 整列垂直居中、不滚;装不下 ⇒ 把选中留在视口内(越界才滚一枚 = 一步)
        let oneSet = CGFloat(windows.count) * step      // 每枚占一个 step ⇒ 与上面的 frame 同一把尺子 ✓
        let fits = self.fits
        let offsetY: CGFloat = fits
            ? (height - oneSet) / 2
            : -CGFloat(viewPos) * step
        let showTop = !fits && viewPos > 0
        let showBottom = !fits && viewPos + slotCount < windows.count

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<(windows.count * copies), id: \.self) { idx in
                    chip(logical: idx % windows.count)
                        .frame(height: PanelMetrics.chipRailStep, alignment: .center)
                }
            }
            .frame(width: lane, alignment: .topLeading)
            .offset(y: offsetY)
        }
        .frame(width: lane, height: height, alignment: .topLeading)
        .clipped()
        .mask(
            LinearGradient(stops: [
                .init(color: showTop ? .clear : .black, location: 0),
                .init(color: .black, location: showTop ? 0.13 : 0),
                .init(color: .black, location: showBottom ? 0.87 : 1),
                .init(color: showBottom ? .clear : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) { edgeBand(up: false) }
        .overlay(alignment: .bottom) { edgeBand(up: true) }
        // ★ 2026-10-25:轨道式**无动效**(用户口径)—— 步进/卡高当拍落
        .animation(nil, value: viewPos)
        .animation(nil, value: railHeight)
        .onChange(of: selPos) { _, _ in clampViewport() }
        .onAppear { clampViewport() }
    }

    private func chip(logical: Int) -> some View {
        let w = windows[logical]
        let isOn = logical == selected
        return HStack(spacing: 6) {
            if let icon = AppIconCache.icon(pid: w.pid) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: PanelMetrics.chipIcon, height: PanelMetrics.chipIcon)
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.chipIcon * 0.30,
                                                style: .continuous))
                    .saturation(isOn ? 1 : 0.28)
                    .opacity(isOn ? 1 : 0.75)
            }
            Text(PanelLayout.title(WindowTitle.display(raw: w.title, bundleID: bundleID)))
                .font(.system(size: PanelMetrics.titleSize, weight: .regular))
                .foregroundStyle(isOn ? PanelColors.chipFgOn : PanelColors.chipFgOff)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle()
                .fill(isOn ? Color.accentColor : PanelColors.chipDotOff)
                .frame(width: PanelMetrics.chipDot, height: PanelMetrics.chipDot)
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .frame(width: PanelMetrics.chipRailWidth, height: PanelMetrics.chipH, alignment: .center)
        // ★ 与老芯片**同一套材质**(chipBg 0.90 + 发丝边 + 极淡投影):
        //   透明底会被背后的代码文字干扰(用户实报「现在这个透明的有点被背景的文字干扰了」)✗
        .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .overlay(Capsule(style: .continuous)
            .strokeBorder(PanelColors.chipBorder, lineWidth: PanelMetrics.hairline))
        .contentShape(Rectangle())
        // hover 选中**保留**(用户实测「鼠标不选中有点怪」✗);
        // 唯独顶/底感应带触发滚动的那一下不许换选中 —— 那里没有 onSelect,天然隔离 ✓
        .onHover { inside in if inside { onSelect(logical) } }
        .onTapGesture { onSelect(logical); onTap(logical) }
    }

    /// 边缘感应带:鼠标进顶/底 12pt ⇒ 轨道滚**一枚**;
    /// **只滚视口,不动选中**(用户口径:「我只是想让轨道滚动起来,而不是代替移动」)✓
    @ViewBuilder private func edgeBand(up: Bool) -> some View {
        if !fits && windows.count > slotCount {
            Color.clear
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside else { return }
                    let hi = windows.count - slotCount
                    viewPos = min(max(viewPos + (up ? 1 : -1), 0), hi)
                }
        }
    }

    /// 视口只为"选中出视口"服务 —— **一次一枚**,不按像素算最小距离 ✓
    private func clampViewport() {
        if selPos - viewPos < 0 { viewPos = selPos }
        if selPos - viewPos > slotCount - 1 { viewPos = selPos - slotCount + 1 }
    }

}
