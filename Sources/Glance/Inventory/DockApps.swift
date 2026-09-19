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

    /// **白名单**(2026-09-19):不在 Dock 常驻的 App 也进未启动环。存 bundle id(见 spec note 6)。
    /// 名单在设置页编辑;两名单互斥由选择器保证(已在对方名单的 App 根本不出现)。
    static var whitelist: [String] { UserDefaults.standard.stringArray(forKey: "launch.whitelist") ?? [] }
    static func setWhitelist(_ ids: [String]) { UserDefaults.standard.set(ids, forKey: "launch.whitelist") }
    /// **黑名单**:Dock 常驻也不进未启动环。
    static var blacklist: [String] { UserDefaults.standard.stringArray(forKey: "launch.blacklist") ?? [] }
    static func setBlacklist(_ ids: [String]) { UserDefaults.standard.set(ids, forKey: "launch.blacklist") }

    /// 名单条目(bundle id)在盘上解析出的展示信息。找不到(已卸载)= path 空串,调用方灰显
    struct InstalledApp: Identifiable {
        let id: String
        let name: String
        let path: String
        let icon: NSImage
    }

    /// 名单条数(设置页行尾计数)
    static func listCount(forKey key: String) -> Int {
        UserDefaults.standard.stringArray(forKey: key)?.count ?? 0
    }

    /// 通用名单写入(编辑器的 save 走这里;上面两个具名入口留给语义调用方)
    static func setList(_ ids: [String], forKey key: String) {
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// bundle id → 展示信息。查不到(已卸载)给名字/id 兜底 + 通用图标,别让编辑器开天窗
    static func resolvedApp(_ id: String) -> InstalledApp {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let path = url?.path ?? ""
        let name = url.flatMap { Bundle(url: $0) }.flatMap { bundle in
            bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
        } ?? url.map { $0.deletingPathExtension().lastPathComponent } ?? id
        let icon = path.isEmpty ? NSWorkspace.shared.icon(for: .application)
                                : NSWorkspace.shared.icon(forFile: path)
        return InstalledApp(id: id, name: name, path: path, icon: icon)
    }

    /// 扫已装 App:/Applications 与 /System/Applications,两级深(Utilities 等子目录)。
    /// 排除本 App 自己(把它加进未启动环没有意义)。
    static func scanInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        let ownBundleID = Bundle.main.bundleIdentifier
        var urls: [URL] = []
        for root in ["/Applications", "/System/Applications"] {
            let dir = URL(fileURLWithPath: root)
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            urls.append(contentsOf: children.filter { $0.pathExtension == "app" })
            for sub in children where sub.hasDirectoryPath && sub.pathExtension != "app" {
                let grandchildren = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                urls.append(contentsOf: grandchildren.filter { $0.pathExtension == "app" })
            }
        }
        var seen = Set<String>()
        var out: [InstalledApp] = []
        for url in urls {
            guard let bid = Bundle(url: url)?.bundleIdentifier,
                  bid != ownBundleID, !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            out.append(InstalledApp(id: bid, name: name, path: url.path,
                                    icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 本局面板的"未启动"名单:**Dock 常驻 ∪ 白名单 − 黑名单 − 在跑的**(2026-09-19 收录面扩容)。
    /// `runningBundleIDs`:主环已有谁(本局 groups 的 bundle id ∪ 系统全部在跑 App 的 bundle id)——
    /// 在跑的已由主环/无窗应用支线展示,启动区不再重复。
    static func launchables(excluding runningBundleIDs: Set<String>) -> [LaunchableApp] {
        let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        let blacklist = Set(blacklist)
        var out: [LaunchableApp] = []
        var seen = Set<String>()
        for pinned in DockApps.parse(persistentApps: raw) {
            let bid = pinned.bundleID ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.bundleIdentifier ?? pinned.path
            guard !blacklist.contains(bid), !runningBundleIDs.contains(bid), !seen.contains(bid) else { continue }
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
        // **白名单补录**:不在 Dock 的 App 按名单顺序排在环尾(用户在设置里排的就是展示序)。
        // 黑名单照旧压住(理论上互斥保证不会撞,这里再挡一道——两处编辑可能在两台设备间不同步);
        // 在跑的照旧不算。找不到的(已卸载)静默跳过,名单里留着没坏处——重装即恢复。
        for bid in whitelist where !blacklist.contains(bid) && !seen.contains(bid) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
            let path = url.path
            guard !runningBundleIDs.contains(bid), !runningBundleIDs.contains(path) else { continue }
            seen.insert(bid)
            let icon: NSImage
            if let cached = iconCache[path] {
                icon = cached
            } else {
                icon = NSWorkspace.shared.icon(forFile: path)
                iconCache[path] = icon
            }
            let name = Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            out.append(LaunchableApp(id: bid, name: name, path: path, icon: icon))
        }
        return out
    }

    /// 启动并激活。面板在「确认」一发即关(生效即散场),启动成败**不回头** ——
    /// 失败只能靠日志(用户下一局再试;正常路径不会失败:Dock 里钉的 app 都在盘上)。
    ///
    /// ★ **终端环境净化**(2026-09-19):`OpenConfiguration.environment` 会**并入**当前进程
    /// 环境 —— 而 Glance 自己若是被开发期 `open` 从终端拉起的,环境里就有 `TERM`。
    /// 有些 App(实测 Pearcleaner 4.4.3:`TERM != nil && != "dumb"` 即判"从终端启动",
    /// 打印 CLI 帮助后 `exit(0)`)会因继承到 `TERM` 而闪退。切换器启动 App 应该给
    /// Spotlight/Finder 同款的干净语境:`TERM` 净化为 `dumb`(对 GUI App 无意义,
    /// 对 Pearcleaner 这类自检是"不在终端")。
    static func launch(at path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.environment = ["TERM": "dumb"]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, error in
            if let error { glog("[T83] 启动失败 \(path): \(error.localizedDescription)") }
        }
    }
}
