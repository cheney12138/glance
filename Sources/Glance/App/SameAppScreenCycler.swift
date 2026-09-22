import AppKit
import CoreGraphics
import GlanceCore

/// **系统 ⌘` 的接管**:只在"焦点窗口所在的那块屏"里循环同 App 的窗口 ✓
///
/// ⚠️ 它为什么在 **App 层**而不是 `Focus/`(2026-09-22,架构脚本当场抓出来的 ✓):
///   它既要看**清点**(`WindowEnumerator.ownsByContextScreen`,Inventory 模块 ✓)、
///   又要动**落焦**(`WindowFocuser.focus`,Focus 模块 ✓)⇒
///   放进任何一个模块都会越界(模块依赖只能向下 ✗)。App 层是**唯一允许装配多模块**的地方 ✓
///   同理:`Trigger/HotkeyTap` 不直接调它,只留一个闭包钩子,由 `GlanceApp` 接上 ✓
///   (这条规矩写在 Tools/check-architecture.swift 与 docs/architecture.md 里 ✓)

// MARK: - 系统 ⌘` 的接管(只在当前屏内循环同 App 的窗口)

/// 用户 2026-09-22:「能拦截系统的 cmd+`(只在当前屏幕内容的同类型app跳转)」。
///
/// 系统的 ⌘` 会在**所有屏幕**的同 App 窗口之间跳,于是双屏时会把人送到另一块屏去 ✗;
/// 这里换成"只在当前屏内跳" ✓。开关默认**关**(opt-in)⇒ 关着时一个字都不变 ✓。
enum SameAppScreenCycler {

    // ★ 2026-09-22 用户裁掉了"哪块屏"这个配置项,口径**只留一种**:
    //   「当前焦点在 A 屏 ⇒ 就在 A 屏里的同 App 窗口间切,**与鼠标指针无关**」
    //   理由(用户原话):「太复杂了, 只做一种场景, 当前焦点在 a 屏幕,
    //   然后就在 a 屏幕里的 idea 窗口间切换, 跟鼠标指针无关, 而且不要暴露这个配置项」
    //   ⇒ 焦点窗口 = 前台 App 的**最前一扇**窗(即 key 窗 ✓),它的归属屏就是"当前屏" ✓
    //   归属判定仍然复用唯一那一套(`ownsByContextScreen`)✓

    /// 前台 App 在"当前屏"的窗口,按 **z 序(前→后)** 排 —— 与 `CGWindowList` 的顺序一致 ✓
    /// - Returns: `nil` = 没法判断(前台 App 没有普通窗)⇒ 调用方不动作 ✓
    @MainActor
    static func windowsOnContextScreen() -> (pid: pid_t, name: String, pool: [WindowRecord], screen: NSScreen)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }

        var raw: [(wid: CGWindowID, bounds: CGRect)] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,          // 只认普通层(菜单/浮层都排除 ✓)
                  let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
                  wd > 60, h > 60 else { continue }
            raw.append((CGWindowID(n), CGRect(x: x, y: y, width: wd, height: h)))
        }
        guard let frontBounds = raw.first?.bounds else { return nil }

        // 当前屏 = **焦点窗口所在的那块屏**(与指针无关 ✓)
        let screen = NSScreen.screens.max { a, b in
            let ra = frontBounds.intersection(WindowEnumerator.quartzFrame(of: a))
            let rb = frontBounds.intersection(WindowEnumerator.quartzFrame(of: b))
            let aa = ra.isNull ? 0 : ra.width * ra.height
            let ab = rb.isNull ? 0 : rb.width * rb.height
            return aa < ab
        }
        guard let screen else { return nil }

        // ⚠️ 归属判定**复用唯一那一套**(`ownsByContextScreen`)—— 屏归属绝不许有第二套规则 ✓
        let admitted = AXWindowList.admission(ofPID: pid)?.admitted     // nil = AX 没话说 ⇒ 不过滤 ✓
        let pool = raw.filter { r in
            (admitted?.contains(r.wid) ?? true)
                && WindowEnumerator.ownsByContextScreen(r.bounds, contextScreen: screen)
        }
        return (pid, app.localizedName ?? "", pool.map {
            WindowRecord(wid: $0.wid, pid: pid, ownerName: app.localizedName ?? "", title: "", bounds: $0.bounds)
        }, screen)
    }

    /// 走一步。`forward = false` 用于 ⌘⇧`(反向:直接到最后面那扇 ✓)
    @MainActor
    @discardableResult
    static func step(forward: Bool) -> Bool {
        guard let (pid, name, pool, screen) = windowsOnContextScreen() else {
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
