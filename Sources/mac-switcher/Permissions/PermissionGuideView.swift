import SwiftUI

/// 权限引导窗口:缺哪项亮哪项,按钮直达申请/设置页。
/// 样式走系统默认(窗口形态是功能性引导,不属于 brand-spec 管辖的切换器面板)。
struct PermissionGuideView: View {
    @ObservedObject var monitor: PermissionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("mac-switcher 需要两项系统权限")
                .font(.headline)

            permissionRow(
                title: "辅助功能",
                why: "监听 ⌥Tab、读取与聚焦窗口——没有它,切换器整体不工作",
                granted: monitor.accessibilityGranted,
                grant: monitor.requestAccessibility
            )

            permissionRow(
                title: "屏幕录制",
                why: "预截窗口缩略图——没有它,展开层显示不出窗口内容(T5 依赖)",
                granted: monitor.screenCaptureGranted,
                grant: monitor.requestScreenCapture
            )

            if monitor.allGranted {
                Label("全部就绪,此窗口可以关了", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Text("在系统设置里勾选后,这里会自动变绿,不用重启。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { monitor.refresh() }
    }

    @ViewBuilder
    private func permissionRow(title: String, why: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("去授权", action: grant)
            }
        }
    }
}
