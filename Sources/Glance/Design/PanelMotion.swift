import SwiftUI
import AppKit
import GlanceCore

// MARK: - 动效(弹簧,不是过冲 bezier)
//
// 旧版把 demo 的 `cubic-bezier(.22,1.6,.36,1)` 原样抄成 `.timingCurve(0.22, 1.6, 0.36, 1)`:
// ① y>1 的过冲曲线在 SwiftUI 里不可靠(引擎对越界控制点的处理跟 CSS 不是一回事);
// ② 更要命的是**每打断一次就从零速度重起** —— 连按 Tab 横扫面板时,puck 与图标每次都
//    "顿"一下再弹出去,看着就是机械僵硬。弹簧保留当前速度朝新目标续跑,打断即接力。

/// 动效总闸。**这是本项目的头号"看起来没动效"陷阱**:
/// 实测这台开发机的 `com.apple.universalAccess reduceMotion = 1` ——
/// 旧代码把所有动效写成 `.animation(reduceMotion ? nil : 弹簧)`,系统开关一开,
/// 弹簧、puck 滑动、入场**全部静默归零**,观感就是"弹起来但很硬,没有任何曲线"。
///
/// 现在的规矩:
/// 1. 尊重系统偏好,但**不是掐掉动画**——位移类降级成 160ms 的短淡入淡出
///    (Apple 的 reduce-motion 指引就是"别位移,改淡入淡出",而不是"东西凭空跳过去");
/// 2. **默认全效放行**。macOS 的"减弱动态效果"只有系统级开关,没有 per-app 豁免 API ——
///    想"只给这一个 App 放行",唯一的落点就是 App 自己这套开关(默认开)。
///    设置 → 通用 里可以关掉,回到跟随系统的行为;
/// 3. 面板每次出现打一行日志,动效在不在线一眼可见。
enum MotionPolicy {
    /// 覆盖开关:true = 无视系统偏好,始终播放完整动效(默认 true = 本 App 自己放行)。
    /// 用 `object(forKey:)` 而不是 `bool(forKey:)`:后者在"用户从没写过"时返回 false,
    /// 那样默认值就无法是 true。设置面板的 @AppStorage 用同一个 key、同样默认 true,
    /// 两边口径一致。
    static var alwaysAnimate: Bool {
        UserDefaults.standard.object(forKey: "motion.alwaysAnimate") as? Bool ?? true
    }

    static var systemReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// **从上一个 App 滑过来** —— 额外的一层入场动效,默认**关**。
    ///
    /// 入场分两层,不是二选一(用户口径:"上浮是通用的,从 c 滑动到 a 这个是额外的动效")：
    ///   · **上浮(通用)**:托底 / 选中的那一格 / 整块托盘从原位置下方轻轻浮上来。永远都有,没有开关,
    ///     幅度 = `entryFloatDistance`;
    ///   · **滑过来(额外)**:托底**额外**从"上一局停的那一格"横滑到本局落点 —— 窗口是复用的,
    ///     上一局画出来的那份残影就是它的起点。两局落点相同时它没得滑,自然只剩上浮。
    ///
    /// 默认关:落点差得远时要横穿整条(上一局停第六格、本局落第二格),视觉上很累;
    /// 而且它只存在于**面板刚出现的那一帧**,晚一点看就没了。
    ///
    /// key 换过:`panel.puckRiseFromBottom` 是上一版"上浮/滑 二选一"的开关,语义已经反了,
    /// 特意**不迁移** —— 搬过来会让面板突然开始滑动。旧 key 就此作废。
    static var slideFromLastApp: Bool {
        UserDefaults.standard.object(forKey: "panel.slideFromLastApp") as? Bool ?? false
    }

    /// **通用的上浮幅度** —— 入场每次都有这一层(见 `slideFromLastApp` 的两层说明)。
    ///
    /// 幅度史:1.4 × icon(≈123pt,整块从板子底下钻出来)→ 0.4 × icon(≈35pt)
    /// → **`iconLift`(≈17pt @1.2)**:与图标选中时的上浮同量级,读作"轻轻浮上来"而不是"弹出来"
    /// (用户实评:"有点过犹不及了,改成他们俩直接从原位置开始上浮")。
    ///
    /// ⚠️ 它**故意不引用 `iconLift`**:两者曾经共用同一个值,于是"克制选中上浮"那一刀
    /// 会连带把入场上浮也砍掉 43% —— 那是两个不同的动作(一个是入场,一个是选中态),
    /// 手感要求也不同(本文件开头那条已经说过:入场比跟手快一档)。各自独立取数。
    static var entryFloatDistance: CGFloat { PanelMetrics.scaled(14) }

    /// 是否处于"降级动效"模式
    static var reduced: Bool { !alwaysAnimate && systemReduced }

    /// **唤起静音期**(2026-09-20,帧账驱动):唤起那一拍内**任何动效都不给**。
    /// 病例(用户):「掉帧是第一次 ⌘Tab 唤起的时候」「不管是不是第二个,唤起面板的时候都不要这个动效了」——
    /// 帧探针实测:那一秒里有"首图上屏 +343ms"与"起流握手"两件重活,而**托底还要滑到默认选中那格**
    /// (`switch.advanceOnOpen` 开着 ⇒ 默认落在第二格)⇒ 位移叠在重活上就是肉眼里的卡 ✓。
    /// 所以:唤起后 ~0.45s 内,`animation(_:)` 一律返回 nil(瞬时到位),之后恢复。
    /// 只影响动效,不影响任何状态与逻辑。
    static var summonQuiet = false

    /// 取动效:正常给弹簧;降级给一记短淡出(不位移、也不硬跳)
    static func animation(_ full: Animation, reduced reducedDuration: Double = 0.16) -> Animation? {
        if summonQuiet { return nil }            // 唤起静音期:瞬时到位(见 summonQuiet 的注释)
        return reduced ? .easeOut(duration: reducedDuration) : full
    }

    static var describe: String {
        if alwaysAnimate {
            return systemReduced ? "完整动效(本 App 已放行;系统「减弱动态效果」开着)" : "完整动效"
        }
        return "降级为淡入淡出 —— 系统「减弱动态效果」开着,可在设置里放行本 App"
    }
}

enum PanelMotion {
    /// 开局落位的上膛延迟:跨过 SwiftUI 的首次提交,之后才上膛
    static let entryDelay: Double = 0.06
    /// 图标选中(demo .app-icon 的 .32s):response 越小越"脆",dampingFraction 越小回弹越明显
    /// ⚡ 2026-09-17 提速(用户口径:「选中即切换…有一个上浮动画, 速度加快」→ 澄清:是**想让它更快**):
    /// 0.32/0.55 → **0.22/0.60**。指哪一格,那一格的上浮与托底都更快到位。
    /// ⚠️ 它必须与下面的 `slide` **同一档速度**:托底与选中的图标是同一次 withAnimation 的两个面,
    /// 只调一个就会出现"图标先到、托底后到"(README 的动效口径:两者永远同步)。
    static let select = Animation.spring(response: 0.22, dampingFraction: 0.60)
    /// puck 滑移(demo .puck 的 .38s):阻尼比图标大一点,托底不抖
    /// 与 `select` 同步提速:0.38/0.62 → **0.26/0.66**(见上面 select 的注释,两者必须同一档)
    static let slide = Animation.spring(response: 0.26, dampingFraction: 0.66)
    /// **入场动效**(上浮 / 承接上一格;唯一的使用点是 `PanelController` 把 `contentEntryRise` 归零那一发)。
    /// 比 `slide` 快一档 —— 它是"入场",不是"跟手",不该让人等。会话内的横滑仍用 `slide`。
    ///
    /// 速度史:0.38(与 slide 同) → 0.28("上滑的速度稍微快一点") → 0.20(2026-09-15,幅度收成 17pt 之后,
    /// "这个上浮有点慢了") → **0.16**(2026-09-16 用户:「唤起面板 app 上浮的速度太慢了,加快一点」;
    /// 同轮裁定**入口槽的滑入与它同速** —— 同一根弹簧,两处不会各走各的,见 PanelView.entrySlot)。
    /// 再要动就一次动一个数:`response` 越小越快、`dampingFraction` 越小回弹越明显。
    /// ⚡ 2026-09-17 再提速(用户口径:「cmd tab 唤起的时候, 默认选中第二个, 然后它会有个上浮,
    /// 这个速度加快」):0.16 → **0.11**。
    /// 速度史:0.38(与 slide 同) → 0.28(「上滑的速度稍微快一点」) → 0.20(幅度收成 17pt 之后)
    ///        → 0.16 → **0.11**(2026-09-17)
    // ⚡️ 2026-09-17 极端值试验:用户对 0.16→0.08 的差别**感觉不到** ⇒ 先走到"几乎瞬时",
    // 用来验证"这个旋钮到底管不管那一段"。若极端值也没变化 ⇒ 管的不是它,去查别的层
    // (日志里 `[T6] 入场:…` 那行会说清这一局演了哪几层)。
    /// ⚠️ 2026-09-17:入场"上浮"已整段取消(起点幅度给 0,见 PanelController.showPanel)⇒
    /// 这一档现在**没有主环的用武之地**(留着给别处/以后)。值回退到取消前的那一档。
    static let entrance = Animation.spring(response: 0.16, dampingFraction: 0.62)
    /// 缩略图选中(demo .win-thumb 的 .18s ease):demo 无过冲,阻尼给到 .9
    static let thumb = Animation.spring(response: 0.20, dampingFraction: 0.9)
}


// MARK: - 触感(点按反馈)

/// 触感落地:把 `GlanceCore.HapticPolicy` 的口径搬到 AppKit,并负责**去重**与一行日志。
///
/// 时机是刻意的:在**意图被接受的那一刻**发(面板还没画出来就震)。
/// 于是「震了但没出现预期效果」＝ 真有问题 ✓;「没震」＝ 这一下没被接受 ✓。
/// 手感分档与全部手测用例见 `docs/触感用例.md`。
enum Haptics {
    private static var lastFiredAt: Date?

    static func fire(_ event: HapticEvent, trace: String = "") {
        // ⚠️ 2026-09-20 病例:日志里每一次都发了(63 行),但用户一次震感都没有。
        // 一个嫌疑:ThreeFingerTap 的回调跑在 **CGEvent tap 自己的线程**上,
        // 而 AppKit 的触感在主线程之外调用不可靠(可能被静默丢弃)。
        // ⇒ 统一 hop 到主线程再发。去重也放在主线程里做,避免两处竞态各震一次。
        if Thread.isMainThread {
            perform(event, trace: trace)
        } else {
            DispatchQueue.main.async { perform(event, trace: trace) }
        }
    }

    private static func perform(_ event: HapticEvent, trace: String) {
        let pattern = HapticPolicy.pattern(for: event)
        guard pattern != .none else { return }
        let now = Date()
        // 同一瞬间只震一次:三指与 ⌥Tab 撞车时"双响"读起来像故障
        if HapticPolicy.isDuplicate(now: now, lastFiredAt: lastFiredAt,
                                    window: HapticPolicy.minInterval(for: event)) { return }
        lastFiredAt = now
        func strike(_ p: HapticPattern) {
            let performer = NSHapticFeedbackManager.defaultPerformer
            switch p {
            case .none: break
            case .alignment:  performer.perform(.alignment,  performanceTime: .now)
            case .levelChange: performer.perform(.levelChange, performanceTime: .now)
            case .generic:    performer.perform(.generic,    performanceTime: .now)
            }
        }
        strike(pattern)
        if HapticPolicy.burstCount(for: event) > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { strike(pattern) }   // 第二发:赶在手指完全离开之前
        }
        glog("[触感] \(label(event)) → \(label(pattern))\(trace.isEmpty ? "" : " · \(trace)")")
    }

    private static func label(_ e: HapticEvent) -> String {
        switch e {
        case .summonThreeFinger: return "三指唤起"
        case .summonFourFinger:  return "四指唤起"
        case .clickAppRow:       return "点按 App"
        case .clickPreviewThumb: return "点按托盘"
        case .ringSwap:          return "换环"
        case .hoverAppRow:       return "hover 格"
        case .hoverPreviewThumb: return "hover 托盘"
        case .gestureRejected:   return "手势不动作"
        }
    }
    private static func label(_ p: HapticPattern) -> String {
        switch p {
        case .none: return "无"
        case .alignment: return "轻(落位)"
        case .levelChange: return "中(换档)"
        case .generic: return "钝(提示)"
        }
    }
}
