import Foundation
import Testing
@testable import AgentUsageCore

struct UsageModelsTests {
    private let observedAt = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func syntheticFixturesPopulateCoreModels() throws {
        let account = try CodexUsageMapper.account(from: fixture("account-read"), observedAt: observedAt)
        #expect(account.availability.status == .available)
        #expect(account.value?.value.accountID == "account-example")
        #expect(account.value?.value.planType == "plus")
        #expect(account.value?.source == .codexAccountAPI)
        #expect(account.value?.scope.accountID == "account-example")
        #expect(account.value?.observedAt == observedAt)

        let quota = try CodexUsageMapper.quotaWindows(from: fixture("account-rate-limits"), observedAt: observedAt)
        #expect(quota.availability.status == .available)
        #expect(quota.value?.count == 2) // The legacy view is not counted twice.
        #expect(quota.value?.map(\.value.kind) == [.primary, .secondary])
        #expect(quota.value?.map(\.value.usedPercent) == [25, 40])
        #expect(quota.value?.first?.value.resetsAt == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(quota.value?.allSatisfy { $0.scope.accountID == "account-example" && $0.observedAt == observedAt } == true)

        let tokens = try CodexUsageMapper.tokenActivity(
            from: fixture("account-usage"), accountID: account.value?.value.accountID, observedAt: observedAt
        )
        #expect(tokens.availability.status == .available)
        #expect(tokens.value?.summary?.value.lifetimeTokens == 100_000)
        #expect(tokens.value?.dailyUsage.first?.value.tokens == 1_000)
        #expect(tokens.value?.dailyUsage.first?.scope.accountID == "account-example")
        #expect(tokens.value?.dailyUsage.first?.observedAt == observedAt)
    }

    @Test func missingDataIsUnavailableRatherThanZero() throws {
        let quota = try CodexUsageMapper.quotaWindows(from: Data("{}".utf8), observedAt: observedAt)
        #expect(quota.value == nil)
        #expect(quota.availability.status == .unavailable(reason: "No quota windows were returned."))
        #expect(quota.availability.observedAt == observedAt)

        let tokens = try CodexUsageMapper.tokenActivity(from: Data("{}".utf8), accountID: nil, observedAt: observedAt)
        #expect(tokens.value == nil)
        #expect(tokens.availability.status == .unavailable(reason: "No token activity was returned."))
    }

    private func fixture(_ name: String) throws -> Data {
        TestFixtures.data(name)
    }
}

/// Synthetic app-server responses kept in tracked test source for clean CI checkouts.
enum TestFixtures {
    static func data(_ name: String) -> Data {
        let json: String
        switch name {
        case "account-read":
            json = #"""
                {"account":{"type":"chatgpt","email":"example@example.invalid","planType":"plus"},
                 "workspaceRouting":{"chatgptAccountId":"account-example"}}
                """#
        case "account-rate-limits":
            json = #"""
                {"accountId":"account-example",
                 "rateLimits":{"limitId":"codex",
                               "primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1893456000},
                               "secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1893974400}},
                 "rateLimitsByLimitId":{"codex":{
                    "limitId":"codex",
                    "primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1893456000},
                    "secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1893974400}}}}
                """#
        case "account-usage":
            json = #"""
                {"summary":{"lifetimeTokens":100000,"peakDailyTokens":5000},
                 "dailyUsageBuckets":[{"startDate":"2026-01-01","tokens":1000}]}
                """#
        default:
            preconditionFailure("Unknown test fixture: \(name)")
        }
        return Data(json.utf8)
    }
}
