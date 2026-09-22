import CoreGraphics
import Foundation

/// **一局的不变量**(2026-09-22 起,把"只写在 ADR 里、只有人读"的规矩变成**机器能断言的东西**)。
///
/// 为什么要有它 —— 三条真事故,全都不是"算错了",而是**不变量被悄悄破坏**:
///   ① **窗框宽度当拍跳变**(634 ↔ 1509)⇒ 面板看着"抖"。当时它是"每拍重算的临时值" ✗,
///      后来才改成"两环更宽者 = 一局不变量"(`PanelController.ringWindowWidth()`)✓。
///      如果有断言:**第一次跳变就会被抓住**,不用靠用户肉眼发现 ✓
///   ② **给看不见的卡派帧**(白帧)⇒ 掉帧。规矩"只派当前显示组的帧"写在注释里 ✗,
///      直到有人读注释才发现漏了 `guard` ✓
///   ③ **换环门禁只挡一边** ⇒ "回得来、去不了"。规矩是"两侧对称" ✓,但没人断言它对称 ✗
///
/// 用法(见 `PanelController`):**开局时存一份基线**,之后每处几何真正落地时
/// `violations(baseline:now:)` ⇒ 非空就打日志(常态**一行都不打** ✓)。
/// 它只读、只比、只报,不改任何行为 ✓(与量具同一条规矩:不改变被测物 ✓)。
public struct SessionSnapshot: Equatable, Sendable {
    /// 一局的窗口尺寸(ADR-0006:窗口尺寸是**一局的不变量**)
    public var frameSize: CGSize
    /// 环窗口宽度(两环更宽者;ADR-0014 的"形状不变量")
    public var ringWindowWidth: CGFloat
    /// 当前在跑的流:窗口 id → 帧率档
    public var streamTiers: [UInt32: Int]

    public init(frameSize: CGSize, ringWindowWidth: CGFloat, streamTiers: [UInt32: Int] = [:]) {
        self.frameSize = frameSize
        self.ringWindowWidth = ringWindowWidth
        self.streamTiers = streamTiers
    }
}

/// 违反了哪一条(用来打日志;每一条都指得出对应的真事故)
public enum SessionViolation: Equatable, CustomStringConvertible {
    case frameSizeChanged(from: CGSize, to: CGSize)
    case ringWindowWidthChanged(from: CGFloat, to: CGFloat)
    /// 有流在跑,但它这扇窗**不在**当前该跑的那一拨里(这就是"白帧"那一类 ✗)
    case streamOutsideWanted(windowID: UInt32)

    public var description: String {
        switch self {
        case let .frameSizeChanged(a, b):
            return String(format: "一局内窗框尺寸变了 %.1fx%.1f → %.1fx%.1f(ADR-0006)", a.width, a.height, b.width, b.height)
        case let .ringWindowWidthChanged(a, b):
            return String(format: "一局内环窗口宽度变了 %.1f → %.1f(两环更宽者才是一局的不变量)", a, b)
        case let .streamOutsideWanted(wid):
            return String(format: "窗口 %u 有流在跑,但它不在「该跑」的名单里(会派白帧)", wid)
        }
    }
}

public enum SessionInvariants {
    /// 容差:几何是浮点累加出来的,0.5pt(与 `CardSizing` 同一条口径)
    public static let tolerance: CGFloat = 0.5

    /// 一局内**不该变**的东西变了 ⇒ 报出来。
    ///
    /// ⚠️ 有意**不检查**的:
    ///   · `origin`(位置):位置会随屏幕/居中合法性而变,那是**允许**的 ✓(ADR-0014 已裁定"保留形状、接受位移")
    ///   · 流的有无:开合流本来就是按组变化的 ✓;只有"跑着但在名单外"才算违反 ✗
    public static func violations(baseline: SessionSnapshot, now: SessionSnapshot) -> [SessionViolation] {
        var out: [SessionViolation] = []
        if abs(now.frameSize.width - baseline.frameSize.width) > tolerance
            || abs(now.frameSize.height - baseline.frameSize.height) > tolerance {
            out.append(.frameSizeChanged(from: baseline.frameSize, to: now.frameSize))
        }
        if abs(now.ringWindowWidth - baseline.ringWindowWidth) > tolerance {
            out.append(.ringWindowWidthChanged(from: baseline.ringWindowWidth, to: now.ringWindowWidth))
        }
        return out
    }

    /// 派帧门禁:在跑的每一扇窗都必须在"该跑"的名单里(或明确被 keepAlive 豁免)。
    ///
    /// 真事故:① 里那批"看不见的卡也换图"就是它没被断言 ✗
    public static func streamViolations(running: [UInt32], wanted: Set<UInt32>,
                                        keepAlive: Set<UInt32> = []) -> [SessionViolation] {
        running.filter { !wanted.contains($0) && !keepAlive.contains($0) }
            .sorted()
            .map { .streamOutsideWanted(windowID: $0) }
    }

    /// 一扇窗一条流(ADR-0007 原子操作):重复的 id 本身就是账本写坏的症状
    public static func duplicateStreams(_ ids: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        var dup = Set<UInt32>()
        for i in ids where !seen.insert(i).inserted { dup.insert(i) }
        return dup.sorted()
    }
}
