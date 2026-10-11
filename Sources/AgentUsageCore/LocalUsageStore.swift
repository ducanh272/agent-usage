import CryptoKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var codexExecutablePath: String
    public var codexHomePath: String
    public var lastAccountID: String?
    public var menuBarDisplayMode: MenuBarDisplayMode

    public init(codexExecutablePath: String = "", codexHomePath: String = "",
                lastAccountID: String? = nil, menuBarDisplayMode: MenuBarDisplayMode = .iconAndPercentage) {
        self.codexExecutablePath = codexExecutablePath
        self.codexHomePath = codexHomePath
        self.lastAccountID = lastAccountID
        self.menuBarDisplayMode = menuBarDisplayMode
    }

    private enum CodingKeys: String, CodingKey {
        case codexExecutablePath, codexHomePath, lastAccountID, menuBarDisplayMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codexExecutablePath = try values.decodeIfPresent(String.self, forKey: .codexExecutablePath) ?? ""
        codexHomePath = try values.decodeIfPresent(String.self, forKey: .codexHomePath) ?? ""
        lastAccountID = try values.decodeIfPresent(String.self, forKey: .lastAccountID)
        menuBarDisplayMode = try values.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)
            ?? .iconAndPercentage
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
        return try decoder.decode(AppSettings.self, from: Data(contentsOf: url))
    }

    public func updateSettings(executablePath: String, homePath: String) throws -> AppSettings {
        var settings = try loadSettings()
        settings.codexExecutablePath = executablePath
        settings.codexHomePath = homePath
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
    }

    public func updateMenuBarDisplayMode(_ mode: MenuBarDisplayMode) throws -> AppSettings {
        var settings = try loadSettings()
        settings.menuBarDisplayMode = mode
        try write(settings, to: directory.appendingPathComponent("settings.json"))
        return settings
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
