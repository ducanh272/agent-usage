import CryptoKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var lastAccountID: String?
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var notificationsEnabled: Bool
    public var refreshInterval: RefreshInterval

    public init(lastAccountID: String? = nil, menuBarDisplayMode: MenuBarDisplayMode = .iconAndPercentage,
                notificationsEnabled: Bool = false, refreshInterval: RefreshInterval = .fiveMinutes) {
        self.lastAccountID = lastAccountID
        self.menuBarDisplayMode = menuBarDisplayMode
        self.notificationsEnabled = notificationsEnabled
        self.refreshInterval = refreshInterval
    }

    private enum CodingKeys: String, CodingKey {
        case lastAccountID, menuBarDisplayMode, notificationsEnabled, refreshInterval
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastAccountID = try? values.decode(String.self, forKey: .lastAccountID)
        menuBarDisplayMode = (try? values.decode(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode))
            ?? .iconAndPercentage
        notificationsEnabled = (try? values.decode(Bool.self, forKey: .notificationsEnabled)) ?? false
        refreshInterval = (try? values.decode(RefreshInterval.self, forKey: .refreshInterval))
            ?? .fiveMinutes
    }
}

public struct CachedUsageSnapshot: Codable, Equatable, Sendable {
    public let accountID: String
    public let snapshot: UsageSnapshot
    public let savedAt: Date

    public init(accountID: String, snapshot: UsageSnapshot, savedAt: Date) {
        self.accountID = accountID
        self.snapshot = snapshot
        self.savedAt = savedAt
    }

    public func isStale(at date: Date = Date(), after interval: TimeInterval = 600) -> Bool {
        let age = date.timeIntervalSince(savedAt)
        return age < 0 || age >= interval
    }
}

/// Stores settings and one snapshot per identified account under Application Support.
public actor LocalUsageStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Usage", isDirectory: true)
    }

    public func loadSettings() throws -> AppSettings {
        let url = directory.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: url.path) else { return AppSettings() }
        let data = try Data(contentsOf: url)
        let settings = try decoder.decode(AppSettings.self, from: data)
        if let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           fields["codexExecutablePath"] != nil || fields["codexHomePath"] != nil {
            try write(settings, to: url)
        }
        return settings
    }

    public func updateMenuBarDisplayMode(_ mode: MenuBarDisplayMode) throws -> AppSettings {
        var settings = try loadSettings()
        settings.menuBarDisplayMode = mode
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
    }

    public func updateNotificationsEnabled(_ enabled: Bool) throws -> AppSettings {
        var settings = try loadSettings()
        settings.notificationsEnabled = enabled
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
    }

    public func updateRefreshInterval(_ interval: RefreshInterval) throws -> AppSettings {
        var settings = try loadSettings()
        settings.refreshInterval = interval
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
    }

    /// Removes only saved account readings. Preferences and alert history stay intact.
    public func clearCachedUsage() throws -> AppSettings {
        let accounts = directory.appendingPathComponent("accounts", isDirectory: true)
        if fileManager.fileExists(atPath: accounts.path) {
            try fileManager.removeItem(at: accounts)
        }
        var settings = try loadSettings()
        settings.lastAccountID = nil
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
    }

    /// Persists deduplication before callers submit notifications to the system.
    public func alertsToSend(for state: UsageRefreshState, at date: Date = Date()) throws -> [QuotaAlert] {
        let url = directory.appendingPathComponent("sent-alerts.json")
        var ledger = fileManager.fileExists(atPath: url.path)
            ? try decoder.decode(QuotaAlertLedger.self, from: Data(contentsOf: url))
            : QuotaAlertLedger()
        let alerts = ledger.newAlerts(for: state, at: date)
        if !alerts.isEmpty { try write(ledger, to: url) }
        return alerts
    }

    /// Anonymous readings are not cached because they cannot be safely assigned to an account.
    @discardableResult
    public func save(_ snapshot: UsageSnapshot, at date: Date = Date()) throws -> CachedUsageSnapshot? {
        guard let accountID = identifiedAccountID(in: snapshot) else { return nil }
        let cached = CachedUsageSnapshot(accountID: accountID, snapshot: snapshot, savedAt: date)
        try write(cached, to: snapshotURL(for: accountID))
        var settings = try loadSettings()
        settings.lastAccountID = accountID
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return cached
    }

    public func loadLatestSnapshot() throws -> CachedUsageSnapshot? {
        guard let accountID = try loadSettings().lastAccountID else { return nil }
        return try loadSnapshot(for: accountID)
    }

    public func loadSnapshot(for accountID: String) throws -> CachedUsageSnapshot? {
        let url = snapshotURL(for: accountID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let cached = try decoder.decode(CachedUsageSnapshot.self, from: Data(contentsOf: url))
        guard cached.accountID == accountID else { return nil }
        return cached
    }

    private func identifiedAccountID(in snapshot: UsageSnapshot) -> String? {
        let candidates = [
            snapshot.account.value?.value.accountID,
            snapshot.account.availability.scope.accountID,
            snapshot.quotaWindows.availability.scope.accountID,
            snapshot.tokenActivity.availability.scope.accountID
        ]
        let identities = Set(candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        return identities.count == 1 ? identities.first : nil
    }

    private func snapshotURL(for accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("\(name).json")
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if parent != directory {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
