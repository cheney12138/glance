import AppKit
import GlanceCore
import SwiftUI

/// 快捷键速查卡（轻量独立纸面窗，与设置/权限窗同源 `SettingsTheme`）。
///
/// 纪律：
/// - 所有键帽均从真实配置读取（触发键、送窗键、功能开关），绝不硬写死；
/// - 一屏 3 栏扫完，按 `Esc` / `?` / 红灯即关。
struct ShortcutCheatSheetView: View {
    var onOpenSettings: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var trigger = TriggerConfig.load()
    @State private var moveWindow = TriggerConfig.loadMoveWindow()
    @State private var digitPicksApp = Keys.digitPicksApp
    @State private var graveTakeover = (UserDefaults.standard.object(forKey: Keys.triggerTakeoverGraveCyclesWindows) as? Bool) ?? KeyDefaults.takeoverGraveCyclesWindows
    @State private var tabEntersLaunch = (UserDefaults.standard.object(forKey: Keys.panelTabEntersLaunchSection) as? Bool) ?? KeyDefaults.tabEntersLaunchSection
    @State private var threeFinger = (UserDefaults.standard.object(forKey: Keys.pointerThreeFingerTapPanel) as? Bool) ?? KeyDefaults.threeFingerTapPanel
    @State private var fourFinger = (UserDefaults.standard.object(forKey: Keys.pointerFourFingerTapLaunchRing) as? Bool) ?? KeyDefaults.fourFingerTapLaunchRing
    @State private var doubleOption = (UserDefaults.standard.object(forKey: Keys.pointerDoubleOptionJumps) as? Bool) ?? KeyDefaults.doubleOptionJumps
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏（0…39pt 给系统原生红绿灯让位，78pt 起步避开 12…68pt 灯组）
            HStack(spacing: 10) {
                Text("快捷键速查")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Spacer()
                Text("按 Esc 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.ink2)
                if let onOpenSettings {
                    Button("调整设置") {
                        dismiss()
                        onOpenSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.beam)
                    .padding(.leading, 6)
                }
            }
            .padding(.leading, 78)
            .padding(.trailing, 18)
            .frame(height: SettingsMetrics.prismTop)

            SettingsTheme.prism
                .frame(height: SettingsMetrics.prismHeight)
                .opacity(SettingsMetrics.prismOpacity)

            HStack(alignment: .top, spacing: 20) {
                column(title: "唤起与切窗", items: [
                    .init(key: trigger.display, label: "唤起 / 下一个 App"),
                    .init(key: "⇧" + trigger.display, label: "上一个 App"),
                    .init(key: "← / →", label: "跳到首 / 末格"),
                    .init(key: graveTakeover ? "⌘`" : "`", label: "同 App 窗口切换"),
                    .init(key: "1 – 9", label: "直选第 N 个 App", badge: digitPicksApp ? nil : "已关闭"),
                    .init(key: "⇧1 – 9", label: "直选当前 App 第 N 窗"),
                    .init(key: "↩ / ␣", label: "确认切换（钉住态）"),
                    .init(key: "Esc", label: "放弃并关闭面板"),
                ])

                Divider().overlay(SettingsTheme.hairline)

                column(title: "双环与多屏", items: [
                    .init(key: "↓ / ↑", label: "进 / 出未启动环"),
                    .init(key: "Tab", label: "走到底进未启动环", badge: tabEntersLaunch ? nil : "已关闭"),
                    .init(key: moveWindow.display, label: "前台窗送去另一块屏"),
                    .init(key: "双击 ⌥", label: "指针与焦点跳到下一屏", badge: doubleOption ? nil : "已关闭"),
                    .init(key: "三指轻点", label: "唤起并保持面板打开", badge: threeFinger ? nil : "已关闭"),
                    .init(key: "四指轻点", label: "直接打开未启动环", badge: fourFinger ? nil : "已关闭"),
                    .init(key: "双指滑动", label: "在面板上横移选中"),
                ])

                Divider().overlay(SettingsTheme.hairline)

                column(title: "窗口动作", items: [
                    .init(key: "Q", label: "退出选中 App"),
                    .init(key: "W", label: "关闭选中窗口"),
                    .init(key: "M", label: "最小化选中窗口"),
                    .init(key: "H", label: "隐藏选中 App"),
                    .init(key: "F", label: "选中窗口进出全屏"),
                    .init(key: "⌘+点击", label: "单窗落焦（不级联拉起）"),
                    .init(key: "? / /", label: "打开本速查卡"),
                ])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(width: 760)
        .background {
            SettingsWindowChrome().frame(width: 0, height: 0)
            SettingsTheme.paper
        }
        .ignoresSafeArea(.container, edges: .top)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
        .onAppear {
            reloadFromDefaults()
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadFromDefaults()
        }
    }

    private struct Item: Identifiable {
        let id = UUID()
        let key: String
        let label: String
        var badge: String? = nil
    }

    @ViewBuilder
    private func column(title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(SettingsTheme.ink)
                    .frame(width: 3, height: 11)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsTheme.ink)
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
                HStack(alignment: .center, spacing: 8) {
                    KeyChip(text: item.key)
                    Text(item.label)
                        .font(.system(size: 12))
                        .foregroundStyle(item.badge == nil ? SettingsTheme.ink : SettingsTheme.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SettingsTheme.ink2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(SettingsTheme.tabRail))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reloadFromDefaults() {
        let ud = UserDefaults.standard
        trigger = TriggerConfig.load()
        moveWindow = TriggerConfig.loadMoveWindow()
        digitPicksApp = Keys.digitPicksApp
        graveTakeover = (ud.object(forKey: Keys.triggerTakeoverGraveCyclesWindows) as? Bool) ?? KeyDefaults.takeoverGraveCyclesWindows
        tabEntersLaunch = (ud.object(forKey: Keys.panelTabEntersLaunchSection) as? Bool) ?? KeyDefaults.tabEntersLaunchSection
        threeFinger = (ud.object(forKey: Keys.pointerThreeFingerTapPanel) as? Bool) ?? KeyDefaults.threeFingerTapPanel
        fourFinger = (ud.object(forKey: Keys.pointerFourFingerTapLaunchRing) as? Bool) ?? KeyDefaults.fourFingerTapLaunchRing
        doubleOption = (ud.object(forKey: Keys.pointerDoubleOptionJumps) as? Bool) ?? KeyDefaults.doubleOptionJumps
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc (53) 或 / (44) 关闭速查窗
            if event.keyCode == 53 || event.keyCode == 44 {
                dismiss()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
