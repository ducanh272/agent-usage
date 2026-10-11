import Foundation
import Testing
@testable import AgentUsageCore

struct MenuBarPresentationTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func usesLowestRemainingWindow() {
        let state = state(windows: [15, 78, 40])
        let label = MenuBarPresentation.make(state: state, mode: .iconAndPercentage, at: date)
        #expect(label.text == "22%")
        #expect(label.accessibilityLabel.contains("22 percent remaining"))

        let iconOnly = MenuBarPresentation.make(state: state, mode: .iconOnly, at: date)
        #expect(iconOnly.text == nil)
        #expect(iconOnly.accessibilityLabel == label.accessibilityLabel)
    }

    @Test func unavailableAndOldReadingsNeverShowZero() {
        for state in [Optional<UsageRefreshState>.none, self.state(windows: []),
                      self.state(windows: [Double.nan])] {
            let label = MenuBarPresentation.make(state: state, mode: .iconAndPercentage, at: date)
            #expect(label.text == "—")
            #expect(label.accessibilityLabel.contains("unavailable"))
        }
        let cached = state(windows: [100], isCached: true)
        #expect(MenuBarPresentation.make(state: cached, mode: .iconAndPercentage, at: date).text == "—")
        let expired = state(windows: [100])
        #expect(MenuBarPresentation.make(state: expired, mode: .iconAndPercentage,
                                         at: date.addingTimeInterval(600)).text == "—")
        #expect(MenuBarPresentation.make(state: state(windows: [100]), mode: .iconAndPercentage,
                                         at: date).text == "0%")
    }

    @Test func resetExpiryMakesCompactLabelUnavailableUntilNewQuota() {
        let state = state(windows: [80], reset: date.addingTimeInterval(30))
        #expect(MenuBarPresentation.make(state: state, mode: .iconAndPercentage,
                                         at: date.addingTimeInterval(29)).text == "20%")
        #expect(MenuBarPresentation.make(state: state, mode: .iconAndPercentage,
                                         at: date.addingTimeInterval(30)).text == "—")
    }

    @Test func oldSettingsDecodeAndModePersists() async throws {
        let legacy = Data(#"{"codexExecutablePath":"/codex","codexHomePath":"/home","lastAccountID":"one"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.menuBarDisplayMode == .iconAndPercentage)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        _ = try await store.updateSettings(executablePath: "/codex", homePath: "/home")
        _ = try await store.updateMenuBarDisplayMode(.iconOnly)
        let restored = try await store.loadSettings()
        #expect(restored.menuBarDisplayMode == .iconOnly)
        #expect(restored.codexExecutablePath == "/codex")
        #expect(restored.codexHomePath == "/home")
    }

    private func state(windows used: [Double], isCached: Bool = false, reset: Date? = nil) -> UsageRefreshState {
        let scope = UsageScope(accountID: "one")
        let availability = SourceAvailability(status: used.isEmpty ? .unsupported : .available,
                                              source: .codexAccountAPI, scope: scope, observedAt: date)
        let windows = used.map {
            UsageMetric(value: QuotaWindow(limitID: "codex", kind: .primary, usedPercent: $0,
                                           durationMinutes: nil, resetsAt: reset),
                        source: .codexAccountAPI, scope: scope, observedAt: date)
        }
        let snapshot = UsageSnapshot(
            account: UsageReading(availability: availability, value: nil),
            quotaWindows: UsageReading(availability: availability, value: used.isEmpty ? nil : windows),
            tokenActivity: UsageReading(availability: availability, value: nil)
        )
        return UsageRefreshState(snapshot: snapshot, lastSuccessfulRefresh: date,
                                 isRefreshing: false, consecutiveFailures: 0, isCached: isCached)
    }
}
