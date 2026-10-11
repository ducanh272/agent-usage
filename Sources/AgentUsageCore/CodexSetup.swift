import Foundation

public struct CodexSetupConfiguration: Sendable {
    public var executableOverride: String?
    public var homeOverride: String?

    public init(executableOverride: String? = nil, homeOverride: String? = nil) {
        self.executableOverride = executableOverride
        self.homeOverride = homeOverride
    }
}

public enum CodexSetupStatus: Equatable, Sendable {
    case ready
    case missingInstallation
    case invalidExecutableOverride
    case invalidHomeDirectory
    case missingSignIn
    case unsupportedAuthentication
    case unableToCheckLogin
}

public struct CodexSetupResult: Equatable, Sendable {
    public let status: CodexSetupStatus
    public let executableURL: URL?
    public let codexHomeURL: URL

    public init(status: CodexSetupStatus, executableURL: URL?, codexHomeURL: URL) {
        self.status = status
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
    }
}

/// Uses the process environment but also searches locations available to Finder-launched apps.
public struct CodexExecutableLocator: Sendable {
    public let environment: [String: String]
    public let userHomeURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment
        self.userHomeURL = userHomeURL
    }

    public func codexHomeURL(override: String? = nil) -> URL {
        let selected = nonempty(override) ?? nonempty(environment["CODEX_HOME"])
        return selected.map(expandPath) ?? userHomeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    public func locate(override: String? = nil, codexHomeOverride: String? = nil) -> (url: URL?, invalidOverride: Bool) {
        if let override = nonempty(override) {
            guard override.hasPrefix("/") || override == "~" || override.hasPrefix("~/") else {
                return (nil, true)
            }
            let url = expandPath(override)
            return isExecutable(url) ? (url, false) : (nil, true)
        }

        let home = userHomeURL.path
        let codexHome = codexHomeURL(override: codexHomeOverride).path
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = pathEntries + [
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/Library/pnpm", "\(home)/.cargo/bin", "\(home)/.nix-profile/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
            "\(codexHome)/packages/standalone/current/bin"
        ]
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if isExecutable(url) { return (url, false) }
        }
        return (nil, false)
    }

    private func expandPath(_ path: String) -> URL {
        let expanded = path == "~" ? userHomeURL.path
            : path.hasPrefix("~/") ? userHomeURL.path + String(path.dropFirst()) : path
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func isExecutable(_ url: URL) -> Bool {
        url.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: url.path)
            && !FileManager.default.directoryExists(at: url)
    }

    private func nonempty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct CodexSetupChecker: Sendable {
    public let locator: CodexExecutableLocator

    public init(locator: CodexExecutableLocator = CodexExecutableLocator()) {
        self.locator = locator
    }

    public func check(configuration: CodexSetupConfiguration = CodexSetupConfiguration()) async -> CodexSetupResult {
        let home = locator.codexHomeURL(override: configuration.homeOverride)
        let location = locator.locate(override: configuration.executableOverride, codexHomeOverride: configuration.homeOverride)
        guard let executable = location.url else {
            return CodexSetupResult(
                status: location.invalidOverride ? .invalidExecutableOverride : .missingInstallation,
                executableURL: nil, codexHomeURL: home
            )
        }
        guard FileManager.default.directoryExists(at: home) else {
            return CodexSetupResult(status: .invalidHomeDirectory, executableURL: executable, codexHomeURL: home)
        }
        let environment = locator.environment.merging(["CODEX_HOME": home.path]) { _, selected in selected }
        let status = await Task.detached(priority: .utility) {
            Self.loginStatus(executable: executable, environment: environment)
        }.value
        return CodexSetupResult(status: status, executableURL: executable, codexHomeURL: home)
    }

    private static func loginStatus(executable: URL, environment: [String: String]) -> CodexSetupStatus {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["login", "status"]
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .unableToCheckLogin }
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return .unableToCheckLogin
        }
        // Inspect status phrases only; never return or log raw CLI output.
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let statusText = text.lowercased()
        if process.terminationStatus == 0 && statusText.contains("logged in using chatgpt") { return .ready }
        if statusText.contains("not logged in") { return .missingSignIn }
        if process.terminationStatus == 0 && statusText.contains("logged in using") { return .unsupportedAuthentication }
        return .unableToCheckLogin
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
