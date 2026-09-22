import AppKit

/// 一扇被枚举出来的窗的最小事实。
struct WindowRecord {
    let wid: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect

    /// 窗口宽高比(横窗 >1,竖窗 <1)。卡片自适应宽度(T88)与出图高度推导共用这一个口径 ——
    /// 两边各算各的必然漂(截图的高就是按它推的)。
    var aspect: CGFloat { bounds.width / max(bounds.height, 1) }
}

/// 一个 App 与其本屏窗的聚合(CONTEXT.md「本屏窗」)。
/// `bundleID` 给预览卡标题用:终端要 tab 名、编辑器要工程名,两条规则不同(GlanceCore.WindowTitle)
struct AppGroup {
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var windows: [WindowRecord]
}

/// 窗口枚举:只认 CONTEXT.md 三个定义。
///   本屏窗   = 归属屏恰为语境屏(几何交占比最大)且占比 ≥20%
///   不可见窗 = 没 ordered-in 的一律不要(.optionOnScreenOnly 天然排除最小化/⌘H 隐藏)
///   排序     = MRU 证据(ADR-0003)
/// 幽灵窗日志去重用的锁与上次内容(见 `WindowEnumerator.logGhostOnce`)。
/// 文件级:枚举在后台线程跑,碰不到 actor 状态。
private let ghostLogLock = NSLock()
nonisolated(unsafe) private var seenGhostLines: Set<String> = []

/// **善后期退役**(2026-09-19 用户裁定:「窗口关掉了,再次唤醒时没有任何间隔,
/// APP 就应该在这儿」):无窗应用**立即入环**,不设时限。
///
/// 原 T90 的 10s 善后期防的是「⌘Q 后窗已关、进程还在善后 → 无窗分支把它挂回条带尾部诈尸
/// 一次」。退役后这条老病的看门换了分工:
///   · 面板自己 Q → `PanelController.quitPIDs`(先记后杀)+ `verifyQuit` 复核,原样承担;
///   · 外部 ⌘Q → 死亡间隙只有 1~3s 且自愈(下次枚举自然消失),期间若恰逢唤起,
///     环里短暂出现一个无点条目、确认激活无效果 —— 接受。
/// (曾想用 `willTerminateApplicationNotification` 事件替代时间窗 —— AppKit **没有**这个
/// 通知,T90 老注释是对的,此处记档防再犯。)
///
/// **无窗应用的"落屏记忆"快照**(2026-09-19 用户问句:「窗口上次关闭在哪个屏幕,再次唤起
/// 就在哪个屏幕」):App 确认后恢复的窗会回到它自己记住的屏 —— 我们把这份记忆也抄一份:
/// 每次枚举,有可见窗的 App 记下"此刻活在哪块屏"(按 bundleID 持久化,跨重启有效);
/// 它变成无窗后,**只回最后活跃的那块屏**的环,不再全屏撒。
/// (落屏探针实测:开新窗型 App 跟随激活语境,恢复型 App 回记忆屏 —— 两类都与
/// lastScreen 语义吻合。)键 = bundleID(pid 跨 App 重启不稳);屏名跨会话基本稳定。
nonisolated(unsafe) private var lastScreenByBundle: [String: String]? = nil
private let lastScreenLock = NSLock()
private let lastScreenDefaultsKey = "ring.lastScreenByBundle"

/// 读快照(惰性装载一次;坏档当空表,下次写回覆盖)
private func loadLastScreensIfNeeded() {
    lastScreenLock.lock()
    defer { lastScreenLock.unlock() }
    guard lastScreenByBundle == nil else { return }
    let raw = UserDefaults.standard.dictionary(forKey: lastScreenDefaultsKey) as? [String: String]
    lastScreenByBundle = raw ?? [:]
}

/// 记/查快照的统一出入口(调用方持锁由这里管)
private func updateLastScreen(bundleID: String?, screenName: String) {
    guard let bundleID, !bundleID.isEmpty else { return }
    loadLastScreensIfNeeded()
    lastScreenLock.lock()
    defer { lastScreenLock.unlock() }
    guard lastScreenByBundle?[bundleID] != screenName else { return }
    lastScreenByBundle![bundleID] = screenName
    UserDefaults.standard.set(lastScreenByBundle, forKey: lastScreenDefaultsKey)
}

private func lastScreen(ofBundle bundleID: String?) -> String? {
    guard let bundleID, !bundleID.isEmpty else { return nil }
    loadLastScreensIfNeeded()
    lastScreenLock.lock()
    defer { lastScreenLock.unlock() }
    return lastScreenByBundle?[bundleID]
}

@MainActor
enum WindowEnumerator {
    private static let ownershipThreshold: CGFloat = 0.2

    static func enumerate(owning screen: NSScreen?) -> [AppGroup] {
        guard let screen else { return [] }
        return orderByMRU(rawGroups(on: screen), on: screen)
    }

    /// 枚举里**与主线程无关**的那一半:CGWindowList 与 NSWorkspace 都是线程安全的读操作。
    /// 拆出来是为了能在后台跑 —— 这几十毫秒压在事件 tap 的回调里,系统会判回调超时把 tap 停用,
    /// 漏出去的那几颗 ⌘Tab 就是“用着用着变成原生切换器”的现场(实机量到 begin 后主线程被占 ~110ms)。
    /// 剩下的排序证据(`MruEvidence`)是主线程状态,由 `orderByMRU` 在主线程补上。
    nonisolated static func rawGroups(on screen: NSScreen) -> [AppGroup] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var candidates: [WindowRecord] = []
        for info in infos {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0, // 只收普通 app 窗
                  // ★ 自家窗**不再按 pid 一刀切排除**(2026-09-18 用户实报「打开了设置面板,
                  // 它要有图标,跟别的 app 一样」):设置/权限窗口是普通图层(0)的正常窗口,
                  // 应与其他 App 的窗一样进环。切换器自家的面板仍被排除 —— 它们是
                  // popUpMenu 图层(≠0),上面那道 layer 过滤天然挡住,不需要 pid 特判
                  true,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1
            else { continue }

            // 幽灵窗廉价启发式(不做 alt-tab 的完整探测器——不做清单;两条规则挡 90%):
            //   ① alpha ≈ 0 的隐形窗  ② 任一维度 <50pt 的迷你窗
            // Chrome 等 Electron 系会在 layer 0 挂无标题隐形辅助窗(实机现形:
            // 一个真窗口冒出第二个空白无标题窗)
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.05 || bounds.width < 50 || bounds.height < 50 {
                let ownerForLog = info[kCGWindowOwnerName as String] as? String ?? "?"
                Self.logGhostOnce("\(ownerForLog) alpha=\(alpha) \(Int(bounds.width))x\(Int(bounds.height))")
                continue
            }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let owner = info[kCGWindowOwnerName as String] as? String ?? "(未知应用)"
            candidates.append(WindowRecord(wid: wid, pid: pid, ownerName: owner, title: title, bounds: bounds))
        }

        // **AX 认可过滤**:杀掉"空壳 surface"(病例:Chrome 只有一扇窗却出两张卡片,那张无标题卡
        // 快照还是一片空白 —— Chromium 挂在 layer 0、alpha 1、尺寸正常的辅助 surface)。
        // 判据照 AltTab 的 WindowAdmissionResolver:可切换目标必须在 AX 侧也对得上。
        // 安全阀:AX 没话说(nil)时**不过滤**,否则会把不暴露 AX 的 App 整组清空。
        var axFiltered: [WindowRecord] = []
        axFiltered.reserveCapacity(candidates.count)
        for (pid, group) in Dictionary(grouping: candidates, by: \.pid) {
            guard let admission = AXWindowList.admission(ofPID: pid) else {
                axFiltered.append(contentsOf: group)
                continue
            }
            let kept = group.filter { admission.admitted.contains($0.wid) }
            let dropped = group.filter { !admission.admitted.contains($0.wid) }
            if !dropped.isEmpty {
                Self.logGhostOnce("\(group.first?.ownerName ?? "?"):AX 不认 \(dropped.count)/\(group.count) 扇 — "
                      + dropped.map { "#\($0.wid)\"\($0.title)\"(\(admission.rejected[$0.wid] ?? "?"))" }
                                .joined(separator: ", "))
            }
            axFiltered.append(contentsOf: kept)
        }

        // 归属过滤:只留本屏窗
        let records = axFiltered.filter { ownsByContextScreen($0.bounds, contextScreen: screen) }
        // ★ **全屏探测**(2026-09-19,用户划线):存在一扇铺满某块屏的 layer 0 可见窗
        //   = 有显示器处于全屏。全屏会把别的桌面整体盖住 —— 此刻"看不见"的窗可能是
        //   被全屏挡住的(不许灌环,用户铁律:A 屏的 App 出现在 B 屏绝对不可以),
        //   也可能是用户关掉的(应该立即入环)—— CGWindowList 分不出这两者,
        //   所以用**全屏状态**当判据切换无窗判定面(见下方 allWindowedPIDs)
        let screensSnapshot = NSScreen.screens
        var fullscreenActive = false
        for r in axFiltered {
            for s in screensSnapshot {
                if r.bounds.width >= s.frame.width - 2, r.bounds.height >= s.frame.height - 2,
                   abs(r.bounds.midX - s.frame.midX) < 2, abs(r.bounds.midY - s.frame.midY) < 2 {
                    fullscreenActive = true
                }
            }
        }
        var byPID: [pid_t: AppGroup] = [:]
        for r in records {
            // **系统权限弹窗过滤**(2026-09-15 用户报:"要权限的时候那个系统弹窗也被识别到,没有 app 图标,
            // 是一个齿轮状空白")。这类窗口(辅助功能/屏幕录制提示)由**后台进程**渲染:它们没有 Dock 图标,
            // 判据就是 `activationPolicy == .prohibited` —— 用它而不是 bundle id 名单:
            // 名单会随系统版本漂(不同的 macOS 用 tccd / UserNotificationCenter / CoreServicesUIAgent …),
            // 而"有没有常规激活策略"是系统自己维护的事实 ✓。
            // 注意**不要**顺手动 `.accessory`(菜单栏型 App)—— 它们可以有正当的窗口(例如我们自己的设置窗,若将来放出来)。
            let app = NSRunningApplication(processIdentifier: r.pid)
            let bundleID = app?.bundleIdentifier ?? ""
            let byPolicy = app?.activationPolicy == .prohibited
            let byBundle = Self.promptHostBundleIDs.contains(bundleID)
            let byName = Self.promptHostNames.contains(r.ownerName)
            if byPolicy || byBundle || byName {
                let why = byPolicy ? "无 Dock 图标的后台进程(activationPolicy=prohibited)"
                    : byBundle ? "系统提示框宿主(点名 bundle)"
                    : "系统提示框宿主(点名进程名)"
                // bundle 取不到时把"取不到"写出来,而不是留一个空的方括号 ——
                // 这正是本次定位到的线索:名单里有它,却因为 bundleIdentifier 为空而匹配不上
                let idText = bundleID.isEmpty ? "无 bundle id" : bundleID
                Self.logGhostOnce("\(r.ownerName)[\(idText)]:\(why) —— 不入面板")
                continue
            }
            byPID[r.pid, default: AppGroup(pid: r.pid, appName: r.ownerName,
                                            bundleID: NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier,
                                            windows: [])].windows.append(r)
        }

        // **落屏记忆快照**(见文件头):有可见窗的 App 记下"此刻活在这块屏"。
        // 无窗后它只回这块屏的环(确认恢复的窗本来就会回它记住的屏,两边语义对齐)
        let screenName = screen.localizedName
        for g in byPID.values where !g.windows.isEmpty {
            updateLastScreen(bundleID: g.bundleID, screenName: screenName)
        }

        // 无窗应用(T15,用户拍板):全系统一扇可见窗都没有的已打开 App,
        // 不划分显示器分组,任何语境屏都展示;确认 = 激活该 App。
        // ★ **判定面随全屏状态切换**(2026-09-19,用户划线定案):
        //   · **无全屏**(常态):判定面 = 可见窗 —— 用户关掉某 App 的所有窗,它**立即**
        //     成为无窗应用入环(病例:CatDesk 关窗后不出现;其"关窗"实现为 orderOut,
        //     CGWindowList 全量清单里窗还活着,AX 也查无此窗 —— 系统层面与"被全屏
        //     挡住的窗"无法区分,只能靠全屏状态当判据)。
        //   · **有屏全屏**(fullscreenActive):判定面 = 全量窗清单(ghost 同款过滤)——
        //     被全屏挡住的别屏 App **不许**以无窗条目灌环(铁律:F2/F4,实测 14 → 2 的
        //     缩水与跨屏串场)。代价:全屏期间"关窗式无窗 App"暂时退环,全屏退出即回。
        //   (AX 探针实证:CatDesk 关窗后 AX 窗口数 = 0,但全量 CG 清单里窗仍在 ——
        //    AX 与 CG 在这一对场景里读数相同,分不出意图,故走状态开关。)
        var allWindowedPIDs: Set<pid_t> = []
        if fullscreenActive {
            if let allInfos = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] {
                for info in allInfos {
                    guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                          let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                          let bounds = CGRect(dictionaryRepresentation: boundsDict),
                          bounds.width > 1, bounds.height > 1
                    else { continue }
                    // ★ 幽灵窗启发式必须与上方 candidates **同款**(2026-09-19 回归修复):
                    //   CatDesk 这类 App 关掉真窗后还挂着 alpha=0 的隐形辅助窗 —— 不过滤的话
                    //   它被全量清单算成"有窗",永远进不了无窗应用名单,从环里消失
                    //   (用户实报:关掉 CatDesk 的窗口后它不出现)
                    let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                    if alpha <= 0.05 || bounds.width < 50 || bounds.height < 50 { continue }
                    allWindowedPIDs.insert(pid)
                }
            }
        } else {
            allWindowedPIDs = Set(candidates.map(\.pid))
        }
        // 不划分显示器分组,任何语境屏都展示;确认 = 激活该 App。
        // ★ **立即入环**(2026-09-19 用户裁定):窗全关 = 马上是无窗应用,不设时限 ——
        //   防"⌘Q 诈尸"的分工见文件头(quitPIDs + 外部 ⌘Q 死亡间隙自愈)
        // ★ **只回最后活跃屏**(2026-09-19 用户问句):无窗 App 不再全屏撒 —— 快照里
        //   记着它最后活在哪块屏,就只进那块屏的环;从未有过窗的真·无窗应用(无快照)
        //   照旧任何语境屏都展示。有屏全屏时无窗条目整体退环(F2/F4 铁律,见上)
        let excludedSystemApps: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui"]
        let contextScreenName = screen.localizedName
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  !allWindowedPIDs.contains(app.processIdentifier),
                  !excludedSystemApps.contains(app.bundleIdentifier ?? ""),
                  !app.isTerminated else { continue }
            if fullscreenActive { continue }                       // 全屏屏不收无窗条目(F2/F4)
            if let ls = lastScreen(ofBundle: app.bundleIdentifier), ls != contextScreenName {
                continue                                           // 有记忆但不是这块屏:不进
            }
            byPID[app.processIdentifier] = AppGroup(
                pid: app.processIdentifier,
                appName: app.localizedName ?? "(未知应用)",
                bundleID: app.bundleIdentifier,
                windows: []
            )
        }

        return Array(byPID.values)
    }

    /// **已知的系统提示框宿主**。
    ///
    /// 病例(2026-09-15):用户报"要权限时那个系统弹窗也被识别到,没有 app 图标,是一个齿轮状空白"。
    /// 先在主路按 `activationPolicy == .prohibited`(无 Dock 图标)过滤 —— **没挡住** ✗:
    /// 从日志的 `[T6] 落点顺序` 里抓到它的名字是 `universalAccessAuthWarn`(辅助功能警告窗的宿主),
    /// 而这类提示框宿主的激活策略是 `.regular`(实测当前所有 layer0 窗口的归属,清一色 regular)。
    ///
    /// 所以规则是"通用规则 + 点名":通用规则(激活策略)管"没有 Dock 图标的后台进程",
    /// 这里点名管"有 Dock 图标身份、但本质是系统提示框"的那几个。
    /// **这份名单为什么可以存在**:它只收系统提示框宿主(极小),而且名单外的任何闯入者
    /// 会**直接出现在 `[T6] 落点顺序` 那一行里**(App 名一目了然)—— 维护成本几乎为零。
    /// 为什么还需要**按进程名**点名(2026-09-16 追加,用户报"这种权限弹窗还是出现了"):
    /// 录屏许可提示窗的宿主进程叫 `universalAccessAuthWarn`,但它的 `bundleIdentifier` **取不到**
    /// (bundle-less 的 XPC 小进程,按需拉起;提示窗关掉后进程就没了,连 find 都找不到)
    /// ⇒ 上报名单里的 "com.apple.universalAccessAuthWarn" **永远匹配不上**,弹窗照旧混进面板。
    /// 日志实证(它真的进了面板,而且能被操作):
    ///   `[T6] 选中(指针 hover): [10/10] universalAccessAuthWarn(共 1 窗)`
    ///   `[T7] 已聚焦: universalAccessAuthWarn — 录屏`
    /// 所以除 bundle id 之外**再按进程名点名** —— 提示框宿主多为无 bundle 的 XPC 小进程,
    /// 进程名才是可靠标识。名单仍然只收系统提示框宿主,闯入者照样会在 `[T6] 落点顺序` 里现形。
    nonisolated static let promptHostNames: Set<String> = [
        "universalAccessAuthWarn",      // 录屏 / 辅助功能许可提示(本次实证)
        "UserNotificationCenter",       // 通用通知 / 权限提示
        "CoreServicesUIAgent",          // "xxx 想打开…" 之类
        "tccd",                         // TCC 本体(某些系统版本直接由它出窗)
        "ScreenCaptureApprovalUI",      // 录屏许可确认
    ]

    nonisolated static let promptHostBundleIDs: Set<String> = [
        "com.apple.universalAccessAuthWarn",   // 辅助功能警告(本次实测抓到)
        "com.apple.UserNotificationCenter",    // 通用通知 / 权限提示
        "com.apple.CoreServicesUIAgent",       // "xxx 想打开…" 之类
        "com.apple.tccd",                      // TCC 本体(某些系统版本直接由它出窗)
        "com.apple.ScreenCaptureApprovalUI",   // 录屏许可确认
    ]

    /// 幽灵窗日志**同一条只记一次**(2026-09-15):它每局枚举都会重印,而内容几乎永远一样
    /// (CatDesk 的空壳窗、Chrome 的查找条)—— 一天上千行,把真信号淹了。
    /// 只在**内容变化**时打:新出现的幽灵窗仍然一眼可见,重复的不再刷屏。
    /// 被 `nonisolated` 的枚举路径调用(枚举跑后台),所以状态放文件级全局 + 加锁 ——
    /// 挂在 `@MainActor` 的 enum 上是编译不过的,这不是绕路,是它本来就跨线程。
    nonisolated private static func logGhostOnce(_ line: String) {
        ghostLogLock.lock()
        defer { ghostLogLock.unlock() }
        // ⚠️ 原来只跟"上一条"比 —— 而两条幽灵窗日志是**交替**出现的
        // (CatDesk 的空壳窗 / Chrome 的查找条),于是每局都把两条重印一遍 ✗
        // (2026-09-15 实测:一份日志里同两条各出现 7 次)。改成"见过的就不再印"。
        guard !seenGhostLines.contains(line) else { return }
        seenGhostLines.insert(line)
        print("[幽灵窗滤除] \(line)")
    }

    /// 排序(主线程状态,必须在主线程调用)。
    ///
    /// ★★ 2026-09-22 病例(用户实报):「我在内建屏操作完之后, 回来外接屏直接选中默认选中 Chrome 了,
    ///    但我外接屏本来就停留在 Chrome 的。应该是 Chrome 的上一个 —— ghostty」。
    ///    真因:App 集合是**按屏**的(ADR-0008 ✓),排序却用**全局** MRU ✗
    ///    ⇒ 在另一块屏上用过别的 App,这块屏的"上一个"就变了 ✗(落点跳到错误的人身上)。
    ///    口径:**先按"这块屏上最近用过"排**(`ScreenRecency` ✓),
    ///    没有本屏记录的再按全局 MRU 补 ✓ —— 两条都是**证据**,不是重排 ✓。
    ///    ⚠️ 必须保住"**第一格 = 当前 App**"(落点规则靠它 ✓):所以前台 App 显式提前 ✓
    /// 这批 App 里**最靠前**的那个 pid —— 按 `CGWindowList` 的普通窗顺序(前→后 ✓)。
    ///
    /// 为什么不用 `NSWorkspace.frontmostApplication`(2026-09-22 病例):
    ///   面板在场时它可能报的是**我们自己**(面板是 key 窗 ✓),或干脆是 nil ⇒
    ///   "第一格 = 当前 App"这条不变量就会悄悄失效 ✗(用户截图里第一格是别的 App ✗)
    /// 窗口表是我们唯一自己掌握顺序的证据 ✓(排除自己 ✓:面板那扇窗永远在最前 ✗)
    static func frontmostPID(of pids: Set<pid_t>) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let wd = b["Width"], let h = b["Height"], wd > 60, h > 60 else { continue }
            if pids.contains(pid) { return pid }
        }
        return nil
    }

    static func orderByMRU(_ groups: [AppGroup], on screen: NSScreen) -> [AppGroup] {
        let byPID = Dictionary(groups.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let pids = Array(byPID.keys)
        func rank(_ pid: pid_t) -> Int? { ScreenRecency.shared.rank(of: pid, on: screen) }
        let local = pids.filter { rank($0) != nil }
            .sorted { (rank($0) ?? .max) < (rank($1) ?? .max) }
        let rest = MruEvidence.shared.ordered(pids: pids.filter { rank($0) == nil })
        var ordered = (local + rest).compactMap { byPID[$0] }
        // 前台 App 必须在第一格(原设计:第一眼与原生一致 ✓,落点规则也认这一条 ✓)
        if let front = frontmostPID(of: Set(pids)),
           let i = ordered.firstIndex(where: { $0.pid == front }), i != 0 {
            let g = ordered.remove(at: i)
            ordered.insert(g, at: 0)
        }
        return ordered
    }

    /// 归属判定:与所有屏求几何交集,占比最大的屏是归属屏;必须正好是语境屏且占比达标。
    ///
    /// 坐标系注意:CGWindowList 的 bounds 是 Quartz 坐标(主屏左上原点),
    /// NSScreen.frame 是 AppKit 坐标(主屏左下原点),Y 轴反向。
    /// 交集前必须统一,否则外接屏恒无交集(T4 双屏实机现形)。
    /// `nonisolated`:归属判定要跟着枚举一起下后台(见 `rawGroups`);`NSScreen.screens` 是快照式读取。
    /// 从 private 放开为 internal:落焦要复用同一套「本屏窗」判定,不复制规则。
    nonisolated static func ownsByContextScreen(_ bounds: CGRect, contextScreen: NSScreen) -> Bool {
        let area = bounds.width * bounds.height
        guard area > 0 else { return false }
        var bestScreen: NSScreen?
        var bestRatio: CGFloat = 0
        for s in NSScreen.screens {
            let rect = bounds.intersection(quartzFrame(of: s))
            guard !rect.isNull else { continue }
            let ratio = (rect.width * rect.height) / area
            if ratio > bestRatio { (bestScreen, bestRatio) = (s, ratio) }
        }
        return bestScreen == contextScreen && bestRatio >= ownershipThreshold
    }

    /// NSScreen.frame(AppKit)→ Quartz 坐标。只需翻转 Y:qy = 主屏高 - y - 高
    nonisolated static func quartzFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.origin.x, y: primaryHeight - f.origin.y - f.height, width: f.width, height: f.height)
    }
}
