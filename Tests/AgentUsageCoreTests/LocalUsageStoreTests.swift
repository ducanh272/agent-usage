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

        let settings = try await store.updateSettings(executablePath: "/custom/codex", homePath: "/custom/home")
        #expect(settings.codexExecutablePath == "/custom/codex")
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
        #expect(restored.codexExecutablePath == "/custom/codex")
        #expect(restored.codexHomePath == "/custom/home")
        #expect(restored.lastAccountID == "account-two")
        _ = try await store.updateSettings(executablePath: "", homePath: "")
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
