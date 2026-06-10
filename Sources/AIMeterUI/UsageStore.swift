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
    @ObservationIgnored
    private var autoRefreshTask: Task<Void, Never>?

    var readings: [ProviderUsage]
    var configurations: [ProviderConfiguration] {
        didSet {
            persistConfigurations()
        }
    }
    var isRefreshing = false
    var lastUpdated: Date?
    var errorMessage: String?
    var hasLoaded = false
    var autoRefreshEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                autoRefreshEnabled,
                forKey: Self.autoRefreshKey
            )
        }
    }
    var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(
                refreshIntervalSeconds,
                forKey: Self.refreshIntervalKey
            )
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
        self.refreshIntervalSeconds = storedInterval > 0 ? storedInterval : 60
        self.showMenuBarMeters = UserDefaults.standard.object(
            forKey: Self.showMenuBarMetersKey
        ) as? Bool ?? true
        self.readings = configurations
            .filter(\.isEnabled)
            .map {
                ProviderUsage(
                    id: $0.id,
                    tier: $0.tier,
                    usedTokens: 0,
                    tokenLimit: $0.tokenLimit,
                    resetAt: $0.nextResetAt,
                    availability: .unavailable,
                    sourceDetail: "Waiting for first refresh"
                )
        }
    }

    public init(previewReadings: [ProviderUsage]) {
        configurations = ProviderConfiguration.defaults()
        autoRefreshEnabled = true
        refreshIntervalSeconds = 60
        showMenuBarMeters = true
        readings = previewReadings
        lastUpdated = .now
        hasLoaded = true
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
        let low = readings.filter(\.isLow).count

        if low > 0 {
            return "\(low) \(low == 1 ? "limit" : "limits") running low."
        }
        if reported > 0 {
            return "\(reported) provider \(reported == 1 ? "quota" : "quotas") detected."
        }
        return "Token usage measured locally; plan limits unavailable."
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil

        normalizeResetDates()
        let activeConfigurations = configurations.filter(\.isEnabled)
        let results = await Task.detached(priority: .userInitiated) {
            LocalUsageScanner.scan(configurations: activeConfigurations)
        }.value

        readings = activeConfigurations.map { configuration in
            let result = results.first { $0.provider == configuration.id }
            return ProviderUsage(
                id: configuration.id,
                tier: result?.planUsage?.planName ?? configuration.tier,
                usedTokens: result?.tokens ?? 0,
                tokenLimit: max(configuration.tokenLimit, 0),
                resetAt: result?.planUsage?.windows.first?.resetsAt
                    ?? configuration.nextResetAt,
                availability: result?.availability ?? .unavailable,
                sourceDetail: result?.detail ?? "No compatible local records found",
                planUsage: result?.planUsage
            )
        }

        if results.contains(where: { $0.availability == .failed }) {
            errorMessage = "Some local usage records could not be read."
        }

        lastUpdated = .now
        hasLoaded = true
        isRefreshing = false
    }

    public func refreshIfStale(maxAge: TimeInterval = 15) async {
        guard
            let lastUpdated,
            Date().timeIntervalSince(lastUpdated) < maxAge
        else {
            await refresh()
            return
        }
    }

    public func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshIfStale(maxAge: 5)

            while !Task.isCancelled {
                let interval = max(self.refreshIntervalSeconds, 30)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                if self.autoRefreshEnabled {
                    await self.refresh()
                }
            }
        }
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

    private func normalizeResetDates(now: Date = .now) {
        for index in configurations.indices {
            let hours = max(configurations[index].windowHours, 1)
            var nextReset = configurations[index].nextResetAt
            while nextReset <= now {
                nextReset = Calendar.current.date(
                    byAdding: .hour,
                    value: hours,
                    to: nextReset
                ) ?? now.addingTimeInterval(TimeInterval(hours * 3_600))
            }
            configurations[index].nextResetAt = nextReset
        }
    }

    private func persistConfigurations() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
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
