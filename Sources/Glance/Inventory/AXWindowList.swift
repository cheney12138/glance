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

    /// nil = AX 没话说,调用方不许过滤
    static func admission(ofPID pid: pid_t) -> Admission? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }

        var admitted = Set<CGWindowID>()
        var rejected: [CGWindowID: String] = [:]
        for window in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { continue }
            let subrole = string(window, kAXSubroleAttribute)
            let isMain = (bool(window, kAXMainAttribute) ?? false)
            let title = string(window, kAXTitleAttribute) ?? ""
            let standard = subrole == kAXStandardWindowSubrole
            let dialogWithTitle = subrole == kAXDialogSubrole && !title.isEmpty
            if standard || isMain || dialogWithTitle {
                admitted.insert(wid)
            } else {
                rejected[wid] = "subrole=\(subrole ?? "-") main=\(isMain) title=\"\(title)\""
            }
        }
        // 安全阀 1:一个都没认出来 = 这套 AX 读法对该 App 不适用,干脆不过滤
        guard !admitted.isEmpty else { return nil }
        // 安全阀 2:全部被判成"不该收"(既没认出来也没剔除记录)也算没话说
        guard rejected.isEmpty || admitted.count < windows.count else { return nil }
        return Admission(admitted: admitted, rejected: rejected)
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
