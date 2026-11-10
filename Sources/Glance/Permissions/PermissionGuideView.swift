import SwiftUI

/// 权限引导窗口:缺哪项亮哪项,按钮直达申请/设置页。
/// 2026-11-05 重绘:搬进设置窗的"纸面"语言(SettingsTheme)——原来是系统默认样式,
/// 和产品 UI 完全两个世界(用户:「样式上要贴合产品现在的 ui ux」)。
/// 内容三段式(照 Snow Shot 的引导):直达面板 + 拖拽提示 + ⌘⇧G 隐藏技巧。
struct PermissionGuideView: View {
    @ObservedObject var monitor: PermissionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTheme.paper
                .frame(height: 0)               // 纸色就是窗口底(见 SettingsView 的构图),这里只标语义
            VStack(alignment: .leading, spacing: 14) {
                Text("Glance 需要两项系统权限")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)

                permissionRow(
                    title: "辅助功能",
                    why: "监听 ⌥Tab、读取与聚焦窗口——没有它,切换器整体不工作",
                    granted: monitor.accessibilityGranted,
                    grant: monitor.requestAccessibility
                )

                permissionRow(
                    title: "屏幕录制",
                    why: "预截窗口缩略图——没有它,展开层显示不出窗口内容",
                    granted: monitor.screenCaptureGranted,
                    grant: monitor.requestScreenCapture
                )

                // ── 系统设置里的两条省力路径(照 Snow Shot 的引导,贴产品语言) ──
                if !monitor.allGranted {
                    Divider().overlay(SettingsTheme.hairline)
                    Text("点「去授权」后,跟着系统设置窗口右下角的拖拽助手把 Glance 拖进权限列表,再把开关打开。")
                        .font(.caption)
                        .foregroundStyle(SettingsTheme.ink2)
                }

                if monitor.allGranted {
                    Label("全部就绪,此窗口可以关了", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Text("在系统设置中完成授权后,此处会自动更新,无需重启。")
                        .foregroundStyle(SettingsTheme.ink2)
                        .font(.caption)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(SettingsTheme.paper)
        .onAppear { monitor.refresh() }
        // 授权齐了收掉拖拽助手(轮询每秒在刷新,这一拍总会到)
        .onChange(of: monitor.allGranted) { _, granted in
            if granted { PermissionDragPanel.shared.hide() }
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, why: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : SettingsTheme.beam)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(SettingsTheme.ink)
                Text(why).font(.caption).foregroundStyle(SettingsTheme.ink2)
            }
            Spacer()
            if !granted {
                Button("去授权") {
                    grant()
                    // 拖拽助手跟着设置面板一起出:文字提示之外给一枚真能拖的图标
                    PermissionDragPanel.shared.show()
                }
            }
        }
    }
}
