import Foundation

/// 边缘触发与保活状态机的当前状态。
public enum DockTriggerState: Equatable, Sendable {
    case idle
    case dwelling(displayID: UInt32, enteredAt: Double)
    case open(displayID: UInt32)
    case leaving(displayID: UInt32, leftAt: Double)
}

/// 状态机迁移产出的副作用指令。
public enum DockTriggerEffect: Equatable, Sendable {
    case none
    case scheduleDwellCheck(after: Double)
    case openDock(displayID: UInt32)
    case scheduleLeaveCheck(after: Double)
    case closeDock
}

/// 贴边 dwell 唤起与离区 grace 收起的纯状态机（时间以参数注入，无定时器副作用）。
public struct DockTriggerMachine: Equatable, Sendable {
    public private(set) var state: DockTriggerState
    public var dwellDuration: Double
    public var leaveGraceDuration: Double

    private static let timeEpsilon: Double = 1e-9

    public init(dwellDuration: Double = 0.10, leaveGraceDuration: Double = 0.26) {
        self.state = .idle
        self.dwellDuration = dwellDuration
        self.leaveGraceDuration = leaveGraceDuration
    }

    public mutating func edgeEntered(
        displayID: UInt32,
        mouseButtonsPressed: Bool,
        suppressed: Bool,
        now: Double
    ) -> DockTriggerEffect {
        if mouseButtonsPressed || suppressed {
            if case .dwelling = state {
                state = .idle
            }
            return .none
        }

        switch state {
        case .idle:
            return startDwellOrOpen(displayID: displayID, now: now)

        case .dwelling(let currentID, _):
            if currentID == displayID {
                return .none
            }
            return startDwellOrOpen(displayID: displayID, now: now)

        case .open:
            return .none

        case .leaving(let currentID, _):
            if currentID == displayID {
                state = .open(displayID: currentID)
            }
            return .none
        }
    }

    public mutating func edgeExited(displayID: UInt32, now: Double) -> DockTriggerEffect {
        if case .dwelling(let currentID, _) = state, currentID == displayID {
            state = .idle
        }
        return .none
    }

    public mutating func pointerEnteredSurface(displayID: UInt32, now: Double) -> DockTriggerEffect {
        if case .leaving(let currentID, _) = state, currentID == displayID {
            state = .open(displayID: currentID)
        }
        return .none
    }

    public mutating func pointerLeftSurface(displayID: UInt32, now: Double) -> DockTriggerEffect {
        guard case .open(let currentID) = state, currentID == displayID else {
            return .none
        }
        if leaveGraceDuration <= 0 {
            state = .idle
            return .closeDock
        }
        state = .leaving(displayID: currentID, leftAt: now)
        return .scheduleLeaveCheck(after: leaveGraceDuration)
    }

    public mutating func tick(
        now: Double,
        mouseButtonsPressed: Bool,
        suppressed: Bool
    ) -> DockTriggerEffect {
        switch state {
        case .idle:
            return .none

        case .dwelling(let id, let enteredAt):
            if mouseButtonsPressed || suppressed {
                state = .idle
                return .none
            }
            let elapsed = now - enteredAt
            if elapsed >= dwellDuration - Self.timeEpsilon {
                state = .open(displayID: id)
                return .openDock(displayID: id)
            }
            let remaining = max(0, min(dwellDuration, dwellDuration - elapsed))
            return .scheduleDwellCheck(after: remaining)

        case .open:
            if suppressed {
                state = .idle
                return .closeDock
            }
            return .none

        case .leaving(_, let leftAt):
            if suppressed {
                state = .idle
                return .closeDock
            }
            let elapsed = now - leftAt
            if elapsed >= leaveGraceDuration - Self.timeEpsilon {
                state = .idle
                return .closeDock
            }
            let remaining = max(0, min(leaveGraceDuration, leaveGraceDuration - elapsed))
            return .scheduleLeaveCheck(after: remaining)
        }
    }

    public mutating func forceClose() -> DockTriggerEffect {
        switch state {
        case .open, .leaving:
            state = .idle
            return .closeDock
        case .dwelling:
            state = .idle
            return .none
        case .idle:
            return .none
        }
    }

    private mutating func startDwellOrOpen(displayID: UInt32, now: Double) -> DockTriggerEffect {
        if dwellDuration <= 0 {
            state = .open(displayID: displayID)
            return .openDock(displayID: displayID)
        }
        state = .dwelling(displayID: displayID, enteredAt: now)
        return .scheduleDwellCheck(after: dwellDuration)
    }
}
