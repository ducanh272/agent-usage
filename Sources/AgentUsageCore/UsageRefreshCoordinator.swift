import Foundation

public protocol UsageSnapshotCollecting: Sendable {
    func collect() async throws -> UsageSnapshot
}

extension CodexUsageProvider: UsageSnapshotCollecting {}

/// Uses a fresh App Server session for each refresh, so a failed child can be retried.
public actor CodexSessionCollector: UsageSnapshotCollecting {
    private let executableURL: URL
    private let codexHomeURL: URL

    public init(executableURL: URL, codexHomeURL: URL) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
    }

    public func collect() async throws -> UsageSnapshot {
        let transport = CodexAppServerTransport(executableURL: executableURL, codexHomeURL: codexHomeURL)
        do {
            try await transport.start()
            let snapshot = try await CodexUsageProvider(transport: transport).collect()
            await transport.stop()
            return snapshot
        } catch {
            await transport.stop()
            throw error
        }
    }
}

public struct UsageRefreshState: Sendable {
    public let snapshot: UsageSnapshot?
    public let lastSuccessfulRefresh: Date?
    public let isRefreshing: Bool
    public let consecutiveFailures: Int
    public let isCached: Bool
    public let isStale: Bool

    public init(snapshot: UsageSnapshot?, lastSuccessfulRefresh: Date?, isRefreshing: Bool,
                consecutiveFailures: Int, isCached: Bool = false, isStale: Bool = false) {
        self.snapshot = snapshot
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.isRefreshing = isRefreshing
        self.consecutiveFailures = consecutiveFailures
        self.isCached = isCached
        self.isStale = isStale
    }
}

/// Owns one provider's refresh cadence. All callers share an in-flight collection.
public actor UsageRefreshCoordinator {
    private let provider: any UsageSnapshotCollecting
    private let now: @Sendable () -> Date
    private let pollInterval: TimeInterval
    private var snapshot: UsageSnapshot?
    private var lastSuccessfulRefresh: Date?
    private var isCached: Bool
    private var consecutiveFailures = 0
    private var nextRetryAt: Date?
    private var inFlight: Task<UsageSnapshot, Error>?
    private var inFlightID = 0
    private var pollingTask: Task<Void, Never>?
    private let continuation: AsyncStream<UsageRefreshState>.Continuation
    public nonisolated let updates: AsyncStream<UsageRefreshState>

    public init(
        provider: any UsageSnapshotCollecting,
        cachedSnapshot: CachedUsageSnapshot? = nil,
        pollInterval: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.pollInterval = pollInterval
        self.now = now
        snapshot = cachedSnapshot?.snapshot
        lastSuccessfulRefresh = cachedSnapshot?.savedAt
        isCached = cachedSnapshot != nil
        let stream = AsyncStream.makeStream(of: UsageRefreshState.self, bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream
        continuation = stream.continuation
    }

    public func currentState() -> UsageRefreshState {
        UsageRefreshState(
            snapshot: snapshot,
            lastSuccessfulRefresh: lastSuccessfulRefresh,
            isRefreshing: inFlight != nil,
            consecutiveFailures: consecutiveFailures,
            isCached: isCached,
            isStale: lastSuccessfulRefresh.map { now().timeIntervalSince($0) >= 600 || now() < $0 } ?? false
        )
    }

    /// Polls immediately, then five minutes after a success or after the current failure backoff.
    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshIfDue()
                let delay = await self.secondsUntilNextPoll()
                do { try await Task.sleep(for: .seconds(min(delay, 15))) } catch { break }
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Used when the panel opens or the Mac wakes. A recent success is kept as-is.
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 60) async -> UsageRefreshState {
        if let inFlight { return await finish(inFlight, id: inFlightID) }
        if !isCached, let lastSuccessfulRefresh, now().timeIntervalSince(lastSuccessfulRefresh) < maxAge {
            return currentState()
        }
        guard retryIsAllowed else { return currentState() }
        return await refresh()
    }

    /// Manual refresh bypasses backoff, but joins a collection already in progress.
    @discardableResult
    public func refresh() async -> UsageRefreshState {
        if let inFlight { return await finish(inFlight, id: inFlightID) }
        inFlightID += 1
        let id = inFlightID
        let provider = provider
        let task = Task { try await provider.collect() }
        inFlight = task
        continuation.yield(currentState())
        return await finish(task, id: id)
    }

    private func finish(_ task: Task<UsageSnapshot, Error>, id: Int) async -> UsageRefreshState {
        let result = await task.result
        guard id == inFlightID, inFlight != nil else { return currentState() }
        inFlight = nil
        switch result {
        case .success(let collected) where Self.hasAvailableData(collected):
            snapshot = collected
            lastSuccessfulRefresh = now()
            isCached = false
            consecutiveFailures = 0
            nextRetryAt = nil
        case .success, .failure:
            consecutiveFailures += 1
            let exponent = min(consecutiveFailures - 1, 4)
            nextRetryAt = now().addingTimeInterval(min(30 * Double(1 << exponent), pollInterval))
        }
        let state = currentState()
        continuation.yield(state)
        return state
    }

    private var retryIsAllowed: Bool {
        guard let nextRetryAt else { return true }
        return now() >= nextRetryAt
    }

    private func refreshIfDue() async {
        guard inFlight == nil, retryIsAllowed else { return }
        if !isCached, nextRetryAt == nil, let lastSuccessfulRefresh,
           now().timeIntervalSince(lastSuccessfulRefresh) < pollInterval { return }
        await refresh()
    }

    private func secondsUntilNextPoll() -> TimeInterval {
        let target: Date
        if let nextRetryAt { target = nextRetryAt }
        else if !isCached, let lastSuccessfulRefresh { target = lastSuccessfulRefresh.addingTimeInterval(pollInterval) }
        else { target = now().addingTimeInterval(pollInterval) }
        return max(0.01, target.timeIntervalSince(now()))
    }

    private static func hasAvailableData(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.account.value != nil || snapshot.quotaWindows.value != nil || snapshot.tokenActivity.value != nil
    }
}
