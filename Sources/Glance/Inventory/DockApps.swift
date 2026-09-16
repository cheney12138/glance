import AppKit
import GlanceCore

/// 未启动 App 名单的**提供者**(方案 E「入口槽」的数据源,2026-09-16 对照图拍板)。
///
/// 读法:`CFPreferencesCopyAppValue` 读 `com.apple.dock` 域(经 cfprefsd —— Dock 改动立即可见,
/// 不直接读 plist 文件;那个文件不保证即时落盘)→ 纯解析(`GlanceCore.DockApps`)→
/// 过滤"在跑的"(按 bundle id 对账)→ 按用户钉住的顺序给出。
///
/// **为什么名单可以有**:「收敛」的宪法只约束**窗**(候选集永不跨屏,ADR-0008);
/// 启动区不是窗的候选集,是 Dock 的**镜像** —— 用户钉了什么就有什么,排序也沿用 Dock 顺序
/// (可预测:闭眼知道第几个)。最小化/隐藏的窗仍然不进(「不可见窗」铁律不动)。
@MainActor
enum DockAppsProvider {
    struct LaunchableApp: Identifiable {
        let id: String          // bundleID ?? path(去重键)
        let name: String
        let path: String
        let icon: NSImage
    }

    /// 图标缓存(NSWorkspace.icon(forFile:) 逐次调用不便宜;App 卸载重装极少变,进程级够用)
    private static var iconCache: [String: NSImage] = [:]

    /// 本局面板的"未启动"名单:Dock 常驻 − 在跑的。
    /// `runningBundleIDs`:主环已有谁(本局 groups 的 bundle id ∪ 系统全部在跑 App 的 bundle id)——
    /// 在跑的已由主环/无窗应用支线展示,启动区不再重复。
    static func launchables(excluding runningBundleIDs: Set<String>) -> [LaunchableApp] {
        let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        var out: [LaunchableApp] = []
        var seen = Set<String>()
        for pinned in DockApps.parse(persistentApps: raw) {
            let bid = pinned.bundleID ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.bundleIdentifier ?? pinned.path
            guard !runningBundleIDs.contains(bid), !seen.contains(bid) else { continue }
            seen.insert(bid)
            let icon: NSImage
            if let cached = iconCache[pinned.path] {
                icon = cached
            } else {
                icon = NSWorkspace.shared.icon(forFile: pinned.path)
                iconCache[pinned.path] = icon
            }
            let name = pinned.name
                ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.infoDictionary?["CFBundleName"] as? String
                ?? URL(fileURLWithPath: pinned.path).deletingPathExtension().lastPathComponent
            out.append(LaunchableApp(id: bid, name: name, path: pinned.path, icon: icon))
        }
        return out
    }

    /// 启动并激活。面板在「确认」一发即关(生效即散场),启动成败**不回头** ——
    /// 失败只能靠日志(用户下一局再试;正常路径不会失败:Dock 里钉的 app 都在盘上)。
    static func launch(at path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, error in
            if let error { glog("[T83] 启动失败 \(path): \(error.localizedDescription)") }
        }
    }
}
