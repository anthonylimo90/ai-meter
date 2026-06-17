import Foundation
import AIMeterCore
import AIMeterUI

enum SnapshotFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_781_100_000)

    @MainActor
    static func store() -> UsageStore {
        var configurations = ProviderConfiguration.defaults(now: referenceDate)
        for index in configurations.indices {
            configurations[index].nextResetAt = referenceDate.addingTimeInterval(
                TimeInterval((index + 1) * 3_600)
            )
        }
        configurations[2].customPath = "/Users/example/.gemini/history"

        let readings = [
            ProviderUsage(
                id: .openAI,
                tier: "Plus",
                usedTokens: 1_460_000,
                tokenLimit: 0,
                resetAt: referenceDate.addingTimeInterval(4 * 3_600 + 48 * 60),
                availability: .measured,
                sourceDetail: "Fixture Codex usage",
                planUsage: PlanUsageSnapshot(
                    source: .providerReported,
                    planName: "Plus",
                    windows: [
                        PlanUsageWindow(
                            label: "5-hour",
                            usedPercent: 12,
                            windowMinutes: 300,
                            resetsAt: referenceDate.addingTimeInterval(
                                4 * 3_600 + 48 * 60
                            )
                        ),
                        PlanUsageWindow(
                            label: "Weekly",
                            usedPercent: 14,
                            windowMinutes: 10_080,
                            resetsAt: referenceDate.addingTimeInterval(
                                4 * 24 * 3_600
                            )
                        )
                    ],
                    observedAt: referenceDate
                )
            ),
            ProviderUsage(
                id: .claude,
                tier: "Max",
                usedTokens: 58_800_000,
                tokenLimit: 0,
                resetAt: referenceDate.addingTimeInterval(90 * 60),
                availability: .measured,
                sourceDetail: "Fixture Claude usage",
                planUsage: PlanUsageSnapshot(
                    source: .providerReported,
                    planName: "Max",
                    windows: [
                        PlanUsageWindow(
                            label: "5-hour",
                            usedPercent: 68,
                            windowMinutes: 300,
                            resetsAt: referenceDate.addingTimeInterval(90 * 60)
                        ),
                        PlanUsageWindow(
                            label: "Weekly",
                            usedPercent: 7,
                            windowMinutes: 10_080,
                            resetsAt: referenceDate.addingTimeInterval(
                                6 * 24 * 3_600
                            )
                        )
                    ],
                    observedAt: referenceDate
                )
            ),
            ProviderUsage(
                id: .gemini,
                tier: "Advanced",
                usedTokens: 84_000,
                tokenLimit: 250_000,
                resetAt: referenceDate.addingTimeInterval(8 * 3_600),
                availability: .measured,
                sourceDetail: "Fixture local token usage"
            ),
            ProviderUsage(
                id: .cursor,
                tier: "Pro",
                usedTokens: 0,
                tokenLimit: 0,
                resetAt: referenceDate.addingTimeInterval(24 * 3_600),
                availability: .unavailable,
                sourceDetail: "Fixture unavailable usage"
            ),
            ProviderUsage(
                id: .copilot,
                tier: "Pro",
                usedTokens: 12_500,
                tokenLimit: 0,
                resetAt: referenceDate.addingTimeInterval(24 * 3_600),
                availability: .measured,
                sourceDetail: "Fixture local token usage"
            )
        ]

        return UsageStore(
            previewReadings: readings,
            previewConfigurations: configurations,
            lastUpdated: referenceDate
        )
    }
}
