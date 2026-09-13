import SwiftUI
import AppKit

/// 切换器主面板 v0.2(只装 App 长条;窗口预览已独立成 PreviewPanelView 浮窗——
/// 评审拍板:凑在一个容器里天然对齐不了图标)。
/// 全部度量以 design/brand-spec.md(v0.2 修订)为准。
struct PanelView: View {
    @ObservedObject var controller: PanelController

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        ZStack {
            // ★材质更轻亮:.popover 替代 .underWindowBackground(治"灰蒙蒙")
            VisualEffectBackground(material: .popover)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 0) {
                Text(controller.currentGroup?.appName ?? "")
                    .font(.system(size: 15, weight: .medium)) // ★名 13→15 medium
                    .foregroundStyle(.primary)
                    .frame(height: 18)
                    .padding(.bottom, 20)                        // ★与图标层呼吸加大

                iconStrip
            }
            .padding(.top, 22)
            .padding(.bottom, 26)
            .padding(.horizontal, 30)
        }
        .frame(width: controller.contentSize().width, height: controller.contentSize().height)
        .padding(28) // 阴影呼吸区——必须与 PanelController.paddedSize 口径一致
        .shadow(color: .black.opacity(0.16), radius: 25, y: 8)
    }

    // MARK: - 图标层(★图标 72 / 格 84 / 距 20 / 无形容器)

    private var iconStrip: some View {
        HStack(spacing: 20) {
            ForEach(Array(controller.groups.enumerated()), id: \.element.pid) { i, group in
                IconCell(group: group, selected: i == controller.appIndex, reduceMotion: reduceMotion)
                    .onHover { inside in if inside { controller.hoverApp(i) } }
                    // 点图标 = 选中;再点已选中的 = 确认它的头牌窗(或激活无窗应用)
                    .onTapGesture {
                        if i == controller.appIndex { controller.confirmSelection() } else { controller.hoverApp(i) }
                    }
            }
        }
    }
}

// MARK: - 图标格(★选中 = 极轻灰托底,无描边)

private struct IconCell: View {
    let group: AppGroup
    let selected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.08)) // 深浅双色自适应;不描边
            }
            IconProvider.image(for: group.pid)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
        }
        .frame(width: 84, height: 84)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
    }
}

// MARK: - 毛玻璃封装与 App 图标提供者

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 真实 App 图标(NSRunningApplication.icon),pid 维度缓存。
/// .original:阻止 SwiftUI 把图标当模板图——非 key 窗口里模板图会被染灰
enum IconProvider {
    private static var cache: [pid_t: NSImage] = [:]

    static func image(for pid: pid_t) -> Image {
        if let img = cache[pid] { return Image(nsImage: img) }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        cache[pid] = img
        return Image(nsImage: img)
    }
}
