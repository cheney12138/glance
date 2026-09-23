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

// MARK: - 显示器顺序(全 App 唯一一处口径)

/// **显示器的顺序** —— 所有"下一块屏/上一块屏"都用它 ✓
///
/// 为什么不用 `NSScreen.screens`:它的顺序**没有文档保证** ✗,而 CoreGraphics 的活动显示器列表
/// 是稳定的,而且"双击 ⌥ 跳指针"(`DoubleOptionJump`)一直在用它 ✓ —— **两条功能必须同一套顺序**,
/// 否则"下一块屏"会各走各的 ✗(2026-09-22 统一,顺手把"送窗"从 NSScreen.screens 换过来 ✓)
///
/// 屏数 >2 时的口径(用户 2026-09-22):「这个 app 就不是给超多屏场景设计的 ⇒ 给窗口排个序,
/// 123 循环移动就行了」✓ —— 就是这里的顺序 + `ScreenMovePolicy.nextScreenIndex` 的 `(i+1) % n` ✓
enum DisplayOrder {

    /// 按 CoreGraphics 的顺序返回屏(映射不全时**退回系统顺序** —— 宁可顺序不保证,也不能丢屏 ✗)
    @MainActor
    static func screens() -> [NSScreen] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return NSScreen.screens }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return NSScreen.screens }
        let all = NSScreen.screens
        let ordered = ids.compactMap { id in all.first { displayID(of: $0) == id } }
        return ordered.count == all.count ? ordered : all
    }

    /// 这块屏在这份顺序里的下标(先按对象身份,再按 displayID ✓)
    @MainActor
    static func index(of screen: NSScreen, in list: [NSScreen]) -> Int? {
        if let i = list.firstIndex(where: { $0 === screen }) { return i }
        let id = displayID(of: screen)
        return list.firstIndex { displayID(of: $0) == id }
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - ⇧+双击 ⌥:把落焦窗送到下一块屏(脱面板的全局动作)

/// 用户口径(2026-09-22):「cmd t 是很多 app 的新建快捷键, 我期望做成**脱离面板**的 ——
/// 跟 double option 一样。在**当前落焦的 app** 上使用快捷键之后, 直接移动到另一块屏幕」。
///
/// 为什么住在 App 层:要同时看 Inventory(窗/屏归属)与 Focus(AX 搬窗)——
/// 放 Trigger 里就是**双向越界** ✗(架构脚本会报 ✓;与 `DoubleOptionJump` 同一条理由 ✓)
///
/// 口径:
///   · 对象 = **当前落焦 App 的落焦窗**(AXFocusedWindow ✓)—— 与面板里选中哪一格**无关** ✓
///   · 目的地 = 它**现在所在屏**的下一块(多屏循环 ✓;单屏 ⇒ 什么都不做,只记一行 ✓)
///   · 落点/尺寸 = `GlanceCore.ScreenMovePolicy`(尺寸不变 ✓ 相对位置 ✓)✓
enum MoveFocusedWindowToNextScreen {
    /// `@MainActor`:它要动 AX 与窗口 —— 与 `DoubleOptionJump` 同款隔离 ✓
    @MainActor
    static func run() {
        let screens = DisplayOrder.screens()      // ★ 与"双击 ⌥ 跳指针"同一套顺序 ✓
        guard screens.count > 1 else {
            glog("[T33] 只有一块屏 ⇒ 没有可搬的目的地")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            glog("[T33] 前台就是本 App ⇒ 不搬自己")
            return
        }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"
        guard let win = WindowFocuser.focusedWindow(ofPID: pid), win.bounds.width > 1 else {
            glog("[T33] 取不到 \(name) 的落焦窗 ⇒ 什么都不做")
            return
        }
        // 它现在归哪块屏(ADR-0008 的归属判据 ✓ —— 与面板同一套,别另立口径 ✗)
        guard let srcIdx = screens.firstIndex(where: {
            WindowEnumerator.ownsByContextScreen(win.bounds, contextScreen: $0)
        }), let dstIdx = ScreenMovePolicy.nextScreenIndex(current: srcIdx, count: screens.count) else {
            glog("[T33] 认不出这扇窗归哪块屏 ⇒ 什么都不做")
            return
        }
        let src = screens[srcIdx], dst = screens[dstIdx]
        // ★ 用户口径(2026-09-22):「移动过去之后能**默认撑满整个屏幕**吗, 不是全屏」
        //   ⇒ 目标 = **目标屏的可见区**（避开菜单栏与 Dock ✓）;`.fillScreen` 是默认档 ✓
        //   ⚠️ 这不是 macOS 全屏：不进独立 Space、不播全屏动画、也不改窗口的全屏状态 ✓
        //   想回到"保持原尺寸只挪位置" ⇒ `ScreenMovePolicy.defaultPlacement = .keepSize` 一行 ✓
        // ⚠️ 用**可见区**(`quartzVisibleFrame`)而不是整块屏:整块屏会把窗口送到菜单栏底下,
        //    连标题栏都抓不到 ✗(Quartz 坐标里 y 越小越靠上 ✓)
        let target = ScreenMovePolicy.targetFrame(current: win.bounds,
                                                 source: WindowEnumerator.quartzVisibleFrame(of: src),
                                                 target: WindowEnumerator.quartzVisibleFrame(of: dst))
        let fill = ScreenMovePolicy.defaultPlacement == .fillScreen
        // 屏数 >2 时,这行日志就是"循环对不对"的唯一凭据 ⇒ 必须写明"第 i/N 块屏" ✓
        glog("[T33] 送屏 第 \(srcIdx + 1)/\(screens.count) 块 → 第 \(dstIdx + 1)/\(screens.count) 块"
             + "(\(src.localizedName) → \(dst.localizedName)):\(name) — \(win.title)"
             + " \(ScreenMovePolicy.defaultPlacement.displayName)")
        _ = WindowFocuser.move(window: win, to: target, resize: fill)
    }
}


// MARK: - (已放弃)轻点 ⌘Tab 不弹面板

// 2026-09-22 试过:轻点(短按快松)不弹面板、直接切 App;按住才弹。
// **用户裁定放弃** —— 原话:「延迟还是有点大。要不就摘掉这个吧, 影响也不大,
// macos 原生就这样。只要保证切换逻辑正确就行了」✓
// 两版阈值(0.22s / 0.45s + "先按住 ⌘ 再点 Tab"提前判据)都试过:
// 时间阈值**两全不了** —— 短了轻点也弹面板 ✗,长了想浏览的人要等半秒 ✗。
// ⇒ 恢复原生:**按下即弹面板** ✓;而"切换逻辑的正确性"由这两条保证 ✓:
//   · 落点**跳过当前 App**(`LandingRule.landingIndex(count:from:reverse:)` + `WindowEnumerator.frontmostPID` ✓)
//   · 顺序按"**这块屏**的最近用过"排(`ScreenRecency` ✓)
