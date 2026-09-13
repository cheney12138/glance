import SwiftUI
import AppKit

/// 切换器面板。全部度量与材质以 design/brand-spec.md 为准——改样式先改规格,不改这里。
struct PanelView: View {
    @ObservedObject var controller: PanelController
    @ObservedObject var snapshotter: Snapshotter

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        ZStack {
            // 毛玻璃背板(.underWindowBackground ≈ 图纸 backdrop-filter;深浅由系统接管)
            VisualEffectBackground(material: .underWindowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 0) {
                Text(controller.currentGroup?.appName ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(height: 16)
                    .padding(.bottom, 14)

                iconStrip

                if expandedCards.isEmpty {
                    Spacer(minLength: 0).frame(height: 0)
                } else {
                    previewRow
                        .padding(.top, 16)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 22)
            .padding(.horizontal, 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: expandedCount)
        }
        .frame(width: controller.contentSize().width, height: controller.contentSize().height)
        .padding(28) // 阴影呼吸区
        .shadow(color: .black.opacity(0.18), radius: 20, y: 6) // brand-spec:0 12px 40px 近似
    }

    // MARK: - 图标层

    private var iconStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(controller.groups.enumerated()), id: \.element.pid) { i, group in
                IconCell(group: group, selected: i == controller.appIndex, reduceMotion: reduceMotion)
                    .onHover { inside in if inside { controller.hoverApp(i) } }
                    .onTapGesture { controller.hoverApp(i) }
            }
        }
    }

    // MARK: - 展开层

    private var expandedCount: Int { controller.currentGroup?.windows.count ?? 0 }
    private var expandedCards: [WindowRecord] { controller.currentGroup?.windows ?? [] }

    private var previewRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(expandedCards.enumerated()), id: \.element.wid) { i, w in
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
    }
}

// MARK: - 图标格(80 容器 / 64 图标 / 半透明白块选中)

private struct IconCell: View {
    let group: AppGroup
    let selected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                    )
            }
            IconProvider.image(for: group.pid)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        }
        .frame(width: 80, height: 80)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
    }
}

// MARK: - 窗口缩略卡(240 宽 / 22 标题行 / 2px 白环选中)

private struct WindowCard: View {
    let record: WindowRecord
    let image: NSImage?
    let selected: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(record.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Color.primary.opacity(0.03))

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
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2)
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 0.5)
        )
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

/// 真实 App 图标(NSRunningApplication.icon),pid 维度缓存
enum IconProvider {
    private static var cache: [pid_t: NSImage] = [:]

    static func image(for pid: pid_t) -> Image {
        if let img = cache[pid] { return Image(nsImage: img).renderingMode(.original) }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        cache[pid] = img
        // original:阻止 SwiftUI 把图标当模板图——非 key 窗口里模板图会被染灰(T6 实机现形)
        return Image(nsImage: img).renderingMode(.original)
    }
}
