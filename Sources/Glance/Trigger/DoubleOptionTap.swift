import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GlanceCore

// MARK: - 双击 ⌥ 把指针送到下一块屏幕

/// 双击 ⌥ 把指针送到**下一块屏幕**（今天双屏场景 = 另一块屏，多屏自动循环 ✓）。
///
/// 为什么不是"注册一个热键"：⌘/⌃/⌥/⇧ 是**修饰键**，系统热键 API 只接受"修饰键 + 一个真实按键"，
/// 单独一个 ⌥ 注册不了。所以换一种做法：**监听事件流**，只看不改 ——
/// 两处监听都把事件**原样返回**（`return e`），一个字节都不吞，因此不可能影响 ⌥Tab、⌥⇧ 等任何既有操作。
///
/// 触发键史:曾是双击 ⌃(2026-09-15)—— 用户实测与 IDEA 的 ⌃ 系快捷键打架,2026-09-17 改 ⌥。
///
/// 要小心的不是"冲突"（双 ⌥ 不是 macOS 的系统快捷键 —— 按住 ⌥ 出音标选单那是"按住",
/// 只有一次 down,凑不出双击），而是**误触发**：
/// 一天要按几百次"⌥ + 别的键"。所以规则是 —— **两次干净的 ⌥ 之间只要夹了任何别的按键，立刻作废**。
/// 于是 ⌥ 组合键、⌥Tab(触发键自己也走 ⌥+键的路,被 dirty 拦住)永不误触发；只有"干干净净连按两下 ⌥"才动。
/// 最坏情况的代价也只是指针跳了一下，再双击一次就回来 —— 自纠正。
///
/// 放在这个文件里而不是新建文件：本工程的 pbxproj 用的是**显式文件引用**，
/// 新建 .swift 必须同时在四处登记（PBXBuildFile / PBXFileReference / group / Sources phase），
/// 漏一处就是 `cannot find 'X' in scope`。同一个 domain 的代码就近放，先避免这类机械风险。
final class DoubleOptionTap {
    /// 双击 ⌥:把"跳到下一块屏"整件事交给 **App 层**(见 `App/ScreenScopedSwitching.swift` ✓)
    var onJumpToNextDisplay: (() -> Void)?
    static let shared = DoubleOptionTap()
    private init() {}

    /// 设置项。**默认关**：macOS 本身没有这个功能，按"新开关一律默认对齐 macOS"的规则应为关。
    /// UserDefaults 直读 ⇒ 设置里一改立刻生效，不用重启（和 panel.sheen 等既有开关同一套约定）。
    /// key 随触发键换名(⌃→⌥),**不做旧值迁移**:功能默认关,丢一次开关状态无伤
    /// (先例:panel.puckRiseFromBottom → panel.slideFromLastApp 也是不迁移)。
    static let defaultsKey = Keys.pointerDoubleOptionJumps
    // ⚠️ 这里原来用 `bool(forKey:)`(没写过 ⇒ false,于是默认值写不成 true ✗)⇒
    //    与别处统一成 `object(forKey:) as? Bool ?? KeyDefaults.*` ✓
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? KeyDefaults.doubleOptionJumps
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCleanDown: CFAbsoluteTime?   // 上一次"干净地按下 ⌥"的时刻
    private var dirty = false                    // 这一轮按住 ⌥ 期间有没有夹别的键
    private var optionWasDown = false
    private static let minGap: Double = 0.06     // 太快 ⇒ 同一次按住的抖动，不算双击
    private static let maxGap: Double = 0.30     // 超过 ⇒ 不像"有意双击"（苹果 ~500ms 对修饰键太松）

    func start() {
        guard globalMonitor == nil else { return }   // 幂等：重复 start 不会挂两套监听
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e)
        }
        // 我们自己的窗口在最前时，全局监听**看不到**事件（macOS 的设计）⇒ 补一个本地监听。
        // 注意返回 e 而不是 nil：nil 会**吞掉**事件，那正是要绝对避免的事。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            dirty = true                       // 夹了别的按键 ⇒ 这一轮作废
        case .flagsChanged:
            // ⌘/⌃/⇧ 动过也算"夹了别的键"（fn / capsLock 常驻，不算；⌥ 自己是触发键，不算）
            if !e.modifierFlags.intersection([.command, .control, .shift]).isEmpty { dirty = true }
            let optionDown = e.modifierFlags.contains(.option)
            guard optionDown != optionWasDown else { return }   // 只认状态翻转
            optionWasDown = optionDown
            guard optionDown else { return }                     // 抬起：什么都不做
            let now = CFAbsoluteTimeGetCurrent()
            if let prev = lastCleanDown, now - prev >= Self.minGap, now - prev <= Self.maxGap, !dirty {
                lastCleanDown = nil
                dirty = false
                if enabled { jumpToNextDisplay() }
            } else {
                lastCleanDown = now
                dirty = false
            }
        default:
            break
        }
    }

    /// 移到下一块屏幕，**保持相对位置**（右屏 70% 高处 ⇒ 左屏 70% 高处），
    /// 而不是丢到角落 —— 指针像"平移"过去，这是体感的关键。
    /// ★ 2026-09-22:整段逻辑搬到 **App 层**(`DoubleOptionJump`)——
    ///   它要看清点(Inventory)又要落焦(Focus),放在 Trigger 里会**双向越界** ✗
    ///   (架构脚本报了很久,记在已知账上;现在按同一套"闭包钩子 + App 层装配"还掉 ✓)
    ///   这里只判"这一下该不该算一次跳屏"(拖拽途中不算 ✓),然后把话交给 App 层 ✓
    private func jumpToNextDisplay() {
        guard NSEvent.pressedMouseButtons == 0 else { return }   // 拖拽途中不动（别把拖拽目标搞乱）
        onJumpToNextDisplay?()
    }

}
