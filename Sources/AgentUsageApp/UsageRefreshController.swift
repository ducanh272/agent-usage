import AgentUsageCore
import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

private final class UsageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class UsageRefreshController: ObservableObject {
    @Published private(set) var state: UsageRefreshState?
    @Published private(set) var settings = AppSettings()
    @Published private(set) var settingsLoaded = false
    @Published private(set) var storageError: String?
    @Published private(set) var featureError: String?
    @Published private(set) var cacheMessage: String?
    @Published private(set) var launchAtLoginEnabled = false

    private let store = LocalUsageStore()
    private var cachedSnapshot: CachedUsageSnapshot?
    private var coordinator: UsageRefreshCoordinator?
    private var configuredPaths: (executable: URL, home: URL)?
    private var updateTask: Task<Void, Never>?
    private var configurationID = 0
    private var lastPersistedRefresh: Date?
    private var wakeObserver: NSObjectProtocol?
    private let notificationDelegate = UsageNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshIfStale() }
        }
        Task { [weak self] in await self?.loadAndStart() }
    }

    private func loadAndStart() async {
        do {
            settings = try await store.loadSettings()
            UserDefaults.standard.removeObject(forKey: "codexExecutablePath")
            UserDefaults.standard.removeObject(forKey: "codexHomePath")
            cachedSnapshot = try await store.loadLatestSnapshot()
            if let cachedSnapshot { state = cachedState(cachedSnapshot) }
        } catch {
            storageError = "Saved usage data could not be loaded."
        }
        settingsLoaded = true
        let setup = await CodexSetupChecker().check()
        await configure(for: setup)
    }

    func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) async {
        do {
            settings = try await store.updateMenuBarDisplayMode(mode)
            storageError = nil
        } catch {
            storageError = "Settings could not be saved."
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            do {
                let allowed = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                guard allowed else {
                    featureError = "Allow Agent Usage notifications in System Settings, then try again."
                    return
                }
            } catch {
                featureError = "Notification permission could not be requested."
                return
            }
        }
        do {
            settings = try await store.updateNotificationsEnabled(enabled)
            featureError = nil
        } catch {
            storageError = "Settings could not be saved."
        }
    }

    func setRefreshInterval(_ interval: RefreshInterval) async {
        do {
            settings = try await store.updateRefreshInterval(interval)
            await coordinator?.setPollInterval(interval.seconds)
            storageError = nil
        } catch {
            storageError = "Settings could not be saved."
        }
    }

    func clearCachedUsage() async {
        do {
            let wasCached = state?.isCached == true
            settings = try await store.clearCachedUsage()
            cachedSnapshot = nil
            lastPersistedRefresh = nil
            if wasCached {
                if let coordinator {
                    await coordinator.clearCachedReading()
                    state = await coordinator.currentState()
                    await refresh()
                } else {
                    state = nil
                }
            }
            cacheMessage = "Saved account readings cleared."
            storageError = nil
        } catch {
            storageError = "Saved account readings could not be cleared."
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            featureError = nil
        } catch {
            refreshLaunchAtLoginStatus()
            featureError = "Launch at login could not be changed. Open the packaged app from Applications and try again."
        }
    }

    func configure(for setup: CodexSetupResult) async {
        configurationID += 1
        let id = configurationID
        guard setup.status == .ready, let executable = setup.executableURL else {
            updateTask?.cancel()
            updateTask = nil
            let old = coordinator
            coordinator = nil
            configuredPaths = nil
            state = cachedSnapshot.map(cachedState)
            await old?.stopPolling()
            return
        }
        let home = setup.codexHomeURL
        if configuredPaths?.executable == executable, configuredPaths?.home == home {
            await refreshIfStale()
            return
        }

        updateTask?.cancel()
        updateTask = nil
        let old = coordinator
        coordinator = nil
        configuredPaths = nil
        state = cachedSnapshot.map(cachedState)
        await old?.stopPolling()
        guard id == configurationID else { return }

        let collector = CodexSessionCollector(executableURL: executable, codexHomeURL: home)
        let next = UsageRefreshCoordinator(
            provider: collector, cachedSnapshot: cachedSnapshot,
            pollInterval: settings.refreshInterval.seconds
        )
        coordinator = next
        configuredPaths = (executable, home)
        state = await next.currentState()
        updateTask = Task { [weak self] in
            for await update in next.updates {
                guard !Task.isCancelled else { break }
                await self?.receive(update)
            }
        }
        await next.startPolling()
    }

    private func receive(_ update: UsageRefreshState) async {
        state = update
        guard !update.isCached, !update.isRefreshing, update.consecutiveFailures == 0,
              let snapshot = update.snapshot, let refreshed = update.lastSuccessfulRefresh,
              refreshed != lastPersistedRefresh else { return }
        do {
            cachedSnapshot = try await store.save(snapshot, at: refreshed)
            lastPersistedRefresh = refreshed
            storageError = nil
        } catch {
            storageError = "Usage data could not be saved."
        }
        if settings.notificationsEnabled {
            await sendAlerts(for: update)
        }
    }

    private func sendAlerts(for state: UsageRefreshState) async {
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings().authorizationStatus
        guard authorization == .authorized || authorization == .provisional else {
            featureError = "Notifications are off in System Settings."
            return
        }
        do {
            let alerts = try await store.alertsToSend(for: state)
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = "Codex quota low"
                content.body = "\(alert.limitID) \(alert.kind.rawValue): \(alert.remainingPercent)% remaining"
                content.sound = .default
                try await center.add(UNNotificationRequest(
                    identifier: alert.identifier, content: content, trigger: nil
                ))
            }
            if !alerts.isEmpty { featureError = nil }
        } catch {
            featureError = "Quota alerts could not be saved or delivered."
        }
    }

    private func cachedState(_ cached: CachedUsageSnapshot) -> UsageRefreshState {
        UsageRefreshState(snapshot: cached.snapshot, lastSuccessfulRefresh: cached.savedAt,
                          isRefreshing: false, consecutiveFailures: 0, isCached: true,
                          isStale: cached.isStale())
    }

    func panelOpened() async { await refreshIfStale() }

    func refresh() async {
        guard let coordinator else { return }
        let update = await coordinator.refresh()
        if self.coordinator === coordinator { state = update }
    }

    private func refreshIfStale() async {
        guard let coordinator else { return }
        let update = await coordinator.refreshIfStale()
        if self.coordinator === coordinator { state = update }
    }
}
