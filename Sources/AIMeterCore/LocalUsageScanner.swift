import Foundation

public enum LocalUsageScanner {
    public static func scan(configurations: [ProviderConfiguration]) -> [ScanResult] {
        configurations.map(scan)
    }

    private static func scan(configuration: ProviderConfiguration) -> ScanResult {
        let windowStart = Calendar.current.date(
            byAdding: .hour,
            value: -max(configuration.windowHours, 1),
            to: configuration.nextResetAt
        ) ?? .distantPast

        let roots = resolvedRoots(for: configuration)
        guard !roots.isEmpty else {
            return ScanResult(
                provider: configuration.id,
                tokens: 0,
                availability: .unavailable,
                detail: "No local data folder is available"
            )
        }

        do {
            let files = try usageFiles(in: roots, modifiedAfter: windowStart)
            guard !files.isEmpty else {
                return ScanResult(
                    provider: configuration.id,
                    tokens: 0,
                    availability: .unavailable,
                    detail: "No recent compatible records found"
                )
            }

            let tokens: Int
            let planUsage: PlanUsageSnapshot?
            switch configuration.id {
            case .openAI:
                let result = try scanCodex(files: files, after: windowStart)
                tokens = result.tokens
                planUsage = result.planUsage
            case .claude:
                tokens = try scanClaude(files: files, after: windowStart)
                planUsage = ClaudeUsageProbe.fetch()
            case .gemini, .cursor, .copilot:
                tokens = try scanGeneric(files: files, after: windowStart)
                planUsage = nil
            }

            return ScanResult(
                provider: configuration.id,
                tokens: tokens,
                availability: tokens > 0 ? .measured : .unavailable,
                detail: sourceDetail(
                    provider: configuration.id,
                    tokens: tokens,
                    hasPlanUsage: planUsage != nil
                ),
                planUsage: planUsage
            )
        } catch {
            return ScanResult(
                provider: configuration.id,
                tokens: 0,
                availability: .failed,
                detail: error.localizedDescription
            )
        }
    }

    private static func resolvedRoots(
        for configuration: ProviderConfiguration
    ) -> [URL] {
        var paths = configuration.id.builtInPaths
        let trimmedCustomPath = configuration.customPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustomPath.isEmpty {
            paths.append(trimmedCustomPath)
        }

        return paths
            .map(expandHome(in:))
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func expandHome(in path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path
            + String(path.dropFirst())
    }

    private static func usageFiles(
        in roots: [URL],
        modifiedAfter windowStart: Date
    ) throws -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let supportedExtensions = Set(["json", "jsonl", "log"])
        var files: [URL] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ) else {
                continue
            }

            if !isDirectory.boolValue {
                files.append(root)
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                guard (values?.fileSize ?? 0) <= 25_000_000 else { continue }
                guard (values?.contentModificationDate ?? .distantPast) >= windowStart else {
                    continue
                }
                files.append(fileURL)
            }
        }

        return files
    }

    private static func sourceDetail(
        provider: ProviderID,
        tokens: Int,
        hasPlanUsage: Bool
    ) -> String {
        if hasPlanUsage {
            return "\(provider.sourceLabel): provider-reported plan limits and local tokens"
        }
        if tokens > 0 {
            return "\(provider.sourceLabel): local tokens; plan usage is not exposed"
        }
        return "Records found, but no compatible token metadata"
    }

    private static func scanCodex(
        files: [URL],
        after windowStart: Date
    ) throws -> (tokens: Int, planUsage: PlanUsageSnapshot?) {
        var total = 0
        var newestPlanUsage: (date: Date, snapshot: PlanUsageSnapshot)?

        for file in files where file.pathExtension == "jsonl" {
            var sessionMaximum = 0
            try forEachJSONLine(in: file) { object in
                let date = recordDate(in: object, fallback: windowStart)
                guard date >= windowStart else {
                    return
                }
                sessionMaximum = max(
                    sessionMaximum,
                    TokenLogParser.codexSessionTotal(in: object) ?? 0
                )
                if let snapshot = TokenLogParser.codexPlanUsage(in: object),
                   newestPlanUsage == nil || date > newestPlanUsage!.date {
                    newestPlanUsage = (
                        date,
                        PlanUsageSnapshot(
                            source: snapshot.source,
                            planName: snapshot.planName,
                            windows: snapshot.windows,
                            observedAt: date
                        )
                    )
                }
            }
            total += sessionMaximum
        }

        guard let latest = newestPlanUsage?.snapshot else {
            return (total, nil)
        }
        let activeWindows = latest.windows.filter { $0.resetsAt > .now }
        guard !activeWindows.isEmpty else {
            return (total, nil)
        }
        return (
            total,
            PlanUsageSnapshot(
                source: latest.source,
                planName: latest.planName,
                windows: activeWindows,
                observedAt: latest.observedAt
            )
        )
    }

    private static func scanClaude(files: [URL], after windowStart: Date) throws -> Int {
        var messageTotals: [String: Int] = [:]

        for file in files where file.pathExtension == "jsonl" {
            try forEachJSONLine(in: file) { object in
                guard recordDate(in: object, fallback: windowStart) >= windowStart else {
                    return
                }
                guard let usage = TokenLogParser.claudeUsage(in: object) else {
                    return
                }
                let key = usage.identifier ?? "\(file.path):\(messageTotals.count)"
                messageTotals[key] = max(messageTotals[key] ?? 0, usage.tokens)
            }
        }

        return messageTotals.values.reduce(0, +)
    }

    private static func scanGeneric(files: [URL], after windowStart: Date) throws -> Int {
        var records: [String: Int] = [:]

        for file in files {
            if file.pathExtension == "jsonl" || file.pathExtension == "log" {
                try forEachJSONLine(in: file) { object in
                    guard recordDate(in: object, fallback: windowStart) >= windowStart else {
                        return
                    }
                    guard let usage = TokenLogParser.genericUsage(in: object) else {
                        return
                    }
                    let key = usage.identifier ?? "\(file.path):\(records.count)"
                    records[key] = max(records[key] ?? 0, usage.tokens)
                }
            } else if file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                let object = try JSONSerialization.jsonObject(with: data)
                collectGenericUsage(
                    from: object,
                    file: file,
                    windowStart: windowStart,
                    records: &records
                )
            }
        }

        return records.values.reduce(0, +)
    }

    private static func collectGenericUsage(
        from object: Any,
        file: URL,
        windowStart: Date,
        records: inout [String: Int]
    ) {
        if let dictionary = object as? [String: Any] {
            if recordDate(in: dictionary, fallback: windowStart) >= windowStart,
               let usage = TokenLogParser.genericUsage(in: dictionary) {
                let key = usage.identifier ?? "\(file.path):\(records.count)"
                records[key] = max(records[key] ?? 0, usage.tokens)
            }

            for value in dictionary.values {
                collectGenericUsage(
                    from: value,
                    file: file,
                    windowStart: windowStart,
                    records: &records
                )
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectGenericUsage(
                    from: value,
                    file: file,
                    windowStart: windowStart,
                    records: &records
                )
            }
        }
    }

    private static func forEachJSONLine(
        in file: URL,
        body: ([String: Any]) -> Void
    ) throws {
        let contents = try String(contentsOf: file, encoding: .utf8)
        for line in contents.split(whereSeparator: \.isNewline) {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                continue
            }
            body(object)
        }
    }

    private static func recordDate(
        in object: [String: Any],
        fallback: Date
    ) -> Date {
        let candidates = ["timestamp", "created_at", "createdAt", "time"]
        for key in candidates {
            if let string = object[key] as? String,
               let date = parseISO8601Date(string) {
                return date
            }
            if let seconds = object[key] as? TimeInterval {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return fallback
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct ParsedTokenUsage: Equatable, Sendable {
    let identifier: String?
    let tokens: Int
}

enum TokenLogParser {
    static func codexSessionTotal(in object: [String: Any]) -> Int? {
        guard
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let totalUsage = info["total_token_usage"] as? [String: Any]
        else {
            return nil
        }
        return integer(in: totalUsage, keys: ["total_tokens"])
    }

    static func codexPlanUsage(
        in object: [String: Any]
    ) -> PlanUsageSnapshot? {
        guard
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let rateLimits = payload["rate_limits"] as? [String: Any]
        else {
            return nil
        }

        var windows: [PlanUsageWindow] = []
        if let primary = planWindow(
            in: rateLimits,
            key: "primary",
            fallbackLabel: "Session"
        ) {
            windows.append(primary)
        }
        if let secondary = planWindow(
            in: rateLimits,
            key: "secondary",
            fallbackLabel: "Weekly"
        ) {
            windows.append(secondary)
        }
        guard !windows.isEmpty else { return nil }

        return PlanUsageSnapshot(
            source: .providerReported,
            planName: normalizedPlanName(rateLimits["plan_type"] as? String),
            windows: windows
        )
    }

    static func claudeUsage(in object: [String: Any]) -> ParsedTokenUsage? {
        guard
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else {
            return nil
        }

        let total = sum(
            in: usage,
            keys: [
                "input_tokens",
                "output_tokens",
                "cache_creation_input_tokens",
                "cache_read_input_tokens"
            ]
        )
        guard total > 0 else { return nil }

        let identifier = message["id"] as? String
            ?? object["requestId"] as? String
            ?? object["uuid"] as? String
        return ParsedTokenUsage(identifier: identifier, tokens: total)
    }

    static func genericUsage(in object: [String: Any]) -> ParsedTokenUsage? {
        let usageContainers = [
            object["usage"],
            object["usageMetadata"],
            object["tokenUsage"],
            (object["message"] as? [String: Any])?["usage"]
        ]

        for case let usage as [String: Any] in usageContainers {
            let explicitTotal = integer(
                in: usage,
                keys: [
                    "total_tokens",
                    "totalTokens",
                    "totalTokenCount",
                    "total_token_count"
                ]
            )
            let total = explicitTotal ?? sum(
                in: usage,
                keys: [
                    "input_tokens",
                    "output_tokens",
                    "prompt_tokens",
                    "completion_tokens",
                    "inputTokenCount",
                    "outputTokenCount",
                    "promptTokenCount",
                    "candidatesTokenCount",
                    "cachedContentTokenCount"
                ]
            )
            guard total > 0 else { continue }

            let identifier = object["id"] as? String
                ?? object["uuid"] as? String
                ?? object["requestId"] as? String
                ?? object["request_id"] as? String
            return ParsedTokenUsage(identifier: identifier, tokens: total)
        }

        return nil
    }

    private static func sum(in dictionary: [String: Any], keys: [String]) -> Int {
        keys.reduce(0) { partial, key in
            partial + (integer(in: dictionary, keys: [key]) ?? 0)
        }
    }

    private static func integer(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.intValue
            }
            if let value = dictionary[key] as? String, let number = Int(value) {
                return number
            }
        }
        return nil
    }

    private static func double(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = dictionary[key] as? String,
               let number = Double(value) {
                return number
            }
        }
        return nil
    }

    private static func planWindow(
        in rateLimits: [String: Any],
        key: String,
        fallbackLabel: String
    ) -> PlanUsageWindow? {
        guard
            let window = rateLimits[key] as? [String: Any],
            let usedPercent = double(in: window, keys: ["used_percent"]),
            let windowMinutes = integer(in: window, keys: ["window_minutes"]),
            let resetsAt = double(in: window, keys: ["resets_at"])
        else {
            return nil
        }

        let label: String
        switch windowMinutes {
        case 300:
            label = "5-hour"
        case 10_080:
            label = "Weekly"
        default:
            label = fallbackLabel
        }

        return PlanUsageWindow(
            label: label,
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private static func normalizedPlanName(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
