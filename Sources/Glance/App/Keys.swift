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
    /// `debug.cardSettleScale` —— 卡片"落位"的起始缩放(默认 0.94 = 6% 幅度)
    static let debugCardSettleScale = "debug.cardSettleScale"
    /// `debug.hideTray`
    static let debugHideTray = "debug.hideTray"
    /// `debug.hzProbe`
    static let debugHzProbe = "debug.hzProbe"
    /// `debug.noSegmentAnim`
    static let debugNoSegmentAnim = "debug.noSegmentAnim"
    /// `debug.pinPanelOnRelease`
    /// `debug.pinPanelOnRelease` —— **调试专用**(只随启动参数 `-debug.pinPanelOnRelease 1` 生效)。
    /// 设置里那一行「保持面板打开」用的是下面那条正式键 ✓(那是用户设置,不该是 debug 键 ✗)

    /// `debug.ringFlipDurationMs` —— 换环翻牌的**总时长**(毫秒;默认 180 = 与原来那段同长 ✓)
    /// 翻出去/翻进来各占一半(easeIn / easeOut)⇒ 两半读起来是一次动作 ✓ 0 = 不动效(当拍换)
    static let debugRingFlipDurationMs = "debug.ringFlipDurationMs"
    /// `panel.summonPop` —— 唤起时**整块渐入**(键名不改 ✓;2026-10-08 从"轻轻收一下"改成渐入:
    /// 用户「要 fade 吧……**没有任何的弹动**呢, 比之前的两段弹簧要好」✓)
    static let panelSummonPop = "panel.summonPop"
    /// `debug.summonPopMs` —— 渐入的**时长**(毫秒;默认 **120** ✓)
    /// ⚠️ 老键 `debug.summonPop`(起始倍率)与 `debug.summonPopBounce`(阻尼)**已作废** ——
    ///   渐入不动几何,那两个旋钮没有意义了(键常量一并删掉,别留"写了没用"的假旋钮 ✓)
    static let debugSummonPopMs = "debug.summonPopMs"
    /// `debug.summonRevealDelayMs` —— 快捷键超快切换时不加载/不上屏面板的阈值（毫秒；默认 **130**，设 0 = 按下立即上屏）
    static let debugSummonRevealDelayMs = "debug.summonRevealDelayMs"
    /// `debug.mainThreadWatchdog` —— 主线程看门狗(默认 **关** ✓):卡死时由**后台线程**写一行日志 ✓
    /// (2026-10-08 病例:那次卡死既没有崩溃报告、也没有 spin 报告,trace 又是块缓冲 ⇒
    ///  文件里最后一行可能比真实卡死时刻早几分钟 ✗ ⇒ 现场必须在**还活着**的时候记下来 ✓)
    static let debugMainThreadWatchdog = "debug.mainThreadWatchdog"
    /// 🔬 `debug.glassStyleLight` —— **临时**档位:浅色外观下玻璃用 `clear`(默认)还是 `regular`。
    /// 用户 2026-10-08 口径:「玻璃还是没有 macOS 原生自然, 背景是白色的时候可见性差一点」
    /// ⇒ 拿它做 A/B,量完就删(仓库规矩:验完的开关不留代码 ✓)
    static let debugGlassStyleLight = "debug.glassStyleLight"
    /// 玻璃纱的不透明度(浅色专用;0 = 不加 ✓)
    static let debugGlassVeilAlpha = "debug.glassVeilAlpha"
    /// 亮棱的强度(0 = 不画 ✓)。原生剖面:峰比内部 **+0.22** ✓
    static let debugGlassRimAlpha = "debug.glassRimAlpha"
    /// 入场轻弹的**风格**:off(瞬间到位)/ pop(横向收·不回弹)/ spring(横向收·带回弹)/ fade(不动几何,整块淡入)

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
    /// `debug.tapReattachIdleMin` —— 多指设备"久闲多久后自愈重挂"(分钟;默认 30,0 = 关)
    static let debugTapReattachIdleMin = "debug.tapReattachIdleMin"
    /// `debug.tapUndoDriftPt` —— 生效后"指针位移多少 pt 就撤销"(默认 40;设 0 = 关)
    static let debugTapUndoDriftPt = "debug.tapUndoDriftPt"
    /// `debug.staleListFirst` —— 用上一局的名单先上屏、枚举回来再刷新(默认 true;false = 回到等枚举)
    static let debugStaleListFirst = "debug.staleListFirst"
    /// 🔬 逐轮打印触点**几何账**(峰值速 / 抬手速 / 方向抖)—— 给"滑动尾巴 vs 点按"找新判据用 ✓
    /// 默认关:它每轮一行,是重型诊断 ✓(量完就关;见 TapRound.Snapshot 里"几何账"那段病例)
    static let debugTapGeometry = "debug.tapGeometry"
    /// `debug.moveOverflowRule` —— 送窗"塞不下"时切哪边(keepLeft 默认/center/keepRight)
    /// `debug.sheenGain` —— 指针光晕的强度倍率(默认 1.0;0.5 = 一半,1.5 = 更亮)
    static let debugSheenGain = "debug.sheenGain"
    /// `debug.puckBrightness` —— 选中图标底下那块托底的亮度倍率(浅色模式;默认 0.75,1 = 原样)
    static let debugPuckBrightness = "debug.puckBrightness"
    /// `debug.trayBottomBreath` —— 托盘内容底边与容器底之间那段**固定空气**(pt)。
    /// 2026-10-13 加:用户连提两次「间距太大」而这个数是我拍的(52) ⇒ 把它交给用户现场拧 ✓
    /// **不写这个键 = 用出厂默认**(见 `PanelMetrics.trayBottomBreath`),写了才以它为准 ✓
    static let debugTrayBottomBreath = "debug.trayBottomBreath"
    /// `debug.trayRingGap` —— **卡片芯片到环**那那段净距(pt)。2026-10-13 定稿的**唯一一个旋钮** ✓
    /// 它直接控托盘窗的 y(与阴影/比例无关 ⇒ **两块屏同一个 pt 值** ✓)
    /// 不写 = 用出厂默认 50 ✓
    static let debugTrayRingGap = "debug.trayRingGap"
    static let debugMoveOverflowRule = "debug.moveOverflowRule"
    /// 「送窗撑满门槛」的正式键(2026-09-25:debug 键只活了一天就按用户裁定提升为设置项 ✓)
    static let panelMoveFillMinRatio = "panel.moveFillMinRatio"
    /// `debug.trace`
    static let debugTrace = "debug.trace"

    // MARK: launch —— 启动环（未启动 App 名单）

    /// `launch.blacklist`
    static let launchBlacklist = "launch.blacklist"
    /// `launch.whitelist`
    static let launchWhitelist = "launch.whitelist"

    // MARK: ring —— 切换器主环(运行中的 App)

    /// `ring.blacklist` —— 切换器黑名单:在运行的 App 只要在这里,即使有窗也不进切换器。
    /// 与 `launch.blacklist`(未启动环)互相独立:一个管"没开的 App 展不展示",一个管"开着的 App 展不展示"。
    static let ringBlacklist = "ring.blacklist"

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
    /// `panel.slideFromLastApp`
    static let panelSlideFromLastApp = "panel.slideFromLastApp"
    /// `panel.tabEntersLaunchSection`
    static let panelTabEntersLaunchSection = "panel.tabEntersLaunchSection"
    /// `panel.windowLayout` —— 组内窗口的**呈现方式**(2026-10-25,ADR-0017):
    ///   · `row`  = **卡片行**(现行):每扇窗一张卡,多窗口时换行
    ///   · `rail` = **芯片轨道**(新):只有选中那扇窗有卡,其余窗口是一列芯片(ADR 全文见 docs/adr/0017)
    /// ★ 两套实现**完全隔离**(`PanelTrayWindow` 里二选一),互不影响 ✓
    static let panelWindowLayout = "panel.windowLayout"

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
    /// `switch.digitPicksApp`:数字键 1…9 直接跳到环上第 N 个 App(2026-11-12)
    static let switchDigitPicksApp = "switch.digitPicksApp"
    /// `switch.includeMinimized`:是否在本屏切换列表尾部收录已最小化的窗口（沿用遗照灰，选中单窗还原；默认关）
    static let switchIncludeMinimized = "switch.includeMinimized"
    /// `ring.autoQuitZombies`:「预览」等文档/查看型僵尸应用关光窗口并切走后自动安静退出
    static let ringAutoQuitZombies = "ring.autoQuitZombies"
    /// `ring.autoQuitZombieBundles`:可选追加的 0 窗自动退出 bundleID 列表
    static let ringAutoQuitZombieBundles = "ring.autoQuitZombieBundles"

    // MARK: trigger —— 触发键

    /// `trigger.keyCode`
    static let triggerKeyCode = "trigger.keyCode"
    /// `trigger.modifier`
    static let triggerModifier = "trigger.modifier"
    /// **跨屏送窗**的快捷键(默认 ⌘⇧M ⇒ 默认值住在 `GlanceCore.TriggerConfig.moveWindowDefault` ✓
    /// —— 与触发键同一套约定:Keys 只管键名,不抄默认值 ✗)
    static let moveWindowKeyCode = "moveWindow.keyCode"
    static let moveWindowModifier = "moveWindow.modifier"

    // MARK: app —— 引导与生命周期

    /// `app.onboardingCompleted` —— 首次 30 秒轻引导是否已完成（老用户启动时自动静默置 true）
    static let appOnboardingCompleted = "app.onboardingCompleted"

    // MARK: dock —— 原生 Dock 替代（ADR-0018）

    /// `dock.enabled` —— 是否启用 Glance 原生 Dock 替代（默认关，opt-in）
    static let dockEnabled = "dock.enabled"
    /// `dock.position` —— 贴边唤起位置（`bottom` / `left` / `right`）
    static let dockPosition = "dock.position"
    /// `dock.displayMode` —— 程序坞显示方式（`autoHide` 自动隐藏 / `alwaysOn` 常驻显示）。
    /// 常驻模式（方案 A：悬浮常驻 + 全屏自动避让）的**总开关**就这一个键 ✓
    static let dockDisplayMode = "dock.displayMode"
    /// `dock.dwellMs` —— 指针贴边驻留唤起阈值（毫秒；默认 100）
    static let dockDwellMs = "dock.dwellMs"
    /// `dock.iconSize` —— 程序坞图标目标尺寸（pt，范围 36…96，默认 56；独立于 ⌘Tab 的 120% 固定尺寸）
    static let dockIconSize = "dock.iconSize"
    /// `dock.previewScale` —— 程序坞窗口预览尺寸百分比（范围 80…150，默认 120，与 ⌘Tab 一致）
    static let dockPreviewScale = "dock.previewScale"
    /// `dock.centerTray` —— 程序坞窗口预览托盘是否始终居中（默认开；关闭后跟随悬停图标移动）
    static let dockCenterTray = "dock.centerTray"
    /// `dock.nativeSnapshot` —— 接管前备份的原生 `com.apple.dock` 偏好快照（JSON，不暴露在设置页）
    static let dockSavedSnapshot = "dock.nativeSnapshot"
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

    /// 「送窗撑满门槛」的**唯一读取点**(0–1;默认 0.5)。每次按快捷键现读 ⇒ 设置里拖完即生效 ✓
    static var moveFillMinRatio: Double {
        let v = (UserDefaults.standard.object(forKey: panelMoveFillMinRatio) as? NSNumber)?.doubleValue
        return min(max(v ?? KeyDefaults.moveFillMinRatio, 0), 100) / 100
    }

    /// 「数字键选 App」的**唯一读取点**(2026-11-12):触发层每颗数字键现读 ⇒ 设置里开关即生效 ✓
    /// 关 ⇒ 裸数字不再跳 App(⇧+数字选窗不受此开关管 —— 那是另一条独立的老功能 ✓)
    static var digitPicksApp: Bool {
        UserDefaults.standard.object(forKey: switchDigitPicksApp) as? Bool ?? KeyDefaults.digitPicksApp
    }

    static var includeMinimized: Bool {
        UserDefaults.standard.object(forKey: switchIncludeMinimized) as? Bool ?? KeyDefaults.includeMinimized
    }

    static var autoQuitZombies: Bool {
        UserDefaults.standard.object(forKey: ringAutoQuitZombies) as? Bool ?? KeyDefaults.autoQuitZombies
    }

    static let defaultZombieViewerBundleIDs: Set<String> = [
        "com.apple.Preview",
        "com.apple.QuickTimePlayerX",
        "com.apple.TextEdit",
    ]

    static var zombieViewerBundleIDs: Set<String> {
        let extra = UserDefaults.standard.stringArray(forKey: ringAutoQuitZombieBundles) ?? []
        return extra.isEmpty ? defaultZombieViewerBundleIDs : defaultZombieViewerBundleIDs.union(extra)
    }

    static var onboardingCompleted: Bool {
        UserDefaults.standard.object(forKey: appOnboardingCompleted) as? Bool ?? KeyDefaults.onboardingCompleted
    }

    static var isDockEnabled: Bool {
        UserDefaults.standard.object(forKey: dockEnabled) as? Bool ?? KeyDefaults.dockEnabled
    }

    static var currentDockPosition: DockPosition {
        let raw = UserDefaults.standard.string(forKey: dockPosition) ?? KeyDefaults.dockPosition
        return DockPosition(rawValue: raw) ?? .bottom
    }

    /// 程序坞显示方式的**唯一读取点**。没写过 / 写成垃圾值都回退 `.autoHide`
    /// （常驻模式是新能力，读不到就必须等价于老行为 ✓）
    static var currentDockDisplayMode: DockDisplayMode {
        let raw = UserDefaults.standard.string(forKey: dockDisplayMode) ?? KeyDefaults.dockDisplayMode
        return DockDisplayMode(rawValue: raw) ?? .autoHide
    }

    /// 常驻模式是否开启（调用点可读性用：比每次比较枚举干净）
    static var isDockAlwaysOn: Bool { currentDockDisplayMode == .alwaysOn }

    static var dockDwellMsValue: Int {
        let v = (UserDefaults.standard.object(forKey: dockDwellMs) as? NSNumber)?.intValue
        return max(0, v ?? KeyDefaults.dockDwellMs)
    }

    static var dockDwellSeconds: Double {
        Double(dockDwellMsValue) / 1000.0
    }

    /// 程序坞图标尺寸（pt，夹紧在 36…96，默认 56）
    static var dockIconSizePt: CGFloat {
        let v = (UserDefaults.standard.object(forKey: dockIconSize) as? NSNumber)?.doubleValue
        return CGFloat(min(max(v ?? KeyDefaults.dockIconSize, 36), 96))
    }

    /// 程序坞预览窗口倍率（0.80…1.50，默认 1.20，独立于图标尺寸）
    static var dockPreviewScaleRatio: CGFloat {
        let v = (UserDefaults.standard.object(forKey: dockPreviewScale) as? NSNumber)?.doubleValue
        return CGFloat(min(max(v ?? KeyDefaults.dockPreviewScale, 80), 150)) / 100.0
    }

    /// 程序坞预览卡片是否始终相对程序坞居中（默认开）
    static var isDockTrayCentered: Bool {
        UserDefaults.standard.object(forKey: dockCenterTray) as? Bool ?? KeyDefaults.dockCenterTray
    }

    /// 老用户免打扰迁移：若从未写过 `app.onboardingCompleted`，但已存在历史运行配置键，
    /// 直接静默标为已完成，避免升级后打扰老用户。
    static func migrateOnboardingForLegacyUserIfNeeded() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: appOnboardingCompleted) == nil else { return }
        let legacySignals = [
            "ring.lastScreenByBundle",
            triggerKeyCode,
            panelAppearance,
            panelWindowLayout,
            launchBlacklist,
            ringBlacklist,
        ]
        if legacySignals.contains(where: { ud.object(forKey: $0) != nil }) {
            ud.set(true, forKey: appOnboardingCompleted)
        }
    }
}

extension Notification.Name {
    /// 面板成功唤起一次时发出，用于引导第 1 步实时打勾（不耦合 PanelController 类型）。
    static let glancePanelDidSummon = Notification.Name("com.cheney12138.glance.panelDidSummon")
}

/// 组内窗口的呈现方式(键名见 `Keys.panelWindowLayout`)
enum WindowLayout: String, CaseIterable {
    /// 卡片行:每扇窗一张卡(现行)
    case row
    /// 芯片轨道:一张卡 + 右侧一列芯片(ADR-0017)
    case rail

    var label: String {
        switch self {
        case .row:  return "卡片行"
        case .rail: return "芯片轨道"
        }
    }

    static var current: WindowLayout {
        WindowLayout(rawValue: UserDefaults.standard.string(forKey: Keys.panelWindowLayout) ?? "")
            ?? .row
    }
}

enum KeyDefaults {
    /// 高光效果。**开**:首次打开就显得讲究 ✓(视觉打磨,不是功能开关)
    static let sheen = true
    static let summonPop = true
    /// Tab 进入未启动区。**开**(原判):关闭后 Tab 两个方向都不跨段,进出口交给 ↓/↑ ✓
    static let tabEntersLaunchSection = true
    /// 组内窗口呈现方式。**row**(现行)为出厂默认 —— 新方案还没经过实机验收,
    /// 不许默默改掉老用户看到的样子 ✓(验收通过再翻默认值,那是另一次提交)
    static let windowLayout = WindowLayout.row.rawValue
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
    /// 数字键 1…9 直接跳到环上第 N 个 App(⇧+数字仍是选第 N 扇窗 ✓)。**开**(2026-11-12):
    /// 真正的"让用户知道有这功能"靠设置面板这一行说明文字 ✓ —— 面板上**不画角标**(用户裁定:
    /// 角标很丑 ✗;位置语义与 Tab 顺序天然一致,无需号码提示)
    static let digitPicksApp = true
    /// 在本屏切换列表尾部收录已最小化窗口（默认关，零额外枚举开销）
    static let includeMinimized = false
    /// 关光全部窗口并切走后自动安静退出僵尸查看器（默认开：预览 / QuickTime / 文本编辑）
    static let autoQuitZombies = true
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
    /// 送窗撑满门槛(窗口面积占源屏可见区的百分数)。**50**(2026-09-25 用户口径:
    /// "超过 1/2 原显示器占比的才全屏" ✓;0 = 一律撑满,100 = 一律保持原尺寸)
    static let moveFillMinRatio: Double = 50
    /// 接管系统 ⌘Tab / ⌘`。**关**:抢系统快捷键必须先问(ADR-0005)⇒ 出厂不许默认抢 ✓
    static let takeoverSystemSwitcher = false
    /// ⌘` —— **开**(2026-10-27 用户裁定:把它改成"唤起只有窗口的一局",不再保留系统那条)。
    /// 语义:按 ⌘` ⇒ 托盘/芯片轨道出现(没有环)、默认先切一扇;松手才真正切窗;
    ///       Esc / 点空白 = 放弃。⇧⌘` 反向。
    static let takeoverGraveCyclesWindows = true
    /// 首次 30 秒轻引导默认未完成（老用户会在启动迁移中自动标 true）
    static let onboardingCompleted = false
    /// 原生 Dock 替代（默认关，opt-in，见 ADR-0018）
    static let dockEnabled = false
    /// Dock 停靠位置（`bottom` / `left` / `right`）
    static let dockPosition = "bottom"
    /// 程序坞默认**自动隐藏** —— 老行为（100% 兼容已装机用户：这个键没写过就还是老样子 ✓）
    static let dockDisplayMode = DockDisplayMode.autoHide.rawValue
    /// 指针贴边驻留唤起阈值（毫秒）
    static let dockDwellMs = 100
    /// 程序坞图标默认尺寸（pt；作为屏幕边缘栏位比 ⌘Tab 紧凑）
    static let dockIconSize: Double = 56
    /// 程序坞预览窗口默认尺寸（百分比；120% 与 ⌘Tab 对齐，确保实时预览清晰可见）
    static let dockPreviewScale: Double = 120
    /// 程序坞预览卡片默认始终居中（与 ⌘Tab 一致）
    static let dockCenterTray = true
}
