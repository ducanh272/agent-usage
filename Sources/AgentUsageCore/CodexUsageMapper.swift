import Foundation

/// Converts account API response bodies into provider-neutral core models.
public enum CodexUsageMapper {
    public static func account(from data: Data, observedAt: Date) throws -> UsageReading<UsageMetric<AccountIdentity>> {
        let response = try JSONDecoder().decode(AccountResponse.self, from: data)
        let accountID = response.workspaceRouting?.chatgptAccountId
        let scope = UsageScope(accountID: accountID)
        guard let account = response.account else {
            return reading(nil, status: .unavailable(reason: "No account is signed in."), scope: scope, at: observedAt)
        }
        let identity = AccountIdentity(accountID: accountID, email: account.email, planType: account.planType)
        return reading(metric(identity, scope: scope, at: observedAt), status: .available, scope: scope, at: observedAt)
    }

    public static func quotaWindows(from data: Data, observedAt: Date) throws -> UsageReading<[UsageMetric<QuotaWindow>]> {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        let scope = UsageScope(accountID: response.accountId)
        // The legacy rateLimits field mirrors a bucket in rateLimitsByLimitId.
        let limits: [RateLimit]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            limits = byID.keys.sorted().compactMap { byID[$0] }
        } else {
            limits = response.rateLimits.map { [$0] } ?? []
        }
        var windows: [UsageMetric<QuotaWindow>] = []
        for limit in limits {
            for (kind, window) in [(QuotaWindow.Kind.primary, limit.primary), (.secondary, limit.secondary)] {
                guard let window, let usedPercent = window.usedPercent else { continue }
                let value = QuotaWindow(
                    limitID: limit.limitId,
                    kind: kind,
                    usedPercent: usedPercent,
                    durationMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
                )
                windows.append(metric(value, scope: scope, at: observedAt))
            }
        }
        let status: AvailabilityStatus = windows.isEmpty ? .unavailable(reason: "No quota windows were returned.") : .available
        return reading(windows.isEmpty ? nil : windows, status: status, scope: scope, at: observedAt)
    }

    public static func tokenActivity(from data: Data, accountID: String?, observedAt: Date) throws -> UsageReading<TokenActivity> {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let scope = UsageScope(accountID: accountID)
        let summary: UsageMetric<TokenSummary>?
        if let raw = response.summary, raw.lifetimeTokens != nil || raw.peakDailyTokens != nil {
            summary = metric(TokenSummary(lifetimeTokens: raw.lifetimeTokens, peakDailyTokens: raw.peakDailyTokens), scope: scope, at: observedAt)
        } else {
            summary = nil
        }
        let buckets = (response.dailyUsageBuckets ?? []).compactMap { bucket -> UsageMetric<DailyTokenUsage>? in
            guard let date = bucket.startDate, let tokens = bucket.tokens else { return nil }
            return metric(DailyTokenUsage(date: date, tokens: tokens), scope: scope, at: observedAt)
        }
        guard summary != nil || !buckets.isEmpty else {
            return reading(nil, status: .unavailable(reason: "No token activity was returned."), scope: scope, at: observedAt)
        }
        return reading(TokenActivity(summary: summary, dailyUsage: buckets), status: .available, scope: scope, at: observedAt)
    }

    private static func metric<Value>(_ value: Value, scope: UsageScope, at date: Date) -> UsageMetric<Value> {
        UsageMetric(value: value, source: .codexAccountAPI, scope: scope, observedAt: date)
    }

    private static func reading<Value>(_ value: Value?, status: AvailabilityStatus, scope: UsageScope, at date: Date) -> UsageReading<Value> {
        UsageReading(
            availability: SourceAvailability(status: status, source: .codexAccountAPI, scope: scope, observedAt: date),
            value: value
        )
    }
}

private struct AccountResponse: Decodable {
    struct Account: Decodable {
        let email: String?
        let planType: String?
    }
    struct WorkspaceRouting: Decodable {
        let chatgptAccountId: String?
    }
    let account: Account?
    let workspaceRouting: WorkspaceRouting?
}

private struct RateLimitsResponse: Decodable {
    let accountId: String?
    let rateLimits: RateLimit?
    let rateLimitsByLimitId: [String: RateLimit]?
}

private struct RateLimit: Decodable {
    let limitId: String
    let primary: RawQuotaWindow?
    let secondary: RawQuotaWindow?
}

private struct RawQuotaWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}

private struct UsageResponse: Decodable {
    struct Summary: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
    }
    struct Bucket: Decodable {
        let startDate: String?
        let tokens: Int64?
    }
    let summary: Summary?
    let dailyUsageBuckets: [Bucket]?
}
