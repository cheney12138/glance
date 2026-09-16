import SwiftUI
import AppKit
import GlanceCore

/// 窗口预览托盘 —— 施工契约 = 最新设计 demo 的 `.preview-tray`。
///
/// 构型变了:托盘住在长条**头顶**,由「App 名 · N 个窗口」一行题头 + 一排 128px 缩略图组成。
/// demo 里的 `.win-chrome`(三粒装饰点 + 64px 渐变块)是给没有真截图的 HTML 用的假窗皮——
/// 原生这边截图本身就是真窗口,所以缩略图 = 截图 + 下方标题条两段,不再叠装饰点。
struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter

    private var windows: [WindowRecord] { controller.currentGroup?.windows ?? [] }

    var body: some View {
        // **没有题头行**(2026-09-14 用户口径:"你把额头去掉我看看效果"):
        // App 名已由长条里选中的那个图标承担、窗口数由卡片张数承担 —— 那行只是把两件已知的事各写一遍,
        // 还占掉托盘顶部一整条高度。去掉后托盘 = 卡片 + 芯片
        thumbGrid
        .padding(.top, PanelMetrics.trayPadTop)
        .padding(.horizontal, PanelMetrics.trayPadX)
        .padding(.bottom, PanelMetrics.trayPadBottom)
        .frame(width: controller.previewContentSize().width, height: controller.previewContentSize().height)
        .background(GlassBackground(cornerRadius: PanelMetrics.rTray))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rTray, style: .continuous))
        // 顶缘受光边:与长条同一道(深色靠它交代厚度;浅色透明)—— 同样挂总闸
        .overlay {
            if PanelEdgeStyle.drawsEdge {
                LinearGradient(colors: [PanelColors.glassTopEdge, .clear],
                               startPoint: .top,
                               endPoint: UnitPoint(x: 0.5, y: 0.015))
                    .allowsHitTesting(false)
            }
        }
        .glassEdge(cornerRadius: PanelMetrics.rTray)
        // 顶缘内阴影(demo inset 0 1px 0 --glass-inner-shadow):两块玻璃同一配方 —— 同样挂总闸
        .overlay {
            if PanelEdgeStyle.drawsEdge {
                RoundedRectangle(cornerRadius: PanelMetrics.rTray, style: .continuous)
                    .strokeBorder(PanelColors.glassInner, lineWidth: PanelMetrics.hairline)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
        }
        .elevation(.tray)
        .padding(PanelMetrics.shadowPadPop) // 必须与 PanelController.previewSize 口径一致
        // **入场上浮**:整块托盘(玻璃 + 卡片)从"原位置再低一小截"浮到该在的位置。
        // 与长条里**选中格 + 托底**用的是同一个值、同一次 withAnimation —— 所以这两边永远同步上浮,
        // 其余图标不动(2026-09-15 用户口径:"他们俩直接从原位置开始上浮")。
        // 退场仍不做动效(2026-09-14 砍的:用户实评"拖沓"),窗口由控制器直接 orderOut
        .offset(y: controller.contentEntryRise)
        // 托盘窗口按**整局最大布局**开(见 PanelController.trayMaxContentSize):本组摆得小时,
        // 玻璃要**贴着窗口底边**(= 与今天等尺寸时的位置完全一致),水平居中由默认对齐负责。
        // 不这么摆的话内容会在更大的窗口里垂直居中 → 玻璃整体上浮一截,和长条之间的缝就变了
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
        let (rows, cols) = controller.trayLayout(count: windows.count)
        let rowsSafe = max(rows, 1)
        let colsSafe = max(cols, 1)
        return VStack(spacing: PanelMetrics.trayRowGap) {
            ForEach(0..<rowsSafe, id: \.self) { r in
                HStack(spacing: PanelMetrics.thumbGap) {
                    ForEach(r * colsSafe..<min(r * colsSafe + colsSafe, windows.count), id: \.self) { i in
                        thumb(at: i)
                    }
                }
            }
        }
    }

    private func thumb(at i: Int) -> some View {
        let w = windows[i]
        return WindowThumb(
            record: w,
            bundleID: controller.currentGroup?.bundleID,
            image: snapshotter.cache[w.wid],
            selected: i == controller.winIndex, // 换窗即接力:弹簧打断保速
            traffic: {
                // 三粒灯的动作 T14 就实现了(WindowFocuser.close/minimize/zoom),
                // T15 换卡片样式时把 UI 丢了 —— 2026-09-14 用户要求恢复
                TrafficLights(
                    wid: w.wid,
                    close: { controller.closeWindowClicked(w.wid) },
                    minimize: { controller.minimizeWindowClicked(w.wid) },
                    zoom: { controller.zoomWindowClicked(w.wid) },
                    dimmed: !(i == controller.winIndex)
                )
            },
            motion: MotionPolicy.animation(PanelMotion.thumb)
        )
        .onHover { inside in if inside { controller.hoverWindow(i) } }
        .onTapGesture { controller.hoverWindow(i); controller.confirmSelection() }
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
struct TrafficLights: View {
    let wid: CGWindowID
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
    /// 未选中的卡片:三粒灯去饱和(= macOS 上"非激活窗口"的样子 ✓)
    let dimmed: Bool
    /// 哪一粒被直接踩到(nil = 没踩到整组):
    /// 整组里**任意一粒**被悬停 → 三粒一起出符号;只有被直接踩到的那一粒放大
    @State private var hoveredDot: Int?

    var body: some View {
        // spacing 归零、每粒自带 3pt 内边:间距不变(11+6),但两粒之间的缝也算"踩到"
        HStack(spacing: 0) {
            light(PanelColors.tlClose, "xmark", "关闭窗口", 0, close)
            light(PanelColors.tlMin, "minus", "最小化窗口", 1, minimize)
            light(PanelColors.tlZoom, "arrow.up.left.and.arrow.down.right", "缩放窗口", 2, zoom)
        }
    }

    private func light(_ color: Color, _ symbol: String, _ hint: String,
                       _ index: Int, _ action: @escaping () -> Void) -> some View {
        TrafficLight(color: color, symbol: symbol, hint: hint,
                     showsGlyph: hoveredDot != nil,
                     hovering: hoveredDot == index,
                     dimmed: dimmed,
                     action: action)
            .padding(3)
            // 逐粒听 hover,而不是给 HStack 挂一个:容器上的 onHover 会被子按钮吃掉
            // (实机现形:只有被踩到的那一粒出符号,另两粒没反应)
            .onHover { inside in
                if inside {
                    hoveredDot = index
                } else if hoveredDot == index {
                    hoveredDot = nil
                }
            }
    }
}

/// 一粒灯。状态由父级传(整组管符号、单粒管放大 —— 两个层级,与 macOS 同构)
private struct TrafficLight: View {
    let color: Color
    let symbol: String
    let hint: String
    let showsGlyph: Bool
    let hovering: Bool
    /// 未选中 = 灰(见 TrafficLights.dimmed)
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        // Button 而不是 onTapGesture:卡片本身挂着"点一下 = 确认"的手势,
        // Button 才能把它隔开(子级优先),不会误触确认
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    // 符号色 = 本色的深色版(黑 50% 叠上去就是系统那个暗红/暗赭/暗绿)
                    Image(systemName: symbol)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.5))
                        .opacity(showsGlyph ? 1 : 0)
                }
                .scaleEffect(hovering ? 1.15 : 1)
                // 去饱和是"克制"的来源:亮点只在你看着它的时候出现。
                // 用 saturation+opacity 而非新增灰色常量 —— 灰值随明暗外观自动正确,
                // 也不必为一个中间态往设计系统里塞 token ✓
                .saturation(dimmed ? 0 : 1)
                .opacity(dimmed ? 0.55 : 1)
                .animation(.easeOut(duration: 0.18), value: dimmed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: showsGlyph)
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}

private struct WindowThumb<Overlay: View>: View {
    let record: WindowRecord
    /// 决定标题显示什么:终端要 tab 名、编辑器要工程名(见 `GlanceCore.WindowTitle`)
    let bundleID: String?
    let image: NSImage?
    let selected: Bool
    /// 卡片的浮层(红绿灯):泛型入参,免得把面板控制器的依赖引进来
    @ViewBuilder let traffic: () -> Overlay
    let motion: Animation?

    /// 芯片上那一行字:编辑器家族抽工程名,其余原样;宽度不够时先截文字再截宽度
    private var displayTitle: String {
        PanelLayout.title(WindowTitle.display(raw: record.title, bundleID: bundleID))
    }

    var body: some View {
        // 卡片与芯片**分离**:环、浮起、阴影都只长在卡片上,芯片是卡片之外的一枚胶囊
        // (用户口径:"不跟预览窗耦合" —— 所以选中态的各种形变不会拖着芯片一起动)
        VStack(spacing: PanelMetrics.chipGap) {
            card
            chip
        }
        .frame(width: PanelMetrics.thumbW, height: PanelMetrics.thumbH)
    }

    /// 预览卡本体:**只有截图**(顶边毛玻璃 + 红绿灯 + 选中环都长在它身上)
    private var card: some View {
        ZStack {
            if let image {
                // **fill 定版**(2026-09-14 试过 fit,退回):
                // fit 虽然不裁内容,但卡片是**定尺**的窗口卡,而红绿灯锚在卡片左上角 ——
                // 宽窗(终端 1.83)被 fit 上下留出"信纸边"后,三粒灯就落在浅色空边上,
                // 用户实评"加歪了"。fill 只裁两侧几个点,内容仍是满幅,灯稳稳落在画面里。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // **卡面压色**(方案 D,`design/卡面实验台.html` 用户拍板):非选中的卡把截图
                    // 压到 30%,统一底色(`PanelColors.thumbBg`)接管卡面 —— 一排过去不再深浅乱跳;
                    // 选中/悬停的那张恢复原样。压色量挂在卡片末尾同一条
                    // `.animation(motion, value: selected)` 上,换选中是"底色涨上来/退下去",不是跳变
                    .opacity(selected ? 1 : PanelMetrics.thumbWash)
            } else {
                Rectangle().fill(Color.gray.opacity(0.15))
                Text("截图中…")
                    .font(.system(size: PanelMetrics.titleSize))
                    .foregroundStyle(PanelColors.txt2)
            }
        }
        .frame(width: PanelMetrics.thumbW, height: PanelMetrics.shotH)
        .clipped()
        // 「座」= **毛玻璃的渐变**:把这张截图自己再画一份、模糊掉,再用纵向渐变遮成"上糊下清"。
        // 三版才走到这里,记下来免得重走:
        //   · 径向暗斑   → 用户:"阴影做的太捞了"(浅色截图上就是一块脏印);
        //   · 整条暗渐变 → 用户:"不是黑的一团,是**毛玻璃**的效果"(而且要和长条的模糊一致);
        //   · 现在这版   → 不加任何暗色,只是把画面自己糊掉,再用渐变过渡回清晰。
        // 几何必须与底图**逐像素对齐**(同样的 frame + .fill + clipped),否则模糊层会与底图错位。
        .overlay {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: PanelMetrics.thumbW, height: PanelMetrics.shotH)
                    .clipped()
                    .blur(radius: PanelMetrics.lightsBlur, opaque: true)
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
            Text(displayTitle)
                // regular 而不是 medium:芯片要"轻",字重是最直接的一档(题头那边用 medium 是因为它是标题)
                .font(.system(size: PanelMetrics.titleSize, weight: .regular))
                .foregroundStyle(PanelColors.thumbTitle)
                .lineLimit(1)
                // 中段:芯片宽度不够时保头保尾(尾部才是文件名/工程的区分位)
                .truncationMode(.middle)
        }
            // 文字宽度上限里要扣掉圆点与间距,否则整枚芯片会超出卡片宽
            .frame(maxWidth: PanelMetrics.thumbW - 18 - PanelMetrics.chipDot - 5)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(PanelColors.chipBg))
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
