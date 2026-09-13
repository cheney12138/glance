import SwiftUI
import AppKit

/// 设置面板(DockDoor 式侧边栏)。内容边界见 Q8:通用 / 快捷键 / 关于,三节打住。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionMonitor

    enum Page: String, CaseIterable, Identifiable {
        case general = "通用"
        case shortcut = "快捷键"
        case about = "关于"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .shortcut: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    @State private var page: Page = .general
    @AppStorage("debug.pinPanelOnRelease") private var pinPanel = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 130, ideal: 140, max: 160)
        } detail: {
            Group {
                switch page {
                case .general: generalPage
                case .shortcut: ShortcutPage()
                case .about: aboutPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(width: 560, height: 300)
    }

    // MARK: - 通用

    private var generalPage: some View {
        Form {
            Toggle("开机时启动 mac-switcher", isOn: $store.launchAtLogin)
            Text("登录到这台 Mac 后自动拉起;关掉后需要手动从应用程序里启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("松手不关闭切换器面板", isOn: $pinPanel)
            Text("开启后松开 ⌥ 面板保持打开:Tab/←→ 继续导航,Enter 确认聚焦,Esc 放弃。关闭则回到「松手即确认」的原生节奏。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            LabeledContent("版本") { Text("\(version) (\(build))") }
            Divider()
            LabeledContent("辅助功能") { statusDot(granted: permissions.accessibilityGranted) }
            LabeledContent("屏幕录制") { statusDot(granted: permissions.screenCaptureGranted) }
            Text("权限异常时:菜单栏 → 权限 一行可重开引导;也可用 README 里的 tccutil 命令彻底重置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func statusDot(granted: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(granted ? .green : .orange).frame(width: 8, height: 8)
            Text(granted ? "已授权" : "未授权")
        }
    }
}

/// 快捷键页:录制式改键(Q8 冻结)。按一下按钮进录制态,下一次"修饰键+普通键"
/// 即写入;Esc 取消。只允许 ⌥/⌘/⌃ 当修饰键——⇧ 永久留给反向导航。
struct ShortcutPage: View {
    @State private var config = TriggerConfig.load()
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Toggle("接管系统切换器(⌘Tab)", isOn: takeoverBinding)
            Text("开启后 ⌘Tab 归 mac-switcher:我们的 tap 在 HID 层抢先,系统自带切换器收不到事件。本 App 退出/崩溃,原生 ⌘Tab 自动复活,无副作用。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("自定义触发键") {
                Button(recording ? "请按新组合…(Esc 取消)" : config.display) {
                    recording ? stopRecording() : startRecording()
                }
                .keyboardShortcut(.cancelAction) // 录制态显示期间 Esc 也有兜底
            }
            Text("默认 ⌥Tab。修饰键只收 ⌥ / ⌘ / ⌃;改完即时生效,不用重启。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    /// 篡位开关:开 = 触发键写成 ⌘Tab;关 = 还原默认 ⌥Tab(现状即读即时生效)
    private var takeoverBinding: Binding<Bool> {
        Binding(
            get: {
                let d = UserDefaults.standard
                return d.string(forKey: "trigger.modifier") == "command" && d.integer(forKey: "trigger.keyCode") == 0x30
            },
            set: { on in
                if on {
                    UserDefaults.standard.set(0x30, forKey: "trigger.keyCode")
                    UserDefaults.standard.set("command", forKey: "trigger.modifier")
                } else {
                    UserDefaults.standard.removeObject(forKey: "trigger.keyCode")
                    UserDefaults.standard.removeObject(forKey: "trigger.modifier")
                }
                config = TriggerConfig.load()
                print("[T13] ⌘Tab 篡位: \(on ? "接管" : "还原 ⌥Tab")")
            }
        )
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { stopRecording(); return nil } // Esc 取消
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let mod = allowedModifier(in: flags) else { return event } // 没有合法修饰键,继续等
            UserDefaults.standard.set(Int(event.keyCode), forKey: "trigger.keyCode")
            UserDefaults.standard.set(mod, forKey: "trigger.modifier")
            config = TriggerConfig.load()
            print("[T9] 触发键改为: \(config.display)")
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func allowedModifier(in flags: NSEvent.ModifierFlags) -> String? {
        if flags.contains(.option) { return "option" }
        if flags.contains(.command) { return "command" }
        if flags.contains(.control) { return "control" }
        return nil
    }
}
