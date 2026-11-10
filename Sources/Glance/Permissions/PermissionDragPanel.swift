import AppKit
import SwiftUI
import QuartzCore
/// 拖拽助手浮层(2026-11-05,照 Snow Shot 的引导,二次重写对齐其源码)。
///
/// 病例:权限引导窗里只写了"可拖进列表"的文字,但**拖拽得有源头** —— 系统设置的
/// 权限列表接受 .app 拖放,接住提示只在真的有拖拽悬停时才出现。这个浮层提供一枚
/// **可拖的 App 图标**:按住它拖到权限列表上,系统就弹原生的"拖到上方列表"接住
/// 提示,松手即完成添加(拖进去后**仍需手动拨开关** —— TCC 安全设计,谁也绕不过)。
///
/// v2(读 Snow Shot 源码后的三处对齐):
/// 1. **定位贴着设置窗口右下角**(CGWindowList 拿真实 bounds),不是屏幕下方 ——
///    设置窗口挪了/换屏,浮层 100ms 跟一次;
/// 2. **跟随与消失**:设置最小化/切 Space/被关 → 浮层跟着藏;激活回来 → 跟回;
///    授权齐了 → 收;拖拽进行中 → 冻结一切重定位与消失(拖一半消失太尴尬);
/// 3. 窗口 `hidesOnDeactivate = false` + NonactivatingPanel + 全空间 ——
///    浮层是"设置的贴身助手",不是"屏幕上的孤儿贴纸"。
@MainActor
final class PermissionDragPanel {
    static let shared = PermissionDragPanel()

    private var panel: NSPanel?
    private var tick: Timer?
    /// 是否见过设置窗口(找不到窗口时藏自己,但见过之后再找不到 = 最小化/切 Space)
    private var sawSettingsWindow = false
    private var showStartedAt = CACurrentMediaTime()

    // MARK: 生命周期

    /// 点「去授权」后调用:等 System Settings 上屏,再开始贴身跟随。
    /// 设置 5s 内没起来就放弃(孤儿浮层比没有浮层更糟 —— Snow Shot 同口径)。
    func show() {
        hide()
        showStartedAt = CACurrentMediaTime()
        startTick()
    }

    func hide() {
        tick?.invalidate()
        tick = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: tick(100ms,Snow Shot 同节奏)

    private func startTick() {
        tick?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePlacement() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func updatePlacement() {
        guard let settings = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == "com.apple.systempreferences" })
        else {
            // 设置整个退出了:收(点按钮后它可能还没起来,给 5s 窗口)
            if CACurrentMediaTime() - showStartedAt > 5.0 { hide() }
            else { panel?.orderOut(nil) }
            return
        }
        // 设置没激活且浮层也不是 key:跟着藏(Snow Shot:settingsActive || guideActive)
        let settingsActive = settings.isActive
        let guideVisible = panel?.isVisible == true
        if !settingsActive && !guideVisible {
            // 还在等它起来;超过 5s 没等到就整个放弃
            if CACurrentMediaTime() - showStartedAt > 5.0 { hide() }
            return
        }
        // CGWindowList 拿设置窗口的真实 bounds(macOS 14 的 NSRunningApplication 没有窗口列表)
        guard let bounds = settingsWindowBounds(pid: settings.processIdentifier) else {
            // 找不到窗口:最小化 / 切了 Space / 还在启动 —— 藏自己,继续等
            sawSettingsWindow = false
            panel?.orderOut(nil)
            return
        }
        sawSettingsWindow = true
        if panel == nil { presentPanel() }
        // 拖拽中冻结重定位(拖一半面板跑了 = 灾难)。SwiftUI 的 onDrag 没有结束回调,
        // 直接探测鼠标左键:按着 = 拖拽进行中(Snow Shot 用 QDrag.exec 阻塞拿同款语义)
        if NSEvent.pressedMouseButtons & 1 != 0 { return }
        placeBeside(settingsBounds: bounds)
        panel?.orderFrontRegardless()
    }

    /// CGWindowList:设置进程里**最大的一块 layer-0 在屏窗口** = 主设置窗
    private func settingsWindowBounds(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [ .optionOnScreenOnly, .excludeDesktopElements ], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let dict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = dict["X"], let y = dict["Y"],
                  let w = dict["Width"], let h = dict["Height"],
                  w >= 300, h >= 200     // 主窗体(排除小工具窗/提示条)
            else { continue }
            let r = CGRect(x: x, y: y, width: w, height: h)
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    /// 贴在设置窗口**右下角内侧**(Snow Shot permissionGuidePlacement 同款:
    /// right - width - 12, bottom - height - 16,夹在屏幕可视区内)。
    /// 注意 CGWindowList 的 y 轴向下、AppKit 的向上 —— 统一换算成 AppKit 坐标再摆。
    private func placeBeside(settingsBounds cg: CGRect) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.intersects(cg) })
                ?? NSScreen.main else { return }
        let panelSize = panel.frame.size
        let screenHeight = screen.frame.height
        // CG 坐标(AppKit 屏幕坐标系:原点主屏左上,y 向下)转 AppKit 全局坐标
        let appKitX = cg.origin.x
        let appKitBottomY = screenHeight - (cg.origin.y + cg.height)
        // 贴右下角内侧:右边距 12,下边距 16
        var x = appKitX + cg.width - panelSize.width - 12
        var y = appKitBottomY + 16
        // 夹进这块屏的可视区(避开 Dock/菜单栏)
        let vis = screen.visibleFrame
        x = min(max(x, vis.minX + 12), vis.maxX - panelSize.width - 12)
        y = min(max(y, vis.minY + 12), vis.maxY - panelSize.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 真正建窗(第一次见到设置窗口时)
    private func presentPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 116),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false      // 浮层不随 Glance 失活消失(它是设置的贴身助手)
        p.hasShadow = true
        // ⚠️ 不能开 isMovableByWindowBackground(2026-11-05 病例):它会在 mouse-down 阶段
        //   把整窗拖走,SwiftUI 的 .onDrag 根本接不到手势 —— 用户实测「拖图标整个窗口都在跑」。
        p.contentView = NSHostingView(rootView: DragPanelContent(onClose: { [weak self] in self?.hide() }))
        panel = p
    }
}

/// 浮层内容:提示 + 可拖的 App 图标 + 关闭。样式走设置纸面语言(SettingsTheme)。
private struct DragPanelContent: View {
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SettingsTheme.beam)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 10) {
                Text("将“Glance”拖到上方的权限列表中，再把开关打开")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                AppIconDragSource(bundleURL: Bundle.main.bundleURL)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink2)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsTheme.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
                )
        )
    }
}
/// 可拖的 App 图标行:拖拽负载 = bundle 的文件 URL,**Finder 同款写字板**(2026-11-09 v3)。
///
/// 病例(v2 SwiftUI `.onDrag`):拖进权限列表「什么都没发生」—— NSItemProvider 的负载
/// 类型与 Finder 不等价。v3 换 AppKit 原生拖拽源:`NSPasteboard.writeObjects([NSURL])`,
/// 与 Finder 写入一字不差(Finder 能进,这个就能进)。
///
/// 热区教训(2026-11-09 用户,气死状):「只移动 app」= **拖拽只能从图标本身起手** ——
/// 本 view 就是 28×28 的图标,热区严格等于图标 frame,行内文字/胶囊底不接拖拽 ✓
private struct AppIconDragSource: View {
    let bundleURL: URL

    var body: some View {
        // ★ v4 样式(2026-11-09 用户):去掉胶囊容器和「Glance」文字 —— 那个透明容器会让
        //   人以为整个都能拖;只剩一枚大图标,热区 = 图标 = 视觉,所见即可拖 ✓
        DragIconNSView.Representable(bundleURL: bundleURL)
            .frame(width: 44, height: 44)
    }
}

/// 原生拖拽源(热区 = 本 view frame = 图标本身;拖拽影像 = 48pt 图标,热点居中)
private final class DragIconNSView: NSView {
    var bundleURL: URL
    private var dragStarted = false

    /// SwiftUI 桥:DragIconNSView 是 NSView(有 .frame 属性),不能直接当 View 用 ——
    /// 第一版直接塞 body,`.frame(width:height:)` 被解析成 NSView.frame(CGRect)的调用 ✗
    struct Representable: NSViewRepresentable {
        let bundleURL: URL
        func makeNSView(context: Context) -> DragIconNSView { DragIconNSView(bundleURL: bundleURL) }
        func updateNSView(_ view: DragIconNSView, context: Context) { view.bundleURL = bundleURL; view.refreshIcon() }
    }

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        // 图标本体(v3 病例:拖拽源 view 是透明的,忘了画图标 ⇒ 胶囊里只剩「Glance」文字)
        // ⚠️ v4 病例(用户:「图标颜色这么淡」):isEnabled = false 会让 NSImageView 把图
        //   画成淡化态 ⇒ 保持 enabled,事件隔离改由 hitTest 拦截(见下)✓
        let iv = NSImageView(frame: bounds)
        iv.image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)
    }

    /// 事件全收在拖拽源自己手里(热区 = 图标 frame);NSImageView 不参与命中,免得
    /// 它自己的 mouseDown 语义分走拖拽 —— 但不能靠 isEnabled=false(会淡化图标 ✗)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    func refreshIcon() {
        (subviews.first as? NSImageView)?.image = NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false   // 每次按下重置(拖起才算,纯点击不拖)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 拖拽阈值(≥5pt 才算拖,免得点击误起手)
        guard abs(p.x - bounds.midX) > 4 || abs(p.y - bounds.midY) > 4 else { return }
        dragStarted = true
        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        // ★ Finder 同款负载:NSURL 写进拖拽写字板(会带 public.file-url + bundle 的真实类型)
        pb.writeObjects([bundleURL as NSURL])
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        item.setDraggingFrame(NSRect(x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: DragSourceProxy.shared)
    }
}

/// beginDraggingSession 要求一个持久的 source(拖拽会话期间不能被释放)。
/// 无状态代理单例:负载在 pasteboard 里,source 无事可做(不拒收、不叠加)。
private final class DragSourceProxy: NSObject, NSDraggingSource {
    static let shared = DragSourceProxy()
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
