import Foundation
import Testing
@testable import AgentUsageCore

struct CodexSetupTests {
    @Test func findsCodexWithoutShellPath() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".local/bin/codex")
        try makeExecutable(at: executable, body: "echo 'Logged in using ChatGPT'")

        let locator = CodexExecutableLocator(environment: ["PATH": ""], userHomeURL: root)
        #expect(locator.locate().url == executable)
        #expect(locator.locate(override: root.appendingPathComponent("missing").path).invalidOverride)
        #expect(locator.locate(override: "relative/codex").invalidOverride)
    }

    @Test func respectsConfiguredCodexHomeAndDetectsSignIn() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".local/bin/codex")
        try makeExecutable(at: executable, body: "if [ -f \"$CODEX_HOME/signed-in\" ]; then echo 'Logged in using ChatGPT'; else echo 'Not logged in' >&2; fi")
        let configuredHome = root.appendingPathComponent("custom-codex-home")
        try FileManager.default.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        try Data().write(to: configuredHome.appendingPathComponent("signed-in"))

        let locator = CodexExecutableLocator(
            environment: ["PATH": "", "CODEX_HOME": configuredHome.path], userHomeURL: root
        )
        let checker = CodexSetupChecker(locator: locator)
        let ready = await checker.check()
        #expect(ready.status == .ready)
        #expect(ready.codexHomeURL.pathComponents == configuredHome.pathComponents)
        #expect(ready.executableURL == executable)

        let unsignedHome = root.appendingPathComponent("unsigned-home")
        try FileManager.default.createDirectory(at: unsignedHome, withIntermediateDirectories: true)
        let missing = await checker.check(configuration: CodexSetupConfiguration(homeOverride: unsignedHome.path))
        #expect(missing.status == .missingSignIn)
        #expect(missing.codexHomeURL.pathComponents == unsignedHome.pathComponents)

        let absentHome = root.appendingPathComponent("absent-home")
        let invalid = await checker.check(configuration: CodexSetupConfiguration(homeOverride: absentHome.path))
        #expect(invalid.status == .invalidHomeDirectory)
    }

    @Test func distinguishesUnsupportedAuthenticationAndMissingInstallation() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = CodexExecutableLocator(environment: ["PATH": ""], userHomeURL: root)
        let checker = CodexSetupChecker(locator: locator)
        #expect(await checker.check().status == .missingInstallation)

        let executable = root.appendingPathComponent("codex-api-key")
        try makeExecutable(at: executable, body: "echo 'Logged in using an API key'")
        let result = await checker.check(configuration: CodexSetupConfiguration(executableOverride: executable.path))
        #expect(result.status == .unsupportedAuthentication)
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(at url: URL, body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
