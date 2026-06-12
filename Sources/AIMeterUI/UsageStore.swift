import Foundation
import Observation
import AIMeterCore

@MainActor
@Observable
public final class UsageStore {
    private static let settingsKey = "provider-configurations-v3"
    private static let autoRefreshKey = "auto-refresh-enabled"
    private static let refreshIntervalKey = "refresh-interval-seconds"
    private static let showMenuBarMetersKey = "show-menu-bar-meters"
    private static let readingsKey = "last-provider-readings-v1"
    private static let lastUpdatedKey = "last-provider-update"
    private static let lastClaudeQuotaAttemptKey =
        "last-claude-quota-attempt"
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
    private var lastClaudeQuotaAttemptAt: Date?

    var readings: [ProviderUsage]
    var configurations: [ProviderConfiguration] {
        didSet {
            scheduleConfigurationPersistence()
        }
    }
    var isRefreshing = false
    var refreshingProviders: Set<ProviderID> = []
    var staleProviders: Set<ProviderID> = []
    var lastUpdated: Date?
    var errorMessage: String?
    var hasLoaded = false
    var autoRefreshEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                autoRefreshEnabled,
                forKey: Self.autoRefreshKey
            )
            rescheduleAutoRefresh(
                performInitialRefresh: autoRefreshEnabled && !oldValue
            )
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
        let storedReadings = Self.loadReadings()
        self.readings = configurations.filter(\.isEnabled).map { configuration in
            if let stored = storedReadings.first(where: {
                $0.id == configuration.id
            }) {
                return ProviderUsage(
                    id: stored.id,
                    tier: stored.planUsage?.planName ?? configuration.tier,
                    usedTokens: stored.usedTokens,
                    tokenLimit: max(configuration.tokenLimit, 0),
                    resetAt: stored.planUsage?.windows.first?.resetsAt
                        ?? configuration.nextResetAt,
                    availability: stored.availability,
                    sourceDetail: stored.sourceDetail,
                    planUsage: stored.planUsage
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
        self.hasLoaded = !storedReadings.isEmpty
        self.lastClaudeQuotaAttemptAt = UserDefaults.standard.object(
            forKey: Self.lastClaudeQuotaAttemptKey
        ) as? Date ?? readings.first(where: {
            $0.id == .claude
        })?.planUsage?.observedAt
    }

    public init(previewReadings: [ProviderUsage]) {
        configurations = ProviderConfiguration.defaults()
        autoRefreshEnabled = true
        refreshIntervalSeconds = UsageRefreshPolicy.defaultInterval
        showMenuBarMeters = true
        readings = previewReadings
        lastUpdated = .now
        hasLoaded = true
        lastClaudeQuotaAttemptAt = previewReadings.first(where: {
            $0.id == .claude
        })?.planUsage?.observedAt
    }

    public var menuBarTitle: String {
        guard hasLoaded else { return "AI Meter" }
        let lowCount = readings.filter(\.isLow).count
        return lowCount > 0 ? "\(lowCount) low" : "AI Meter"
    }

    public var openAIMenuBarReading: ProviderUsage? {
        liveMenuBarReading(for: .openAI)
    }

    public var claudeMenuBarReading: ProviderUsage? {
        liveMenuBarReading(for: .claude)
    }

    public var hasLiveMenuBarReadings: Bool {
        openAIMenuBarReading != nil || claudeMenuBarReading != nil
    }

    var statusSummary: String {
        let reported = readings.filter {
            $0.planUsageSource == .providerReported
        }.count
        let measured = readings.filter {
            $0.availability == .measured
        }.count
        let failed = readings.filter {
            $0.availability == .failed
        }.count
        let low = readings.filter(\.isLow).count

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

    public func refresh(forceClaudeQuota: Bool = true) async {
        if !forceClaudeQuota, let refreshTask {
            await refreshTask.value
            return
        }

        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(
                forceClaudeQuota: forceClaudeQuota,
                generation: generation
            )
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
            await refresh(forceClaudeQuota: false)
            return
        }
    }

    public func startAutoRefresh() {
        guard !hasStartedAutoRefresh else { return }
        hasStartedAutoRefresh = true
        scheduleAutoRefresh(performInitialRefresh: autoRefreshEnabled)
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
                await self.refresh(forceClaudeQuota: false)
            }
        }
    }

    private func rescheduleAutoRefresh(performInitialRefresh: Bool) {
        guard hasStartedAutoRefresh else { return }
        scheduleAutoRefresh(
            performInitialRefresh: performInitialRefresh
        )
    }

    private func liveMenuBarReading(
        for provider: ProviderID
    ) -> ProviderUsage? {
        readings.first {
            $0.id == provider
                && $0.planUsageSource == .providerReported
                && $0.primaryPlanWindow != nil
        }
    }

    func resetConfiguration() {
        configurations = ProviderConfiguration.defaults()
        readings = configurations.map {
            ProviderUsage(
                id: $0.id,
                tier: $0.tier,
                usedTokens: 0,
                tokenLimit: $0.tokenLimit,
                resetAt: $0.nextResetAt,
                availability: .unavailable,
                sourceDetail: "Refresh to scan local records"
            )
        }
    }

    func isRefreshing(_ provider: ProviderID) -> Bool {
        refreshingProviders.contains(provider)
    }

    private func performRefresh(
        forceClaudeQuota: Bool,
        generation: UUID
    ) async {
        normalizeResetDates()
        let activeConfigurations = configurations.filter(\.isEnabled)
        let now = Date()
        let shouldFetchClaudeQuota = activeConfigurations.contains {
            $0.id == .claude
        } && UsageRefreshPolicy.shouldAttemptClaudeQuota(
            lastAttempt: lastClaudeQuotaAttemptAt,
            now: now,
            force: forceClaudeQuota
        )
        if shouldFetchClaudeQuota {
            lastClaudeQuotaAttemptAt = now
            UserDefaults.standard.set(
                now,
                forKey: Self.lastClaudeQuotaAttemptKey
            )
        }

        isRefreshing = true
        refreshingProviders = Set(activeConfigurations.map(\.id))
        errorMessage = nil
        var hadWarnings = false

        for await result in LocalUsageScanner.results(
            configurations: activeConfigurations,
            fetchClaudeQuota: shouldFetchClaudeQuota
        ) {
            guard !Task.isCancelled, generation == refreshGeneration else {
                return
            }
            merge(
                result,
                preservingClaudeQuota: !shouldFetchClaudeQuota
            )
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
        errorMessage = hadWarnings
            ? "Some local usage records could not be read."
            : nil
        lastUpdated = .now
        hasLoaded = true
        persistReadings()
    }

    private func merge(
        _ result: ScanResult,
        preservingClaudeQuota: Bool
    ) {
        guard let configuration = configurations.first(where: {
            $0.id == result.provider
        }) else {
            return
        }
        let previous = readings.first { $0.id == result.provider }
        if result.availability == .failed, let previous {
            let staleReading = ProviderUsage(
                id: previous.id,
                tier: previous.tier,
                usedTokens: previous.usedTokens,
                tokenLimit: previous.tokenLimit,
                resetAt: previous.resetAt,
                availability: previous.availability,
                sourceDetail: "\(result.detail); showing last known value",
                planUsage: previous.planUsage
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
        let preservedPlanUsage = result.provider == .claude
            && (preservingClaudeQuota || result.planUsage == nil)
            ? previous?.planUsage
            : nil
        let planUsage = result.planUsage ?? preservedPlanUsage
        let reading = ProviderUsage(
            id: configuration.id,
            tier: planUsage?.planName ?? configuration.tier,
            usedTokens: result.tokens,
            tokenLimit: max(configuration.tokenLimit, 0),
            resetAt: planUsage?.windows.first?.resetsAt
                ?? configuration.nextResetAt,
            availability: result.availability,
            sourceDetail: result.detail,
            planUsage: planUsage
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
        guard let data = try? JSONEncoder().encode(readings) else { return }
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
}

enum UsageRefreshPolicy {
    static let defaultInterval = 300
    static let minimumInterval = 60
    static let lowPowerInterval = 900
    static let claudeQuotaInterval: TimeInterval = 900
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

    static func shouldAttemptClaudeQuota(
        lastAttempt: Date?,
        now: Date,
        force: Bool
    ) -> Bool {
        if force {
            return true
        }
        guard let lastAttempt else {
            return true
        }
        return now.timeIntervalSince(lastAttempt) >= claudeQuotaInterval
    }
}
