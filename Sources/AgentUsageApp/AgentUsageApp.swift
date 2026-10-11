import AgentUsageCore
import AppKit
import Combine
import SwiftUI

@MainActor
@main
private enum AgentUsageApp {
    private static let statusBar = StatusBarController()

    static func main() {
        let app = NSApplication.shared
        app.delegate = statusBar
        app.run()
    }
}

@MainActor
private final class StatusBarController: NSObject, NSApplicationDelegate {
    private let usage = UsageRefreshController()
    private let sizing = PopoverSizing()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        statusItem = item
        guard let button = item.button else { return }
        let icon = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: AppInfo.displayName)
        icon?.isTemplate = true
        button.image = icon
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 180)
        popover.contentViewController = NSHostingController(rootView: UsagePanel(usage: usage, sizing: sizing) { [weak self] height in
            guard let self, abs(self.popover.contentSize.height - height) >= 1 else { return }
            self.popover.contentSize = NSSize(width: 380, height: height)
        })

        usage.$state.combineLatest(usage.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, settings in
                self?.updateStatus(state: state, mode: settings.menuBarDisplayMode)
            }
            .store(in: &subscriptions)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                self.updateStatus(state: self.usage.state, mode: self.usage.settings.menuBarDisplayMode, at: date)
            }
            .store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMaximumHeight() }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateMaximumHeight()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateMaximumHeight() {
        let availableHeight = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 640
        sizing.maximumHeight = min(600, max(180, availableHeight - 40))
    }

    private func updateStatus(state: UsageRefreshState?, mode: MenuBarDisplayMode, at date: Date = .now) {
        guard let button = statusItem?.button else { return }
        let presentation = MenuBarPresentation.make(state: state, mode: mode, at: date)
        button.title = "AU" + (presentation.text.map { " \($0)" } ?? "")
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }
}

@MainActor
private final class PopoverSizing: ObservableObject {
    @Published var maximumHeight: CGFloat = 600
}

private enum PanelRegion: Hashable {
    case header, content, footer
}

private struct PanelHeightsKey: PreferenceKey {
    static let defaultValue: [PanelRegion: CGFloat] = [:]

    static func reduce(value: inout [PanelRegion: CGFloat], nextValue: () -> [PanelRegion: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct UsagePanel: View {
    @ObservedObject var usage: UsageRefreshController
    @ObservedObject var sizing: PopoverSizing
    let onHeightChange: (CGFloat) -> Void
    @State private var setup: CodexSetupResult?
    @State private var showSettings = false
    @State private var showClearCacheConfirmation = false
    @State private var measuredHeights: [PanelRegion: CGFloat] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                measured(header(at: context.date), region: .header)
                Divider()
                ScrollView {
                    measured(middleContent(at: context.date), region: .content)
                }
                .frame(height: scrollHeight)
                Divider()
                measured(footer(at: context.date), region: .footer)
            }
            .padding(16)
            .frame(width: 380, alignment: .leading)
            .onPreferenceChange(PanelHeightsKey.self) { measuredHeights = $0 }
            .onChange(of: desiredHeight) { _, height in onHeightChange(height) }
            .onAppear { onHeightChange(desiredHeight) }
        }
        .task(id: usage.settingsLoaded) { if usage.settingsLoaded { await checkSetup() } }
        .onAppear {
            usage.refreshLaunchAtLoginStatus()
            Task { await usage.panelOpened() }
        }
        .confirmationDialog("Clear saved account readings?", isPresented: $showClearCacheConfirmation) {
            Button("Clear cached usage", role: .destructive) {
                Task { await usage.clearCachedUsage() }
            }
        } message: {
            Text("Saved quota and token readings will be removed. A connected account can refresh them again.")
        }
    }

    private var chromeHeight: CGFloat {
        32 + 48 + 2 + (measuredHeights[.header] ?? 0) + (measuredHeights[.footer] ?? 0)
    }

    private var scrollHeight: CGFloat {
        min(measuredHeights[.content] ?? 1, max(1, sizing.maximumHeight - chromeHeight))
    }

    private var desiredHeight: CGFloat {
        min(sizing.maximumHeight, chromeHeight + scrollHeight)
    }

    private func measured<Content: View>(_ content: Content, region: PanelRegion) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightsKey.self, value: [region: geometry.size.height])
            }
        }
    }

    private func header(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppInfo.displayName).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if usage.state?.isRefreshing == true {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage")
                }
            }
            let fresh = setup?.status == .ready && usage.state?.isCached != true &&
                usage.state?.isQuotaStale(at: date) == false && usage.state?.failure == nil
            let plan = UsagePresentation.planLabel(usage.state?.snapshot?.account.value?.value.planType)
            let icon = setup?.status != .ready ? "exclamationmark.circle" :
                (fresh ? "checkmark.circle.fill" : "clock.arrow.circlepath")
            Label {
                Text(plan).foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(fresh ? Color.green : Color.secondary)
            }
                .font(.subheadline)
                .lineLimit(1)
                .help(plan)
        }
    }

    private func middleContent(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content(at: date)
            if let error = usage.storageError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let error = usage.featureError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let message = usage.cacheMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if showSettings { settingsContent }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(at date: Date) -> some View {
        HStack(spacing: 10) {
            if let updated = usage.state?.lastSuccessfulRefresh {
                let exact = updated.formatted(date: .abbreviated, time: .shortened)
                Text(UsagePresentation.updatedLabel(updated, now: date))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Last updated \(exact)")
                    .accessibilityLabel("Last updated \(exact)")
            }
            Spacer(minLength: 4)
            Button { Task { await usage.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh")
            .help("Refresh usage")
            .disabled(setup?.status != .ready || usage.state?.isRefreshing == true)
            .keyboardShortcut("r", modifiers: .command)
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(showSettings ? "Hide settings" : "Show settings")
            .help(showSettings ? "Hide settings" : "Show settings")
            .keyboardShortcut(",", modifiers: .command)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
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
            if disconnected || state?.isQuotaStale(at: date) == true || state?.isCached == true {
                Label(disconnected ? "Saved reading · disconnected" :
                        state?.isQuotaStale(at: date) == true ? "Saved reading · stale" : "Saved reading · awaiting refresh",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            } else if (state?.consecutiveFailures ?? 0) > 0 {
                Label("Refresh failed · showing last reading", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let failure = state?.failure {
                Text(recoveryMessage(failure)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            quotaContent(snapshot.quotaWindows, at: date)
            Divider()
            tokenContent(snapshot.tokenActivity)
        } else if state?.isRefreshing == true {
            Text("Loading account usage…").foregroundStyle(.secondary)
        } else if !disconnected, (state?.consecutiveFailures ?? 0) > 0 {
            Text(state?.failure.map(recoveryMessage) ?? "Usage could not be loaded. Try Refresh.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !disconnected {
            Text("Waiting for account usage…").foregroundStyle(.secondary)
        }
    }

    private func quotaContent(_ reading: UsageReading<[UsageMetric<QuotaWindow>]>, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quota").font(.subheadline).fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Remaining").font(.caption).foregroundStyle(.secondary)
            }
            if let windows = reading.value, !windows.isEmpty {
                let titles = UsagePresentation.quotaTitles(for: windows.map(\.value))
                ForEach(Array(windows.enumerated()), id: \.offset) { index, metric in
                    let window = metric.value
                    let title = titles[index]
                    if let remaining = UsagePresentation.remainingPercent(for: window) {
                        let displayed = Double(Int(remaining.rounded()))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(title).lineLimit(1).help(title)
                                Spacer()
                                Text("\(Int(displayed))%")
                                    .fontWeight(.medium).monospacedDigit()
                            }
                            .font(.callout)
                            ProgressView(value: displayed, total: 100)
                                .tint(.blue)
                                .accessibilityLabel("\(title) quota")
                                .accessibilityValue("\(Int(displayed)) percent remaining")
                            if let reset = window.resetsAt {
                                let exact = reset.formatted(date: .abbreviated, time: .shortened)
                                let label = UsagePresentation.resetLabel(reset, observedAt: metric.observedAt, now: date)
                                Text(label)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help("Reset time: \(exact)")
                                    .accessibilityLabel("\(label). Reset time: \(exact)")
                            }
                        }
                    } else {
                        Text("\(title) quota unavailable")
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Token activity").font(.subheadline).fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let lifetime = reading.value?.summary?.value.lifetimeTokens {
                    Text("Lifetime: \(UsagePresentation.compactTokens(lifetime))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Lifetime: \(UsagePresentation.fullTokens(lifetime)) tokens")
                        .accessibilityLabel("Lifetime: \(UsagePresentation.fullTokens(lifetime)) tokens")
                }
            }
            if let activity = reading.value {
                if let peak = activity.summary?.value.peakDailyTokens {
                    tokenRow("Peak day", tokens: peak)
                }
                ForEach(Array(activity.dailyUsage.sorted { $0.value.date > $1.value.date }.prefix(5)), id: \.value.date) { metric in
                    tokenRow(UsagePresentation.shortDate(metric.value.date), tokens: metric.value.tokens)
                }
            } else {
                Text(availabilityMessage(reading.availability.status, metric: "Token activity"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func tokenRow(_ label: String, tokens: Int64) -> some View {
        let full = UsagePresentation.fullTokens(tokens)
        return HStack {
            Text(label)
            Spacer()
            Text(UsagePresentation.compactTokens(tokens)).monospacedDigit()
        }
        .help("\(label): \(full) tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(full) tokens")
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("Codex settings").font(.subheadline).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            if let email = usage.state?.snapshot?.account.value?.value.email {
                LabeledContent("Account", value: email)
                    .lineLimit(1).truncationMode(.middle).help(email)
            }
            Picker("Menu bar", selection: Binding(
                get: { usage.settings.menuBarDisplayMode },
                set: { mode in Task { await usage.setMenuBarDisplayMode(mode) } }
            )) {
                Text("Icon and percentage").tag(MenuBarDisplayMode.iconAndPercentage)
                Text("Icon only").tag(MenuBarDisplayMode.iconOnly)
            }
            Picker("Refresh every", selection: Binding(
                get: { usage.settings.refreshInterval },
                set: { interval in Task { await usage.setRefreshInterval(interval) } }
            )) {
                Text("1 minute").tag(RefreshInterval.oneMinute)
                Text("5 minutes").tag(RefreshInterval.fiveMinutes)
                Text("15 minutes").tag(RefreshInterval.fifteenMinutes)
            }
            .accessibilityHint("Controls how often fresh account usage is requested.")
            Toggle("Quota alerts at 20% and 5%", isOn: Binding(
                get: { usage.settings.notificationsEnabled },
                set: { enabled in Task { await usage.setNotificationsEnabled(enabled) } }
            ))
            Toggle("Launch at login", isOn: Binding(
                get: { usage.launchAtLoginEnabled },
                set: { usage.setLaunchAtLogin($0) }
            ))
            Button("Recheck sign-in") { Task { await checkSetup() } }
            Divider()
            Text("Data access").font(.subheadline).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Text("Agent Usage reads account quota and token activity through your signed-in Codex CLI. Saved readings stay on this Mac; credentials and conversation content are not copied.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Clear cached usage") { showClearCacheConfirmation = true }
                .accessibilityHint("Removes saved account readings from this Mac.")
        }
        .font(.caption)
    }

    private func availabilityMessage(_ status: AvailabilityStatus, metric: String) -> String {
        switch status {
        case .available: return "\(metric) is unavailable."
        case .unsupported: return "\(metric) is not supported by this Codex version. Update Codex, then Refresh."
        case .unavailable(let reason): return "\(metric) unavailable: \(reason)"
        }
    }

    private func recoveryMessage(_ failure: UsageRefreshFailure) -> String {
        switch failure {
        case .cliError:
            return "Codex could not be reached. Check the CLI installation, then Recheck sign-in and Refresh."
        case .signInExpired:
            return "Codex sign-in expired. Run `codex login` in Terminal, then Recheck sign-in and Refresh."
        case .incompatibleVersion:
            return "This Codex version does not support quota reads. Update Codex, then Recheck sign-in and Refresh."
        case .quotaUnavailable:
            return "Codex could not return quota data. Check sign-in, then Refresh."
        }
    }

    private var statusMessage: String {
        switch setup?.status {
        case .ready: return "Codex is signed in with ChatGPT."
        case .missingInstallation: return "Codex CLI was not found. Install it, then Recheck sign-in."
        case .invalidExecutableOverride: return "The Codex executable is invalid. Reinstall Codex, then Recheck sign-in."
        case .invalidHomeDirectory: return "The Codex home directory does not exist. Check CODEX_HOME, then Recheck sign-in."
        case .missingSignIn: return "Codex is not signed in. Run `codex login` in Terminal, then recheck."
        case .unsupportedAuthentication: return "Sign in with ChatGPT using `codex login`, then recheck."
        case .unableToCheckLogin: return "Could not check sign-in. Run `codex login status` in Terminal, then Recheck sign-in."
        case nil: return "Checking Codex setup…"
        }
    }

    private func checkSetup() async {
        let checked = await CodexSetupChecker().check()
        guard !Task.isCancelled else { return }
        setup = checked
        await usage.configure(for: checked)
    }
}
