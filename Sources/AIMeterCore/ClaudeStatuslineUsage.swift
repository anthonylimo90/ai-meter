import Foundation

/// Reads Claude plan usage from the JSON captured by the AI Meter status-line
/// helper. Claude Code passes `rate_limits` (5-hour and weekly windows) to the
/// configured status-line command on stdin; the helper persists it here. This
/// is a documented, ToS-compliant local channel — no credentials, no network.
///
/// https://code.claude.com/docs/en/statusline
public enum ClaudeStatuslineUsage {
    /// Shared location written by the status-line helper and read by AI Meter.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ai-meter/claude-statusline.json")
    }

    /// Builds a provider-reported snapshot from the captured status-line JSON,
    /// or `nil` when the file is missing, unreadable, or carries no usable
    /// window. Window expiry is handled by the caller via `active(at:)`.
    public static func read(
        at url: URL = defaultURL,
        now: Date = .now
    ) -> PlanUsageSnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data),
            let object = root as? [String: Any]
        else {
            return nil
        }
        return snapshot(from: object, observedAt: modificationDate(of: url) ?? now)
    }

    /// Pure parse step, separated for testing.
    public static func snapshot(
        from object: [String: Any],
        observedAt: Date
    ) -> PlanUsageSnapshot? {
        guard let rateLimits = object["rate_limits"] as? [String: Any] else {
            return nil
        }
        var windows: [PlanUsageWindow] = []
        if let window = window(
            from: rateLimits["five_hour"],
            label: "5-hour",
            windowMinutes: 300
        ) {
            windows.append(window)
        }
        if let window = window(
            from: rateLimits["seven_day"],
            label: "Weekly",
            windowMinutes: 10_080
        ) {
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }
        return PlanUsageSnapshot(
            source: .providerReported,
            planName: nil,
            windows: windows,
            observedAt: observedAt
        )
    }

    private static func window(
        from value: Any?,
        label: String,
        windowMinutes: Int
    ) -> PlanUsageWindow? {
        guard
            let object = value as? [String: Any],
            let usedPercent = number(object["used_percentage"]),
            let resetsAt = number(object["resets_at"])
        else {
            return nil
        }
        return PlanUsageWindow(
            label: label,
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }
}
