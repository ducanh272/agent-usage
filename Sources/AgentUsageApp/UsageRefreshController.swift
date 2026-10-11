import AgentUsageCore
import AppKit
import Combine
import Foundation

@MainActor
final class UsageRefreshController: ObservableObject {
    @Published private(set) var state: UsageRefreshState?
    @Published private(set) var settings = AppSettings()
    @Published private(set) var settingsLoaded = false
    @Published private(set) var storageError: String?

    private let store = LocalUsageStore()
    private var cachedSnapshot: CachedUsageSnapshot?
    private var coordinator: UsageRefreshCoordinator?
    private var configuredPaths: (executable: URL, home: URL)?
    private var updateTask: Task<Void, Never>?
    private var configurationID = 0
    private var lastPersistedRefresh: Date?
    private var wakeObserver: NSObjectProtocol?

    init() {
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
            let legacyExecutable = UserDefaults.standard.string(forKey: "codexExecutablePath") ?? ""
            let legacyHome = UserDefaults.standard.string(forKey: "codexHomePath") ?? ""
            if settings.codexExecutablePath.isEmpty, settings.codexHomePath.isEmpty,
               !legacyExecutable.isEmpty || !legacyHome.isEmpty {
                settings = try await store.updateSettings(executablePath: legacyExecutable, homePath: legacyHome)
                UserDefaults.standard.removeObject(forKey: "codexExecutablePath")
                UserDefaults.standard.removeObject(forKey: "codexHomePath")
            }
            cachedSnapshot = try await store.loadLatestSnapshot()
            if let cachedSnapshot { state = cachedState(cachedSnapshot) }
        } catch {
            storageError = "Saved usage data could not be loaded."
        }
        settingsLoaded = true
        let executable = settings.codexExecutablePath
        let home = settings.codexHomePath
        let setup = await CodexSetupChecker().check(configuration: CodexSetupConfiguration(
            executableOverride: executable.isEmpty ? nil : executable,
            homeOverride: home.isEmpty ? nil : home
        ))
        guard executable == settings.codexExecutablePath, home == settings.codexHomePath else { return }
        await configure(for: setup)
    }

    func setExecutablePath(_ path: String) async {
        await updateSettings(executablePath: path, homePath: settings.codexHomePath)
    }

    func setHomePath(_ path: String) async {
        await updateSettings(executablePath: settings.codexExecutablePath, homePath: path)
    }

    private func updateSettings(executablePath: String, homePath: String) async {
        do {
            settings = try await store.updateSettings(executablePath: executablePath, homePath: homePath)
            storageError = nil
        } catch {
            storageError = "Settings could not be saved."
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
        let next = UsageRefreshCoordinator(provider: collector, cachedSnapshot: cachedSnapshot)
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
