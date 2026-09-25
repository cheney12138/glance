import Foundation
import GlanceCore   // `tapUndoPolicy` 要拼领域层的 `TapUndoPolicy`(判据只在那边 ✓)

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
    /// ⚠️ 2026-09-22:「保持面板打开」已提升为**用户设置**(`Keys.panelPinOnRelease`)⇒
    /// 它不再是调试开关,也不该出现在"重型开关自报"名单里 ✓ 这里保留只为兼容启动参数那条老路
    static var pinPanelOnRelease: Bool { UserDefaults.standard.bool(forKey: Keys.debugPinPanelOnRelease) }

    /// 无论是否隐藏托盘（排查"托盘没被收走"这类收场问题时用）。
    static var hideTray: Bool { UserDefaults.standard.bool(forKey: Keys.debugHideTray) }

    /// **关面板预拍推迟多少毫秒**(默认 500)。
    ///
    /// 病例(2026-09-22 用户「体感上有掉帧, 抓下日志」):那次 `max 652ms` 的长帧,与
    /// 「关面板预拍:15 窗」和 0.13s 后紧接着的**唤起入场**完全同段 ✓
    /// ⇒ 一次拍 15 扇窗(实打实 GPU 活)与入场抢资源 ✗ —— 仓库自己早写过这句
    /// (见 `invalidateAll` 的注释 ✓),只是这条路一直没让开 ✓
    /// 做成**可试档位**:推迟多少才够要在真机上找 ⇒ `defaults write` 一个数就能 A/B ✓
    /// (设 0 = 恢复旧行为 ✓;能区分"没写过"与"写成 0" ✓)
    static var sweepDelayMs: Int {
        (UserDefaults.standard.object(forKey: Keys.debugSweepDelayMs) as? Int) ?? 500
    }

    /// **三/四指点按的时长下限**(毫秒,默认 30 = 原行为)。
    ///
    /// 病例(2026-09-22 用户「就在回复的时候, 三指误触又出现了」):日志里那次是
    /// `三指 60ms[state 4] 位移 norm=0.0018 abs=0.3 → 唤起` ✓ —— 位移几乎为零、时长 60ms,
    /// 在 30ms 下限的口径里**它就是**一记标准点按 ⇒ 判卷没写错 ✗
    /// 要治的是"这种形状也可能是无意的一搭"(手指掠过触控板 ✓)⇒ 只能由用户在真机上定
    /// "还认得出有意轻点"的下限 ⇒ 做成可试档位 ✓
    /// ⚠️ 代价说清楚:抬下限 ⇒ **更快的轻点也会被挡** ✓ 所以它不是默认值 ✓
    static var tapMinDurationMs: Int {
        (UserDefaults.standard.object(forKey: Keys.debugTapMinDurationMs) as? Int) ?? 30
    }

    /// **触点的重量下限**(默认 0.6;设 0 = 关掉这条门 ✓)。
    ///
    /// 病例(2026-09-22 用户「误触了, 我可以抬起的很轻很慢, 就会稳定出现」):很轻地搭上再慢慢抬,
    /// 触控板报出的 size 一路变小(0.4–0.5,日志里最轻的一档),触点随后在系统层面消失
    /// ⇒ 我们读到"全部离手"就判卷 ⇒ 误触 ✓
    /// ⚠️ 0.6 是**初步值**:有意轻点的 size 分布还没有样本(日志里只有这两次误触 ✓)
    ///    ⇒ 真机 A/B:`defaults write … -float 0.6` / `-float 0.4` / `-int 0` ✓
    static var tapMinContactSize: Float {
        // ⚠️ 出厂默认值**只有一处** = `TapRound.Policy.standard.minContactSize`(领域层 ✓)
        //   这里原来写死 0.6 ⇒ 改领域层默认值时这里会悄悄跟不上 ✗(把一件事实写成两份)
        (UserDefaults.standard.object(forKey: Keys.debugTapMinContactSize) as? NSNumber)?.floatValue
            ?? TapRound.Policy.standard.minContactSize
    }

    /// 关掉换组时的分段动效（用来确认某个抖动是不是动效造成的）。
    static var noSegmentAnim: Bool { UserDefaults.standard.bool(forKey: Keys.debugNoSegmentAnim) }

    // MARK: 启动期一次性开关

    /// 启动后直接打开设置面板（改设置时省去手点）。
    static var autoOpenSettings: Bool { UserDefaults.standard.bool(forKey: Keys.debugAutoOpenSettings) }

    /// 把 AX 探针限定到某个 pid（值为 pid 字符串；空 = 不限）。用于定位"某 App 的窗口列不出来"。
    static var axprobePid: String? { UserDefaults.standard.string(forKey: Keys.debugAxprobePid) }

    // MARK: 开机自报：**重型开关不允许静默开着**

    /// 每个重型开关的"代价"一句话（与实测数字挂钩）。
    ///
    /// 为什么要有这张表（2026-09-21 第二次事故）：`dumpSources` 被上轮实验留在 ON 上，
    /// 之后每次 hover 都在往磁盘写 1–2 张 PNG ⇒ 用户“又发现掉帧了”，
    /// 而我们量到的长帧里，**有一部分是量具自己造成的**（max 45.4ms → 关掉后 28–37ms）。
    /// 上一个同族事故是 `screenProbe`（一开就产出 **70–190ms** 长帧，量到的“卡顿”其实是它）。
    /// ⇒ 教训：**重型开关必须醒着** ⇒ 开机就把它报出来，并把代价写在报的那一行里。
    static let heavySwitches: [(name: String, isOn: Bool, cost: String)] = [
        ("debug.screenProbe", screenProbe, "逐帧读回屏幕像素；**本身就是 70–190ms 的长帧**（量具会改变被测物）"),
        ("debug.dumpSources", dumpSources, "每次 hover 往磁盘写 1–2 张 PNG；实测 max 帧 45.4ms → 关掉后 28–37ms"),
        ("debug.hzProbe", hzProbe, "另开一扇临时窗口做 120Hz A/B；会遮挡屏幕左下角"),
        ("debug.hideTray", hideTray, "不显示托盘 ⇒ **改变观感**"),
        ("debug.noSegmentAnim", noSegmentAnim, "关掉换组分段动效 ⇒ **改变观感**"),
        ("debug.autoOpenSettings", autoOpenSettings, "启动即弹设置窗"),
    ]

    /// 启动时叫一次（`GlanceApp.init`）：有重型开关开着就大声报出来。
    /// 常态（全关）下**一行都不打** ⇒ 不影响日志预算。
    /// **生效后"指针位移多少 pt 就撤销"**(默认 40pt;设 0 = 关掉这条)。
    ///
    /// 病例(2026-09-23 用户「又复现误触了」):判卷那一拍样样合规(150ms / 位移 0.3 / size 1.4),
    /// 指针却在 +220ms 后动了 152pt,而系统把拖拽事件拖到 +1.2s 才交出来 ✗
    /// ⇒ 这条把撤销从"等拖拽事件"提前到 **250ms 那一拍** ✓
    /// ⚠️ 只在 **手指还在板上** 时才撤(hover 选 App 时手已离板 ⇒ 不撤)—— 判据见 `TapUndoPolicy` ✓
    static var tapUndoDriftPt: Double {
        (UserDefaults.standard.object(forKey: Keys.debugTapUndoDriftPt) as? NSNumber)?.doubleValue ?? 40
    }

    /// **陈旧名单先上屏**(默认 true):唤起不等枚举,先用上一局的名单把面板画出来,
    /// 枚举回来走现成的刷新路径(`applyRefreshed`)✓ —— 门槛在 `GlanceCore.StaleListPolicy` ✓
    ///
    /// 账(2026-09-24):`[打卡] 唤起 共 85.9ms | 枚举 44.8 · …` ⇒ 枚举占一多半,
    /// 而且它**挡在面板出现之前** ⇒ 入口那两根弹簧的头 3 帧被等掉 ✗
    /// 关掉它(`-bool false`)就是旧行为,用来 A/B ✓
    static var staleListFirst: Bool {
        (UserDefaults.standard.object(forKey: Keys.debugStaleListFirst) as? Bool) ?? true
    }

    /// **三指判卷的位移上限**(归一化;默认取领域层)。
    /// 2026-09-24 用户实报「三指要点好多遍才能唤起」⇒ 真点按的漂移(0.03–0.05)被误杀 ✗
    /// 想更宽容:`defaults write com.cheney12138.macswitcher debug.tapMaxMoveNorm -float 0.08`
    static var tapMaxMoveNorm: Float {
        (UserDefaults.standard.object(forKey: Keys.debugTapMaxMoveNorm) as? NSNumber)?.floatValue
            ?? TapRound.Policy.standard.maxMove
    }

    /// 把档位拼成领域层判据(**唯一一处拼装**)
    /// 把两个档位拼成判卷策略(**唯一一处拼装** ✓ —— 触发层只认它)
    static var tapPolicy: TapRound.Policy {
        var p = TapRound.Policy.standard
        p.minDuration = Double(tapMinDurationMs) / 1000   // 时长下限(默认 30ms)
        p.minContactSize = tapMinContactSize              // 重量门:太小 = 搭着/掠着(默认 0.6)
        p.maxMove = tapMaxMoveNorm                        // 位移上限(默认 0.05)
        p.maxMajor = tapMaxMajor                          // 主轴上限:太大 = 掌心/掌缘(默认 14)
        return p
    }

    /// **触点"主轴"上限**(默认取领域层 = 14)。
    /// 2026-09-24 用户实报:笔记本打字时**掌心**压到触摸板 ⇒ 误触三指 ✓
    /// 实测掌心主轴 17–29 ✗、手指 8–10 ✓ ⇒ 14 在中间;掌心误触还多就调小
    ///     defaults write com.cheney12138.macswitcher debug.tapMaxMajor -float 12
    static var tapMaxMajor: Float {
        (UserDefaults.standard.object(forKey: Keys.debugTapMaxMajor) as? NSNumber)?.floatValue
            ?? TapRound.Policy.standard.maxMajor
    }

    static var tapUndoPolicy: TapUndoPolicy {
        var p = TapUndoPolicy.standard
        p.minDrift = tapUndoDriftPt
        return p
    }

    /// **送窗"塞不下"时切哪边**(2026-09-24 用户实报 DataGrip 右沿跑出去后加)。
    ///
    /// 病例:请求内建屏可见区 1728 宽,而 DataGrip 最小宽度 1752 ⇒ 多出的 24pt 必然被切 ✗
    /// ⇒ 默认 `keepLeft`(**现状,一个字都不变** ✓);想换边就改这个键(改完即生效,不用重启 ✓)
    ///    按本仓"锚定只能用固定边 / 或居中"的口径,只有这三档 ✓
    static var moveOverflowRule: ScreenMovePolicy.OverflowRule {
        let raw = UserDefaults.standard.string(forKey: Keys.debugMoveOverflowRule) ?? ""
        return ScreenMovePolicy.OverflowRule(rawValue: raw) ?? .keepLeft
    }

    // (送窗撑满门槛曾是 debug 键 —— 2026-09-25 当天提升为正式设置项 `panel.moveFillMinRatio`,
    //  唯一读取点 `Keys.moveFillMinRatio` ✓ 这里不再留第二把尺 ✗)

    /// **托底(选中标志那块板)的亮度倍率**（只作用于浅色模式 ✓ 默认 0.75）。
    ///
    /// 用户原话(2026-09-24):「其实我是想把**原本那个白色的高光**给去掉, 有点太亮了,
    /// 或者说可以降一点亮度试试」—— 他指的是选中图标底下那块**白亮板 + 白唇** ✓
    ///     defaults write com.cheney12138.macswitcher debug.puckBrightness -float 0.5   # 更淡
    ///     defaults write com.cheney12138.macswitcher debug.puckBrightness -float 1.0   # 回到原样
    ///     defaults delete com.cheney12138.macswitcher debug.puckBrightness              # 复位
    static var puckBrightness: Double {
        (UserDefaults.standard.object(forKey: Keys.debugPuckBrightness) as? NSNumber)?.doubleValue ?? 0.75
    }

    /// **指针光晕的强度倍率**（默认 1.0 ✓）。
    ///
    /// 2026-09-24 用户口径：「目前的高光有点亮了, 能不能把固定的高光变成选中 app 图标本身的颜色晕染」
    /// ⇒ 两件事一起做了：① 颜色改成**选中图标的主色**（见 `IconTint` / `VibrantColor` ✓）
    ///    ② 默认强度降下来（白 → 饱和色本身观感就暗一档，再加一档 ✓）
    /// 这个倍率是给"还嫌亮/还想更亮"留的出口，**改完即生效不用重启** ✓
    ///     defaults write com.cheney12138.macswitcher debug.sheenGain -float 0.6
    ///     defaults delete com.cheney12138.macswitcher debug.sheenGain
    static var sheenGain: Double {
        (UserDefaults.standard.object(forKey: Keys.debugSheenGain) as? NSNumber)?.doubleValue ?? 1.0
    }

    /// **多指设备"久闲多久后自愈重挂"**(分钟;默认 30 ✓ 设 0 = 关)。
    /// 病例(2026-09-25):合盖一夜后三指/四指全哑 —— 睡醒会让 Multitouch 回调死掉,
    /// 而原自愈住在喂帧路径里(没帧 ⇒ 不触发)⇒ 久闲后的第一发触发键主动重挂一遍 ✓
    static var tapReattachIdleMin: Int {
        (UserDefaults.standard.object(forKey: Keys.debugTapReattachIdleMin) as? NSNumber)?.intValue ?? 30
    }

    static func reportHeavySwitchesIfNeeded() {
        // 这两个不是布尔开关(是毫秒档位),但它们**改变时序/判据** ⇒
        // 与重型量具同一条纪律:不许静默偏离默认 ✓
        if moveOverflowRule != .keepLeft {
            print("[重型开关] debug.moveOverflowRule = \(moveOverflowRule.rawValue)(默认 keepLeft)—— 送窗塞不下时切哪边")
            print("[重型开关]   复位:defaults delete com.cheney12138.macswitcher \(Keys.debugMoveOverflowRule)")
        }
        if tapUndoDriftPt != 40 {
            print("[重型开关] debug.tapUndoDriftPt = \(tapUndoDriftPt)pt(默认 40, 设 0 = 关)—— 生效后撤销的位移下限")
            print("[重型开关]   排查完请复位:defaults delete com.cheney12138.macswitcher \(Keys.debugTapUndoDriftPt)")
        }
        if tapMinContactSize != 0.6 {
            print("[⚠️ 重型开关] debug.tapMinContactSize = \(tapMinContactSize)(默认 0.6, 设 0 = 关)—— 点按触点重量下限")
            print("[⚠️ 重型开关]   排查完请复位：defaults delete com.cheney12138.macswitcher \(Keys.debugTapMinContactSize)")
        }
        if tapMinDurationMs != 30 {
            print("[⚠️ 重型开关] debug.tapMinDurationMs = \(tapMinDurationMs)ms(默认 30)—— 三/四指点按时长下限")
            print("[⚠️ 重型开关]   排查完请复位：defaults delete com.cheney12138.macswitcher \(Keys.debugTapMinDurationMs)")
        }
        if sweepDelayMs != 500 {
            print("[⚠️ 重型开关] debug.sweepDelayMs = \(sweepDelayMs)ms(默认 500)—— 关面板预拍的推迟量")
            print("[⚠️ 重型开关]   排查完请复位：defaults delete com.cheney12138.macswitcher \(Keys.debugSweepDelayMs)")
        }
        for s in heavySwitches where s.isOn {
            print("[⚠️ 重型开关] \(s.name) 已打开 —— \(s.cost)")
            print("[⚠️ 重型开关]   排查完请关掉：defaults write com.cheney12138.macswitcher \(s.name) -bool false")
        }
    }

}
