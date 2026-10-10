import Foundation
import Testing
@testable import AgentUsageCore

struct CodexUsageProviderTests {
    private let observedAt = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func unsupportedTokenHistoryDoesNotHideQuota() async throws {
        let server = MockAccountServer(responses: [
            "account/read": .success(try fixture("account-read")),
            "account/rateLimits/read": .success(try fixture("account-rate-limits")),
            "account/usage/read": .failure(.serverError(code: -32601))
        ])
        let provider = CodexUsageProvider(transport: server, now: { observedAt })
        let snapshot = try await provider.collect()

        #expect(snapshot.account.value?.value.accountID == "account-example")
        #expect(snapshot.quotaWindows.availability.status == .available)
        #expect(snapshot.quotaWindows.value?.count == 2)
        #expect(snapshot.quotaWindows.value?.map(\.value.usedPercent) == [25, 40])
        #expect(snapshot.quotaWindows.value?.map(\.value.durationMinutes) == [300, 10_080])
        #expect(snapshot.quotaWindows.value?.first?.value.resetsAt == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(snapshot.tokenActivity.availability.status == .unsupported)
        #expect(snapshot.tokenActivity.value == nil)
        #expect(snapshot.tokenActivity.availability.scope.accountID == "account-example")
        #expect(snapshot.tokenActivity.availability.observedAt == observedAt)

        let calls = await server.calls
        #expect(calls.map(\.method) == ["account/read", "account/rateLimits/read", "account/usage/read"])
        let accountParams = try #require(calls.first?.params)
        let object = try #require(JSONSerialization.jsonObject(with: accountParams) as? [String: Bool])
        #expect(object["refreshToken"] == false)
        #expect(calls.dropFirst().allSatisfy { $0.params == nil })
    }

    @Test func failedAccountReadStillAllowsQuotaAndTokens() async throws {
        let server = MockAccountServer(responses: [
            "account/read": .failure(.serverError(code: -32000)),
            "account/rateLimits/read": .success(try fixture("account-rate-limits")),
            "account/usage/read": .success(try fixture("account-usage"))
        ])
        let provider = CodexUsageProvider(transport: server, now: { observedAt })
        let snapshot = try await provider.collect()

        #expect(snapshot.account.value == nil)
        #expect(snapshot.account.availability.status == .unavailable(reason: "Codex account data could not be read."))
        #expect(snapshot.quotaWindows.availability.status == .available)
        #expect(snapshot.tokenActivity.availability.status == .available)
        #expect(snapshot.tokenActivity.value?.summary?.value.lifetimeTokens == 100_000)
        #expect(snapshot.tokenActivity.value?.summary?.scope.accountID == "account-example")
        #expect(snapshot.tokenActivity.value?.dailyUsage.first?.scope.accountID == "account-example")
    }

    @Test func emptyTokenResponseIsUnavailableWithoutChangingQuota() async throws {
        let server = MockAccountServer(responses: [
            "account/read": .success(try fixture("account-read")),
            "account/rateLimits/read": .success(try fixture("account-rate-limits")),
            "account/usage/read": .success(Data("{}".utf8))
        ])
        let snapshot = try await CodexUsageProvider(transport: server, now: { observedAt }).collect()
        #expect(snapshot.quotaWindows.value?.count == 2)
        #expect(snapshot.tokenActivity.availability.status == .unavailable(reason: "No token activity was returned."))
    }

    private func fixture(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: directory.appendingPathComponent("docs/fixtures/\(name).json"))
    }
}

private actor MockAccountServer: AppServerRequesting {
    struct Call: Sendable {
        let method: String
        let params: Data?
    }

    let responses: [String: Result<Data, AppServerTransportError>]
    private(set) var calls: [Call] = []

    init(responses: [String: Result<Data, AppServerTransportError>]) {
        self.responses = responses
    }

    func request(method: String, params: Data?, timeout: Duration?) async throws -> Data {
        calls.append(Call(method: method, params: params))
        guard let result = responses[method] else { throw AppServerTransportError.serverError(code: -32601) }
        return try result.get()
    }
}
