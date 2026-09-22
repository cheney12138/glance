import Foundation

/// 触感(触控板震动)的口径 —— **纯逻辑,不碰 AppKit**(与本包其他文件同一条约定)。
///
/// 为什么需要它:面板是"先动作、后可见"的 —— 窗口要等 SwiftUI 提交那一帧、
/// 手势要等判定(位移/指头数)。于是"卡住了 / 手势没生效 / 我点到了没"这三种情况
/// 从屏幕上看**完全一样**。用户的口径(2026-09-20):
///
///   「只要捕捉到操控,就有反馈;如果没出现预期的效果,那就是有问题。」
///
/// ⇒ 所以触感要在**意图被接受的那一刻**发生,不能等效果出现之后。
///
/// 它还承担一层"语法":三指 / 四指 / 点按 **手感不同** —— 不看屏幕也能知道自己触发了哪一档。
/// (四指 = 进未启动环,给一档更明确的"换档"感;这与 `↓` 换环同档。)
public enum HapticEvent: CaseIterable {
    /// 三指轻点:唤起面板
    case summonThreeFinger
    /// 四指轻点:唤起并直接进未启动环
    case summonFourFinger
    /// 点按 App 行(选中 / 切换)
    case clickAppRow
    /// 点按预览托盘里的窗口
    case clickPreviewThumb
    /// ↑ / ↓ 换环(两个环之间的门)
    case ringSwap
    /// 指针移到另一个 App 格上(★ 探针性质:手指一直贴在板上,震没震一试便知)
    case hoverAppRow
    /// 指针移到预览托盘的另一个窗口上
    case hoverPreviewThumb
    /// 手势被判成拖动 ⇒ 本次**不动作**
    /// (正是"我以为点了,其实没生效"那一类 —— 沉默最容易被读成"卡住")
    case gestureRejected
}

/// 与 `NSHapticFeedbackManager.FeedbackPattern` 一一对应。
/// 核心包不 import AppKit,故在这里自己列一遍;App 层做一次 1:1 映射。
public enum HapticPattern: Equatable {
    case none
    /// 最轻:落位(点按、三指唤起)
    case alignment
    /// 中档:换档(四指进环、↑↓ 换环)
    case levelChange
    /// 最钝:提示(手势被拒)
    case generic
}

/// **触感强度**(2026-09-22 用户实报:「没感受到震感, 是不是强度太低了」)。
///
/// 实话:触感 API **没有强度参数** —— `NSHapticFeedbackManager` 只给三档**离散**手感
/// (`alignment` < `levelChange` < `generic`),没有"震 30%"这种旋钮 ✗。
/// 所以能做的就是:把档位挑出来(并**暴露到设置里**)⇒ 按自己的手感和设备选 ✓
/// (2026-09-20 已实测:同一档在**外接板**上很弱、**内置板**上清晰 ⇒ 设备差异比档位差异还大 ✓)
public enum HapticStrength: String, CaseIterable {
    case light, medium, strong

    public var pattern: HapticPattern {
        switch self {
        case .light:  return .alignment     // 三档里最轻
        case .medium: return .levelChange
        case .strong: return .generic       // 三档里最重(最"钝"、最容易感觉到)
        }
    }

    public var label: String {
        switch self {
        case .light:  return "轻"
        case .medium: return "中"
        case .strong: return "强"
        }
    }
}

public enum HapticPolicy {
    /// 开关:**默认关**(2026-09-20 用户裁定)。
    /// 仍然用 `object(forKey:) as? Bool ?? false`,不用 `bool(forKey:)` ——
    /// 口径是"**没写过"与"写成 false"必须能区分**,默认值是查询时补上的,不靠 UserDefaults 的缺省。
    /// (对比:`MotionPolicy.alwaysAnimate` 默认开,同一套写法,只是补 false 还是 true 不同。)
    /// 键名(单一来源):App 侧的 `Keys.hapticEnabled` 引用它 ⇒ **不写两遍** ✓
    public static let defaultsKey = "haptic.enabled"
    /// 强度档位的键名(同样单一来源 ✓)
    public static let strengthKey = "haptic.strength"

    /// 当前强度档:默认 **中**(2026-09-22 用户报"轻档感觉不到" ⇒ 默认抬一档 ✓)
    public static var strength: HapticStrength {
        HapticStrength(rawValue: UserDefaults.standard.string(forKey: strengthKey) ?? "") ?? .medium
    }

    /// 出厂默认:**开**(2026-09-22 用户裁定:唯一保留的触感,回答"我到底换到下一格了吗" ✓)。
    /// ⚠️ App 侧 `KeyDefaults.haptic` 必须与它一致 —— 改一处要改两处(跨层,Core 看不到 Keys ✗),
    ///    所以两处都写了注释指回来 ✓
    public static let enabledDefault = true

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? enabledDefault
    }

    /// 事件 ⇒ 手感。**开关关掉时一律 none**(设置是绝对权威:关了就是通通不震)。
    ///
    /// 刻意**不覆盖**的动作:导航键逐格移动(⌥ 松开前的每次方向键)。
    /// 那是"连续移动",每按一下震一下会变成噪声 —— 与"点按一次"不是同类动作。
    public static func pattern(for event: HapticEvent,
                              enabled: Bool = HapticPolicy.enabled) -> HapticPattern {
        guard enabled else { return .none }
        // ★ 2026-09-20 用户裁定:「三指四指 / 点按的震动不要了,只保留 hover 的。」
        // 原因链(踩过的都留着,免得以后又加回来):
        //   ① 三指/四指是**抬手之后**才判出指头数 ⇒ 单发落在手指已离开之后,几乎感觉不到;
        //   ② 改成双脉冲能感觉到一点,但外接触控板的致动器天生很弱,性价比不高;
        //   ③ hover 是唯一"手指确实还在板上"的时刻 ⇒ 也成了唯一值得发震动的事件。
        // 其余事件的反馈交给**视觉脉冲**(PanelController.nudge,见 visualSink):它不挑设备。
        switch event {
        case .hoverAppRow, .hoverPreviewThumb: break
        default: return .none
        }
        // 档位(2026-09-20 用户实测"外接板震感很小,内置板的清晰"):
        // 整个阶梯**抬一档** —— 触感 API 没有强度参数,只能换档。
        //   hover = 最轻(扫一排时不能抢戏)
        //   点按 / 三指 = 中
        //   四指 / 换环 / 不动作 = 重(最钝最明显的那一档)
        switch event {
        // ★ 2026-09-22:两个 hover 事件的强弱**交给设置**(用户实报"轻档感觉不到" ✓)
        //   其余事件仍按下面那套固定阶梯(它们现在都被上面的滤网挡掉了 ⇒ 保留只为记档 ✓)
        case .hoverAppRow, .hoverPreviewThumb: return strength.pattern
        case .summonThreeFinger: return .levelChange
        case .clickAppRow:       return .levelChange
        case .clickPreviewThumb: return .levelChange
        case .summonFourFinger:  return .generic
        case .ringSwap:          return .generic
        case .gestureRejected:   return .generic
        }
    }

    /// 同一瞬间只震一次。
    /// 唤起可能同时来自手势与热键(三指与 ⌥Tab 撞在一起),两个都震 = "双响",读起来像故障。
    /// 窗口给 0.25s:比一次手势的真实抖动大、比人再次主动触发的间隔小。
    /// 脉冲次数。**只给"手指会离开"的那类事件**双脉冲:
    /// 三指 / 四指是**抬手之后**才判出指头数的 ⇒ 那一刻手指已经在离开,
    /// 单发经常落在"已经没有接触"之后(用户实评:"点一下就离开了,感受不到")。
    /// 两发相隔 ~60ms,第二发还能赶上最后那点接触。
    /// 点按 / hover 保持单发:它们本来就发生在手指/指针还在的时候,双发只会变吵。
    public static func burstCount(for event: HapticEvent) -> Int {
        switch event {
        case .summonThreeFinger, .summonFourFinger: return 2
        default: return 1
        }
    }

    /// 每个事件的最小间隔。hover 比点按**短**(扫过一排格子要跟手),但也不能太短 ——
    /// 80ms 以下会连成一片嗡嗡响,读不出"过了几格"。
    public static func minInterval(for event: HapticEvent) -> TimeInterval {
        switch event {
        case .hoverAppRow, .hoverPreviewThumb: return 0.09
        default: return 0.25
        }
    }

    public static func isDuplicate(now: Date, lastFiredAt: Date?, window: TimeInterval = 0.25) -> Bool {
        guard let lastFiredAt else { return false }
        return now.timeIntervalSince(lastFiredAt) < window
    }
}
