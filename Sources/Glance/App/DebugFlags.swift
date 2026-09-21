import Foundation

/// ★ 全部调试/诊断开关的**唯一入口**。
///
/// 为什么要有这个文件（不只是"好看"）：
///   1. **知道现在开着什么** —— 改前这些开关以 `UserDefaults.standard.bool(forKey: …)`
///      散在 8 个文件里，想知道"现在还有哪些诊断在跑"只能全仓库 grep；
///   2. **默认必须是关的** —— 2026-09-21 抓到过一次严重误诊：上屏像素探针
///      (`screenProbe`) 一开就自己产出 **70–190ms 长帧**，我们量到的"卡顿"其实是
///      **量具自己**（"量具不得改变被测物"）。重诊断必须**有独立开关 + 默认关**，
///      而且要在同一处写清它有多重；
///   3. 常态日志的预算：**每次调用 ≤ 2 行**；凡是 per-frame / ±pixel / per-keystroke
///      的量都要靠 `trace` 门禁（`[悬停拍]`、`[卡变]` 这一族就是）。
///
/// 用法：`defaults write com.cheney12138.macswitcher debug.trace -bool true`
/// （键名见 `Keys`；**键名不改**）。
enum DebugFlags {

    // MARK: 常态量尺（便宜，可长开）

    /// 总门禁：打开后才有常态量尺（`[直播]`/`[帧]`/`[悬停拍]`/`[对位]`/`[屏]` …）。
    /// 关掉时这些量尺**一行都不打** —— 日志零噪声。
    static var trace: Bool { UserDefaults.standard.bool(forKey: Keys.debugTrace) }

    // MARK: 重型诊断（默认关，且会在数值上影响被测物 —— 用前先读注释）

    /// ⚠️ **重型，会改变被测物**：上屏像素探针（逐帧读回屏幕上真实像素来验证"画面有没有上去"）。
    /// 实测它一开就产出 **70–190ms 的长帧** ⇒ 量到的"卡顿"是**它自己**（2026-09-21 误诊事故）。
    /// 只在需要确认"像素到底有没有上屏"时短开。
    static var screenProbe: Bool { UserDefaults.standard.bool(forKey: Keys.debugScreenProbe) }

    /// 把窗口来源（AX / CG / 快照）导成图到桌面，用来核对"这张卡取的是哪扇窗"。
    static var dumpSources: Bool { UserDefaults.standard.bool(forKey: Keys.debugDumpSources) }

    /// 120Hz A/B 诊断（内建 XDR 屏上"我们只有 60 拍、独立 App 能拿 120"那桩悬案）。
    static var hzProbe: Bool { UserDefaults.standard.bool(forKey: Keys.debugHzProbe) }

    // MARK: 交互/状态类实验开关（会改变行为，只在排查时开）

    /// 按住触发键期间**钉住面板不消失**（用来从容地看中间态）。
    static var pinPanelOnRelease: Bool { UserDefaults.standard.bool(forKey: Keys.debugPinPanelOnRelease) }

    /// 无论是否隐藏托盘（排查"托盘没被收走"这类收场问题时用）。
    static var hideTray: Bool { UserDefaults.standard.bool(forKey: Keys.debugHideTray) }

    /// 关掉换组时的分段动效（用来确认某个抖动是不是动效造成的）。
    static var noSegmentAnim: Bool { UserDefaults.standard.bool(forKey: Keys.debugNoSegmentAnim) }

    // MARK: 启动期一次性开关

    /// 启动后直接打开设置面板（改设置时省去手点）。
    static var autoOpenSettings: Bool { UserDefaults.standard.bool(forKey: Keys.debugAutoOpenSettings) }

    /// 把 AX 探针限定到某个 pid（值为 pid 字符串；空 = 不限）。用于定位"某 App 的窗口列不出来"。
    static var axprobePid: String? { UserDefaults.standard.string(forKey: Keys.debugAxprobePid) }
}
