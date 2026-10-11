import Foundation

public enum RefreshInterval: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15

    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}
