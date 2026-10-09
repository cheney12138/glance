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
    /// ⚠️ 自 2026-10-09 起它会在**后台线程**被读写(候选名单的重活挪去了后台 ✓)
    ///   ⇒ 加锁;代价可忽略(每局几次字典访问 ✓)
    nonisolated(unsafe) private static var iconCache: [String: NSImage] = [:]
    nonisolated(unsafe) private static let iconLock = NSLock()
    /// 取图标(命中就回;未命中就加载并存入 ✓ 锁只圈字典、不圈加载 ⇒ 不会卡住别人 ✓)
    nonisolated private static func cachedIcon(_ path: String) -> NSImage {
        iconLock.lock(); let hit = iconCache[path]; iconLock.unlock()
        if let hit { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconLock.lock(); iconCache[path] = icon; iconLock.unlock()
        return icon
    }

    /// **白名单**(2026-09-19):不在 Dock 常驻的 App 也进未启动环。存 bundle id(见 spec note 6)。
    /// 名单在设置页编辑;两名单互斥由选择器保证(已在对方名单的 App 根本不出现)。
    nonisolated static var whitelist: [String] { UserDefaults.standard.stringArray(forKey: Keys.launchWhitelist) ?? [] }
    static func setWhitelist(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: Keys.launchWhitelist)
        invalidateCandidates()   // 设置一改 ⇒ 下一局重算(设置是绝对权威 ✓)
    }
    /// **黑名单**:Dock 常驻也不进未启动环。
    nonisolated static var blacklist: [String] { UserDefaults.standard.stringArray(forKey: Keys.launchBlacklist) ?? [] }
    static func setBlacklist(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: Keys.launchBlacklist)
        invalidateCandidates()
    }

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
    /// ★★ 2026-10-09:**候选名单的进程级缓存** —— 这块活是每次唤起里最贵的一段 ✗
    ///
    /// 细账(13 次唤起,拆到段):
    ///   `陈旧上屏 3.6 · 顺序 2.0 · 剪枝 0.1 · **Dock 20.0(max 27)** · 落点 0.0 · 置框 1.8 · 上屏 12.2 · 首帧 12.7`
    ///   ⇒ 一次唤起 36–75ms,`Dock` 一段占**一半** ✗
    /// 但把这段里的每个调用**单独量**(独立进程、真样本)全都很快:
    ///   读 Dock plist 0.00 · `runningApplications` 0.4 · 7 个 App 图标+元数据 0.8 ·
    ///   白名单 7 次 `urlForApplication` 0.03ms(热态)⇒ 合计 ~1.5ms,**解释不了 20ms** ✗
    /// ⇒ 剩下最合理的机制:它**与后台枚举抢同一批系统服务**(那 40–60ms 正并发跑着 ✓
    ///   —— 同一段日志里 `[T8] 按键→枚举就位 53ms(后台枚举)` 就是它 ✓)
    ///   按本仓老规矩(**掉帧要让开,不是调曲线**):不管谁对,把这份活挪出关键路径 ✓
    ///
    /// 口径:缓存的是**候选**(Dock ∪ 白名单 − 黑名单,含图标 —— 那份确定、也就那份贵 ✓);
    /// "在跑的"每次唤起**现减**(读一次 `runningApplications` 只要 0.4ms ✓)
    ///   ⇒ "刚启动的 App 立刻从启动区消失"这条语义一个字不变 ✓
    /// 失效:设置里改名单 ⇒ `invalidateCandidates()`;每次唤起之后再后台刷一遍 ✓
    /// ⚠️ 隔离说明:`candidateCache` 与下面两个入口都 `nonisolated` —— 因为**重活必须在后台算** ✓
    ///   (若留在 `@MainActor` 里,后台任务就调不了它 ✗,只能丢回主线程 ⇒ 又把卡顿请回来了 ✗)
    ///   读写口径:`candidates()/storeCandidates()` 只在主线程调 ✓;后台线程只跑
    ///   `computeCandidates()`(纯函数、不碰缓存 ✓)⇒ 没有交叉访问 ✓
    nonisolated(unsafe) private static var candidateCache: [LaunchableApp]?

    nonisolated static func invalidateCandidates() { candidateCache = nil }

    /// 取候选(命中就返回;没有就同步算一次 —— 只在开机第一局或名单刚改过时发生 ✓)
    nonisolated static func candidates() -> [LaunchableApp] {
        if let c = candidateCache { return c }
        let list = computeCandidates()
        candidateCache = list
        return list
    }

    /// 后台算好的候选交回来(只许主线程调 ✓)
    nonisolated static func storeCandidates(_ list: [LaunchableApp]) { candidateCache = list }

    /// 真正那份重活的入口:供**后台任务**调用 ✓ ⇒ 它不碰缓存字段本身(无共享可变状态 ✓)
    /// ⚠️ 自 2026-10-09 起**不再包含** "减掉在跑的" —— 那一减改到 `runningSet()`(见下面那段病例)
    nonisolated static func computeCandidates() -> [LaunchableApp] {
        let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        let blacklist = Set(blacklist)
        var out: [LaunchableApp] = []
        var seen = Set<String>()
        for pinned in DockApps.parse(persistentApps: raw) {
            let bid = pinned.bundleID ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.bundleIdentifier ?? pinned.path
            guard !blacklist.contains(bid), !seen.contains(bid) else { continue }
            seen.insert(bid)
            let icon = cachedIcon(pinned.path)
            let name = pinned.name
                ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: URL(fileURLWithPath: pinned.path))?.infoDictionary?["CFBundleName"] as? String
                ?? URL(fileURLWithPath: pinned.path).deletingPathExtension().lastPathComponent
            out.append(LaunchableApp(id: bid, name: name, path: pinned.path, icon: icon))
        }
        // **白名单补录**:不在 Dock 的 App 按名单顺序排在环尾(用户在设置里排的就是展示序)。
        // 黑名单照旧压住(理论上互斥保证不会撞,这里再挡一道——两处编辑可能在两台设备间不同步);
        // 在跑的照旧不算 —— 那一减现在住在 `launchables(excluding:)` 里(每次现减 ✓)。找不到的
        // (已卸载)静默跳过,名单里留着没坏处——重装即恢复。
        for bid in whitelist where !blacklist.contains(bid) && !seen.contains(bid) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
            let path = url.path
            seen.insert(bid)
            let icon = cachedIcon(path)
            let name = Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            out.append(LaunchableApp(id: bid, name: name, path: path, icon: icon))
        }
        return out
    }

    /// ★★ 2026-10-09 第二轮:**"在跑的"那份名单也要缓存** —— 它才是真凶 ✗
    ///
    /// 细账点名(同一份日志,`在跑集合` 那一段的墙钟):
    ///   `[打卡] 唤起 共 38.3ms(CPU 28.6 · 等 9.8) | … · 在跑集合 15.1 · 名单 0.0 · …`
    ///   `[打卡] 唤起 共 65.2ms(CPU 37.1 · 等 28.2) | … · 在跑集合 22.0 · 名单 0.1 · …`
    ///   ⇒ 先前把"候选名单"缓存了,`名单` 确实降到 0.0 ✓;但 `在跑集合` 原封不动地占着 15–22ms ✗
    ///   (它 = `NSWorkspace.shared.runningApplications` + 两次 `compactMap`(bundleIdentifier / bundleURL.path)
    ///    —— 单独量它只要 0.4ms ✗,再一次印证"测出来的 20ms 不在调用里,在**这一拍**" ✓)
    /// ⇒ 同样挪出关键路径:后台刷 + **工作区通知**(启动/退出)保持及时 ✓
    ///   语义一个字不变:刚启动的 App 立刻从启动区消失(通知在毫秒级触发刷新 ✓)
    nonisolated(unsafe) private static var runningCache: Set<String>?

    /// 取"在跑的"(bundle id ∪ bundle path ⇒ 与候选名单两套 id 都对得上 ✓)
    nonisolated static func runningSet() -> Set<String> {
        if let c = runningCache { return c }
        let s = computeRunningSet()
        runningCache = s
        return s
    }

    nonisolated static func storeRunningSet(_ s: Set<String>) { runningCache = s }

    /// 纯函数:自己算一遍(供后台任务调用 ✓)
    nonisolated static func computeRunningSet() -> Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        var s = Set(apps.compactMap(\.bundleIdentifier))
        s.formUnion(apps.compactMap { $0.bundleURL?.path })
        return s
    }

    /// 工作区通知 ⇒ 后台刷新(开机调一次 ✓)。为什么不用定时轮询:
    /// 用户从启动环里启动一个 App 之后,**下一局**它就该从环里消失 —— 靠轮询会滞后 ✗
    nonisolated(unsafe) private static var observingRunning = false
    static func startObservingRunningApps() {
        guard !observingRunning else { return }
        observingRunning = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                refreshRunningSetInBackground()
            }
        }
    }

    /// 后台刷新一次(candidates 与 running 一起刷 ✓ 两者都不碰主线程状态)
    nonisolated static func refreshRunningSetInBackground() {
        Task.detached(priority: .utility) {
            let s = computeRunningSet()
            await MainActor.run { storeRunningSet(s) }
        }
    }

    /// 本局要展示的"未启动"名单 = **候选 − 在跑的**(现减 ✓ 两边都是缓存 ⇒ 亚毫秒 ✓)
    static func launchables(excluding runningBundleIDs: Set<String>) -> [LaunchableApp] {
        candidates().filter { !runningBundleIDs.contains($0.id) && !runningBundleIDs.contains($0.path) }
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
