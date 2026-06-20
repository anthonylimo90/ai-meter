import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case claude
    case gemini
    case cursor
    case copilot

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openAI: "ChatGPT / OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        }
    }

    /// Compact label for tight surfaces such as the menu bar.
    public var shortName: String {
        switch self {
        case .openAI: "GPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        }
    }

    public var defaultTier: String {
        switch self {
        case .openAI: "Plus / Codex"
        case .claude: "Pro"
        case .gemini: "Advanced"
        case .cursor: "Pro"
        case .copilot: "Pro"
        }
    }

    public var symbolName: String {
        switch self {
        case .openAI: "circle.hexagongrid.fill"
        case .claude: "sun.max.fill"
        case .gemini: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .openAI: "Codex session logs"
        case .claude: "Claude project logs"
        case .gemini: "Gemini CLI records"
        case .cursor: "Cursor local records"
        case .copilot: "Copilot local records"
        }
    }

    public var builtInPaths: [String] {
        switch self {
        case .openAI:
            ["~/.codex/sessions"]
        case .claude:
            ["~/.claude/projects"]
        case .gemini:
            ["~/.gemini/tmp", "~/.gemini/history"]
        case .cursor:
            [
                "~/.cursor",
                "~/Library/Application Support/Cursor/User/globalStorage"
            ]
        case .copilot:
            [
                "~/.config/github-copilot",
                "~/Library/Application Support/Code/User/globalStorage/github.copilot-chat"
            ]
        }
    }
}

public struct ProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    public let id: ProviderID
    public var isEnabled: Bool
    public var tier: String
    public var tokenLimit: Int
    public var windowHours: Int
    public var nextResetAt: Date
    public var customPath: String
    public var defaultModelName: String
    public var costTrackingEnabled: Bool
    public var customRates: [TokenCostRate]

    public init(
        id: ProviderID,
        isEnabled: Bool,
        tier: String,
        tokenLimit: Int,
        windowHours: Int,
        nextResetAt: Date,
        customPath: String,
        defaultModelName: String = "",
        costTrackingEnabled: Bool = false,
        customRates: [TokenCostRate] = []
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.tier = tier
        self.tokenLimit = tokenLimit
        self.windowHours = windowHours
        self.nextResetAt = nextResetAt
        self.customPath = customPath
        self.defaultModelName = defaultModelName
        self.costTrackingEnabled = costTrackingEnabled
        self.customRates = customRates
    }

    public static func defaults(now: Date = .now) -> [ProviderConfiguration] {
        let calendar = Calendar.current

        func resetDate(hours: Int) -> Date {
            if hours == 24 {
                let startOfToday = calendar.startOfDay(for: now)
                return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            }

            if hours == 168 {
                let startOfToday = calendar.startOfDay(for: now)
                let weekday = calendar.component(.weekday, from: startOfToday)
                let daysUntilMonday = (9 - weekday) % 7
                let daysToAdd = daysUntilMonday == 0 ? 7 : daysUntilMonday
                return calendar.date(
                    byAdding: .day,
                    value: daysToAdd,
                    to: startOfToday
                ) ?? now
            }

            return calendar.date(byAdding: .hour, value: hours, to: now) ?? now
        }

        return [
            ProviderConfiguration(
                id: .openAI,
                isEnabled: true,
                tier: ProviderID.openAI.defaultTier,
                tokenLimit: 0,
                windowHours: 24,
                nextResetAt: resetDate(hours: 24),
                customPath: ""
            ),
            ProviderConfiguration(
                id: .claude,
                isEnabled: true,
                tier: ProviderID.claude.defaultTier,
                tokenLimit: 0,
                windowHours: 24,
                nextResetAt: resetDate(hours: 24),
                customPath: ""
            ),
            ProviderConfiguration(
                id: .gemini,
                isEnabled: true,
                tier: ProviderID.gemini.defaultTier,
                tokenLimit: 0,
                windowHours: 24,
                nextResetAt: resetDate(hours: 24),
                customPath: ""
            ),
            ProviderConfiguration(
                id: .cursor,
                isEnabled: true,
                tier: ProviderID.cursor.defaultTier,
                tokenLimit: 0,
                windowHours: 168,
                nextResetAt: resetDate(hours: 168),
                customPath: ""
            ),
            ProviderConfiguration(
                id: .copilot,
                isEnabled: true,
                tier: ProviderID.copilot.defaultTier,
                tokenLimit: 0,
                windowHours: 168,
                nextResetAt: resetDate(hours: 168),
                customPath: ""
            )
        ]
    }

    enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case tier
        case tokenLimit
        case windowHours
        case nextResetAt
        case customPath
        case defaultModelName
        case costTrackingEnabled
        case customRates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        tier = try container.decode(String.self, forKey: .tier)
        tokenLimit = try container.decode(Int.self, forKey: .tokenLimit)
        windowHours = try container.decode(Int.self, forKey: .windowHours)
        nextResetAt = try container.decode(Date.self, forKey: .nextResetAt)
        customPath = try container.decode(String.self, forKey: .customPath)
        defaultModelName = try container.decodeIfPresent(
            String.self,
            forKey: .defaultModelName
        ) ?? ""
        costTrackingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .costTrackingEnabled
        ) ?? false
        customRates = try container.decodeIfPresent(
            [TokenCostRate].self,
            forKey: .customRates
        ) ?? []
    }
}

public struct TokenBreakdown: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    public var otherTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        otherTokens: Int = 0
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.cacheWriteTokens = max(cacheWriteTokens, 0)
        self.cacheReadTokens = max(cacheReadTokens, 0)
        self.otherTokens = max(otherTokens, 0)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens
            + cacheReadTokens + otherTokens
    }

    public var splitTokenCount: Int {
        inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens
            + cacheReadTokens
    }

    public var hasDetailedSplit: Bool {
        splitTokenCount > 0
    }

    public static var zero: TokenBreakdown {
        TokenBreakdown()
    }

    public static func aggregate(_ tokens: Int) -> TokenBreakdown {
        TokenBreakdown(otherTokens: tokens)
    }

    public static func + (
        lhs: TokenBreakdown,
        rhs: TokenBreakdown
    ) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            otherTokens: lhs.otherTokens + rhs.otherTokens
        )
    }

    public static func += (
        lhs: inout TokenBreakdown,
        rhs: TokenBreakdown
    ) {
        lhs = lhs + rhs
    }

    public func replacingTotalWithOtherTokens(_ total: Int) -> TokenBreakdown {
        TokenBreakdown(otherTokens: total)
    }
}

public struct TokenCostRate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: ProviderID
    public var modelName: String
    public var currencyCode: String
    public var inputPerMillion: Decimal
    public var outputPerMillion: Decimal
    public var cachedInputPerMillion: Decimal
    public var cacheWritePerMillion: Decimal
    public var cacheReadPerMillion: Decimal
    public var isEnabled: Bool
    public var updatedAt: Date?
    public var sourceNote: String

    public init(
        id: String,
        provider: ProviderID,
        modelName: String,
        currencyCode: String = "USD",
        inputPerMillion: Decimal = 0,
        outputPerMillion: Decimal = 0,
        cachedInputPerMillion: Decimal = 0,
        cacheWritePerMillion: Decimal = 0,
        cacheReadPerMillion: Decimal = 0,
        isEnabled: Bool = true,
        updatedAt: Date? = nil,
        sourceNote: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.modelName = modelName
        self.currencyCode = currencyCode
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
        self.sourceNote = sourceNote
    }
}

public struct TokenCostEstimate: Codable, Equatable, Sendable {
    public var currencyCode: String
    public var estimatedAmount: Decimal
    public var modelName: String?
    public var isEstimated: Bool
    public var missingPricingReason: String?

    public init(
        currencyCode: String,
        estimatedAmount: Decimal,
        modelName: String?,
        isEstimated: Bool,
        missingPricingReason: String? = nil
    ) {
        self.currencyCode = currencyCode
        self.estimatedAmount = estimatedAmount
        self.modelName = modelName
        self.isEstimated = isEstimated
        self.missingPricingReason = missingPricingReason
    }
}

public enum TokenCostEstimator {
    public static func estimate(
        breakdown: TokenBreakdown,
        rate: TokenCostRate?,
        modelName: String?
    ) -> TokenCostEstimate? {
        guard breakdown.totalTokens > 0 else { return nil }
        guard let rate, rate.isEnabled else {
            return TokenCostEstimate(
                currencyCode: "USD",
                estimatedAmount: 0,
                modelName: modelName,
                isEstimated: true,
                missingPricingReason: "Pricing rate is not configured"
            )
        }

        let million = Decimal(1_000_000)
        let amount =
            Decimal(breakdown.inputTokens) / million * rate.inputPerMillion
            + Decimal(breakdown.outputTokens) / million * rate.outputPerMillion
            + Decimal(breakdown.cachedInputTokens) / million
                * rate.cachedInputPerMillion
            + Decimal(breakdown.cacheWriteTokens) / million
                * rate.cacheWritePerMillion
            + Decimal(breakdown.cacheReadTokens) / million
                * rate.cacheReadPerMillion
            + Decimal(breakdown.otherTokens) / million * rate.inputPerMillion

        return TokenCostEstimate(
            currencyCode: rate.currencyCode,
            estimatedAmount: amount,
            modelName: modelName ?? rate.modelName,
            isEstimated: breakdown.otherTokens > 0,
            missingPricingReason: nil
        )
    }
}

public enum UsageAvailability: String, Codable, Sendable {
    case measured
    case unavailable
    case failed
}

public enum PlanUsageSource: String, Codable, Sendable {
    case providerReported
    case configuredBudget
    case unavailable
}

public struct PlanUsageWindow: Codable, Equatable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date

    public init(
        label: String,
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date
    ) {
        self.label = label
        self.usedPercent = max(0, min(usedPercent, 100))
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingFraction: Double {
        max(0, min(1 - (usedPercent / 100), 1))
    }

    public var remainingPercent: Int {
        Int((remainingFraction * 100).rounded())
    }
}

public struct PlanUsageSnapshot: Codable, Equatable, Sendable {
    public let source: PlanUsageSource
    public let planName: String?
    public let windows: [PlanUsageWindow]
    public let observedAt: Date?

    public init(
        source: PlanUsageSource,
        planName: String?,
        windows: [PlanUsageWindow],
        observedAt: Date? = nil
    ) {
        self.source = source
        self.planName = planName
        self.windows = windows
        self.observedAt = observedAt
    }

    public func active(at date: Date = .now) -> PlanUsageSnapshot? {
        let activeWindows = windows.filter { $0.resetsAt > date }
        guard !activeWindows.isEmpty else { return nil }
        return PlanUsageSnapshot(
            source: source,
            planName: planName,
            windows: activeWindows,
            observedAt: observedAt
        )
    }
}

public enum PlanUsageReadStatus: Equatable, Sendable {
    case notRequested
    case measured
    case unavailable(String)
    case failed(String)
}

public struct PlanUsageReadResult: Equatable, Sendable {
    public let status: PlanUsageReadStatus
    public let snapshot: PlanUsageSnapshot?

    public init(
        status: PlanUsageReadStatus,
        snapshot: PlanUsageSnapshot? = nil
    ) {
        self.status = status
        self.snapshot = snapshot
    }

    public static func measured(
        _ snapshot: PlanUsageSnapshot
    ) -> PlanUsageReadResult {
        PlanUsageReadResult(status: .measured, snapshot: snapshot)
    }
}

public struct ProviderUsage: Codable, Equatable, Identifiable, Sendable {
    public let id: ProviderID
    public let tier: String
    public let tokenBreakdown: TokenBreakdown
    public let tokenLimit: Int
    public let resetAt: Date
    public let availability: UsageAvailability
    public let sourceDetail: String
    public let planUsage: PlanUsageSnapshot?
    public let modelName: String?
    public let costEstimate: TokenCostEstimate?

    public init(
        id: ProviderID,
        tier: String,
        usedTokens: Int,
        tokenLimit: Int,
        resetAt: Date,
        availability: UsageAvailability,
        sourceDetail: String,
        planUsage: PlanUsageSnapshot? = nil,
        modelName: String? = nil,
        costEstimate: TokenCostEstimate? = nil
    ) {
        self.init(
            id: id,
            tier: tier,
            tokenBreakdown: .aggregate(usedTokens),
            tokenLimit: tokenLimit,
            resetAt: resetAt,
            availability: availability,
            sourceDetail: sourceDetail,
            planUsage: planUsage,
            modelName: modelName,
            costEstimate: costEstimate
        )
    }

    public init(
        id: ProviderID,
        tier: String,
        tokenBreakdown: TokenBreakdown,
        tokenLimit: Int,
        resetAt: Date,
        availability: UsageAvailability,
        sourceDetail: String,
        planUsage: PlanUsageSnapshot? = nil,
        modelName: String? = nil,
        costEstimate: TokenCostEstimate? = nil
    ) {
        self.id = id
        self.tier = tier
        self.tokenBreakdown = tokenBreakdown
        self.tokenLimit = tokenLimit
        self.resetAt = resetAt
        self.availability = availability
        self.sourceDetail = sourceDetail
        self.planUsage = planUsage
        self.modelName = modelName
        self.costEstimate = costEstimate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tier
        case usedTokens
        case tokenBreakdown
        case tokenLimit
        case resetAt
        case availability
        case sourceDetail
        case planUsage
        case modelName
        case costEstimate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        tier = try container.decode(String.self, forKey: .tier)
        if let breakdown = try container.decodeIfPresent(
            TokenBreakdown.self,
            forKey: .tokenBreakdown
        ) {
            tokenBreakdown = breakdown
        } else {
            tokenBreakdown = .aggregate(
                try container.decodeIfPresent(Int.self, forKey: .usedTokens) ?? 0
            )
        }
        tokenLimit = try container.decode(Int.self, forKey: .tokenLimit)
        resetAt = try container.decode(Date.self, forKey: .resetAt)
        availability = try container.decode(
            UsageAvailability.self,
            forKey: .availability
        )
        sourceDetail = try container.decode(String.self, forKey: .sourceDetail)
        planUsage = try container.decodeIfPresent(
            PlanUsageSnapshot.self,
            forKey: .planUsage
        )
        modelName = try container.decodeIfPresent(
            String.self,
            forKey: .modelName
        )
        costEstimate = try container.decodeIfPresent(
            TokenCostEstimate.self,
            forKey: .costEstimate
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tier, forKey: .tier)
        try container.encode(usedTokens, forKey: .usedTokens)
        try container.encode(tokenBreakdown, forKey: .tokenBreakdown)
        try container.encode(tokenLimit, forKey: .tokenLimit)
        try container.encode(resetAt, forKey: .resetAt)
        try container.encode(availability, forKey: .availability)
        try container.encode(sourceDetail, forKey: .sourceDetail)
        try container.encodeIfPresent(planUsage, forKey: .planUsage)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(costEstimate, forKey: .costEstimate)
    }

    public var usedTokens: Int {
        tokenBreakdown.totalTokens
    }

    public var remainingTokens: Int {
        max(tokenLimit - usedTokens, 0)
    }

    public var remainingFraction: Double? {
        remainingFraction(at: .now)
    }

    public func remainingFraction(at date: Date) -> Double? {
        if let primaryWindow = planUsage?.active(at: date)?.windows.first {
            return primaryWindow.remainingFraction
        }
        guard tokenLimit > 0 else { return nil }
        return max(0, min(Double(remainingTokens) / Double(tokenLimit), 1))
    }

    public var remainingPercent: Int? {
        remainingPercent(at: .now)
    }

    public func remainingPercent(at date: Date) -> Int? {
        remainingFraction(at: date).map { Int(($0 * 100).rounded()) }
    }

    public var isLow: Bool {
        isLow(at: .now)
    }

    public func isLow(at date: Date) -> Bool {
        guard let remainingFraction = remainingFraction(at: date) else {
            return false
        }
        return remainingFraction <= 0.25
    }

    public var isUnavailable: Bool {
        availability != .measured
    }

    public var planUsageSource: PlanUsageSource {
        planUsageSource(at: .now)
    }

    public func planUsageSource(at date: Date) -> PlanUsageSource {
        if let source = planUsage?.active(at: date)?.source {
            return source
        }
        return tokenLimit > 0 ? .configuredBudget : .unavailable
    }

    public var primaryPlanWindow: PlanUsageWindow? {
        primaryPlanWindow(at: .now)
    }

    public func primaryPlanWindow(at date: Date) -> PlanUsageWindow? {
        planUsage?.active(at: date)?.windows.first
    }

    public var secondaryPlanWindow: PlanUsageWindow? {
        secondaryPlanWindow(at: .now)
    }

    public func secondaryPlanWindow(at date: Date) -> PlanUsageWindow? {
        guard
            let windows = planUsage?.active(at: date)?.windows,
            windows.count > 1
        else {
            return nil
        }
        return windows[1]
    }
}

public struct ScanResult: Sendable {
    public let provider: ProviderID
    public let tokenBreakdown: TokenBreakdown
    public let availability: UsageAvailability
    public let detail: String
    public let planUsage: PlanUsageSnapshot?
    public let planUsageStatus: PlanUsageReadStatus
    public let hasWarnings: Bool
    public let modelName: String?

    public init(
        provider: ProviderID,
        tokens: Int,
        availability: UsageAvailability,
        detail: String,
        planUsage: PlanUsageSnapshot? = nil,
        planUsageStatus: PlanUsageReadStatus = .notRequested,
        hasWarnings: Bool = false,
        modelName: String? = nil
    ) {
        self.init(
            provider: provider,
            tokenBreakdown: .aggregate(tokens),
            availability: availability,
            detail: detail,
            planUsage: planUsage,
            planUsageStatus: planUsageStatus,
            hasWarnings: hasWarnings,
            modelName: modelName
        )
    }

    public init(
        provider: ProviderID,
        tokenBreakdown: TokenBreakdown,
        availability: UsageAvailability,
        detail: String,
        planUsage: PlanUsageSnapshot? = nil,
        planUsageStatus: PlanUsageReadStatus = .notRequested,
        hasWarnings: Bool = false,
        modelName: String? = nil
    ) {
        self.provider = provider
        self.tokenBreakdown = tokenBreakdown
        self.availability = availability
        self.detail = detail
        self.planUsage = planUsage
        self.planUsageStatus = planUsageStatus
        self.hasWarnings = hasWarnings
        self.modelName = modelName
    }

    public var tokens: Int {
        tokenBreakdown.totalTokens
    }
}
