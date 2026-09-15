import ServiceManagement

/// 设置持久化(T9)。Q8 冻结边界:只有两个持久化键域——开机启动、触发键;
/// 皮肤/动画时长/展开上限永不落盘(动它们就回 brand-spec 的样式争议区)
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private var applying = false

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            print("[T9] 开机启动: \(launchAtLogin ? "开" : "关")")
        } catch {
            print("[T9] 开机启动设置失败: \(error.localizedDescription),已回滚")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
