import SwiftUI
import AppKit

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

    /// 入场的**起点**(整块内容:图标 + 托底;用户实评 2026-09-14):
    ///
    /// 开 = 从**面板下缘升起** —— 无论新选中在第几格,整块内容都被按到选中格下方,
    /// 距离恒定且短(而且开场那一帧它整块落在面板下缘之外,被圆角裁掉,升起是干净的);
    /// 关 = 从**上一局选中的那个格子**滑过来 —— a→b 之后 b 排到第一、a 落在第 6 位时,
    /// 整条要横跨从右滑到左,"视觉上很累"。
    ///
    /// 曾经试过"从长条左缘滑入",实评效果不好(横向的插入感很硬),改成纵向升起 ——
    /// **动效本身没动**,只换了起点方向。两种都会滑,所以这是一个二选一,不是动效开关。
    static var entryRisesFromBottom: Bool {
        UserDefaults.standard.object(forKey: "panel.puckRiseFromBottom") as? Bool ?? true
    }

    /// "从底部升起"的距离。取 1.4×图标边长,是算出来的最小充分值:
    /// 让内容在开场那一帧**完全**落到面板下缘之外(推导:icon + 30×scale;1.4×icon = 123×scale > 118×scale)
    static var entryRiseDistance: CGFloat { PanelMetrics.icon * 1.4 }

    /// 是否处于"降级动效"模式
    static var reduced: Bool { !alwaysAnimate && systemReduced }

    /// 取动效:正常给弹簧;降级给一记短淡出(不位移、也不硬跳)
    static func animation(_ full: Animation, reduced reducedDuration: Double = 0.16) -> Animation {
        reduced ? .easeOut(duration: reducedDuration) : full
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
    static let select = Animation.spring(response: 0.32, dampingFraction: 0.55)
    /// puck 滑移(demo .puck 的 .38s):阻尼比图标大一点,托底不抖
    static let slide = Animation.spring(response: 0.38, dampingFraction: 0.62)
    /// 托底**入场**(从面板下缘升起)。比 `slide` 快一档:升幅有 1.4×图标那么长,
    /// 用同一根弹簧会显得"慢慢飘上来" —— 用户实评"上滑的速度稍微快一点"。
    /// 会话内的横滑仍用 `slide`(两个动作的手感本来就该不同:一个是入场,一个是跟手)
    static let entrance = Animation.spring(response: 0.28, dampingFraction: 0.62)
    /// 缩略图选中(demo .win-thumb 的 .18s ease):demo 无过冲,阻尼给到 .9
    static let thumb = Animation.spring(response: 0.20, dampingFraction: 0.9)
}
