import Foundation
import Testing
@testable import AgentUsageCore

struct LocalUsageStoreTests {
    @Test func settingsAndSnapshotsRemainSeparatedByAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        let firstDate = Date(timeIntervalSince1970: 1_900_000_000)
        let secondDate = firstDate.addingTimeInterval(60)

        _ = try await store.updateRefreshInterval(.fifteenMinutes)
        _ = try await store.save(snapshot(for: "account-one"), at: firstDate)
        _ = try await store.save(snapshot(for: "account-two"), at: secondDate)

        let first = try await store.loadSnapshot(for: "account-one")
        let second = try await store.loadSnapshot(for: "account-two")
        let latest = try await store.loadLatestSnapshot()
        #expect(first?.accountID == "account-one")
        #expect(first?.savedAt == firstDate)
        #expect(second?.accountID == "account-two")
        #expect(latest == second)

        let restored = try await store.loadSettings()
        #expect(restored.refreshInterval == .fifteenMinutes)
        #expect(restored.lastAccountID == "account-two")
        #expect(try await store.loadLatestSnapshot()?.accountID == "account-two")

        let files = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("accounts"), includingPropertiesForKeys: nil
        )
        #expect(files.count == 2)
        #expect(files.allSatisfy { !$0.lastPathComponent.contains("account-") })
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func anonymousReadingsAreNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        let saved = try await store.save(snapshot(for: nil))
        #expect(saved == nil)
        #expect(try await store.loadLatestSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func mixedAccountReadingsAreNotCachedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        let first = snapshot(for: "account-one")
        let otherScope = UsageScope(accountID: "account-two")
        let quota = UsageReading<[UsageMetric<QuotaWindow>]>(
            availability: SourceAvailability(status: .unsupported, source: .codexAccountAPI,
                                             scope: otherScope, observedAt: Date()), value: nil
        )
        let mixed = UsageSnapshot(account: first.account, quotaWindows: quota, tokenActivity: first.tokenActivity)
        #expect(try await store.save(mixed) == nil)
        #expect(try await store.loadLatestSnapshot() == nil)
    }

    @Test func cachedReadingBecomesStaleAtTenMinutes() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let cached = CachedUsageSnapshot(accountID: "account", snapshot: snapshot(for: "account"), savedAt: date)
        #expect(!cached.isStale(at: date.addingTimeInterval(599)))
        #expect(cached.isStale(at: date.addingTimeInterval(600)))
        #expect(cached.isStale(at: date.addingTimeInterval(-1)))
    }

    @Test func refreshIntervalDefaultsAndPersists() async throws {
        let legacy = Data(#"{"codexExecutablePath":"/codex","codexHomePath":""}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).refreshInterval == .fiveMinutes)
        let unknown = Data(#"{"refreshInterval":99,"menuBarDisplayMode":"future"}"#.utf8)
        let recovered = try JSONDecoder().decode(AppSettings.self, from: unknown)
        #expect(recovered.refreshInterval == .fiveMinutes)
        #expect(recovered.menuBarDisplayMode == .iconAndPercentage)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        _ = try await store.updateRefreshInterval(.oneMinute)
        #expect(try await store.loadSettings().refreshInterval == .oneMinute)
        _ = try await store.updateMenuBarDisplayMode(.iconOnly)
        #expect(try await store.loadSettings().refreshInterval == .oneMinute)
        _ = try await store.updateRefreshInterval(.fifteenMinutes)
        #expect(try await store.loadSettings().refreshInterval.seconds == 900)
    }

    @Test func oldPathSettingsAreRemovedOnLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"codexExecutablePath":"/old/codex","codexHomePath":"/old/home","lastAccountID":"one","refreshInterval":15}"#.utf8)
            .write(to: url)
        let store = LocalUsageStore(directory: directory)
        let settings = try await store.loadSettings()
        #expect(settings.lastAccountID == "one")
        #expect(settings.refreshInterval == .fifteenMinutes)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("codexExecutablePath"))
        #expect(!rewritten.contains("codexHomePath"))
    }

    @Test func clearingUsageKeepsPreferencesAndAlertHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalUsageStore(directory: directory)
        _ = try await store.updateMenuBarDisplayMode(.iconOnly)
        _ = try await store.updateRefreshInterval(.fifteenMinutes)
        _ = try await store.updateNotificationsEnabled(true)
        _ = try await store.save(snapshot(for: "one"))
        _ = try await store.save(snapshot(for: "two"))
        let history = directory.appendingPathComponent("sent-alerts.json")
        try Data(#"{"sentIdentifiers":[]}"#.utf8).write(to: history)

        let cleared = try await store.clearCachedUsage()
        #expect(cleared.lastAccountID == nil)
        #expect(cleared.menuBarDisplayMode == .iconOnly)
        #expect(cleared.refreshInterval == .fifteenMinutes)
        #expect(cleared.notificationsEnabled)
        #expect(try await store.loadLatestSnapshot() == nil)
        #expect(try await store.loadSnapshot(for: "one") == nil)
        #expect(FileManager.default.fileExists(atPath: history.path))
    }

    private func snapshot(for accountID: String?) -> UsageSnapshot {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let scope = UsageScope(accountID: accountID)
        let availability = SourceAvailability(status: .available, source: .codexAccountAPI,
                                              scope: scope, observedAt: date)
        let account = UsageMetric(value: AccountIdentity(accountID: accountID, email: nil, planType: "plus"),
                                  source: .codexAccountAPI, scope: scope, observedAt: date)
        return UsageSnapshot(
            account: UsageReading(availability: availability, value: account),
            quotaWindows: UsageReading(availability: availability, value: nil),
            tokenActivity: UsageReading(availability: availability, value: nil)
        )
    }
}
