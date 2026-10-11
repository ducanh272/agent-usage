import Foundation
import Testing
@testable import AgentUsageCore

struct UsageRefreshCoordinatorTests {
    @Test func staleChecksAndBackoff() async {
        let clock = TestDateClock()
        let collector = ScriptedCollector(results: [
            .failure(TestFailure.failed),
            .failure(TestFailure.failed),
            .success(Self.snapshot),
            .success(Self.snapshot)
        ])
        let coordinator = UsageRefreshCoordinator(provider: collector, now: { clock.now() })

        let first = await coordinator.refreshIfStale()
        #expect(first.consecutiveFailures == 1)
        #expect(await collector.calls == 1)
        _ = await coordinator.refreshIfStale()
        #expect(await collector.calls == 1)

        clock.advance(by: 30)
        let second = await coordinator.refreshIfStale()
        #expect(second.consecutiveFailures == 2)
        #expect(await collector.calls == 2)
        clock.advance(by: 59)
        _ = await coordinator.refreshIfStale()
        #expect(await collector.calls == 2)

        clock.advance(by: 1)
        let success = await coordinator.refreshIfStale()
        #expect(success.consecutiveFailures == 0)
        #expect(success.snapshot != nil)
        #expect(success.lastSuccessfulRefresh == clock.now())
        #expect(await collector.calls == 3)

        clock.advance(by: 59)
        _ = await coordinator.refreshIfStale()
        #expect(await collector.calls == 3)
        clock.advance(by: 1)
        _ = await coordinator.refreshIfStale()
        #expect(await collector.calls == 4)
    }

    @Test func manualRefreshBypassesBackoff() async {
        let collector = ScriptedCollector(results: [.failure(TestFailure.failed), .success(Self.snapshot)])
        let coordinator = UsageRefreshCoordinator(provider: collector)
        _ = await coordinator.refresh()
        let state = await coordinator.refresh()
        #expect(await collector.calls == 2)
        #expect(state.consecutiveFailures == 0)
    }

    @Test func cachedSnapshotIsLabeledAndDoesNotDelayFreshRefresh() async {
        let clock = TestDateClock()
        let cached = CachedUsageSnapshot(accountID: "account", snapshot: Self.snapshot,
                                         savedAt: clock.now().addingTimeInterval(-30))
        let collector = ScriptedCollector(results: [.success(Self.snapshot)])
        let coordinator = UsageRefreshCoordinator(provider: collector, cachedSnapshot: cached, now: { clock.now() })
        let initial = await coordinator.currentState()
        #expect(initial.isCached)
        #expect(!initial.isStale)
        #expect(initial.lastSuccessfulRefresh == cached.savedAt)

        let refreshed = await coordinator.refreshIfStale()
        #expect(await collector.calls == 1)
        #expect(!refreshed.isCached)
        #expect(refreshed.lastSuccessfulRefresh == clock.now())
    }

    @Test func concurrentRefreshesShareOneCollection() async {
        let collector = GatedCollector(snapshot: Self.snapshot)
        let coordinator = UsageRefreshCoordinator(provider: collector)
        let first = Task { await coordinator.refresh() }
        await collector.waitUntilStarted()
        let second = Task { await coordinator.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await collector.calls == 1)
        await collector.release()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult.snapshot != nil)
        #expect(secondResult.snapshot != nil)
        #expect(await collector.calls == 1)
    }

    @Test func pollingStartsImmediatelyAndRepeatsAfterInterval() async throws {
        let collector = ScriptedCollector(results: Array(repeating: .success(Self.snapshot), count: 10))
        let coordinator = UsageRefreshCoordinator(provider: collector, pollInterval: 0.04)
        await coordinator.startPolling()
        try await Task.sleep(for: .milliseconds(130))
        await coordinator.stopPolling()
        #expect(await collector.calls >= 2)
    }

    private static let snapshot: UsageSnapshot = {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let scope = UsageScope(accountID: "account")
        func reading<Value: Codable & Equatable & Sendable>(_ value: Value?) -> UsageReading<Value> {
            UsageReading(
                availability: SourceAvailability(
                    status: value == nil ? .unsupported : .available,
                    source: .codexAccountAPI, scope: scope, observedAt: date
                ),
                value: value
            )
        }
        let account = UsageMetric(
            value: AccountIdentity(accountID: "account", email: nil, planType: "plus"),
            source: .codexAccountAPI, scope: scope, observedAt: date
        )
        return UsageSnapshot(
            account: reading(account),
            quotaWindows: reading(Optional<[UsageMetric<QuotaWindow>]>.none),
            tokenActivity: reading(Optional<TokenActivity>.none)
        )
    }()
}

private enum TestFailure: Error { case failed }

private final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)

    func now() -> Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor ScriptedCollector: UsageSnapshotCollecting {
    private var results: [Result<UsageSnapshot, TestFailure>]
    private(set) var calls = 0

    init(results: [Result<UsageSnapshot, TestFailure>]) { self.results = results }

    func collect() async throws -> UsageSnapshot {
        calls += 1
        return try results.removeFirst().get()
    }
}

private actor GatedCollector: UsageSnapshotCollecting {
    let snapshot: UsageSnapshot
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }

    func collect() async throws -> UsageSnapshot {
        calls += 1
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return snapshot
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
