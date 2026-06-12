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

    public init(
        id: ProviderID,
        isEnabled: Bool,
        tier: String,
        tokenLimit: Int,
        windowHours: Int,
        nextResetAt: Date,
        customPath: String
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.tier = tier
        self.tokenLimit = tokenLimit
        self.windowHours = windowHours
        self.nextResetAt = nextResetAt
        self.customPath = customPath
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
}

public struct ProviderUsage: Codable, Equatable, Identifiable, Sendable {
    public let id: ProviderID
    public let tier: String
    public let usedTokens: Int
    public let tokenLimit: Int
    public let resetAt: Date
    public let availability: UsageAvailability
    public let sourceDetail: String
    public let planUsage: PlanUsageSnapshot?

    public init(
        id: ProviderID,
        tier: String,
        usedTokens: Int,
        tokenLimit: Int,
        resetAt: Date,
        availability: UsageAvailability,
        sourceDetail: String,
        planUsage: PlanUsageSnapshot? = nil
    ) {
        self.id = id
        self.tier = tier
        self.usedTokens = usedTokens
        self.tokenLimit = tokenLimit
        self.resetAt = resetAt
        self.availability = availability
        self.sourceDetail = sourceDetail
        self.planUsage = planUsage
    }

    public var remainingTokens: Int {
        max(tokenLimit - usedTokens, 0)
    }

    public var remainingFraction: Double? {
        if let primaryWindow = planUsage?.windows.first {
            return primaryWindow.remainingFraction
        }
        guard tokenLimit > 0 else { return nil }
        return max(0, min(Double(remainingTokens) / Double(tokenLimit), 1))
    }

    public var remainingPercent: Int? {
        remainingFraction.map { Int(($0 * 100).rounded()) }
    }

    public var isLow: Bool {
        guard let remainingFraction else { return false }
        return remainingFraction <= 0.25
    }

    public var isUnavailable: Bool {
        availability != .measured
    }

    public var planUsageSource: PlanUsageSource {
        if let source = planUsage?.source {
            return source
        }
        return tokenLimit > 0 ? .configuredBudget : .unavailable
    }

    public var primaryPlanWindow: PlanUsageWindow? {
        planUsage?.windows.first
    }

    public var secondaryPlanWindow: PlanUsageWindow? {
        guard let windows = planUsage?.windows, windows.count > 1 else {
            return nil
        }
        return windows[1]
    }
}

public struct ScanResult: Sendable {
    public let provider: ProviderID
    public let tokens: Int
    public let availability: UsageAvailability
    public let detail: String
    public let planUsage: PlanUsageSnapshot?
    public let hasWarnings: Bool

    public init(
        provider: ProviderID,
        tokens: Int,
        availability: UsageAvailability,
        detail: String,
        planUsage: PlanUsageSnapshot? = nil,
        hasWarnings: Bool = false
    ) {
        self.provider = provider
        self.tokens = tokens
        self.availability = availability
        self.detail = detail
        self.planUsage = planUsage
        self.hasWarnings = hasWarnings
    }
}
