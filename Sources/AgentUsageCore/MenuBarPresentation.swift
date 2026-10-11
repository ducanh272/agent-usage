import Foundation

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Sendable {
    case iconAndPercentage
    case iconOnly
}

/// A short menu bar value and a complete VoiceOver description of its source state.
public struct MenuBarPresentation: Equatable, Sendable {
    public let text: String?
    public let accessibilityLabel: String

    public static func make(
        state: UsageRefreshState?,
        mode: MenuBarDisplayMode,
        at date: Date = Date()
    ) -> MenuBarPresentation {
        let remaining: Double?
        if let state,
           !state.isCached, !state.isQuotaStale(at: date),
           let windows = state.snapshot?.quotaWindows.value {
            remaining = windows.map(\.value.usedPercent)
                .filter(\.isFinite)
                .map { max(0, min(100, 100 - $0)) }
                .min()
        } else {
            remaining = nil
        }

        guard let remaining else {
            return MenuBarPresentation(
                text: mode == .iconOnly ? nil : "—",
                accessibilityLabel: "Agent Usage, Codex quota unavailable"
            )
        }
        let percentage = Int(remaining.rounded())
        return MenuBarPresentation(
            text: mode == .iconOnly ? nil : "\(percentage)%",
            accessibilityLabel: "Agent Usage, Codex lowest quota \(percentage) percent remaining"
        )
    }
}
