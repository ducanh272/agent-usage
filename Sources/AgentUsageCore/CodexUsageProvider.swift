import Foundation

/// The small transport surface needed by account collection.
public protocol AppServerRequesting: Sendable {
    func request(method: String, params: Data?, timeout: Duration?) async throws -> Data
}

extension CodexAppServerTransport: AppServerRequesting {}

/// Collects each account capability separately; one failed method does not hide other readings.
public actor CodexUsageProvider: UsageProvider {
    private let transport: any AppServerRequesting
    private let now: @Sendable () -> Date
    private var accountID: String?

    public init(transport: any AppServerRequesting, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    public func readAccount() async throws -> UsageReading<UsageMetric<AccountIdentity>> {
        accountID = nil
        let result = try await transport.request(
            method: "account/read", params: Data("{\"refreshToken\":false}".utf8), timeout: nil
        )
        let reading = try CodexUsageMapper.account(from: result, observedAt: now())
        accountID = reading.value?.value.accountID
        return reading
    }

    public func readQuotaWindows() async throws -> UsageReading<[UsageMetric<QuotaWindow>]> {
        let result = try await transport.request(method: "account/rateLimits/read", params: nil, timeout: nil)
        let reading = try CodexUsageMapper.quotaWindows(from: result, observedAt: now())
        if let returnedID = reading.availability.scope.accountID { accountID = returnedID }
        return reading
    }

    public func readTokenActivity() async throws -> UsageReading<TokenActivity> {
        let result = try await transport.request(method: "account/usage/read", params: nil, timeout: nil)
        return try CodexUsageMapper.tokenActivity(from: result, accountID: accountID, observedAt: now())
    }

    /// Reads all capabilities without letting an unsupported or failed method abort the snapshot.
    public func collect() async throws -> UsageSnapshot {
        let account = try await capture { try await readAccount() }
        let quota = try await capture { try await readQuotaWindows() }
        let tokens = try await capture { try await readTokenActivity() }
        return UsageSnapshot(account: account, quotaWindows: quota, tokenActivity: tokens)
    }

    private func capture<Value: Codable & Equatable & Sendable>(
        _ read: () async throws -> UsageReading<Value>
    ) async throws -> UsageReading<Value> {
        try Task.checkCancellation()
        do { return try await read() }
        catch {
            try Task.checkCancellation()
            let status: AvailabilityStatus
            if case AppServerTransportError.serverError(code: -32601) = error {
                status = .unsupported
            } else {
                status = .unavailable(reason: "Codex account data could not be read.")
            }
            return UsageReading(
                availability: SourceAvailability(
                    status: status,
                    source: .codexAccountAPI,
                    scope: UsageScope(accountID: accountID),
                    observedAt: now()
                ),
                value: nil
            )
        }
    }
}
