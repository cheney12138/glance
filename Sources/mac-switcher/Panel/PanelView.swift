import SwiftUI
import AppKit

/// 切换器主面板 v1(design/v3/tokens-v1.md 施工契约,交互语义仍以 brand-spec 为准)。
/// 变化:App 名从长条删除(评审拍板)、图标 76/格 88/距 8、选中=上浮+投影+轻托底、
/// 背板 22 圆角 + 顶部受光边 + 双层阴影。
struct PanelView: View {
    @ObservedObject var controller: PanelController

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .popover)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            iconStrip
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            // v1 §1:顶部 0.5px 受光边——浮层"厚度"的唯一诚实来源
            VStack(spacing: 0) {
                Rectangle()
                    .fill(PanelColors.edgeHi)
                    .frame(height: 0.5)
                    .padding(.horizontal, 22)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .frame(width: controller.contentSize().width, height: controller.contentSize().height)
        .padding(28) // 阴影呼吸区——必须与 PanelController.paddedSize 口径一致
        // §3 双层阴影:远层给"浮",近层给"锚"
        .shadow(color: .black.opacity(0.09), radius: 8, y: 4)
        .shadow(color: .black.opacity(0.20), radius: 35, y: 24)
    }

    // MARK: - 图标层(主角体格:76 图标 / 88 格 / 8 距)

    private var iconStrip: some View {
        HStack(spacing: 8) {
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

// MARK: - 图标格(选中 = 上浮 1pt + 投影加深 + 0.055 托底,无色块套娃)

private struct IconCell: View {
    let group: AppGroup
    let selected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
            IconProvider.image(for: group.pid)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 76)
                // v1 §1:不裁圆角——真实 squircle 自带 alpha;阴影跟轮廓走(.shadow 打点,
                // 不用大框 box-shadow),掉格即贴纸
                .shadow(color: .black.opacity(selected ? 0.26 : 0.14), radius: selected ? 4 : 2, y: selected ? 3 : 1.5)
                .shadow(color: .black.opacity(selected ? 0.24 : 0.20), radius: selected ? 8 : 6, y: selected ? 8 : 5)
                .offset(y: selected ? -1 : 0)
        }
        .frame(width: 88, height: 88)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
    }
}

// MARK: - 共享色板(v1 §1 HTML → 原生)

enum PanelColors {
    /// 顶部受光边:浅 白 .55 / 深 白 .13
    static let edgeHi = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white.withAlphaComponent(0.13)
            : .white.withAlphaComponent(0.55)
    })
}

// MARK: - 布局度量共享(规格唯一来源;PanelController 的定位数学与视图同源)

enum PanelMetrics {
    /// 卡片宽 = 190 × 窗口真实比例,clamp 140…420(等高等比 = Mission Control 群像感;
    /// 等宽裁切 = 表格感,v0.2 的病根)
    static func cardWidth(of record: WindowRecord) -> CGFloat {
        let aspect = record.bounds.width / max(record.bounds.height, 1)
        return min(max(190 * aspect, 140), 420)
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
