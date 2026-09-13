import SwiftUI
import AppKit

/// 窗口预览浮窗 v1(design/v3/tokens-v1.md 施工契约)。
/// 卡面 = 26pt 标题栏带(红绿灯入住 + 窗口名居中)+ 等高等比截图;
/// 选中 = knockout 缝 + 系统聚焦蓝环 + 阴影升档,不再叠白块。
struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var windows: [WindowRecord] { controller.currentGroup?.windows ?? [] }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(windows.enumerated()), id: \.element.wid) { i, w in
                WindowCard(
                    record: w,
                    image: snapshotter.cache[w.wid],
                    selected: i == controller.winIndex,
                    reduceMotion: reduceMotion,
                    controller: controller
                )
                .onHover { inside in if inside { controller.hoverWindow(i) } }
                .onTapGesture { controller.hoverWindow(i); controller.confirmSelection() }
            }
        }
        .padding(12) // §4 --pop-pad:卡与卡、卡与边同距
        .background(
            VisualEffectBackground(material: .popover)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(
            VStack(spacing: 0) {
                Rectangle().fill(PanelColors.edgeHi).frame(height: 0.5).padding(.horizontal, 22)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(0)
        )
        .padding(12) // 阴影呼吸区(收敛:28 → 12,治"大黑框"——之前呼吸区被当成阴影面板看)
        .shadow(color: .black.opacity(0.10), radius: 6, y: 4)
        .shadow(color: .black.opacity(0.18), radius: 20, y: 14)
    }
}

// MARK: - 红绿灯按钮(有原生语义的地砖:磨砂面上唯一允许的三粒"实物")

private struct TrafficLight: View {
    let color: Color
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 12, height: 12)
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 窗口卡 v1:标题栏带(原生物证)+ 等高等比截图

private struct WindowCard: View {
    let record: WindowRecord
    let image: NSImage?
    let selected: Bool
    let reduceMotion: Bool

    let controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            // §5 标题栏带:磨砂 titlebar 材质 + 下车发丝;红绿灯垂直居中住带内,窗口名居中
            ZStack {
                VisualEffectBackground(material: .titlebar)
                HStack(spacing: 7) {
                    // 红绿灯 = 真按钮(评审拍板,不再当装饰):红关/黄最小/绿缩放
                    TrafficLight(color: Color(hex: 0xFF5F57), symbol: "xmark") { controller.closeWindowClicked(record.wid) }
                    TrafficLight(color: Color(hex: 0xFEBC2E), symbol: "minus") { controller.minimizeWindowClicked(record.wid) }
                    TrafficLight(color: Color(hex: 0x28C840), symbol: "plus") { controller.zoomWindowClicked(record.wid) }
                    // 名字跟灯走,间距拉开;按宽度截断,不数字数
                    Text(record.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 2)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 0.5)
            }

            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.15))
                    Text("截图中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: PanelMetrics.cardWidth(of: record), height: 190)
            .clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // §4 未选卡发丝:截图四边一根"纸边",否则亮截图在亮玻璃上化开
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: selected ? 0 : 0.5)
        )
        .overlay(
            // §1 knockout 缝:把蓝环从花花绿绿的截图上剥开
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.95), lineWidth: selected ? 4 : 0)
        )
        .overlay(
            // §1 系统聚焦环:唯一的彩色
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
        )
        // §3 选中卡"离席":阴影升一档,与聚焦环同时发生
        .shadow(color: .black.opacity(selected ? 0.12 : 0.10), radius: selected ? 4 : 3, y: 2)
        .shadow(color: .black.opacity(selected ? 0.20 : 0.14), radius: selected ? 16 : 12, y: selected ? 14 : 10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
