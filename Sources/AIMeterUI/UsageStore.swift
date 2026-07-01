import Foundation
import Observation
import AIMeterCore

@MainActor
@Observable
public final class UsageStore {
    private static let settingsKey = "provider-configurations-v4"
    private static let autoRefreshKey = "auto-refresh-enabled"
    private static let refreshIntervalKey = "refresh-interval-seconds"
    private static let showMenuBarMetersKey = "show-menu-bar-meters"
    private static let menuBarProvidersKey = "menu-bar-providers-v1"
    private static let showMenuBarMascotKey = "show-menu-bar-mascot"
    public static let maxMenuBarProviders = 3
    private static let readingsKey = "last-provider-readings-v3"
    private static let lastUpdatedKey = "last-provider-update"
    private static let lastRollupKey = "last-cost-rollup-update"
    /// Cost rollups read ~30 days of logs, far more than the headline quota
    /// scan, so they run on this slower cadence; the previous buckets are
    /// preserved between rollup passes.
    private static let rollupMinInterval: TimeInterval = 3_600
    @ObservationIgnored
    private var lastRollupAt: Date?
    @ObservationIgnored
    private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshGeneration = UUID()
    @ObservationIgnored
    private var configurationPersistenceTask: Task<Void, Never>?
    @ObservationIgnored
    private var hasStartedAutoRefresh = false
    @ObservationIgnored
    private var activityWatcher: ActivityWatcher?

    /// Update mechanism (Sparkle), injected by the app target at launch. Nil in
    /// previews and the snapshot tool.
    @ObservationIgnored
    public var updater: AppUpdating?

    /// Whether the Claude status-line usage helper is installed.
    var claudeStatuslineEnabled = false
    var claudeStatuslineError: String?

    /// Whether AI Meter's Claude Code activity hooks are installed. When on, a
    /// directory watcher refreshes the moment a Claude turn ends.
    var claudeHooksEnabled = false
    var claudeHooksError: String?

    /// Live Claude Code session activity (from the hooks) and the mascot state
    /// derived from it, the refresh state, and low quotas.
    @ObservationIgnored
    private var sessionActivities: [SessionActivity] = []
    @ObservationIgnored
    private var providerActivityMonitor: ProviderActivityMonitor?
    @ObservationIgnored
    private var providerLastActive: [ProviderID: Date] = [:]
    @ObservationIgnored
    private var mascotDecayTask: Task<Void, Never>?
    var mascotStatus: MascotStatus = .idle

    var readings: [ProviderUsage]
    var configurations: [ProviderConfiguration] {
        didSet {
            reconcileReadingsWithConfigurations()
            scheduleConfigurationPersistence()
            updateProviderMonitor()
        }
    }
    var isRefreshing = false
    var refreshingProviders: Set<ProviderID> = []
    var staleProviders: Set<ProviderID> = []
    var lastUpdated: Date?
    var errorMessage: String?
    var hasLoaded = false
    /// Which Settings tab to show. Set before calling `openSettings()` to
    /// deep-link — the popover's "Set a budget" affordance routes here.
    public var selectedSettingsTab: SettingsTab = .general
    var autoRefreshEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                autoRefreshEnabled,
                forKey: Self.autoRefreshKey
            )
            rescheduleAutoRefresh(
                performInitialRefresh: autoRefreshEnabled && !oldValue
            )
            updateProviderMonitor()
        }
    }
    var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(
                refreshIntervalSeconds,
                forKey: Self.refreshIntervalKey
            )
            rescheduleAutoRefresh(performInitialRefresh: false)
        }
    }
    public var showMenuBarMeters: Bool {
        didSet {
            UserDefaults.standard.set(
                showMenuBarMeters,
                forKey: Self.showMenuBarMetersKey
            )
        }
    }
    /// Providers pinned to the menu bar, in display order. Always shown (even
    /// when a plan % isn't available) so the menu bar never "switches" to
    /// whichever provider happens to be reporting.
    public var menuBarProviders: [ProviderID] {
        didSet {
            UserDefaults.standard.set(
                menuBarProviders.map(\.rawValue),
                forKey: Self.menuBarProvidersKey
            )
        }
    }
    public var showMenuBarMascot: Bool {
        didSet {
            UserDefaults.standard.set(
                showMenuBarMascot,
                forKey: Self.showMenuBarMascotKey
            )
        }
    }

    public init() {
        let configurations = Self.loadConfigurations()
        self.configurations = configurations
        self.autoRefreshEnabled = UserDefaults.standard.object(
            forKey: Self.autoRefreshKey
        ) as? Bool ?? true
        let storedInterval = UserDefaults.standard.integer(
            forKey: Self.refreshIntervalKey
        )
        self.refreshIntervalSeconds = UsageRefreshPolicy.normalizedInterval(
            storedInterval
        )
        self.showMenuBarMeters = UserDefaults.standard.object(
            forKey: Self.showMenuBarMetersKey
        ) as? Bool ?? true
        if let raw = UserDefaults.standard.stringArray(
            forKey: Self.menuBarProvidersKey
        ) {
            self.menuBarProviders = raw.compactMap(ProviderID.init(rawValue:))
        } else {
            self.menuBarProviders = [.openAI, .claude]
        }
        self.showMenuBarMascot = UserDefaults.standard.object(
            forKey: Self.showMenuBarMascotKey
        ) as? Bool ?? false
        let storedReadings = Self.loadReadings()
        let now = Date()
        self.readings = configurations.filter(\.isEnabled).map { configuration in
            if let stored = storedReadings.first(where: {
                $0.id == configuration.id
            }) {
                let activePlanUsage = stored.planUsage?.active(at: now)
                return ProviderUsage(
                    id: stored.id,
                    tier: activePlanUsage?.planName ?? configuration.tier,
                    tokenBreakdown: stored.tokenBreakdown,
                    tokenLimit: max(configuration.tokenLimit, 0),
                    resetAt: activePlanUsage?.windows.first?.resetsAt
                        ?? configuration.nextResetAt,
                    availability: stored.availability,
                    sourceDetail: stored.sourceDetail,
                    planUsage: activePlanUsage,
                    modelName: stored.modelName,
                    costEstimate: Self.costEstimate(
                        for: stored.tokenBreakdown,
                        modelName: stored.modelName,
                        configuration: configuration
                    )
                )
            }
            return ProviderUsage(
                id: configuration.id,
                tier: configuration.tier,
                usedTokens: 0,
                tokenLimit: configuration.tokenLimit,
                resetAt: configuration.nextResetAt,
                availability: .unavailable,
                sourceDetail: "Waiting for first refresh"
            )
        }
        self.lastUpdated = UserDefaults.standard.object(
            forKey: Self.lastUpdatedKey
        ) as? Date
        self.lastRollupAt = UserDefaults.standard.object(
            forKey: Self.lastRollupKey
        ) as? Date
        self.hasLoaded = !storedReadings.isEmpty
        self.claudeStatuslineEnabled = ClaudeStatuslineInstaller.isEnabled()
        self.claudeHooksEnabled = ClaudeHooksInstaller.isEnabled()
    }

    public init(
        previewReadings: [ProviderUsage],
        previewConfigurations: [ProviderConfiguration]? = nil,
        lastUpdated: Date = .now
    ) {
        configurations = previewConfigurations
            ?? ProviderConfiguration.defaults(now: lastUpdated)
        autoRefreshEnabled = true
        refreshIntervalSeconds = UsageRefreshPolicy.defaultInterval
        showMenuBarMeters = true
        menuBarProviders = [.openAI, .claude]
        showMenuBarMascot = false
        readings = previewReadings
        self.lastUpdated = lastUpdated
        hasLoaded = true
    }

    public var menuBarTitle: String {
        guard hasLoaded else { return "AI Meter" }
        let lowCount = readings.filter(\.isLow).count
        return lowCount > 0 ? "\(lowCount) low" : "AI Meter"
    }

    /// The pinned providers' readings, in pin order. Only those currently
    /// enabled (present in `readings`) appear; each is shown regardless of
    /// whether a live plan % is available.
    public var menuBarReadings: [ProviderUsage] {
        menuBarProviders.compactMap { id in
            readings.first { $0.id == id }
        }
    }

    public var isMenuBarPinFull: Bool {
        menuBarProviders.count >= Self.maxMenuBarProviders
    }

    public func isPinnedToMenuBar(_ id: ProviderID) -> Bool {
        menuBarProviders.contains(id)
    }

    /// Toggle a provider's menu-bar pin, preserving order and the pin cap.
    public func setMenuBarPinned(_ id: ProviderID, _ pinned: Bool) {
        if pinned {
            guard !menuBarProviders.contains(id), !isMenuBarPinFull else { return }
            menuBarProviders.append(id)
        } else {
            menuBarProviders.removeAll { $0 == id }
        }
    }

    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// Asks Sparkle to check for updates. Sparkle drives all subsequent UI
    /// (release notes, download, install, relaunch).
    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Installs or removes Claude Code's status-line helper that lets AI Meter
    /// read live Claude plan usage locally.
    public func setClaudeStatuslineEnabled(_ enabled: Bool) {
        claudeStatuslineError = nil
        do {
            if enabled {
                try ClaudeStatuslineInstaller.enable()
            } else {
                try ClaudeStatuslineInstaller.disable()
            }
        } catch {
            claudeStatuslineError = Self.describeStatuslineError(error)
        }
        claudeStatuslineEnabled = ClaudeStatuslineInstaller.isEnabled()
        Task { await refresh() }
    }

    private static func describeStatuslineError(_ error: Error) -> String {
        switch error {
        case ClaudeStatuslineInstaller.InstallError.settingsUnreadable:
            return "Claude Code settings weren't found. Open Claude Code once, then try again."
        case ClaudeStatuslineInstaller.InstallError.settingsNotJSON:
            return "AI Meter couldn't read Claude Code's settings file."
        case ClaudeStatuslineInstaller.InstallError.writeFailed:
            return "AI Meter couldn't update Claude Code's settings."
        default:
            return error.localizedDescription
        }
    }

    /// Installs or removes AI Meter's Claude Code activity hooks and starts or
    /// stops the directory watcher that turns those hooks into instant refreshes.
    public func setClaudeHooksEnabled(_ enabled: Bool) {
        claudeHooksError = nil
        do {
            if enabled {
                try ClaudeHooksInstaller.enable()
            } else {
                try ClaudeHooksInstaller.disable()
            }
        } catch {
            claudeHooksError = Self.describeHooksError(error)
        }
        claudeHooksEnabled = ClaudeHooksInstaller.isEnabled()
        updateActivityWatcher()
        Task { await refresh() }
    }

    private static func describeHooksError(_ error: Error) -> String {
        switch error {
        case ClaudeHooksInstaller.InstallError.settingsUnreadable:
            return "Claude Code settings weren't found. Open Claude Code once, then try again."
        case ClaudeHooksInstaller.InstallError.settingsNotJSON:
            return "AI Meter couldn't read Claude Code's settings file."
        case ClaudeHooksInstaller.InstallError.writeFailed:
            return "AI Meter couldn't update Claude Code's settings."
        default:
            return error.localizedDescription
        }
    }

    /// Starts the activity watcher when hooks are installed, tears it down when
    /// not. A hook bump (`activity.touch`) triggers a coalesced refresh, which
    /// already de-dupes against any in-flight scan and skips the wide rollup.
    private func updateActivityWatcher() {
        guard claudeHooksEnabled else {
            activityWatcher?.stop()
            activityWatcher = nil
            return
        }
        guard activityWatcher == nil else { return }
        let watcher = ActivityWatcher(
            directory: ClaudeHooksInstaller.Paths.default.supportDir,
            debounce: .milliseconds(500)
        ) { [weak self] in
            self?.handleActivitySignal()
        }
        watcher.start()
        activityWatcher = watcher
        refreshActivityState()
    }

    /// A hook fired: update the buddy immediately (cheap session read), then
    /// kick a coalesced full refresh for the numbers.
    private func handleActivitySignal() {
        refreshActivityState()
        Task { await refresh(coalescing: true) }
    }

    /// Re-read the session files and recompute the mascot state.
    func refreshActivityState(now: Date = .now) {
        sessionActivities = SessionActivityStore.read(now: now)
        recomputeMascotStatus(now: now)
    }

    private func recomputeMascotStatus(now: Date = .now) {
        let claudeKind = SessionActivityStore.aggregate(sessionActivities, now: now)
        let next: MascotStatus
        if claudeKind == .awaiting {
            next = MascotStatus(face: .awaiting, tint: .claude)
        } else {
            // Fold Claude's precise hook activity into the file-derived map so
            // the tint is whichever provider is working most recently.
            var activity = providerLastActive
            if claudeKind == .active {
                activity[.claude] = sessionActivities
                    .filter { $0.kind == .active }
                    .map(\.timestamp)
                    .max() ?? now
            }
            if let active = ProviderActivityResolver.mostRecentlyActive(activity, now: now) {
                next = MascotStatus(face: .active, tint: active)
            } else if isRefreshing {
                next = MascotStatus(face: .refreshing)
            } else if let low = lowestLowProvider(at: now) {
                next = MascotStatus(face: .low, tint: low)
            } else {
                next = .idle
            }
        }
        if next != mascotStatus {
            mascotStatus = next
        }
        ensureMascotDecay()
    }

    /// While the buddy is active, re-evaluate every few seconds so it decays
    /// back to idle once activity stops (no further filesystem event arrives).
    private func ensureMascotDecay() {
        guard mascotStatus.face == .active else {
            mascotDecayTask?.cancel()
            mascotDecayTask = nil
            return
        }
        guard mascotDecayTask == nil else { return }
        mascotDecayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.recomputeMascotStatus()
            }
        }
    }

    /// Starts/stops the FSEvents monitor over the enabled providers' record
    /// folders. Runs whenever automatic refresh is on, so the buddy reacts to
    /// any AI tool — not just Claude — and changes also drive a coalesced
    /// refresh (event-driven updates for every provider).
    private func updateProviderMonitor() {
        guard hasStartedAutoRefresh, autoRefreshEnabled else {
            providerActivityMonitor?.stop()
            providerActivityMonitor = nil
            return
        }
        // Rebuild so newly enabled/disabled providers are reflected.
        providerActivityMonitor?.stop()
        let paths = providerWatchPaths()
        guard !paths.isEmpty else {
            providerActivityMonitor = nil
            return
        }
        let monitor = ProviderActivityMonitor(paths: paths) { [weak self] changed in
            self?.handleProviderActivity(changed)
        }
        monitor.start()
        providerActivityMonitor = monitor
    }

    private func providerWatchPaths() -> [String] {
        var paths = Set<String>()
        let fileManager = FileManager.default
        for configuration in configurations where configuration.isEnabled {
            for url in ProviderActivityResolver.roots(
                for: configuration.id,
                customPath: configuration.customPath
            ) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ) else { continue }
                paths.insert(
                    isDirectory.boolValue
                        ? url.path
                        : url.deletingLastPathComponent().path
                )
            }
        }
        return Array(paths)
    }

    private func handleProviderActivity(_ changedPaths: [String]) {
        let roots = Dictionary(
            uniqueKeysWithValues: configurations.filter(\.isEnabled).map {
                ($0.id, ProviderActivityResolver.roots(
                    for: $0.id,
                    customPath: $0.customPath
                ))
            }
        )
        let now = Date()
        var touched = false
        for path in changedPaths {
            if let provider = ProviderActivityResolver.provider(
                forChangedPath: path,
                roots: roots
            ) {
                providerLastActive[provider] = now
                touched = true
            }
        }
        guard touched else { return }
        recomputeMascotStatus(now: now)
        Task { await refresh(coalescing: true) }
    }

    private func lowestLowProvider(at now: Date) -> ProviderID? {
        readings
            .filter { $0.isLow(at: now) }
            .min(by: {
                ($0.remainingPercent(at: now) ?? 100)
                    < ($1.remainingPercent(at: now) ?? 100)
            })?
            .id
    }

    var statusSummary: String {
        statusSummary(at: .now)
    }

    func statusSummary(at date: Date) -> String {
        let reported = readings.filter {
            $0.planUsageSource(at: date) == .providerReported
        }.count
        let measured = readings.filter {
            $0.availability == .measured
        }.count
        let failed = readings.filter {
            $0.availability == .failed
        }.count
        let low = readings.filter { $0.isLow(at: date) }.count

        if low > 0 {
            return "\(low) \(low == 1 ? "limit" : "limits") running low."
        }
        if reported > 0 {
            return "\(reported) provider \(reported == 1 ? "quota" : "quotas") detected."
        }
        if measured > 0 {
            return "\(measured) local token "
                + (measured == 1 ? "source" : "sources")
                + " measured."
        }
        if failed > 0 {
            return "Some local usage records could not be read."
        }
        if readings.isEmpty {
            return "No providers are enabled."
        }
        return "No recent compatible usage records found."
    }

    public func refresh(coalescing: Bool = false) async {
        if coalescing, let refreshTask {
            await refreshTask.value
            return
        }

        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshTask = task
        await task.value
        if generation == refreshGeneration {
            refreshTask = nil
        }
    }

    public func refreshIfStale(maxAge: TimeInterval = 15) async {
        guard
            let lastUpdated,
            Date().timeIntervalSince(lastUpdated) < maxAge
        else {
            await refresh(coalescing: true)
            return
        }
    }

    public func startAutoRefresh() {
        guard !hasStartedAutoRefresh else { return }
        hasStartedAutoRefresh = true
        scheduleAutoRefresh(performInitialRefresh: autoRefreshEnabled)
        updateActivityWatcher()
        updateProviderMonitor()
    }

    private func scheduleAutoRefresh(performInitialRefresh: Bool) {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard autoRefreshEnabled else { return }
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            if performInitialRefresh {
                await self.refreshIfStale(maxAge: 5)
            }

            while !Task.isCancelled {
                guard self.autoRefreshEnabled else { return }
                let interval = UsageRefreshPolicy.automaticInterval(
                    configured: self.refreshIntervalSeconds,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                )
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refresh(coalescing: true)
            }
        }
    }

    private func rescheduleAutoRefresh(performInitialRefresh: Bool) {
        guard hasStartedAutoRefresh else { return }
        scheduleAutoRefresh(
            performInitialRefresh: performInitialRefresh
        )
    }

    func resetConfiguration() {
        configurations = ProviderConfiguration.defaults()
    }

    func isRefreshing(_ provider: ProviderID) -> Bool {
        refreshingProviders.contains(provider)
    }

    private func performRefresh(generation: UUID) async {
        normalizeResetDates()
        reconcileReadingsWithConfigurations()
        let activeConfigurations = configurations.filter(\.isEnabled)

        isRefreshing = true
        refreshingProviders = Set(activeConfigurations.map(\.id))
        errorMessage = nil
        recomputeMascotStatus()
        var hadWarnings = false

        // Recompute the wide day/week/month rollup only on the slow cadence (or
        // when we have none yet); narrow refreshes preserve the last buckets.
        let includeRollup = lastRollupAt.map {
            Date().timeIntervalSince($0) >= Self.rollupMinInterval
        } ?? true

        for await result in LocalUsageScanner.results(
            configurations: activeConfigurations,
            includeRollup: includeRollup
        ) {
            guard !Task.isCancelled, generation == refreshGeneration else {
                return
            }
            merge(result)
            refreshingProviders.remove(result.provider)
            hadWarnings = hadWarnings
                || result.availability == .failed
                || result.hasWarnings
        }

        guard !Task.isCancelled, generation == refreshGeneration else {
            return
        }
        isRefreshing = false
        refreshingProviders = []
        reconcileReadingsWithConfigurations()
        errorMessage = hadWarnings
            ? "Some local usage records could not be read."
            : nil
        lastUpdated = .now
        if includeRollup {
            lastRollupAt = .now
            UserDefaults.standard.set(lastRollupAt, forKey: Self.lastRollupKey)
        }
        hasLoaded = true
        persistReadings()
        refreshActivityState()
    }

    func merge(_ result: ScanResult) {
        guard let configuration = configurations.first(where: {
            $0.id == result.provider && $0.isEnabled
        }) else {
            return
        }
        let previous = readings.first { $0.id == result.provider }
        if result.availability == .failed, let previous {
            let planUsage = resolvedPlanUsage(
                result: result,
                previous: previous
            )
            let staleReading = ProviderUsage(
                id: previous.id,
                tier: planUsage?.planName ?? configuration.tier,
                tokenBreakdown: previous.tokenBreakdown,
                tokenLimit: max(configuration.tokenLimit, 0),
                resetAt: planUsage?.windows.first?.resetsAt
                    ?? configuration.nextResetAt,
                availability: previous.availability,
                sourceDetail: sourceDetail(
                    for: result,
                    suffix: "showing last known local token value"
                ),
                planUsage: planUsage,
                modelName: previous.modelName,
                costEstimate: Self.costEstimate(
                    for: previous.tokenBreakdown,
                    modelName: previous.modelName,
                    configuration: configuration
                ),
                costRollup: Self.costRollup(
                    for: previous.rollupBreakdown,
                    modelName: previous.modelName,
                    configuration: configuration
                ),
                rollupBreakdown: previous.rollupBreakdown
            )
            if let index = readings.firstIndex(where: {
                $0.id == result.provider
            }) {
                readings[index] = staleReading
            }
            staleProviders.insert(result.provider)
            return
        }
        staleProviders.remove(result.provider)
        let planUsage = resolvedPlanUsage(
            result: result,
            previous: previous
        )
        let modelName = Self.resolvedModelName(
            scannedModelName: result.modelName,
            configuration: configuration
        )
        // A narrow refresh omits the wide rollup scan; keep the last computed
        // buckets so the day/week/month line doesn't blink out between the
        // slower rollup passes.
        let rollupBreakdown = result.rollup ?? previous?.rollupBreakdown
        let reading = ProviderUsage(
            id: configuration.id,
            tier: planUsage?.planName ?? configuration.tier,
            tokenBreakdown: result.tokenBreakdown,
            tokenLimit: max(configuration.tokenLimit, 0),
            resetAt: planUsage?.windows.first?.resetsAt
                ?? configuration.nextResetAt,
            availability: result.availability,
            sourceDetail: sourceDetail(for: result),
            planUsage: planUsage,
            modelName: modelName,
            costEstimate: Self.costEstimate(
                for: result.tokenBreakdown,
                modelName: modelName,
                configuration: configuration
            ),
            costRollup: Self.costRollup(
                for: rollupBreakdown,
                modelName: modelName,
                configuration: configuration
            ),
            rollupBreakdown: rollupBreakdown
        )
        if let index = readings.firstIndex(where: { $0.id == result.provider }) {
            readings[index] = reading
        } else {
            readings.append(reading)
            readings.sort {
                ProviderID.allCases.firstIndex(of: $0.id)!
                    < ProviderID.allCases.firstIndex(of: $1.id)!
            }
        }
    }

    private func resolvedPlanUsage(
        result: ScanResult,
        previous: ProviderUsage?
    ) -> PlanUsageSnapshot? {
        switch result.planUsageStatus {
        case .measured:
            return result.planUsage?.active()
        case .notRequested:
            // Preserve a previously measured provider-reported window (e.g.
            // Codex) between scans that did not re-read it.
            return previous?.planUsage?.active()
        case .unavailable, .failed:
            return nil
        }
    }

    private func sourceDetail(
        for result: ScanResult,
        suffix: String? = nil
    ) -> String {
        var parts = [result.detail]
        switch result.planUsageStatus {
        case .notRequested, .measured:
            break
        case let .unavailable(message), let .failed(message):
            if !result.detail.localizedCaseInsensitiveContains(message) {
                parts.append(message)
            }
        }
        if let suffix {
            parts.append(suffix)
        }
        return parts.joined(separator: "; ")
    }

    private func reconcileReadingsWithConfigurations(now: Date = .now) {
        let enabled = configurations.filter(\.isEnabled)
        let enabledIDs = Set(enabled.map(\.id))
        readings = enabled.map { configuration in
            guard let previous = readings.first(where: {
                $0.id == configuration.id
            }) else {
                return ProviderUsage(
                    id: configuration.id,
                    tier: configuration.tier,
                    usedTokens: 0,
                    tokenLimit: max(configuration.tokenLimit, 0),
                    resetAt: configuration.nextResetAt,
                    availability: .unavailable,
                    sourceDetail: "Refresh to scan local records"
                )
            }
            let activePlanUsage = previous.planUsage?.active(at: now)
            return ProviderUsage(
                id: previous.id,
                tier: activePlanUsage?.planName ?? configuration.tier,
                tokenBreakdown: previous.tokenBreakdown,
                tokenLimit: max(configuration.tokenLimit, 0),
                resetAt: activePlanUsage?.windows.first?.resetsAt
                    ?? configuration.nextResetAt,
                availability: previous.availability,
                sourceDetail: previous.sourceDetail,
                planUsage: activePlanUsage,
                modelName: previous.modelName,
                costEstimate: Self.costEstimate(
                    for: previous.tokenBreakdown,
                    modelName: previous.modelName,
                    configuration: configuration
                ),
                costRollup: Self.costRollup(
                    for: previous.rollupBreakdown,
                    modelName: previous.modelName,
                    configuration: configuration
                ),
                rollupBreakdown: previous.rollupBreakdown
            )
        }
        refreshingProviders.formIntersection(enabledIDs)
        staleProviders.formIntersection(enabledIDs)
    }

    private func normalizeResetDates(now: Date = .now) {
        var normalized = configurations
        for index in normalized.indices {
            let hours = max(normalized[index].windowHours, 1)
            var nextReset = normalized[index].nextResetAt
            while nextReset <= now {
                nextReset = Calendar.current.date(
                    byAdding: .hour,
                    value: hours,
                    to: nextReset
                ) ?? now.addingTimeInterval(TimeInterval(hours * 3_600))
            }
            normalized[index].nextResetAt = nextReset
        }
        if normalized != configurations {
            configurations = normalized
        }
    }

    private func scheduleConfigurationPersistence() {
        configurationPersistenceTask?.cancel()
        configurationPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistConfigurations()
        }
    }

    private func persistConfigurations() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func persistReadings() {
        let now = Date()
        let sanitized = readings.map { reading in
            let planUsage = reading.planUsage?.active(at: now)
            return ProviderUsage(
                id: reading.id,
                tier: planUsage?.planName ?? reading.tier,
                tokenBreakdown: reading.tokenBreakdown,
                tokenLimit: reading.tokenLimit,
                resetAt: planUsage?.windows.first?.resetsAt ?? reading.resetAt,
                availability: reading.availability,
                sourceDetail: reading.sourceDetail,
                planUsage: planUsage,
                modelName: reading.modelName,
                costEstimate: reading.costEstimate,
                costRollup: reading.costRollup,
                rollupBreakdown: reading.rollupBreakdown
            )
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        UserDefaults.standard.set(data, forKey: Self.readingsKey)
        UserDefaults.standard.set(lastUpdated, forKey: Self.lastUpdatedKey)
    }

    private static func loadReadings() -> [ProviderUsage] {
        guard
            let data = UserDefaults.standard.data(forKey: readingsKey),
            let readings = try? JSONDecoder().decode(
                [ProviderUsage].self,
                from: data
            )
        else {
            return []
        }
        return readings
    }

    private static func loadConfigurations() -> [ProviderConfiguration] {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let configurations = try? JSONDecoder().decode(
                [ProviderConfiguration].self,
                from: data
            )
        else {
            return ProviderConfiguration.defaults()
        }
        return configurations
    }

    private static func resolvedModelName(
        scannedModelName: String?,
        configuration: ProviderConfiguration
    ) -> String? {
        let configured = configuration.defaultModelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let scannedModelName,
           !scannedModelName.trimmingCharacters(
                in: .whitespacesAndNewlines
           ).isEmpty {
            return scannedModelName
        }
        return configured.isEmpty ? nil : configured
    }

    private static func costEstimate(
        for breakdown: TokenBreakdown,
        modelName: String?,
        configuration: ProviderConfiguration
    ) -> TokenCostEstimate? {
        guard configuration.costTrackingEnabled else { return nil }
        let rate = rate(for: modelName, configuration: configuration)
        return TokenCostEstimator.estimate(
            breakdown: breakdown,
            rate: rate,
            modelName: modelName
        )
    }

    private static func costRollup(
        for rollup: CostRollupBreakdown?,
        modelName: String?,
        configuration: ProviderConfiguration
    ) -> TokenCostRollup? {
        guard configuration.costTrackingEnabled, let rollup else { return nil }
        let rate = rate(for: modelName, configuration: configuration)
        func estimate(_ breakdown: TokenBreakdown) -> TokenCostEstimate? {
            TokenCostEstimator.estimate(
                breakdown: breakdown,
                rate: rate,
                modelName: modelName
            )
        }
        let result = TokenCostRollup(
            day: estimate(rollup.day),
            week: estimate(rollup.week),
            month: estimate(rollup.month)
        )
        // Nothing worth showing if every bucket is empty.
        if result.day == nil, result.week == nil, result.month == nil {
            return nil
        }
        return result
    }

    private static func rate(
        for modelName: String?,
        configuration: ProviderConfiguration
    ) -> TokenCostRate? {
        let enabledRates = configuration.customRates.filter {
            $0.isEnabled && $0.provider == configuration.id
        }
        if let modelName {
            let normalized = modelName.lowercased()
            // A user's custom rate for this exact model always wins.
            if let exact = enabledRates.first(where: {
                $0.modelName.lowercased() == normalized
            }) {
                return exact
            }
            // Otherwise fall back to the bundled list price for the model.
            if let builtIn = BuiltInPricing.rate(
                for: configuration.id,
                modelName: modelName
            ) {
                return builtIn
            }
        }
        // No model match: prefer any custom rate the user configured, else
        // there is no sensible bundled default to guess at.
        return enabledRates.first
    }
}

enum UsageRefreshPolicy {
    static let defaultInterval = 300
    static let minimumInterval = 60
    static let lowPowerInterval = 900
    static let supportedIntervals = [60, 300, 900]

    static func normalizedInterval(_ storedInterval: Int) -> Int {
        if storedInterval > 0 && storedInterval < minimumInterval {
            return minimumInterval
        }
        guard supportedIntervals.contains(storedInterval) else {
            return defaultInterval
        }
        return storedInterval
    }

    static func automaticInterval(
        configured: Int,
        lowPowerMode: Bool
    ) -> Int {
        let normalized = normalizedInterval(configured)
        return lowPowerMode ? max(normalized, lowPowerInterval) : normalized
    }
}
