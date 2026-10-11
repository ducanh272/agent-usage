import CryptoKit
import Foundation

public struct QuotaAlert: Equatable, Sendable {
    public let identifier: String
    public let limitID: String
    public let kind: QuotaWindow.Kind
    public let threshold: Int
    public let remainingPercent: Int
}

/// Records alerts by account, quota window reset, and threshold without storing account IDs.
public struct QuotaAlertLedger: Codable, Equatable, Sendable {
    private var sentIdentifiers: Set<String>

    public init() { sentIdentifiers = [] }

    public mutating func newAlerts(for state: UsageRefreshState, at date: Date) -> [QuotaAlert] {
        guard !state.isCached, !state.isRefreshing, !state.isQuotaStale(at: date),
              state.failure == nil,
              let accountID = state.snapshot?.account.value?.value.accountID, !accountID.isEmpty,
              let reading = state.snapshot?.quotaWindows,
              reading.availability.status == .available,
              let windows = reading.value,
              reading.availability.scope.accountID == nil ||
                reading.availability.scope.accountID == accountID else { return [] }

        var alerts: [QuotaAlert] = []
        for metric in windows {
            guard metric.scope.accountID == accountID,
                  metric.value.usedPercent.isFinite else { continue }
            if let reset = metric.value.resetsAt, reset <= date { continue }
            let remaining = max(0, min(100, 100 - metric.value.usedPercent))
            guard remaining <= 20 else { continue }
            // Without a reset timestamp, the window cannot be split into cycles.
            // Keep one stable key rather than alerting on every refresh.
            let cycle = metric.value.resetsAt.map { String($0.timeIntervalSince1970) } ?? "unknown"
            let key = "\(accountID)\u{0}\(metric.value.limitID)\u{0}\(metric.value.kind.rawValue)\u{0}\(cycle)"
            let twentyID = Self.identifier(for: key, threshold: 20)
            let fiveID = Self.identifier(for: key, threshold: 5)
            if remaining <= 5 {
                sentIdentifiers.insert(twentyID)
                if sentIdentifiers.insert(fiveID).inserted {
                    alerts.append(QuotaAlert(identifier: fiveID, limitID: metric.value.limitID,
                                             kind: metric.value.kind, threshold: 5,
                                             remainingPercent: Int(remaining.rounded())))
                }
            } else if sentIdentifiers.insert(twentyID).inserted {
                alerts.append(QuotaAlert(identifier: twentyID, limitID: metric.value.limitID,
                                         kind: metric.value.kind, threshold: 20,
                                         remainingPercent: Int(remaining.rounded())))
            }
        }
        return alerts
    }

    private static func identifier(for key: String, threshold: Int) -> String {
        SHA256.hash(data: Data("\(key)\u{0}\(threshold)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
