import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// ADR-0002 圈禁区:全 App 唯一允许出现私有 API 的文件。
// 圈禁物:_SLPSSetFrontProcessWithOptions / SLPSPostEventRecordTo / _AXUIElementGetWindow
// 规则:其余模块只许调 focus(window:) 这一个公开入口;任何私有问题(符号消失、
// 行为改变、系统版本抽风)只许在这个文件内处理。
// ─────────────────────────────────────────────────────────────────────────────

/// 私有 SLPS 符号(dlsym 动态加载——SkyLight 是私有框架无法进 SDK 链接期;
/// DockDoor 同款路线。符号缺席 = 系统版本抽风,优雅降级,不崩)
private typealias SLPSSetFrontProcessFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
) -> CGError
private typealias SLPSPostEventFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> CGError

private enum SLPS {
    /// _SLPSSetFrontProcessWithOptions:前置进程 + 只前置指定窗口
    /// (wid 传进去 = 只 raise 这一扇,不会级联拉起同 App 其他窗——本产品存在的理由)
    static let setFrontProcess: SLPSSetFrontProcessFn? = lookup("_SLPSSetFrontProcessWithOptions")
    /// SLPSPostEventRecordTo:向 WindowServer 投递一条合成事件记录
    static let postEventRecord: SLPSPostEventFn? = lookup("SLPSPostEventRecordTo")

    private static func lookup<T>(_ name: String, as: T.Type = T.self) -> T? {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

/// AX 元素 → CGWindowID(单向桥,alt-tab README:没有反向查询,只能枚举比对)
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Carbon 的 GetProcessForPID 被标记 Swift 不可用,但符号真实存在于系统库,
/// @_silgen_name 重新声明绕开可用性标记(alt-tab 走 bridging header 殊途同归)
@_silgen_name("GetProcessForPID")
private func getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSErr

@MainActor
enum WindowFocuser {
    /// SLPSMode.userGenerated:把这次前置标记为用户发起,防止被系统抑制
    private static let modeUserGenerated: UInt32 = 0x200

    /// 降级只警告一次(ADR-0002:首次降级弹一次告警,之后静默)
    private static var degradedWarned = false

    /// 确认语义的唯一生效动作:聚焦这扇窗,世界其余部分纹丝不动。
    /// 三步(与 alt-tab 收敛同一处实):
    ///   1. _SLPS 前置该窗所在进程 + 该窗
    ///   2. 合成 mouse-down 让它成 key 窗
    ///   3. AX raise 补 App 内 z 序(失败无害,第三步是锦上添花)
    /// 降级:前两步任一异常 → NSRunningApplication.activate(级联拉起,但功能还在)
    static func focus(window w: WindowRecord) {
        var psn = ProcessSerialNumber()
        guard getProcessForPID(w.pid, &psn) == noErr else {
            degrade(w, reason: "GetProcessForPID 返回非 noErr")
            return
        }
        guard let setFront = SLPS.setFrontProcess else {
            degrade(w, reason: "私有符号 _SLPSSetFrontProcessWithOptions 不存在(系统版本抽风?)")
            return
        }
        let frontErr = setFront(&psn, w.wid, modeUserGenerated)
        guard frontErr == .success else {
            degrade(w, reason: "_SLPSSetFrontProcessWithOptions err=\(frontErr.rawValue)")
            return
        }
        makeKeyWindow(&psn, wid: w.wid)
        raiseWithinApp(w)
        glog("[T7] 已聚焦: \(w.ownerName) — \(w.title)")
    }

    // MARK: - 私有区(以下不许被外部调用,也不许离开这个文件)

    /// macOS 14 之后公共 API 无法跨进程设 key 窗。合成一条 mouse-down 投递给 WindowServer,
    /// 落点远在 300000,300000——按 alt-tab 实测:只发 down 就能完成 makeKey,
    /// 且"半条点击"永远无法激活任何控件(down-only、off-content 落点,alt-tab #5381 的教训)
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, wid: CGWindowID) {
        guard let postEvent = SLPS.postEventRecord else { return }
        var mutableWid = wid
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xF8 // 记录自身声明长度
        bytes[0x3A] = 0x10 // 未文档化标志(yabai/Hammerspoon 同值)
        memcpy(&bytes[0x3C], &mutableWid, MemoryLayout<CGWindowID>.size)
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
        bytes[0x08] = 0x01 // kCGEventLeftMouseDown(只发 down)
        _ = postEvent(&psn, &bytes)   // CGError 不用:补焦是"尽人事",失败不该中断流程 ✓
    }

    /// AX raise:在 App 自己的窗口栈里把它顶到最上。元素→wid 只能枚举比对,失败静默
    private static func raiseWithinApp(_ w: WindowRecord) {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// wid → AX 元素(唯一正统桥:枚举该 App 所有窗逐个比对,alt-tab 同法)
    private static func axWindowElement(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        for element in elements {
            var elementWid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &elementWid) == .success, elementWid == wid {
                return element
            }
        }
        return nil
    }

    // MARK: - T12 破坏性键盘操作(Q/W/M,公共 AX/NSRunningApplication,动作仍收口于此)

    /// W:关闭窗口——按它的关闭按钮(等价用户点红灯,尊重 App 的"是否保存"询问)
    static func close(window w: WindowRecord) {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return }
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let closeButton = button as! AXUIElement? else { return }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }

    /// M:最小化窗口(进 Dock;被收走的窗按 CONTEXT.md 归"不可见窗",下次枚举自动消失)
    static func minimize(window w: WindowRecord) {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, true as CFBoolean)
    }

    /// 缩放(绿灯):按它的 zoom 按钮——绿灯是"缩放"不是"全屏",
    /// App 自己决定 content-fit;动作收口与红绿灯语义对齐(预览卡 T14)
    /// F:选中窗进出全屏(AltTab `toggleFullscreenWindowShortcut`,默认 F)。
    ///
    /// 与 Z(zoom,绿灯那颗"铺满")**不是一回事**:全屏会进出**独立的 Space** ——
    /// 所以调用方要重枚举(窗可能整扇离开当前语境屏),面板位置也得跟着重算。
    /// AX 没有公开常量,属性名是字符串 `AXFullScreen`(AltTab 同写法)。
    /// 不支持全屏的窗(某些面板/工具窗)读属性就失败 —— 静默返回,不做任何提示。
    static func toggleFullscreen(window w: WindowRecord) {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return }
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &current) == .success else {
            print("[T29] 这扇窗不支持全屏,忽略")
            return
        }
        let isFullscreen = (current as? Bool) ?? false
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                     (!isFullscreen) as CFBoolean)
    }

    /// H:隐藏选中 App(AltTab `hideShowAppShortcut`,默认 H —— 他们那个是"隐藏/显示"切换)。
    ///
    /// 我们只能**单向隐藏**:本产品只列**在屏窗**(`.optionOnScreenOnly`),App 一隐藏,
    /// 它的窗立刻离屏,面板里也就再也找不到它 —— 这正是原生 ⌘H 的语义,
    /// 想唤回走 Dock 或另开一局。要做成"再按一次唤回",就得把隐藏窗也纳进枚举(那是 T30 候选)。
    /// 返回是否受理(hide() 是**异步**的:受理 ≠ 已经隐完,面板不能等它 —— 见 PanelController.optimisticRemoval)
    @discardableResult
    static func hideApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.hide()
    }

    /// **搬窗**。`resize = true` 时**连尺寸一起设**(撑满用 ✓),否则只挪位置 ✓
    ///
    /// ⚠️ 顺序有讲究:**先尺寸、后位置**。反过来的话,一扇 1600×1000 的窗先挪到小屏上,
    /// 系统会先把它夹小 ✗、再设尺寸又变回大 —— 一来一回 App 会闪一下 ✓;
    /// 先设尺寸再定位,只发生"一次改变" ✓
    /// 设完**回读**一次:有些 App 有最小尺寸/贴边约束 ⇒ 实得与请求不一致是**它的属性**,不是 bug ✗
    /// ⇒ 这一行日志就是为此存在的(`[T33] 搬窗: … 请求 … · 实得 …`)✓
    @discardableResult
    static func move(window w: WindowRecord, to frame: CGRect, resize: Bool = false) -> Bool {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return false }
        var ok = false
        if resize {
            var size = frame.size
            if let value = AXValueCreate(.cgSize, &size) {
                ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
            }
        }
        var origin = frame.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            ok = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success && ok
        }
        var line = "[T33] 搬窗: \(w.title) → 请求 \(Int(frame.minX)),\(Int(frame.minY))"
            + " \(Int(frame.width))x\(Int(frame.height))\(resize ? "(含尺寸)" : "(只挪位)")"
        if let now = readFrame(element) {
            line += " · 实得 \(Int(now.minX)),\(Int(now.minY)) \(Int(now.width))x\(Int(now.height))"
        }
        glog(line)
        return ok
    }

    /// 取某个 App 的**落焦窗**(`AXFocusedWindow` ⇒ `_AXUIElementGetWindow` 拿 wid ✓)
    ///
    /// 用它而不是"窗列表的第一扇":用户口径是"**当前落焦的 app** 上用的快捷键" ⇒
    /// 落焦的那扇窗才是对象 ✓;而且它天然**脱屏**(不必先猜它在哪块屏 ✓)
    static func focusedWindow(ofPID pid: pid_t) -> WindowRecord? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        let element = ref as! AXUIElement
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        return WindowRecord(wid: wid, pid: pid, ownerName: owner,
                            title: (titleRef as? String) ?? "", bounds: readFrame(element) ?? .zero)
    }

    /// 读一扇窗当前的 frame(AX 属性 → CGRect;读不到就 nil)
    private static func readFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func zoom(window w: WindowRecord) {
        guard let element = axWindowElement(pid: w.pid, wid: w.wid) else { return }
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &button) == .success,
              let zoomButton = button as! AXUIElement? else { return }
        AXUIElementPerformAction(zoomButton, kAXPressAction as CFString)
    }

    /// Q:退出整个 App(有未保存内容时 App 会自己弹询问,我们只管发辞呈)
    static func quitApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// T15 无窗应用确认:alt-tab 的处方是"把它当启动一次"——activate 对无窗 App
    /// 在 macOS 14+ 会被系统当君子请求无视(T15 实机现形:选中后没反应)。
    /// openApplication 走不通才退回 activate(allWindows)。
    /// 曾尝试"落点跟随"(T16 轮询/T17 AX 诞生监听:窗口开错屏就挪正),
    /// 两路都有肉眼可感的闪烁,被拍板毙掉(docs/adr/0004)——
    /// 开窗位置交给 macOS 的窗口还原记忆,我们不再管。
    static func focusWindowlessApp(pid: pid_t, contextScreen: NSScreen? = nil) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard let url = app.bundleURL else {
            app.activate(options: .activateAllWindows)
            print("[T15] 无窗应用激活: \(app.localizedName ?? "?")(activate)")
            Self.logLandingProbe(pid: pid, name: app.localizedName ?? "?", contextScreen: contextScreen)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { running, _ in
            if running == nil { app.activate(options: .activateAllWindows) }
        }
        print("[T15] 无窗应用激活: \(app.localizedName ?? "?")(openApplication)")
        Self.logLandingProbe(pid: pid, name: app.localizedName ?? "?", contextScreen: contextScreen)
    }

    /// 🔬 **落屏探针**(2026-09-19,用户问「无窗 App 能不能唤起到我唤起的那块屏」):
    /// 激活后分两拍(0.8s / 1.6s)枚举该 App 的可见窗,量它落在哪块屏、与语境屏是否一致
    /// —— 先量再改:命中率够了,openApplication 的原生语义就是答案;命中率差,
    /// 再考虑指针引导之类的增强。trace 门控,语境屏缺省时不量
    private static func logLandingProbe(pid: pid_t, name: String, contextScreen: NSScreen?) {
        guard isTraceEnabled, let contextScreen else { return }
        let contextName = contextScreen.localizedName   // macOS 26 上它已是 String(非可选)⇒ 别写 `?? "?"` ✗
        for delay in [0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task.detached(priority: .utility) {
                    guard let infos = CGWindowListCopyWindowInfo(
                        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                    ) as? [[String: Any]] else { return }
                    var lines: [String] = []
                    for info in infos {
                        guard let p = info[kCGWindowOwnerPID as String] as? pid_t, p == pid,
                              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                              let b = info[kCGWindowBounds as String] as? NSDictionary,
                              let bounds = CGRect(dictionaryRepresentation: b),
                              bounds.width > 50, bounds.height > 50 else { continue }
                        let landed = NSScreen.screens
                            .first { s in
                                let inter = s.frame.intersection(bounds)
                                return !inter.isEmpty
                                    && inter.width * inter.height > 0.4 * bounds.width * bounds.height
                            }?
                            .localizedName ?? "?"
                        lines.append("\(Int(bounds.width))x\(Int(bounds.height))@\(landed)")
                    }
                    let verdict = lines.isEmpty ? "尚未开窗" : lines.joined(separator: " , ")
                    let hit = !lines.isEmpty && lines.contains { $0.hasSuffix("@\(contextName)") }
                    let mark = lines.isEmpty ? "" : hit ? " ✓" : " ✗"
                    await MainActor.run {
                        print("[落屏探针] +\(String(format: "%.1f", delay))s \(name): \(verdict)(语境=\(contextName))\(mark)")
                    }
                }
            }
        }
    }

    private static func degrade(_ w: WindowRecord, reason: String) {
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
        if !degradedWarned {
            degradedWarned = true
            print("⚠️ [T7] 单窗聚焦降级为整 App 激活(\(reason))。若持续出现请巡检 WindowFocuser")
        }
        print("[T7] 降级聚焦: \(w.ownerName) — \(w.title)(\(reason))")
    }
}
