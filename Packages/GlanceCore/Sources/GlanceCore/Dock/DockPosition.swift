import Foundation

/// Glance Dock 在屏幕上的贴边位置。
public enum DockPosition: String, CaseIterable, Codable, Sendable, Equatable {
    case left
    case bottom
    case right

    public var isVertical: Bool { self != .bottom }

    public var label: String {
        switch self {
        case .left: return "左侧"
        case .bottom: return "底部"
        case .right: return "右侧"
        }
    }
}
