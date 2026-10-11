import AgentUsageCore
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @StateObject private var usage = UsageRefreshController()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(usage: usage)
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let presentation = MenuBarPresentation.make(
                    state: usage.state, mode: usage.settings.menuBarDisplayMode, at: context.date
                )
                HStack(spacing: 3) {
                    Image(systemName: "chart.bar")
                    if let text = presentation.text { Text(text).monospacedDigit() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct UsagePanel: View {
    @ObservedObject var usage: UsageRefreshController
    @State private var setup: CodexSetupResult?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppInfo.displayName).font(.headline)
                Spacer()
                if usage.state?.isRefreshing == true {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        content(at: context.date)
                    }
                    if let error = usage.storageError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if showSettings { settingsContent }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 600)
            Divider()
            HStack {
                Button("Refresh") { Task { await usage.refresh() } }
                    .disabled(setup?.status != .ready || usage.state?.isRefreshing == true)
                Button("Settings") { showSettings.toggle() }
                    .accessibilityLabel(showSettings ? "Hide settings" : "Show settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .task(id: setupKey) { if usage.settingsLoaded { await checkSetup() } }
        .onAppear { Task { await usage.panelOpened() } }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let state = usage.state
        let disconnected = setup?.status != .ready
        if disconnected {
            Label(statusMessage, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let snapshot = state?.snapshot {
            if let identity = snapshot.account.value?.value {
                HStack(spacing: 4) {
                    Text(identity.email ?? "Codex account").fontWeight(.medium)
                    if let plan = identity.planType {
                        Text("· \(plan.capitalized)").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline).lineLimit(1)
            }
            if disconnected || isStale(state, at: date) || state?.isCached == true {
                Label(disconnected ? "Saved reading · disconnected" :
                        isStale(state, at: date) ? "Saved reading · stale" : "Saved reading · awaiting refresh",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            } else if (state?.consecutiveFailures ?? 0) > 0 {
                Label("Refresh failed · showing last reading", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            quotaContent(snapshot.quotaWindows, at: date)
            tokenContent(snapshot.tokenActivity)
        } else if state?.isRefreshing == true {
            Text("Loading account usage…").foregroundStyle(.secondary)
        } else if disconnected {
            Text("Connect Codex to view usage. Open Settings to change its location.")
                .font(.caption).foregroundStyle(.secondary)
        } else if (state?.consecutiveFailures ?? 0) > 0 {
            Text("Usage could not be loaded. Try Refresh or check sign-in in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Waiting for account usage…").foregroundStyle(.secondary)
        }
        if let updated = state?.lastSuccessfulRefresh {
            Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func quotaContent(_ reading: UsageReading<[UsageMetric<QuotaWindow>]>, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Quota").font(.subheadline).fontWeight(.semibold)
            if let windows = reading.value, !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, metric in
                    let window = metric.value
                    if window.usedPercent.isFinite {
                        let remaining = max(0, min(100, 100 - window.usedPercent))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(windowTitle(window))
                                Spacer()
                                Text("\(remaining.formatted(.number.precision(.fractionLength(0))))% remaining")
                                    .fontWeight(.medium)
                            }
                            .font(.caption)
                            ProgressView(value: remaining, total: 100)
                                .accessibilityLabel("\(windowTitle(window)) quota")
                                .accessibilityValue("\(remaining.formatted(.number.precision(.fractionLength(0)))) percent remaining")
                            if let reset = window.resetsAt {
                                Text(resetLabel(reset, at: date)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("\(windowTitle(window)) quota unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(availabilityMessage(reading.availability.status, metric: "Quota"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tokenContent(_ reading: UsageReading<TokenActivity>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account token activity").font(.subheadline).fontWeight(.semibold)
            if let activity = reading.value {
                if let summary = activity.summary?.value {
                    if let lifetime = summary.lifetimeTokens {
                        LabeledContent("Lifetime", value: lifetime.formatted())
                    }
                    if let peak = summary.peakDailyTokens {
                        LabeledContent("Peak day", value: peak.formatted())
                    }
                }
                ForEach(Array(activity.dailyUsage.sorted { $0.value.date > $1.value.date }.prefix(5)), id: \.value.date) { metric in
                    LabeledContent(metric.value.date, value: metric.value.tokens.formatted())
                }
            } else {
                Text(availabilityMessage(reading.availability.status, metric: "Token activity"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("Codex settings").font(.subheadline).fontWeight(.semibold)
            Picker("Menu bar", selection: Binding(
                get: { usage.settings.menuBarDisplayMode },
                set: { mode in Task { await usage.setMenuBarDisplayMode(mode) } }
            )) {
                Text("Icon and percentage").tag(MenuBarDisplayMode.iconAndPercentage)
                Text("Icon only").tag(MenuBarDisplayMode.iconOnly)
            }
            if let executable = setup?.executableURL {
                LabeledContent("Executable", value: executable.path).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Home", value: setup?.codexHomeURL.path ?? "Checking…")
                .lineLimit(1).truncationMode(.middle)
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
            Button("Recheck sign-in") { Task { await checkSetup() } }
        }
        .font(.caption)
    }

    private var setupKey: String {
        "\(usage.settingsLoaded)\u{0}\(usage.settings.codexExecutablePath)\u{0}\(usage.settings.codexHomePath)"
    }

    private func isStale(_ state: UsageRefreshState?, at date: Date) -> Bool {
        guard let refreshed = state?.lastSuccessfulRefresh else { return true }
        return date < refreshed || date.timeIntervalSince(refreshed) >= 600
    }

    private func windowTitle(_ window: QuotaWindow) -> String {
        let kind = window.kind == .primary ? "Primary" : "Secondary"
        guard let minutes = window.durationMinutes else { return "\(window.limitID) · \(kind)" }
        let duration = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return "\(window.limitID) · \(kind) · \(duration)"
    }

    private func resetLabel(_ reset: Date, at date: Date) -> String {
        let absolute = reset.formatted(date: .abbreviated, time: .shortened)
        let seconds = reset.timeIntervalSince(date)
        guard seconds > 0 else { return "Reset time passed · awaiting refresh (\(absolute))" }
        let minutes = Int(ceil(seconds / 60))
        let countdown = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return "Resets in \(countdown) · \(absolute)"
    }

    private func availabilityMessage(_ status: AvailabilityStatus, metric: String) -> String {
        switch status {
        case .available: return "\(metric) is unavailable."
        case .unsupported: return "\(metric) is not supported by this Codex version."
        case .unavailable(let reason): return "\(metric) unavailable: \(reason)"
        }
    }

    private var statusMessage: String {
        switch setup?.status {
        case .ready: return "Codex is signed in with ChatGPT."
        case .missingInstallation: return "Codex CLI was not found. Install it or choose its executable in Settings."
        case .invalidExecutableOverride: return "The selected Codex path is not executable. Choose another file in Settings."
        case .invalidHomeDirectory: return "The Codex home directory does not exist. Choose another directory in Settings."
        case .missingSignIn: return "Codex is not signed in. Run `codex login` in Terminal, then recheck."
        case .unsupportedAuthentication: return "Sign in with ChatGPT using `codex login`, then recheck."
        case .unableToCheckLogin: return "Could not check sign-in. Run `codex login status` in Terminal and verify Settings."
        case nil: return "Checking Codex setup…"
        }
    }

    private func checkSetup() async {
        let configuration = CodexSetupConfiguration(
            executableOverride: usage.settings.codexExecutablePath.isEmpty ? nil : usage.settings.codexExecutablePath,
            homeOverride: usage.settings.codexHomePath.isEmpty ? nil : usage.settings.codexHomePath
        )
        let checked = await CodexSetupChecker().check(configuration: configuration)
        guard !Task.isCancelled else { return }
        setup = checked
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
