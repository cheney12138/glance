import AppKit

/// 颜色外观:浅色 / 深色 / 自动(用户可选,默认**自动**)。
///
/// 为什么只摆一个 `NSApp.appearance` 就够了:
/// 面板的取色全走 `NSColor(name:)` **动态色**(见 `PanelColors.dynamic`),它按绘制时的
/// 「外观」解析 —— 所以只要外观对了,玻璃、发丝、纸面、芯片、文字一次性全换,
/// 不需要给几十个 token 各加一档开关(那种写法改一处漏一处,历史教训见 Glass 那几次反复)。
///
/// 设置窗也跟着换:同一个 App 里两套外观才是真的怪。
/// 默认**自动**(跟随系统)—— macOS 自己的习惯,不给用户调教,只给入口。
enum AppearancePreference {
    static let key = "panel.appearance"
    /// 与设置页三档一一对应:`auto` / `light` / `dark`
    static let auto = "auto"
    static let light = "light"
    static let dark = "dark"

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? auto
    }

    /// 幂等,可以在启动、改设置、开设置窗时随时再调。
    /// 用 `NSApplication.shared` 而不是 `NSApp`:App.init() 阶段 `NSApp` 还是 nil。
    static func apply() {
        switch current {
        case light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil // nil = 跟随系统
        }
    }
}
