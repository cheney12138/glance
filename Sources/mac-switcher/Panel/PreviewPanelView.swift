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
        VStack(spacing: PanelMetrics.trayGap) {
            caption
            thumbRow
        }
        .padding(.top, PanelMetrics.trayPadTop)
        .padding(.horizontal, PanelMetrics.trayPadX)
        .padding(.bottom, PanelMetrics.trayPadBottom)
        .frame(width: controller.previewContentSize().width, height: controller.previewContentSize().height)
        .background(GlassBackground(cornerRadius: PanelMetrics.rTray))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rTray, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.rTray, style: .continuous)
                .strokeBorder(PanelColors.glassBorder, lineWidth: PanelMetrics.hairline)
                .allowsHitTesting(false)
        )
        // 顶缘内阴影(demo inset 0 1px 0 --glass-inner-shadow):两块玻璃同一配方
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.rTray, style: .continuous)
                .strokeBorder(PanelColors.glassInner, lineWidth: PanelMetrics.hairline)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        .elevation(.tray)
        .padding(PanelMetrics.shadowPadPop) // 必须与 PanelController.previewSize 口径一致
        // 入场与退场都不做动效(与长条同一裁决;退场是 2026-09-14 砍的:用户实评"拖沓")。
        // 窗口本身由控制器 orderOut,这里不再需要自己的 shown 状态
        .opacity(controller.isVisible ? 1 : 0)
    }

    private var caption: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(controller.currentGroup?.appName ?? "")
                .font(.system(size: PanelMetrics.captionSize, weight: .semibold))
                .foregroundStyle(PanelColors.txt1)
            Text("· \(windows.count) 个窗口")
                .font(.system(size: PanelMetrics.countSize, weight: .medium))
                .foregroundStyle(PanelColors.txt2)
        }
        .frame(height: PanelMetrics.captionH)
        .lineLimit(1)
    }

    private var thumbRow: some View {
        HStack(spacing: PanelMetrics.thumbGap) {
            ForEach(Array(windows.enumerated()), id: \.element.wid) { i, w in
                WindowThumb(
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
                            zoom: { controller.zoomWindowClicked(w.wid) }
                        )
                    },
                    motion: MotionPolicy.animation(PanelMotion.thumb)
                )
                .onHover { inside in if inside { controller.hoverWindow(i) } }
                .onTapGesture { controller.hoverWindow(i); controller.confirmSelection() }
            }
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
struct TrafficLights: View {
    let wid: CGWindowID
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
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

    /// 卡片上那一行字:编辑器家族抽工程名,其余原样;宽度不够时尾部省略
    private var displayTitle: String {
        PanelLayout.title(WindowTitle.display(raw: record.title, bundleID: bundleID))
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.15))
                    Text("截图中…")
                        .font(.system(size: PanelMetrics.titleSize))
                        .foregroundStyle(PanelColors.txt2)
                }
            }
            .frame(width: PanelMetrics.thumbW, height: PanelMetrics.shotH)
            .clipped()
            // 红绿灯叠在截图左上(macOS 窗的位置)。点它们不会关面板:
            // 点击落在面板内,不触发"面板外点击 = 放弃"那套判定
            .overlay(alignment: .topLeading) { traffic().padding(9) }

            Text(displayTitle)
                .font(.system(size: PanelMetrics.titleSize, weight: .regular))
                .foregroundStyle(PanelColors.thumbTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .frame(width: PanelMetrics.thumbW, height: PanelMetrics.titleH, alignment: .leading)
                .background(PanelColors.thumbPaper)
        }
        .frame(width: PanelMetrics.thumbW, height: PanelMetrics.thumbH)
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
}
