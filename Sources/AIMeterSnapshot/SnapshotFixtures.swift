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
        configurations[0].costTrackingEnabled = true
        configurations[0].defaultModelName = "gpt-5"
        configurations[0].customRates = [
            TokenCostRate(
                id: "openai-gpt-5-fixture",
                provider: .openAI,
                modelName: "gpt-5",
                inputPerMillion: 1.25,
                outputPerMillion: 10,
                cachedInputPerMillion: 0.125,
                sourceNote: "Fixture rate"
            )
        ]
        configurations[2].customPath = "/Users/example/.gemini/history"

        let readings = [
            ProviderUsage(
                id: .openAI,
                tier: "Plus",
                tokenBreakdown: TokenBreakdown(
                    inputTokens: 860_000,
                    outputTokens: 210_000,
                    cachedInputTokens: 390_000
                ),
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
                ),
                modelName: "gpt-5",
                costEstimate: TokenCostEstimator.estimate(
                    breakdown: TokenBreakdown(
                        inputTokens: 860_000,
                        outputTokens: 210_000,
                        cachedInputTokens: 390_000
                    ),
                    rate: configurations[0].customRates.first,
                    modelName: "gpt-5"
                )
            ),
            ProviderUsage(
                id: .claude,
                tier: "Max",
                usedTokens: 58_800_000,
                tokenLimit: 0,
                resetAt: referenceDate.addingTimeInterval(24 * 3_600),
                availability: .measured,
                sourceDetail: "Fixture Claude usage"
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

    /// Menu-bar previews need provider-reported windows that are still active
    /// relative to the real clock, so anchor them to `now` instead of the fixed
    /// `referenceDate`. Pairs a healthy provider with a low one to exercise the
    /// urgency tint.
    @MainActor
    static func menuBarStore(now: Date = .now) -> UsageStore {
        func reading(
            id: ProviderID,
            tier: String,
            label: String,
            usedPercent: Double,
            resetsIn minutes: Int
        ) -> ProviderUsage {
            ProviderUsage(
                id: id,
                tier: tier,
                usedTokens: 0,
                tokenLimit: 0,
                resetAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
                availability: .measured,
                sourceDetail: "Menu-bar fixture",
                planUsage: PlanUsageSnapshot(
                    source: .providerReported,
                    planName: tier,
                    windows: [
                        PlanUsageWindow(
                            label: label,
                            usedPercent: usedPercent,
                            windowMinutes: minutes,
                            resetsAt: now.addingTimeInterval(
                                TimeInterval(minutes * 60)
                            )
                        )
                    ],
                    observedAt: now
                )
            )
        }

        return UsageStore(
            previewReadings: [
                reading(
                    id: .openAI,
                    tier: "Plus",
                    label: "5-hour",
                    usedPercent: 12,
                    resetsIn: 288
                ),
                reading(
                    id: .claude,
                    tier: "Max",
                    label: "5-hour",
                    usedPercent: 91,
                    resetsIn: 42
                )
            ],
            lastUpdated: now
        )
    }

    /// Two concurrent Claude sessions in different states/projects, for
    /// previewing the popover's "Active sessions" section.
    static func sessionActivities(now: Date) -> [SessionActivity] {
        [
            SessionActivity(
                id: "fixture-a",
                project: "ai-meter",
                kind: .awaiting,
                timestamp: now.addingTimeInterval(-120)
            ),
            SessionActivity(
                id: "fixture-b",
                project: "curate-ica",
                kind: .active,
                timestamp: now.addingTimeInterval(-45)
            )
        ]
    }
}
