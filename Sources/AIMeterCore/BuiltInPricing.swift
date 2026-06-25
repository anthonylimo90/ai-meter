import Foundation

/// Bundled, list-price pricing keyed by model name.
///
/// These are public per-million-token prices used to show approximate costs
/// out of the box, without the user having to type rates by hand. A user's
/// `customRates` always take precedence over anything here (see
/// `BuiltInPricing.rate(for:modelName:)` callers) — this table is the fallback.
///
/// Prices go stale when providers change them or ship new models. To refresh:
/// edit the rows below and bump `lastUpdated`. Each row records where its
/// numbers came from in `sourceNote`.
///
/// Sources (captured 2026-06-25):
/// - Anthropic: platform.claude.com list prices. Cache-write is the 5-minute
///   TTL rate (1.25x input); cache-read is ~0.1x input.
/// - OpenAI: openai.com/api/pricing. `cachedInputPerMillion` is the cached
///   prompt rate.
/// - Google: ai.google.dev/gemini-api/docs/pricing (standard context tier).
/// Cursor and Copilot bill on a flat subscription rather than per-token, so
/// they are intentionally absent — a per-token estimate there would mislead.
public enum BuiltInPricing {
    /// The date these list prices were last verified. Surfaced through each
    /// rate's `updatedAt` so the UI can show how fresh the bundled numbers are.
    public static let lastUpdated: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 25
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }()

    /// All bundled rates, in priority order within a provider (more specific
    /// model names first so longest-prefix matching resolves correctly).
    public static let rates: [TokenCostRate] = anthropicRates
        + openAIRates
        + geminiRates

    /// Returns the bundled rate for a detected model under a provider, or `nil`
    /// when nothing matches. Matching is case-insensitive: an exact model-name
    /// match wins; otherwise the longest bundled model name that is a prefix of
    /// the detected name is used (so `claude-opus-4-8[1m]` resolves to the
    /// `claude-opus-4-8` row).
    public static func rate(
        for provider: ProviderID,
        modelName: String?
    ) -> TokenCostRate? {
        guard let normalized = normalizedModelName(modelName) else { return nil }
        let candidates = rates.filter { $0.provider == provider }

        if let exact = candidates.first(where: {
            $0.modelName.lowercased() == normalized
        }) {
            return exact
        }

        return candidates
            .filter { normalized.hasPrefix($0.modelName.lowercased()) }
            .max { $0.modelName.count < $1.modelName.count }
    }

    private static func normalizedModelName(_ modelName: String?) -> String? {
        guard let modelName else { return nil }
        var trimmed = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Gemini logs can prefix the model with "models/".
        if trimmed.hasPrefix("models/") {
            trimmed = String(trimmed.dropFirst("models/".count))
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exact `Decimal` from a literal string. Constructing `Decimal` from a
    /// floating-point literal routes through `Double` and introduces binary
    /// rounding error (e.g. `0.3`, `0.175`); string parsing is exact, which is
    /// the whole point of pricing in `Decimal`.
    private static func dec(_ value: String) -> Decimal {
        Decimal(string: value) ?? 0
    }

    private static func anthropic(
        _ modelName: String,
        input: String,
        output: String,
        cacheWrite: String,
        cacheRead: String
    ) -> TokenCostRate {
        TokenCostRate(
            id: "builtin.\(modelName)",
            provider: .claude,
            modelName: modelName,
            inputPerMillion: dec(input),
            outputPerMillion: dec(output),
            cachedInputPerMillion: dec(cacheRead),
            cacheWritePerMillion: dec(cacheWrite),
            cacheReadPerMillion: dec(cacheRead),
            updatedAt: lastUpdated,
            sourceNote: "Anthropic list price"
        )
    }

    private static let anthropicRates: [TokenCostRate] = [
        anthropic("claude-fable-5", input: "10", output: "50", cacheWrite: "12.5", cacheRead: "1"),
        anthropic("claude-opus-4-8", input: "5", output: "25", cacheWrite: "6.25", cacheRead: "0.5"),
        anthropic("claude-opus-4-7", input: "5", output: "25", cacheWrite: "6.25", cacheRead: "0.5"),
        anthropic("claude-opus-4-6", input: "5", output: "25", cacheWrite: "6.25", cacheRead: "0.5"),
        anthropic("claude-sonnet-4-6", input: "3", output: "15", cacheWrite: "3.75", cacheRead: "0.3"),
        anthropic("claude-haiku-4-5", input: "1", output: "5", cacheWrite: "1.25", cacheRead: "0.1")
    ]

    private static func openAI(
        _ modelName: String,
        input: String,
        output: String,
        cachedInput: String
    ) -> TokenCostRate {
        TokenCostRate(
            id: "builtin.\(modelName)",
            provider: .openAI,
            modelName: modelName,
            inputPerMillion: dec(input),
            outputPerMillion: dec(output),
            cachedInputPerMillion: dec(cachedInput),
            cacheWritePerMillion: 0,
            cacheReadPerMillion: dec(cachedInput),
            updatedAt: lastUpdated,
            sourceNote: "OpenAI list price"
        )
    }

    // Ordered so that more specific names (e.g. gpt-5.3-codex) win the
    // longest-prefix match over shorter ones (e.g. gpt-5-codex).
    private static let openAIRates: [TokenCostRate] = [
        openAI("gpt-5.3-codex", input: "1.75", output: "14", cachedInput: "0.175"),
        openAI("gpt-5-codex", input: "1.25", output: "10", cachedInput: "0.125"),
        openAI("gpt-5.5", input: "5", output: "30", cachedInput: "0.5"),
        openAI("gpt-5.4", input: "2.5", output: "15", cachedInput: "0.25")
    ]

    private static func gemini(
        _ modelName: String,
        input: String,
        output: String
    ) -> TokenCostRate {
        TokenCostRate(
            id: "builtin.\(modelName)",
            provider: .gemini,
            modelName: modelName,
            inputPerMillion: dec(input),
            outputPerMillion: dec(output),
            updatedAt: lastUpdated,
            sourceNote: "Google list price (standard context)"
        )
    }

    private static let geminiRates: [TokenCostRate] = [
        gemini("gemini-2.5-pro", input: "1.25", output: "10"),
        gemini("gemini-2.5-flash", input: "0.3", output: "2.5")
    ]
}
