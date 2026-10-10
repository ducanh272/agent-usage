import Foundation

/// The system that supplied a reading, independent of how it was transported.
public enum UsageSource: String, Codable, Sendable {
    case codexAccountAPI
}

/// An account ID is optional until the provider has identified the signed-in account.
public struct UsageScope: Codable, Equatable, Sendable {
    public let accountID: String?

    public init(accountID: String?) {
        self.accountID = accountID
    }
}

public struct UsageMetric<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let source: UsageSource
    public let scope: UsageScope
    public let observedAt: Date

    public init(value: Value, source: UsageSource, scope: UsageScope, observedAt: Date) {
        self.value = value
        self.source = source
        self.scope = scope
        self.observedAt = observedAt
    }
}

public enum AvailabilityStatus: Codable, Equatable, Sendable {
    case available
    case unsupported
    case unavailable(reason: String)
}

/// Availability has its own provenance so missing data is never mistaken for zero.
public struct SourceAvailability: Codable, Equatable, Sendable {
    public let status: AvailabilityStatus
    public let source: UsageSource
    public let scope: UsageScope
    public let observedAt: Date

    public init(status: AvailabilityStatus, source: UsageSource, scope: UsageScope, observedAt: Date) {
        self.status = status
        self.source = source
        self.scope = scope
        self.observedAt = observedAt
    }
}

public struct UsageReading<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let availability: SourceAvailability
    public let value: Value?

    public init(availability: SourceAvailability, value: Value?) {
        self.availability = availability
        self.value = value
    }
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public let accountID: String?
    public let email: String?
    public let planType: String?

    public init(accountID: String?, email: String?, planType: String?) {
        self.accountID = accountID
        self.email = email
        self.planType = planType
    }
}

/// A provider's quota window. A reset time is a timestamp, not a promise of replenishment.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case primary
        case secondary
    }

    public let limitID: String
    public let kind: Kind
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(limitID: String, kind: Kind, usedPercent: Double, durationMinutes: Int?, resetsAt: Date?) {
        self.limitID = limitID
        self.kind = kind
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }
}

public struct TokenSummary: Codable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?

    public init(lifetimeTokens: Int64?, peakDailyTokens: Int64?) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
    }
}

public struct DailyTokenUsage: Codable, Equatable, Sendable {
    /// The provider's calendar date, kept as a date string to avoid timezone changes.
    public let date: String
    public let tokens: Int64

    public init(date: String, tokens: Int64) {
        self.date = date
        self.tokens = tokens
    }
}

public struct TokenActivity: Codable, Equatable, Sendable {
    public let summary: UsageMetric<TokenSummary>?
    public let dailyUsage: [UsageMetric<DailyTokenUsage>]

    public init(summary: UsageMetric<TokenSummary>?, dailyUsage: [UsageMetric<DailyTokenUsage>]) {
        self.summary = summary
        self.dailyUsage = dailyUsage
    }
}

/// Each capability can be read and fail independently.
public protocol UsageProvider: Sendable {
    func readAccount() async throws -> UsageReading<UsageMetric<AccountIdentity>>
    func readQuotaWindows() async throws -> UsageReading<[UsageMetric<QuotaWindow>]>
    func readTokenActivity() async throws -> UsageReading<TokenActivity>
}
