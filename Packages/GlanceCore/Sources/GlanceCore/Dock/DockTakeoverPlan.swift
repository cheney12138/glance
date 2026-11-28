import Foundation

/// 原生 Dock 偏好的持久化快照，精确区分未设置（`nil`）与显式布尔/浮点值。
public struct DockPreferencesSnapshot: Codable, Equatable, Sendable {
    public let autohide: Bool?
    public let autohideDelay: Double?

    public init(autohide: Bool?, autohideDelay: Double?) {
        self.autohide = autohide
        self.autohideDelay = autohideDelay
    }
}

/// 对 `com.apple.dock` 偏好域的单步变更指令，便于在纯核中单测接管与恢复计划。
public enum DockPreferenceMutation: Equatable, Sendable {
    case setBool(String, Bool)
    case setDouble(String, Double)
    case remove(String)
}

/// 原生 Dock 接管与还原计划（纯逻辑，不触碰真实系统偏好）。
public enum DockTakeoverPlan {
    public static let hiddenAutohideDelay: Double = 1000.0

    private static let autohideKey = "autohide"
    private static let autohideDelayKey = "autohide-delay"
    private static let delayMatchTolerance: Double = 0.01

    /// 需要接管时应写入的变更清单
    public static func takeoverMutations() -> [DockPreferenceMutation] {
        [
            .setBool(autohideKey, true),
            .setDouble(autohideDelayKey, hiddenAutohideDelay),
        ]
    }

    /// 归还原生 Dock 时应写入的恢复清单（精准还原 nil vs 显式值）
    public static func restoreMutations(from snapshot: DockPreferencesSnapshot) -> [DockPreferenceMutation] {
        let autohideMutation: DockPreferenceMutation = if let autohide = snapshot.autohide {
            .setBool(autohideKey, autohide)
        } else {
            .remove(autohideKey)
        }

        let delayMutation: DockPreferenceMutation = if let delay = snapshot.autohideDelay {
            .setDouble(autohideDelayKey, delay)
        } else {
            .remove(autohideDelayKey)
        }

        return [autohideMutation, delayMutation]
    }

    /// 判断当前读取到的系统值是否仍是“我们接管态”（防止二次覆盖原值快照！）
    public static func looksLikeOurTakeover(autohide: Bool?, autohideDelay: Double?) -> Bool {
        guard autohide == true, let autohideDelay else { return false }
        return abs(autohideDelay - hiddenAutohideDelay) < delayMatchTolerance
    }
}
