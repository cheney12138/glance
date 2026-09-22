import AppKit
import CoreGraphics
import GlanceCore

/// **按屏归属的切换** —— 两个功能共用一本窗口账:
///   · 接管系统 ⌘`(只在该屏的同 App 窗口间循环 ✓)
///   · 轻点 ⌘Tab 的静默切换(只切到**该屏上**最近用过的另一个 App ✓)
///
/// ⚠️ 为什么都在 **App 层**(2026-09-22,架构脚本当场抓出来的 ✓):
///   它们既要看**清点**(`WindowEnumerator.ownsByContextScreen`,Inventory ✓)、
///   又要动**落焦**(`WindowFocuser.focus`,Focus ✓)⇒
///   放进任何一个模块都会越界(模块依赖只能向下 ✗)。App 层是**唯一允许装配多模块**的地方 ✓
///   同理:`Trigger/HotkeyTap` 不直接调它们,只留闭包钩子,由 `GlanceApp` 接上 ✓
///   (规矩写在 `Tools/check-architecture.swift` 与 `docs/architecture.md` ✓)
///
/// ⚠️ **屏归属只有一套规则**(ADR-0008:候选集永不跨屏 ✗):
///   两者都用这里的 `ScreenWindowIndex` ✓ —— 绝不许各写一份 ✗
///   (2026-09-22 第一版静默切换就是"直接 activate(App 级)"⇒ **跨屏了** ✗,
///    用户一句"你没做到显示器隔离吧"当场指出 ✓)

// MARK: - 共用:某块屏上的普通窗口

/// 一次 `CGWindowList` 快照里,某扇/某 App 的**普通层**窗口(前→后 z 序 ✓)
enum ScreenWindowIndex {

    /// 一扇普通窗:wid + 位置(Quartz 坐标 ✓)
    struct RawWindow { let wid: CGWindowID; let pid: pid_t; let bounds: CGRect }

    /// 一次快照(整表只查一次 ✓ —— 枚举很贵,别在循环里反复调 ✓)
    static func snapshot() -> [RawWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [RawWindow] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int) == 0,          // 只认普通层(菜单/浮层排除 ✓)
                  let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
                  wd > 60, h > 60 else { continue }
            out.append(RawWindow(wid: CGWindowID(n), pid: pid,
                                 bounds: CGRect(x: x, y: y, width: wd, height: h)))
        }
        return out
    }

    /// 原始条目(给需要 title/owner 的调用方用 ✓ —— 仍然只查一次 CGWindowList ✓)
    struct RawInfo { let wid: CGWindowID; let pid: pid_t?; let layer: Int
                     let bounds: CGRect; let title: String?; let owner: String? }

    static func snapshotRawInfo() -> [RawInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.map { w in
            let b = w[kCGWindowBounds as String] as? [String: CGFloat]
            return RawInfo(wid: (w[kCGWindowNumber as String] as? Int).map(CGWindowID.init) ?? 0,
                           pid: w[kCGWindowOwnerPID as String] as? pid_t,
                           layer: w[kCGWindowLayer as String] as? Int ?? -1,
                           bounds: b.flatMap { bb in
                               guard let x = bb["X"], let y = bb["Y"],
                                     let wd = bb["Width"], let h = bb["Height"] else { return nil }
                               return CGRect(x: x, y: y, width: wd, height: h)
                           } ?? .zero,
                           title: w[kCGWindowName as String] as? String,
                           owner: w[kCGWindowOwnerName as String] as? String)
        }
    }

    /// 一块屏"归"哪扇窗:与各屏求几何交集、取占比最大的那块 ✓(坐标要先统一 ✓)
    static func screen(owning bounds: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ra = bounds.intersection(WindowEnumerator.quartzFrame(of: a))
            let rb = bounds.intersection(WindowEnumerator.quartzFrame(of: b))
            let aa = ra.isNull ? 0 : ra.width * ra.height
            let ab = rb.isNull ? 0 : rb.width * rb.height
            return aa < ab
        }
    }

    /// **当前屏** = 焦点窗口(前台 App 最前一扇窗)所在的那块屏 ✓ —— **与鼠标指针无关** ✓
    /// (用户 2026-09-22 裁掉了"以哪块屏为准"这个配置项,口径只留这一种 ✓)
    static func contextScreen(snapshot snap: [RawWindow]) -> NSScreen? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let bounds = snap.first(where: { $0.pid == front })?.bounds else { return nil }
        return screen(owning: bounds)
    }

    /// 某 App 在**某块屏**上"有没有普通窗"(只看快照 ✓ —— **不调 AX** ✓)
    ///
    /// ⚠️ 这一条是为**快**而存在的:轻点 ⌘Tab 要在几毫秒内决定切谁 ✗,
    ///    而 `windows(ofPID:on:)` 每个 App 都要问一次 AX(10ms 级 ✗)
    ///    ⇒ 用它筛"谁在这块屏上"(廉价 ✓),只对**最后那个目标**才走 AX ✓
    static func hasWindow(pid: pid_t, on screen: NSScreen, snapshot snap: [RawWindow]) -> Bool {
        snap.contains { $0.pid == pid && WindowEnumerator.ownsByContextScreen($0.bounds, contextScreen: screen) }
    }

    /// 某 App 在**某块屏**上的窗口(前→后 ✓)—— 已过"AX 认可 + 归属这块屏"两道 ✓
    /// ⚠️ 每次调用都会问一次 AX(10ms 级)⇒ **别在循环里用** ✗(筛候选请用 `hasWindow ✓`)
    static func windows(ofPID pid: pid_t, on screen: NSScreen, snapshot snap: [RawWindow]) -> [RawWindow] {
        let admitted = AXWindowList.admission(ofPID: pid)?.admitted   // nil = AX 没话说 ⇒ 不过滤 ✓
        return snap.filter { r in
            r.pid == pid
                && (admitted?.contains(r.wid) ?? true)
                && WindowEnumerator.ownsByContextScreen(r.bounds, contextScreen: screen)
        }
    }
}

// MARK: - 接管系统 ⌘`:只在该屏的同 App 窗口间循环

/// 用户 2026-09-22:「能拦截系统的 cmd+`(只在当前屏幕内容的同类型app跳转)」。
/// 系统的 ⌘` 会在**所有屏幕**的同 App 窗口之间跳,双屏时会把人送到另一块屏 ✗;
/// 这里换成"只在当前屏内跳" ✓(开关默认**关** ⇒ 关着时一个字都不变 ✓)。
enum SameAppScreenCycler {

    /// 前台 App 在"当前屏"的窗口(前→后 ✓)
    /// - Returns: `nil` = 没法判断(前台 App 没有普通窗)⇒ 调用方不动作 ✓
    @MainActor
    static func windowsOnContextScreen() -> (pid: pid_t, name: String, pool: [WindowRecord], screen: NSScreen)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let snap = ScreenWindowIndex.snapshot()
        guard let screen = ScreenWindowIndex.contextScreen(snapshot: snap) else { return nil }
        let pool = ScreenWindowIndex.windows(ofPID: pid, on: screen, snapshot: snap)
        let name = app.localizedName ?? ""
        return (pid, name, pool.map {
            WindowRecord(wid: $0.wid, pid: pid, ownerName: name, title: "", bounds: $0.bounds)
        }, screen)
    }

    /// 走一步。`forward = false` 用于 ⌘⇧`(反向:直接到最后面那扇 ✓)
    @MainActor
    @discardableResult
    static func step(forward: Bool) -> Bool {
        guard let (_, name, pool, screen) = windowsOnContextScreen() else {
            if isTraceEnabled { glog("[接管⌘`] 前台 App 没有普通窗 ⇒ 不动作") }
            return false
        }
        guard pool.count > 1 else {
            if isTraceEnabled {
                glog("[接管⌘`] \(name) 在 \(screen.localizedName) 只有 \(pool.count) 扇窗 ⇒ 不动作")
            }
            return false
        }
        let target = forward ? pool[1] : pool[pool.count - 1]
        if isTraceEnabled {
            glog("[接管⌘`] \(name) 在焦点屏(\(screen.localizedName)) "
                 + "\(pool.count) 扇窗 → 跳第 \(forward ? 2 : pool.count) 扇 wid=\(target.wid)")
        }
        WindowFocuser.focus(window: target)
        return true
    }
}

// MARK: - 轻点 ⌘Tab 的静默切换:只在该屏上最近用过的另一个 App

/// 用户 2026-09-22:「cmd tab 如果只是触发了一次, 就不要展示面板, 直接触发窗口切换。
/// 只有 cmd 没松开的时候, 才唤起面板, 然后**显式的定义一下, cmd tab 默认是在 a<->b
/// 两个 app 中反复来回切换的**。这样更效率一点, 就不做设置开关了。」
///
/// 语义(显式):正向 = 切到**这块屏上**最近用过的另一个 App ⇒ A→B、再按 B→A ✓;
/// 反向(⇧⌘Tab)= MRU 里最久没用过的那个 ✓。
///
/// ⚠️ 与"直接 activate(App 级)"的区别(第一版就是那样,被用户当场指出 ✗):
///   activate 会把 App 的**任意一扇窗**拉到前面 —— 双屏时会**跨屏** ✗(违反 ADR-0008)。
///   这里:候选 = **在这块屏上有窗口的 App** ✓,落点 = 它**在这块屏上的最前一扇窗** ✓
enum QuickSwitch {
    @MainActor
    static func toPreviousApp(forward: Bool) {
        let snap = ScreenWindowIndex.snapshot()
        guard let screen = ScreenWindowIndex.contextScreen(snapshot: snap) else { return }

        // 候选:常规 App 里"在这块屏上有窗口"的那些(顺序交给 MRU ✓)
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // ★ 筛候选只查快照(不碰 AX ✓)—— 否则 10 个 App × 10ms = 100ms ✗,
        //   正好把"轻点要快"这件事毁掉 ✗(自己 review 时抓到的 ✓)
        let onScreen = regular.filter { ScreenWindowIndex.hasWindow(pid: $0.processIdentifier,
                                                                   on: screen, snapshot: snap) }
        // ★ 顺序:**先按"这块屏上最近用过"**(ScreenRecency ✓ —— 与面板落点同一本账 ✓),
        //   没有本屏记录的再按全局 MRU 补 ✓(2026-09-22 用户实报:全局顺序跨屏污染 ✗)
        let pids = onScreen.map(\.processIdentifier)
        func rank(_ pid: pid_t) -> Int? { ScreenRecency.shared.rank(of: pid, on: screen) }
        let order = pids.filter { rank($0) != nil }.sorted { (rank($0) ?? .max) < (rank($1) ?? .max) }
            + MruEvidence.shared.ordered(pids: pids.filter { rank($0) == nil })
        guard order.count > 1 else {
            if isTraceEnabled {
                glog("[轻点⌘Tab] \(screen.localizedName) 上不足两个 App ⇒ 不动作(不跨屏 ✗)")
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let idx = front.flatMap { order.firstIndex(of: $0) } ?? 0
        let targetIdx = forward ? (idx + 1) % order.count : (idx - 1 + order.count) % order.count
        let target = order[targetIdx]
        // 落点:那 App **在这块屏上**的最前一扇窗 ⇒ 用与 ⌘` 同一套(清点 + 落焦 ✓)
        guard let window = ScreenWindowIndex.windows(ofPID: target, on: screen, snapshot: snap).first else { return }
        if isTraceEnabled {
            glog("[轻点⌘Tab] \(forward ? "正向" : "反向") ⇒ pid=\(target) 在 \(screen.localizedName)"
                 + " 的 wid=\(window.wid)(MRU 第 \(targetIdx + 1)/\(order.count) 位)")
        }
        WindowFocuser.focus(window: WindowRecord(wid: window.wid, pid: target,
                                                ownerName: "", title: "", bounds: window.bounds))
    }
}

// MARK: - 双击 ⌥:指针跳到下一块屏 + 落焦(从 Trigger 搬来,2026-09-22 还债 ✓)

/// 原在 `Trigger/DoubleOptionTap` ✓ —— 它既要看清点(`WindowEnumerator`)又要落焦(`WindowFocuser`)
/// ⇒ 在 Trigger 里是**双向越界** ✗(架构脚本报了它很久,记在已知账里)。现在按同一套
/// "闭包钩子 + App 层装配"还掉 ✓ —— 那边只剩"拖拽途中不算"这一条判断 ✓,其余全在这里 ✓。
///
/// 语义(用户 2026-09-15 裁定,照旧不改 ✓):
///   · 指针**居中**落到下一块屏的正中间(可预测:闭眼也知道在哪 ✓)
///   · **落焦是固定语义**(没有"只搬指针"模式 —— 「移动过去不落焦那移动的意义是什么」✓)
///   · 落焦到那扇 **窗**(不是 App):同一 App 可能两块屏各有窗,让 App 自己决定键盘给谁
///     正是"激活不保证落焦"那个坑 ✓(见 CONTEXT.md ✓)
enum DoubleOptionJump {

    @MainActor
    static func jumpToNextDisplay() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

        // 全程用 CoreGraphics 坐标系(原点在主屏**左上** ✓):指针位置与屏幕矩形同系 ⇒
        // 不需要 y 翻转 —— 少一次换算出错的机会 ✓(这类翻转是经典 bug 源 ✓)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard let from = ids.firstIndex(where: { CGDisplayBounds($0).contains(cursor) }) else { return }
        let targetID = ids[(from + 1) % ids.count]
        let b = CGDisplayBounds(targetID)

        CGWarpMouseCursorPosition(CGPoint(x: b.minX + 0.5 * b.width, y: b.minY + 0.5 * b.height))
        CGAssociateMouseAndMouseCursorPosition(1)   // 防止与事件流解耦(否则指针"冻住"直到动一下 ✓)

        var landed = ""
        if let w = landingWindow(on: targetID) {
            WindowFocuser.focus(window: w)
            landed = " · 落焦 \(w.ownerName)"
        }
        glog(String(format: "[指针] 双击 ⌥ → 屏 %d → 屏 %d (居中)%@",
                    from + 1, (from + 1) % ids.count + 1, landed))
    }

    /// 目标屏上 **Z 序最前**的那扇窗 = 用户说的"台前第一个 App" ✓
    ///
    /// ⚠️ 不能拿 `rawGroups(on:).first` —— 那个数组是按 pid 分组的 **Dictionary 的值**,
    /// 而 Swift 里 Dictionary 的顺序未定义 ✗(实机现形 2026-09-15:用户报"不是台前第一个,
    /// 现在是系统自己选的" ✓)。⇒ 直接问 `CGWindowList`:它返回的数组是**前到后**的 Z 序 ✓,
    /// 第一个命中者就是"层级最上面"那扇 ✓。过滤规则与 `rawGroups` 保持一致 ✓
    @MainActor
    static func landingWindow(on displayID: CGDirectDisplayID) -> WindowRecord? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in ScreenWindowIndex.snapshotRawInfo() {          // 顺序遍历 = 从最上面往下 ✓
            guard let pid = info.pid, pid != ownPID,
                  info.wid != 0, info.layer == 0,
                  info.bounds.width > 1, info.bounds.height > 1,
                  WindowEnumerator.ownsByContextScreen(info.bounds, contextScreen: screen)
            else { continue }
            let title = (info.title?.isEmpty == false ? info.title! : "(无标题)")
            let owner = info.owner ?? "(未知应用)"
            return WindowRecord(wid: info.wid, pid: pid, ownerName: owner, title: title, bounds: info.bounds)
        }
        return nil
    }
}
