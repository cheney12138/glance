import SwiftUI
import AppKit

/// 窗口预览托盘 —— 施工契约 = 最新设计 demo 的 `.preview-tray`。
///
/// 构型变了:托盘住在长条**头顶**,由「App 名 · N 个窗口」一行题头 + 一排 128px 缩略图组成。
/// demo 里的 `.win-chrome`(三粒装饰点 + 64px 渐变块)是给没有真截图的 HTML 用的假窗皮——
/// 原生这边截图本身就是真窗口,所以缩略图 = 截图 + 下方标题条两段,不再叠装饰点。
struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter

    private var windows: [WindowRecord] { controller.currentGroup?.windows ?? [] }
    @State private var shown = false

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
        // 入场**不做动效**(v1.12,与长条同一裁决):托盘要在选中态一变就到位,
        // 平移 + 缩放登场同样只是拖时间。退场保留淡出(短一档)。
        .opacity(shown ? 1 : 0)
        .animation(shown ? nil : MotionPolicy.animation(PanelMotion.fade(PanelMetrics.tSettle)), value: shown)
        // 入场每会期播一遍、退场也播一遍 —— 由 isVisible 驱动,不做重挂载。
        // 旧版 `.id(isVisible)` 重挂载会把退场整个掐掉:新实例把 shown 重置成 false,
        // 第一帧就是 opacity 0,没有动画可言
        .onAppear { if controller.isVisible { shown = true } }
        .onChange(of: controller.isVisible) { _, on in shown = on }
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
                    image: snapshotter.cache[w.wid],
                    selected: i == controller.winIndex, // 换窗即接力:弹簧打断保速
                    motion: MotionPolicy.animation(PanelMotion.thumb)
                )
                .onHover { inside in if inside { controller.hoverWindow(i) } }
                .onTapGesture { controller.hoverWindow(i); controller.confirmSelection() }
            }
        }
    }
}

// MARK: - 缩略图(截图 + 标题条;选中 = 1.045 放大 + 内圈聚焦光 + 阴影升档)

private struct WindowThumb: View {
    let record: WindowRecord
    let image: NSImage?
    let selected: Bool
    let motion: Animation?

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

            Text(PanelLayout.title(record.title))
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
