/// 「刚生效的这一发，要不要撤回来」—— **决定**，不是动作（ADR-0015 ✓）。
///
/// 病例（2026-09-23 用户：「又复现误触了」）：日志把两件事排得很清楚 ——
/// ```text
/// 10834.23  三指 150ms 位移 abs=0.3 size=1.4 → 唤起(钉住)     ← 判卷这一拍:样样合规
/// 10834.45  [闸] 指针位移 → 发言(654,265)                    ← +220ms 指针才动
/// 10834.49  ⚠️ 生效后 250ms 指针又移动 152pt                  ← 量尺早就看见了
/// 10835.44  ⚠️ 之后系统在拖拽 ⇒ 撤销这次唤起                   ← +1.2s,系统才把拖拽事件交出来
/// ```
/// ⇒ 拖移在**接触期间**就开始了，但系统合成的事件比"抬手判卷"晚 200ms 以上 ✗
///   ⇒ 判卷那一刻没有证据（他加的"按压期间问鼠标"那条门是对的，只是**看不见这种形状** ✓）
/// ⇒ 所以要在**指针一动的这一拍**就撤（+250ms ✓ 而不是等 +1.2s 的拖拽事件 ✗）
///
/// ⚠️ 而"指针一动就撤销"以前被否过 ✗（hover 选 App 本来就要挪指针 ⇒ 误伤了钉住的一局 ✓）
/// ⇒ 区别是**可测的**：真轻点之后**手指已经离开触控板** ✓；误触那一发是拖移，**手指还在板上** ✓
///   所以判据 = 位移够大 **且** 板上仍有 ≥2 指 ✓ —— hover 时手指不在板上 ⇒ 不会误撤 ✓
public struct TapUndoPolicy: Equatable {

    /// 生效后**多久之内**看漂移（秒）。与既有那条 250ms 量尺同一个窗口 ✓
    public var window: Double
    /// 位移下限（pt）。真轻点之后指针是**不动**的（实测 <1pt ✓），误触那发是 152pt ✓
    public var minDrift: Double
    /// 板上至少这么多指才算"拖移还没结束" ✓（hover 时是 0 ✓）
    public var minFingersDown: Int

    public init(window: Double = 0.30, minDrift: Double = 40, minFingersDown: Int = 2) {
        self.window = window
        self.minDrift = minDrift
        self.minFingersDown = minFingersDown
    }

    public static let standard = TapUndoPolicy()

    public enum Verdict: Equatable {
        case undo(String)   // 撤销(理由进日志 ✓)
        case keep(String)   // 留着(理由进日志,方便复盘时确认"是它没撤"✓)
    }

    public func verdict(drift: Double, sinceFire: Double, fingersDown: Int) -> Verdict {
        guard minDrift > 0 else { return .keep("档位已关(下限 0)") }
        guard sinceFire <= window else {
            return .keep(String(format: "窗口外(%.2fs > %.2fs)", sinceFire, window))
        }
        guard drift >= minDrift else {
            return .keep(String(format: "位移不够(%.0fpt < %.0fpt)", drift, minDrift))
        }
        guard fingersDown >= minFingersDown else {
            // ★ 这条就是"不能误伤 hover"的那道闸 ✓：指针在动、但手不在板上 ⇒ 是用户在挪鼠标 ✓
            return .keep(String(format: "手已离板(%d 指 < %d)⇒ 是用户自己挪鼠标", fingersDown, minFingersDown))
        }
        return .undo(String(format: "生效后 %.0fms 指针位移 %.0fpt 且板上仍有 %d 指 ⇒ 拖移还没结束",
                            sinceFire * 1000, drift, fingersDown))
    }
}
