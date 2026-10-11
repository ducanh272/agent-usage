import Foundation
import Testing
@testable import AgentUsageCore

struct QuotaAlertLedgerTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func alertsOnceAtEachThresholdAndAgainAfterReset() {
        var ledger = QuotaAlertLedger()
        let reset = date.addingTimeInterval(3600)
        let twenty = state(account: "one", used: 80, reset: reset)
        #expect(ledger.newAlerts(for: twenty, at: date).map(\.threshold) == [20])
        #expect(ledger.newAlerts(for: twenty, at: date).isEmpty)
        let five = state(account: "one", used: 95, reset: reset)
        #expect(ledger.newAlerts(for: five, at: date).map(\.threshold) == [5])
        #expect(ledger.newAlerts(for: five, at: date).isEmpty)

        let nextWindow = state(account: "one", used: 80, reset: reset.addingTimeInterval(3600))
        #expect(ledger.newAlerts(for: nextWindow, at: date).map(\.threshold) == [20])
        let otherAccount = state(account: "two", used: 80, reset: reset)
        #expect(ledger.newAlerts(for: otherAccount, at: date).map(\.threshold) == [20])
    }

    @Test func firstReadingBelowFiveSendsOnlyUrgentAlert() {
        var ledger = QuotaAlertLedger()
        let reset = date.addingTimeInterval(3600)
        let five = state(account: "one", used: 99, reset: reset)
        #expect(ledger.newAlerts(for: five, at: date).map(\.threshold) == [5])
        #expect(ledger.newAlerts(for: state(account: "one", used: 80, reset: reset), at: date).isEmpty)
    }

    @Test func missingResetTimeStillAlertsOnlyOnce() {
        var ledger = QuotaAlertLedger()
        let reading = state(account: "one", used: 85, reset: nil)
        #expect(ledger.newAlerts(for: reading, at: date).map(\.threshold) == [20])
        #expect(ledger.newAlerts(for: reading, at: date.addingTimeInterval(60)).isEmpty)
    }

    @Test func cachedStaleAndAnonymousReadingsDoNotAlert() {
        var ledger = QuotaAlertLedger()
        let reset = date.addingTimeInterval(3600)
        #expect(ledger.newAlerts(for: state(account: "one", used: 85, reset: reset, cached: true),
                                 at: date).isEmpty)
        #expect(ledger.newAlerts(for: state(account: "one", used: 85, reset: reset, stale: true),
                                 at: date).isEmpty)
        #expect(ledger.newAlerts(for: state(account: nil, used: 85, reset: reset), at: date).isEmpty)
        #expect(ledger.newAlerts(for: state(account: "one", used: 85, reset: date), at: date).isEmpty)
        #expect(ledger.newAlerts(for: state(account: "one", used: .nan, reset: reset), at: date).isEmpty)
        #expect(ledger.newAlerts(for: state(account: "one", used: 85, reset: reset), at: date)
            .map(\.threshold) == [20])
    }

    @Test func deduplicationSurvivesStoreRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = state(account: "one", used: 80, reset: date.addingTimeInterval(3600))
        let first = LocalUsageStore(directory: directory)
        #expect(try await first.alertsToSend(for: state, at: date).count == 1)
        let reopened = LocalUsageStore(directory: directory)
        #expect(try await reopened.alertsToSend(for: state, at: date).isEmpty)

        let legacy = Data(#"{"codexExecutablePath":"","codexHomePath":""}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).notificationsEnabled == false)
        #expect(try await reopened.updateNotificationsEnabled(true).notificationsEnabled)
        #expect(try await reopened.loadSettings().notificationsEnabled)
    }

    private func state(account: String?, used: Double, reset: Date?,
                       cached: Bool = false, stale: Bool = false) -> UsageRefreshState {
        let scope = UsageScope(accountID: account)
        let availability = SourceAvailability(status: .available, source: .codexAccountAPI,
                                              scope: scope, observedAt: date)
        let identity = UsageMetric(value: AccountIdentity(accountID: account, email: nil, planType: "plus"),
                                   source: .codexAccountAPI, scope: scope, observedAt: date)
        let quota = UsageMetric(value: QuotaWindow(limitID: "codex", kind: .primary, usedPercent: used,
                                                   durationMinutes: 60, resetsAt: reset),
                                source: .codexAccountAPI, scope: scope, observedAt: date)
        let snapshot = UsageSnapshot(
            account: UsageReading(availability: availability, value: identity),
            quotaWindows: UsageReading(availability: availability, value: [quota]),
            tokenActivity: UsageReading(availability: availability, value: nil)
        )
        return UsageRefreshState(snapshot: snapshot, lastSuccessfulRefresh: date,
                                 isRefreshing: false, consecutiveFailures: 0,
                                 isCached: cached, isStale: stale)
    }
}
