import Foundation
import GlanceCore

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

    /// `debug.autoOpenSettings`
    static let debugAutoOpenSettings = "debug.autoOpenSettings"
    /// `debug.axprobePid`
    static let debugAxprobePid = "debug.axprobePid"
    /// `debug.entranceMotion` —— **入场弹簧可试档位**(`fast`/`smooth`/`slow`/`snappy`)。
    /// 2026-09-22 用户问「app 上浮的帧率不够流畅, 有没有参数可调」时加。
    /// 为什么先做成调试键:这是"手感档位"(本仓规矩:手感参数要**能试** ✓),
    /// 定下来之后再决定要不要进设置面板(那时是一个**产品决定** ✓)。
    /// ★ 它在**用动画的那一刻**读 ⇒ 改完**不用重启**,下一次唤起就生效 ✓
    static let debugEntranceMotion = "debug.entranceMotion"
    /// `debug.dumpSources`
    static let debugDumpSources = "debug.dumpSources"
    /// `debug.hideTray`
    static let debugHideTray = "debug.hideTray"
    /// `debug.hzProbe`
    static let debugHzProbe = "debug.hzProbe"
    /// `debug.noSegmentAnim`
    static let debugNoSegmentAnim = "debug.noSegmentAnim"
    /// `debug.pinPanelOnRelease`
    /// `debug.pinPanelOnRelease` —— **调试专用**(只随启动参数 `-debug.pinPanelOnRelease 1` 生效)。
    /// 设置里那一行「保持面板打开」用的是下面那条正式键 ✓(那是用户设置,不该是 debug 键 ✗)
    static let debugPinPanelOnRelease = "debug.pinPanelOnRelease"
    /// 「保持面板打开」的正式键(2026-09-22 从 `debug.pinPanelOnRelease` 提升而来:
    /// 那一行在设置里摆了很多版本,却因为 App 每次启动都清掉这个 debug 键 ⇒ **永远存不住** ✗)
    static let panelPinOnRelease = "panel.pinOnRelease"
    static let debugScreenProbe = "debug.screenProbe"
    /// `debug.sweepDelayMs` —— 关面板预拍的**推迟毫秒**(默认 500)
    /// 见 `DebugFlags.sweepDelayMs` 的病例 ✓(2026-09-22 掉帧:15 窗预拍与入场抢 GPU ✗)
    static let debugSweepDelayMs = "debug.sweepDelayMs"
    /// `debug.tapMinDurationMs` —— 三/四指点按的**时长下限**(默认 30)
    /// 见 `DebugFlags.tapMinDurationMs` 的病例(2026-09-22 三指误触 ✓)
    static let debugTapMinDurationMs = "debug.tapMinDurationMs"
    /// `debug.tapMinContactSize` —— 点按的**触点重量下限**(默认 0.6;设 0 = 关)
    static let debugTapMinContactSize = "debug.tapMinContactSize"
    /// `debug.tapMaxMoveNorm` —— 三指判卷的位移上限(归一化;默认取领域层,越大越宽容)
    static let debugTapMaxMoveNorm = "debug.tapMaxMoveNorm"
    /// `debug.tapMaxMajor` —— 三指判卷的触点主轴上界(默认取领域层 14;掌心误触多就调小)
    static let debugTapMaxMajor = "debug.tapMaxMajor"
    /// `debug.tapUndoDriftPt` —— 生效后"指针位移多少 pt 就撤销"(默认 40;设 0 = 关)
    static let debugTapUndoDriftPt = "debug.tapUndoDriftPt"
    /// `debug.staleListFirst` —— 用上一局的名单先上屏、枚举回来再刷新(默认 true;false = 回到等枚举)
    static let debugStaleListFirst = "debug.staleListFirst"
    /// `debug.moveOverflowRule` —— 送窗"塞不下"时切哪边(keepLeft 默认/center/keepRight)
    /// `debug.sheenGain` —— 指针光晕的强度倍率(默认 1.0;0.5 = 一半,1.5 = 更亮)
    static let debugSheenGain = "debug.sheenGain"
    /// `debug.puckBrightness` —— 选中图标底下那块托底的亮度倍率(浅色模式;默认 0.75,1 = 原样)
    static let debugPuckBrightness = "debug.puckBrightness"
    /// `debug.trayEntryFadeMs` —— 托盘入场淡入时长(默认 120ms;0 = 回到"硬出现"的旧行为)
    static let debugTrayEntryFadeMs = "debug.trayEntryFadeMs"
    static let debugMoveOverflowRule = "debug.moveOverflowRule"
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
    /// 悬停触感(2026-09-22 用户要求「hover 震动,app 和预览容器都需要, 做成设置开关」)
    /// ⚠️ 键名**来源在 GlanceCore.HapticPolicy.defaultsKey** —— 那里读、这里显示,一个源 ✓
    static let hapticEnabled = HapticPolicy.defaultsKey
    /// 触感强度档("light"/"medium"/"strong";键名来源同样在 GlanceCore ✓)
    static let hapticStrength = HapticPolicy.strengthKey
    /// 接管系统 ⌘`(与 `trigger.takeoverSystemSwitcher` 同族:都是"接管一条系统快捷键")
    static let triggerTakeoverGraveCyclesWindows = "trigger.takeoverGraveCyclesWindows"

    /// `switch.scrollMovesSelection`
    static let switchScrollMovesSelection = "switch.scrollMovesSelection"

    // MARK: trigger —— 触发键

    /// `trigger.keyCode`
    static let triggerKeyCode = "trigger.keyCode"
    /// `trigger.modifier`
    static let triggerModifier = "trigger.modifier"
    /// **跨屏送窗**的快捷键(默认 ⌘⇧M ⇒ 默认值住在 `GlanceCore.TriggerConfig.moveWindowDefault` ✓
    /// —— 与触发键同一套约定:Keys 只管键名,不抄默认值 ✗)
    static let moveWindowKeyCode = "moveWindow.keyCode"
    static let moveWindowModifier = "moveWindow.modifier"

}

/// **出厂默认值的唯一来源**(2026-09-22 立)。
///
/// 为什么单独立一处:这些键原先的默认值散在**每个读取点**里 ——
/// 设置面板的 `@AppStorage(...) = false` 一份 ✗、拥有者类型里的 `?? false` 又一份 ✗
/// ⇒ 改默认值时漏改一处,就会出现「设置里显示开着、实际不生效」这种最难查的错 ✗。
/// 现在:**键名在 `Keys`,默认值在这里**,两边都引同一处 ✓
///
/// ⚠️ 改这里只影响"从没写过这个键的人"(全新安装 ✓)——
///    已有用户的值一律不动(`object(forKey:) ?? 默认` 的语义 ✓)
extension Keys {
    /// 「保持面板打开」的**唯一读取点**(2026-09-22 病例:触发层读新键、面板层读**旧调试键** ✗
    /// ⇒ 菜单里那个勾**只管一半** —— 用户点了"保持面板打开",面板外点击照样把它关掉 ✗)。
    /// 启动参数 `-debug.pinPanelOnRelease 1` 是自动化测试的老路,仍然优先 ✓
    static var pinOnRelease: Bool {
        if ProcessInfo.processInfo.arguments.contains("-debug.pinPanelOnRelease") { return true }
        return UserDefaults.standard.object(forKey: panelPinOnRelease) as? Bool ?? KeyDefaults.pinOnRelease
    }
}

enum KeyDefaults {
    /// 高光效果。**开**:首次打开就显得讲究 ✓(视觉打磨,不是功能开关)
    static let sheen = true
    /// 展示 Dock 常驻应用。**开**:未启动的 App 也能在环尾找到 ✓
    static let showLaunchables = true
    /// Tab 进入未启动区。**开**(原判):关闭后 Tab 两个方向都不跨段,进出口交给 ↓/↑ ✓
    static let tabEntersLaunchSection = true
    /// 面板里滚动/双指滑动换选中。**开**(原判)
    static let scrollMovesSelection = true
    /// 唤起即切换(与系统 ⌘Tab 行为对齐)。**开**(原判)
    static let advanceOnOpen = true
    /// 三指点按唤起面板。**开**(2026-09-22 用户裁定):这是本 App 的头号入口,
    /// 藏起来等于不存在 —— 新用户根本发现不了手势这条路 ✓(误触风险已由位移判据/落齐计时/截图让权兜住)
    static let threeFingerTapPanel = true
    /// 四指点按进未启动环。**开**:与三指同族(手势是一套语言),只开一个会让人以为四指不能用 ✓
    static let fourFingerTapLaunchRing = true
    /// 会话内 `` ` `` 循环当前 App 的窗口。**开**:不开就永远不知道面板里能按 ` ✓(面板外不生效 ⇒ 无副作用)
    static let graveCyclesWindows = true
    /// 双击 ⌥ 把指针(和键盘焦点)送到另一块屏。**开**:多屏用户的高频痛点 ✓(双击误触概率低)
    static let doubleOptionJumps = true
    /// 悬浮触感。**开**:唯一保留的触感,回答"我到底换到下一格了吗" ✓(强度另有一档设置)
    static let haptic = true
    /// 强制完整动效。**关**(2026-09-22 改):它真正的含义是"**无视**系统的『减弱动态效果』" ⇒
    /// 无障碍上不该默认替用户做主 ✓(想要永远带动效的人自己开 ✓)
    static let alwaysAnimate = false
    /// 从上一局那一格横滑过来。**关**(保持原判):落点差得远时要横穿整条,视觉很累 ✓
    /// (它不是"记住你上次选了谁",是入场的一层额外动效 —— 见 `MotionPolicy.slideFromLastApp`)
    static let slideFromLastApp = false
    /// 保持面板打开(松手不关)。**关**:钉住是高级玩法 ✓
    static let pinOnRelease = false
    /// 接管系统 ⌘Tab / ⌘`。**关**:抢系统快捷键必须先问(ADR-0005)⇒ 出厂不许默认抢 ✓
    static let takeoverSystemSwitcher = false
    static let takeoverGraveCyclesWindows = false
}
