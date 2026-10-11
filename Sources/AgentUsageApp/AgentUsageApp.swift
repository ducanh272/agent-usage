import AgentUsageCore
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @StateObject private var usage = UsageRefreshController()

    var body: some Scene {
        MenuBarExtra(AppInfo.displayName, systemImage: "chart.bar") {
            CodexSetupPanel(usage: usage)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CodexSetupPanel: View {
    @ObservedObject var usage: UsageRefreshController
    @State private var result: CodexSetupResult?
    @State private var showAdvancedSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInfo.displayName).font(.headline)
            Text(statusMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if result?.status == .ready || usage.state?.isCached == true {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(usageMessage(at: context.date))
                        .foregroundStyle(.secondary)
                }
                if let snapshot = usage.state?.snapshot {
                    cachedValues(snapshot)
                }
                if result?.status == .ready {
                    Button("Refresh usage") { Task { await usage.refresh() } }
                }
            }
            if let storageError = usage.storageError {
                Text(storageError).foregroundStyle(.red)
            }

            DisclosureGroup("Advanced setup", isExpanded: $showAdvancedSetup) {
                VStack(alignment: .leading, spacing: 10) {
                    if let executable = result?.executableURL {
                        LabeledContent("Codex", value: executable.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Codex home", value: result?.codexHomeURL.path ?? "Checking…")
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack {
                        Button("Choose Codex…", action: chooseExecutable)
                        if !usage.settings.codexExecutablePath.isEmpty {
                            Button("Use Automatic") { Task { await usage.setExecutablePath("") } }
                        }
                    }
                    HStack {
                        Button("Choose Home…", action: chooseHome)
                        if !usage.settings.codexHomePath.isEmpty {
                            Button("Use Default Home") { Task { await usage.setHomePath("") } }
                        }
                    }
                }
                .padding(.top, 6)
            }
            HStack {
                Button("Recheck") { Task { await checkSetup() } }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(minWidth: 360, alignment: .leading)
        .task(id: setupKey) {
            if usage.settingsLoaded { await checkSetup() }
        }
        .onAppear { Task { await usage.panelOpened() } }
    }

    private var setupKey: String {
        "\(usage.settingsLoaded)\u{0}\(usage.settings.codexExecutablePath)\u{0}\(usage.settings.codexHomePath)"
    }

    private func usageMessage(at date: Date) -> String {
        guard let state = usage.state else { return "Starting usage refresh…" }
        if let refreshed = state.lastSuccessfulRefresh {
            let time = refreshed.formatted(date: .abbreviated, time: .shortened)
            let stale = state.isStale || date < refreshed || date.timeIntervalSince(refreshed) >= 600
            if state.isCached {
                return stale ? "Cached from \(time) · stale" : "Cached from \(time) · awaiting refresh"
            }
            if state.isRefreshing { return "Refreshing usage · last updated \(time)" }
            if state.consecutiveFailures > 0 { return "Last updated \(time) · refresh failed; retrying" }
            return stale ? "Last updated \(time) · stale" : "Usage updated \(time)"
        }
        if state.isRefreshing { return "Refreshing usage…" }
        return state.consecutiveFailures == 0 ? "Waiting for usage data…" : "Usage refresh failed; retrying."
    }

    @ViewBuilder
    private func cachedValues(_ snapshot: UsageSnapshot) -> some View {
        if let email = snapshot.account.value?.value.email {
            Text(email).font(.caption).foregroundStyle(.secondary)
        }
        if let windows = snapshot.quotaWindows.value {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, metric in
                let remaining = max(0, 100 - metric.value.usedPercent)
                Text("\(metric.value.limitID) \(metric.value.kind.rawValue): \(remaining.formatted(.number.precision(.fractionLength(0))))% remaining")
                    .font(.caption)
            }
        }
        if let tokens = snapshot.tokenActivity.value?.summary?.value.lifetimeTokens {
            Text("Lifetime tokens: \(tokens.formatted())").font(.caption)
        }
    }

    private var statusMessage: String {
        switch result?.status {
        case .ready:
            return "Codex is signed in with ChatGPT."
        case .missingInstallation:
            return "Codex CLI was not found. Install it or choose its executable."
        case .invalidExecutableOverride:
            return "The selected Codex path is not an executable. Choose another file or use automatic discovery."
        case .invalidHomeDirectory:
            return "The Codex home directory does not exist. Choose an existing directory or use the default."
        case .missingSignIn:
            return "Codex is not signed in. Run `codex login` in Terminal, then recheck."
        case .unsupportedAuthentication:
            return "Codex uses an unsupported sign-in method. Sign in with ChatGPT using `codex login`."
        case .unableToCheckLogin:
            return "Could not check Codex sign-in. Run `codex login status` in Terminal and verify the selected executable and home."
        case nil:
            return "Checking Codex setup…"
        }
    }

    private func checkSetup() async {
        let configuration = CodexSetupConfiguration(
            executableOverride: usage.settings.codexExecutablePath.isEmpty ? nil : usage.settings.codexExecutablePath,
            homeOverride: usage.settings.codexHomePath.isEmpty ? nil : usage.settings.codexHomePath
        )
        let checked = await CodexSetupChecker().check(configuration: configuration)
        guard !Task.isCancelled else { return }
        result = checked
        await usage.configure(for: checked)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Codex executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { Task { await usage.setExecutablePath(url.path) } }
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Codex home directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { Task { await usage.setHomePath(url.path) } }
    }
}
