import SwiftUI
import AppKit

/// 窗口预览浮窗(评审拍板:预览与 App 长条分容器,中心正对选中 App 头顶)。
/// 卡片 v0.2:无标题文字,左上角原生红绿灯;选中环换蓝色聚焦环(白卡+白描边看不出来)。
struct PreviewPanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var windows: [WindowRecord] { controller.currentGroup?.windows ?? [] }

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(windows.enumerated()), id: \.element.wid) { i, w in
                WindowCard(
                    record: w,
                    image: snapshotter.cache[w.wid],
                    selected: i == controller.winIndex,
                    reduceMotion: reduceMotion
                )
                .onHover { inside in if inside { controller.hoverWindow(i) } }
                .onTapGesture { controller.hoverWindow(i); controller.confirmSelection() }
            }
        }
        .padding(12)
        .background(
            VisualEffectBackground(material: .popover)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .padding(28) // 阴影呼吸区——必须与 PanelController.previewSize 口径一致
        .shadow(color: .black.opacity(0.16), radius: 25, y: 8)
    }
}

// MARK: - 窗口卡 v0.2:红绿灯 + 无标题 + 蓝色聚焦环

private struct WindowCard: View {
    let record: WindowRecord
    let image: NSImage?
    let selected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
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
            .frame(width: 320, height: 200)
            .clipped()

            trafficLights
                .padding(.top, 9)
                .padding(.leading, 11)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            // 选中环:白底衬一圈聚焦蓝(白卡+白描边不可见的实机现形 —— 评审拍板)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: selected ? 0 : 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.85), lineWidth: selected ? 3.5 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
    }

    /// macOS 原生红绿灯(装饰语义,不是按钮;破坏操作归 Q/W/M 键盘)
    private var trafficLights: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(width: 40, height: 10, alignment: .leading)
        .shadow(color: .black.opacity(0.2), radius: 0.5)
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
