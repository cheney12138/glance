import AppKit
import ApplicationServices

/// `_AXUIElementGetWindow`(未公开符号):拿一个 AX 元素对应的窗口 id。
/// 这是 AX 里最便宜的一次调用(不直接跨进程读属性,AppKit 内部就有答案),AltTab 也用它
/// 在 CGWindowList 与 AXWindows 之间对号入座。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// "这扇 CG 窗配不配进切换列表"的**AX 侧证据**。
///
/// 病例(2026-09-14 用户实机):Chrome 只有一扇真窗,面板里却是两张卡片 —— 多出来那张标题"(无标题)"、
/// 快照一片空白,而且它**不是幽灵窗**:实测是 Chrome 的「在页面中查找」浮条,
/// `415×84`、`role=AXWindow`、**`subrole=AXUnknown`**、**`main=0`**、CG 侧标题为空。
/// 只查 alpha/尺寸/层级的"廉价启发式"永远拦不住它。
///
/// 判据抄 AltTab 的 `WindowAdmissionResolver.resolve()`,按公开字段能表达的部分落地:
///   · `subrole == AXStandardWindow`        → 常规窗口,收;
///   · `isMain == true`                     → App 的"主窗",收(它是对 surface 的事实,
///     不是"谁在前台",App 退到后台也仍为 true —— AltTab 跨 Chrome/TextEdit/ChatGPT 实测过);
///   · `subrole == AXDialog` 且**有标题**    → 对话框,收(无标题对话框 = 拿不准,不收);
///   · 其余(浮条/HUD/未知工具包)           → 不收。
///
/// 两道**安全阀**(比"多收一个浮条"重要得多):
///   1. AX 没话说(读不到 AXWindows)→ **不过滤**;
///   2. 按上面的规则会把该 App 的窗**全部**剔掉 → **不过滤**(自定义工具包的 App 就靠这条活下来)。
enum AXWindowList {
    struct Admission {
        let admitted: Set<CGWindowID>
        /// wid → "为什么被剔"(subrole/main/title),写进日志便于复核
        let rejected: [CGWindowID: String]
    }

    /// 枚举路径的 AX 超时(2026-10-27)
    ///
    /// 病例(用户:「现在唤起面板有延迟」):最近 200 次唤起里 5 次 ~600ms,
    /// 全部是 `枚举 530–548ms` —— 正好撞上全局 AX 超时(0.5s):
    /// 某个 App 不响应 AX 时,枚举会一直等满 0.5s,而那一局又没有"陈旧名单"可先上屏 ⇒
    /// 面板就干等这半秒 ✗
    /// ⇒ 枚举这一路把超时压到 **0.15s**(拿不到 AX 时本来就有"不过滤"的降级,不影响正确性),
    ///   并把超过 50ms 的 pid 点名叫出来,下次直接知道是谁在拖 ✓
    /// ⚠️ 用户动作那一侧(`WindowFocuser`)仍用 0.5s,那里超时太短会误伤真实操作 ✗
    static let enumerationTimeout: Float = 0.15
    static var slowCalls: [(pid: pid_t, ms: Double)] = []

    /// nil = AX 没话说,调用方不许过滤
    static func admission(ofPID pid: pid_t) -> Admission? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, enumerationTimeout)
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > 50 {
                DiagnosticRingBuffer.shared.recordAXSlow(ms: ms)
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
                glog(String(format: "[AX] 慢 %.0fms pid=%d %@", ms, pid, name))
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }

        var admitted = Set<CGWindowID>()
        var rejected: [CGWindowID: String] = [:]
        for window in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { continue }
            // ★ 短路求值(2026-11-20 性能修复):常规窗口(`AXStandardWindow`)占 95%+,
            //   不再无条件拉取 main / title / modal 三次多余跨进程 AX IPC(5 次 → 2 次 IPC,语义完全等价 ✓)。
            let subrole = string(window, kAXSubroleAttribute)
            let standard = subrole == kAXStandardWindowSubrole
            var isMain = false
            var title: String?
            var dialogWithTitle = false
            if !standard {
                isMain = (bool(window, kAXMainAttribute) ?? false)
                if !isMain, subrole == kAXDialogSubrole {
                    let t = string(window, kAXTitleAttribute) ?? ""
                    title = t
                    if !t.isEmpty {
                        // ⚠️ 2026-09-17 收窄:模态对话框**不进面板**(保留非模态有标题 AXDialog,如 Ghostty)。
                        let modalValue = bool(window, kAXModalAttribute)
                        dialogWithTitle = !(modalValue ?? false)
                    }
                }
            }
            let kindOK = standard || isMain || dialogWithTitle
            // ⭐ 判据落在"**有没有关闭按钮**"上(2026-09-17,当日第三次才找对)。
            //   NSAlert 一类的确认框没有关闭按钮,真窗都有;仅在 kindOK 时查,未过类型门直接省掉这次 IPC ✓。
            var hasCloseButton = false
            if kindOK {
                var closeRef: CFTypeRef?
                hasCloseButton = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString,
                                                               &closeRef) == .success && closeRef != nil
            }
            if kindOK && hasCloseButton {
                admitted.insert(wid)
            } else {
                let t = title ?? (string(window, kAXTitleAttribute) ?? "")
                rejected[wid] = "subrole=\(subrole ?? "-") main=\(isMain) title=\"\(t)\""
            }
        }
        // 安全阀 1:一个都没认出来 = 这套 AX 读法对该 App 不适用,干脆不过滤
        guard !admitted.isEmpty else { return nil }
        // 安全阀 2:全部被判成"不该收"(既没认出来也没剔除记录)也算没话说
        guard rejected.isEmpty || admitted.count < windows.count else { return nil }
        return Admission(admitted: admitted, rejected: rejected)
    }

    /// 返回该进程在 AX 侧明确处于「已最小化（`kAXMinimized == true`）」的窗口 id 集合。
    /// 用来从非在屏 CGWindowList 里精准区分「最小化窗」与「其他 Space 的正常窗」，
    /// 绝不把别 Space 的窗误捞进当前屏。沿用 0.15s 枚举超时保护。
    static func minimizedWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, enumerationTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return [] }
        var out = Set<CGWindowID>()
        for window in windows {
            guard bool(window, kAXMinimizedAttribute) == true else { continue }
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
                out.insert(wid)
            }
        }
        return out
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

extension AXWindowList {
    /// **全局 AX 消息超时**(借鉴 AltTab:`AXUIElementSetMessagingTimeout(systemWide, 1)`,
    /// 事件监听那个 app 元素他们另外压到 0.25s)。
    ///
    /// 为什么必须有这一行:AX 调用是跨进程同步 IPC,**默认没有上限** —— 对方进程卡住
    /// (IDE 全量索引、Adobe、Electron 大窗)时,调用方会一直等。而我们的
    /// `WindowFocuser.axWindowElement`(每扇窗一次 `_AXUIElementGetWindow`)、
    /// `minimize/close/zoom` 全在**主线程**上跑 → 表现就是"点了要等一会",严重时整个面板假死。
    ///
    /// 取值:AltTab 是全局 1s / app 元素 0.25s。我们取 **0.5s** —— 因为我们的 AX 调用
    /// 几乎全是"用户动作的当场回应"(主线程),宁可早一点放弃(超时后各调用点都有静默降级),
    /// 也不要 UI 冻住;真需要长跑的枚举本来就在后台线程,不受这条影响。
    static func installGlobalMessagingTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }
}
