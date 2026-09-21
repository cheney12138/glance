import Foundation

/// ★ 全部“可配置入口”的键名（唯一来源）。
///
/// 为什么要有这个文件：改前 **29 个键**以字面量散在 12 个文件、共 **50 处**调用点。
/// 后果是很具体的：
///   · 键名打错一个字符 ⇒ 编译通过、运行不报错、开关**静默失效**，
///     排查时只会觉得“设置了没用”（历史上 `debug.*` 家族就踩过这种坑）；
///   · 想知道“现在一共有多少可调项 / 哪些已经没人读了”必须全仓库 grep；
///   · 想改一个键名，得同时改十几处，且没有任何东西会提醒你漏了一处。
///
/// 纪律：**键名字符串一个字都不改**（用户已有配置不能丢）。这里只做“起名 + 归位”。
///
/// `UserDefaults` 的一个坑（记在这里，别再猜）：`bool(forKey:)` 对“没写过”和
/// “写成 false”都返回 `false`，两者**无法区分**。需要区分时用
/// `UserDefaults.standard.object(forKey: K) == nil`（`nil` 才是“没写过”）。
enum Keys {

    // MARK: debug —— 调试开关（重诊断一律默认关）

    /// `debug.noStripShadow`
    static let debugNoStripShadow = "debug.noStripShadow"
    /// `debug.autoOpenSettings`
    static let debugAutoOpenSettings = "debug.autoOpenSettings"
    /// `debug.axprobePid`
    static let debugAxprobePid = "debug.axprobePid"
    /// `debug.dumpSources`
    static let debugDumpSources = "debug.dumpSources"
    /// `debug.hideTray`
    static let debugHideTray = "debug.hideTray"
    /// `debug.hzProbe`
    static let debugHzProbe = "debug.hzProbe"
    /// `debug.noSegmentAnim`
    static let debugNoSegmentAnim = "debug.noSegmentAnim"
    /// `debug.pinPanelOnRelease`
    static let debugPinPanelOnRelease = "debug.pinPanelOnRelease"
    /// `debug.screenProbe`
    static let debugScreenProbe = "debug.screenProbe"
    /// `debug.trace`
    static let debugTrace = "debug.trace"

    // MARK: launch —— 启动环（未启动 App 名单）

    /// `launch.blacklist`
    static let launchBlacklist = "launch.blacklist"
    /// `launch.whitelist`
    static let launchWhitelist = "launch.whitelist"

    // MARK: live —— 实时预览

    /// `live.previewTier`
    static let livePreviewTier = "live.previewTier"

    // MARK: motion —— 动效

    /// `motion.alwaysAnimate`
    static let motionAlwaysAnimate = "motion.alwaysAnimate"

    // MARK: panel —— 长条 / 面板外观

    /// `panel.appearance`
    static let panelAppearance = "panel.appearance"
    /// `panel.iconClearance`
    static let panelIconClearance = "panel.iconClearance"
    /// `panel.scrollSpeed`
    static let panelScrollSpeed = "panel.scrollSpeed"
    /// `panel.sheen`
    static let panelSheen = "panel.sheen"
    /// `panel.showLaunchables`
    static let panelShowLaunchables = "panel.showLaunchables"
    /// `panel.slideFromLastApp`
    static let panelSlideFromLastApp = "panel.slideFromLastApp"
    /// `panel.tabEntersLaunchSection`
    static let panelTabEntersLaunchSection = "panel.tabEntersLaunchSection"

    // MARK: pointer —— 指针手势

    /// `pointer.doubleOptionJumps`
    static let pointerDoubleOptionJumps = "pointer.doubleOptionJumps"
    /// `pointer.fourFingerTapLaunchRing`
    static let pointerFourFingerTapLaunchRing = "pointer.fourFingerTapLaunchRing"
    /// `pointer.threeFingerTapPanel`
    static let pointerThreeFingerTapPanel = "pointer.threeFingerTapPanel"

    // MARK: switch —— 切换行为

    /// `switch.advanceOnOpen`
    static let switchAdvanceOnOpen = "switch.advanceOnOpen"
    /// `switch.captureApps`
    static let switchCaptureApps = "switch.captureApps"
    /// `switch.graveCyclesWindows`
    static let switchGraveCyclesWindows = "switch.graveCyclesWindows"
    /// `switch.scrollMovesSelection`
    static let switchScrollMovesSelection = "switch.scrollMovesSelection"

    // MARK: trigger —— 触发键

    /// `trigger.keyCode`
    static let triggerKeyCode = "trigger.keyCode"
    /// `trigger.modifier`
    static let triggerModifier = "trigger.modifier"

}
