import Darwin
import Foundation

public enum LocalUsageScanner {
    public static func results(
        configurations: [ProviderConfiguration],
        fetchClaudeQuota: Bool = true
    ) -> AsyncStream<ScanResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: ScanResult?.self) { group in
                    for configuration in configurations {
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            return scan(
                                configuration: configuration,
                                claudeUsage: {
                                    fetchClaudeQuota
                                        ? ClaudeUsageProbe.fetch()
                                        : nil
                                }
                            )
                        }
                    }

                    for await result in group {
                        guard !Task.isCancelled else { break }
                        if let result {
                            continuation.yield(result)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func scan(
        configurations: [ProviderConfiguration],
        fetchClaudeQuota: Bool = true
    ) async -> [ScanResult] {
        var resultsByProvider: [ProviderID: ScanResult] = [:]
        for await result in results(
            configurations: configurations,
            fetchClaudeQuota: fetchClaudeQuota
        ) {
            resultsByProvider[result.provider] = result
        }
        return configurations.compactMap {
            resultsByProvider[$0.id]
        }
    }

    static func scan(
        configuration: ProviderConfiguration,
        rootsOverride: [URL]? = nil,
        now: Date = .now,
        claudeUsage: @Sendable () -> PlanUsageSnapshot? = {
            ClaudeUsageProbe.fetch()
        }
    ) -> ScanResult {
        let windowStart = Calendar.current.date(
            byAdding: .hour,
            value: -max(configuration.windowHours, 1),
            to: configuration.nextResetAt
        ) ?? .distantPast

        let roots = rootsOverride ?? resolvedRoots(for: configuration)
        let files: [URL]
        do {
            files = try DirectoryInventoryCache.files(
                in: roots,
                modifiedAfter: windowStart
            )
        } catch {
            return ScanResult(
                provider: configuration.id,
                tokens: 0,
                availability: .failed,
                detail: error.localizedDescription
            )
        }

        switch configuration.id {
        case .claude:
            let tokenScan = scanClaude(files: files, after: windowStart)
            let planUsage = claudeUsage()
            return scanResult(
                configuration: configuration,
                tokenScan: tokenScan,
                planUsage: planUsage,
                hasRoots: !roots.isEmpty
            )
        case .openAI:
            guard !roots.isEmpty else {
                return ScanResult(
                    provider: configuration.id,
                    tokens: 0,
                    availability: .unavailable,
                    detail: "No local data folder is available"
                )
            }
            let scan = scanCodex(files: files, after: windowStart)
            return scanResult(
                configuration: configuration,
                tokenScan: scan.tokenScan,
                planUsage: activePlanUsage(scan.planUsage, now: now),
                hasRoots: true
            )
        case .gemini, .cursor, .copilot:
            guard !roots.isEmpty else {
                return ScanResult(
                    provider: configuration.id,
                    tokens: 0,
                    availability: .unavailable,
                    detail: "No local data folder is available"
                )
            }
            let tokenScan = scanGeneric(
                files: files,
                provider: configuration.id,
                after: windowStart
            )
            return scanResult(
                configuration: configuration,
                tokenScan: tokenScan,
                planUsage: nil,
                hasRoots: true
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

    fileprivate static func usageFiles(
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

        return files.sorted { $0.path < $1.path }
    }

    private static func scanResult(
        configuration: ProviderConfiguration,
        tokenScan: TokenScan,
        planUsage: PlanUsageSnapshot?,
        hasRoots: Bool
    ) -> ScanResult {
        let availability: UsageAvailability
        if tokenScan.tokens > 0 {
            availability = .measured
        } else if tokenScan.failedFiles > 0 && tokenScan.readableFiles == 0 {
            availability = .failed
        } else {
            availability = .unavailable
        }

        var detail: String
        if planUsage != nil && tokenScan.tokens > 0 {
            detail = "\(configuration.id.sourceLabel): provider-reported plan limits and local tokens"
        } else if planUsage != nil {
            detail = "Provider-reported plan limits detected; no recent local token data"
        } else if tokenScan.tokens > 0 {
            detail = "\(configuration.id.sourceLabel): local tokens; plan usage is not exposed"
        } else if !hasRoots {
            detail = "No local data folder is available"
        } else if tokenScan.candidateFiles == 0 {
            detail = "No recent compatible records found"
        } else if tokenScan.failedFiles > 0 && tokenScan.readableFiles == 0 {
            detail = "Compatible records could not be read"
        } else {
            detail = "Records found, but no timestamped compatible token metadata"
        }

        if tokenScan.failedFiles > 0 && tokenScan.readableFiles > 0 {
            detail += "; skipped \(tokenScan.failedFiles) unreadable "
                + (tokenScan.failedFiles == 1 ? "file" : "files")
        }

        return ScanResult(
            provider: configuration.id,
            tokens: tokenScan.tokens,
            availability: availability,
            detail: detail,
            planUsage: planUsage,
            hasWarnings: tokenScan.failedFiles > 0
        )
    }

    private static func scanCodex(
        files: [URL],
        after windowStart: Date
    ) -> CodexScan {
        var total = 0
        var newestPlanUsage: (date: Date, snapshot: PlanUsageSnapshot)?
        var readableFiles = 0
        var failedFiles = 0
        let candidateFiles = files.filter {
            $0.pathExtension.lowercased() == "jsonl"
        }

        for file in candidateFiles {
            guard !Task.isCancelled else { break }
            do {
                let contribution = try IncrementalFileCache.codexContribution(
                    for: file,
                    windowStart: windowStart
                )
                if let snapshot = contribution.newestPlanUsage,
                   newestPlanUsage == nil
                    || snapshot.date > newestPlanUsage!.date {
                    newestPlanUsage = snapshot
                }
                readableFiles += 1
                total += max(
                    contribution.sessionMaximum - contribution.baseline,
                    0
                )
            } catch {
                failedFiles += 1
            }
        }

        let tokenScan = TokenScan(
            tokens: total,
            candidateFiles: candidateFiles.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles
        )
        guard let latest = newestPlanUsage?.snapshot else {
            return CodexScan(tokenScan: tokenScan, planUsage: nil)
        }
        return CodexScan(
            tokenScan: tokenScan,
            planUsage: latest
        )
    }

    private static func activePlanUsage(
        _ snapshot: PlanUsageSnapshot?,
        now: Date
    ) -> PlanUsageSnapshot? {
        guard let snapshot else { return nil }
        let activeWindows = snapshot.windows.filter { $0.resetsAt > now }
        guard !activeWindows.isEmpty else { return nil }
        return PlanUsageSnapshot(
            source: snapshot.source,
            planName: snapshot.planName,
            windows: activeWindows,
            observedAt: snapshot.observedAt
        )
    }

    private static func scanClaude(
        files: [URL],
        after windowStart: Date
    ) -> TokenScan {
        var messageTotals: [String: Int] = [:]
        var readableFiles = 0
        var failedFiles = 0
        let candidateFiles = files.filter {
            $0.pathExtension.lowercased() == "jsonl"
        }

        for file in candidateFiles {
            guard !Task.isCancelled else { break }
            do {
                let contribution = try IncrementalFileCache.tokenContribution(
                    for: file,
                    provider: .claude,
                    windowStart: windowStart
                )
                for (key, tokens) in contribution.records {
                    messageTotals[key] = max(messageTotals[key] ?? 0, tokens)
                }
                readableFiles += 1
            } catch {
                failedFiles += 1
            }
        }

        return TokenScan(
            tokens: messageTotals.values.reduce(0, +),
            candidateFiles: candidateFiles.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles
        )
    }

    private static func scanGeneric(
        files: [URL],
        provider: ProviderID,
        after windowStart: Date
    ) -> TokenScan {
        var records: [String: Int] = [:]
        var readableFiles = 0
        var failedFiles = 0

        for file in files {
            guard !Task.isCancelled else { break }
            do {
                let pathExtension = file.pathExtension.lowercased()
                if pathExtension == "jsonl" || pathExtension == "log" {
                    let contribution = try IncrementalFileCache.tokenContribution(
                        for: file,
                        provider: provider,
                        windowStart: windowStart
                    )
                    for (key, tokens) in contribution.records {
                        records[key] = max(records[key] ?? 0, tokens)
                    }
                } else if pathExtension == "json" {
                    let contribution = try IncrementalFileCache.jsonContribution(
                        for: file,
                        windowStart: windowStart
                    )
                    for (key, tokens) in contribution.records {
                        records[key] = max(records[key] ?? 0, tokens)
                    }
                }
                readableFiles += 1
            } catch {
                failedFiles += 1
            }
        }

        return TokenScan(
            tokens: records.values.reduce(0, +),
            candidateFiles: files.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles
        )
    }

    fileprivate static func collectGenericUsage(
        from object: Any,
        file: URL,
        inheritedDate: Date?,
        windowStart: Date,
        records: inout [String: Int]
    ) {
        if let dictionary = object as? [String: Any] {
            let date = recordDate(in: dictionary) ?? inheritedDate
            if let date,
               date >= windowStart,
               let usage = TokenLogParser.genericUsage(in: dictionary) {
                let key = usage.identifier ?? "\(file.path):\(records.count)"
                records[key] = max(records[key] ?? 0, usage.tokens)
            }

            for value in dictionary.values {
                collectGenericUsage(
                    from: value,
                    file: file,
                    inheritedDate: date,
                    windowStart: windowStart,
                    records: &records
                )
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectGenericUsage(
                    from: value,
                    file: file,
                    inheritedDate: inheritedDate,
                    windowStart: windowStart,
                    records: &records
                )
            }
        }
    }

    fileprivate static func forEachJSONLine(
        in file: URL,
        fromOffset offset: UInt64 = 0,
        body: ([String: Any]) -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: file)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: offset)
        var pending = Data()
        var processedOffset = offset
        while let chunk = try handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                parseJSONLine(Data(line), body: body)
                processedOffset += UInt64(newline + 1)
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty,
           parseJSONLine(pending, body: body) {
            processedOffset += UInt64(pending.count)
        }
        return processedOffset
    }

    @discardableResult
    private static func parseJSONLine(
        _ data: Data,
        body: ([String: Any]) -> Void
    ) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return false
        }
        body(object)
        return true
    }

    fileprivate static func recordDate(in object: [String: Any]) -> Date? {
        let candidates = ["timestamp", "created_at", "createdAt", "time"]
        for key in candidates {
            if let string = object[key] as? String,
               let date = parseISO8601Date(string) {
                return date
            }
            if let seconds = object[key] as? TimeInterval {
                return dateFromUnixTimestamp(seconds)
            }
        }
        return nil
    }

    private static func dateFromUnixTimestamp(_ value: TimeInterval) -> Date {
        let seconds = abs(value) >= 100_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        if let date = try? Date(
            value,
            strategy: .iso8601
        ) {
            return date
        }
        return try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true
            )
        )
    }
}

private struct TokenScan: Sendable {
    let tokens: Int
    let candidateFiles: Int
    let readableFiles: Int
    let failedFiles: Int
}

private struct CodexScan: Sendable {
    let tokenScan: TokenScan
    let planUsage: PlanUsageSnapshot?
}

private struct FileSignature: Hashable, Sendable {
    let path: String
    let modifiedAt: Date
    let size: Int
}

private struct InventoryCacheKey: Hashable, Sendable {
    let roots: [String]
    let windowStart: Date
}

private struct DirectoryInventoryEntry: Sendable {
    let createdAt: Date
    let files: [URL]
}

private enum DirectoryInventoryCache {
    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var entries: [InventoryCacheKey: DirectoryInventoryEntry] = [:]

    static func files(
        in roots: [URL],
        modifiedAfter windowStart: Date
    ) throws -> [URL] {
        ensureWatchers(for: roots)
        let key = InventoryCacheKey(
            roots: roots.map(\.standardizedFileURL.path).sorted(),
            windowStart: windowStart
        )
        if let cached = lock.withLock({ entries[key] }),
           Date().timeIntervalSince(cached.createdAt) < 5 {
            return cached.files
        }
        let files = try LocalUsageScanner.usageFiles(
            in: roots,
            modifiedAfter: windowStart
        )
        lock.withLock {
            entries[key] = DirectoryInventoryEntry(
                createdAt: .now,
                files: files
            )
            if entries.count > 20 {
                entries = entries.filter {
                    Date().timeIntervalSince($0.value.createdAt) < 30
                }
            }
        }
        return files
    }

    private static func ensureWatchers(for roots: [URL]) {
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            let path = root.standardizedFileURL.path
            let needsWatcher = lock.withLock {
                watchers[path] == nil
            }
            guard needsWatcher else { continue }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                lock.withLock {
                    entries = entries.filter {
                        !$0.key.roots.contains(path)
                    }
                }
            }
            source.setCancelHandler {
                close(descriptor)
            }
            lock.withLock {
                watchers[path] = source
            }
            source.resume()
        }
    }

    nonisolated(unsafe)
    private static var watchers: [
        String: DispatchSourceFileSystemObject
    ] = [:]
}

private struct CodexFileContribution: Sendable {
    var baseline = 0
    var sessionMaximum = 0
    var newestPlanUsage: (
        date: Date,
        snapshot: PlanUsageSnapshot
    )?
}

private struct TokenFileContribution: Sendable {
    var records: [String: Int] = [:]
}

private enum FileContribution: Sendable {
    case codex(CodexFileContribution)
    case tokens(TokenFileContribution)
}

private struct IncrementalFileEntry: Sendable {
    let windowStart: Date
    let modifiedAt: Date
    let size: Int
    let processedOffset: UInt64
    let contribution: FileContribution
}

private enum IncrementalFileCache {
    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var entries: [String: IncrementalFileEntry] = [:]

    static func codexContribution(
        for file: URL,
        windowStart: Date
    ) throws -> CodexFileContribution {
        let signature = fileSignature(file)
        let path = file.standardizedFileURL.path
        let cacheKey = "\(ProviderID.openAI.rawValue)|\(path)"
        let cached = lock.withLock { entries[cacheKey] }
        var contribution: CodexFileContribution
        var offset: UInt64
        if let cached,
           cached.windowStart == windowStart,
           cached.size <= signature.size,
           case let .codex(value) = cached.contribution {
            if cached.size == signature.size,
               cached.modifiedAt == signature.modifiedAt {
                return value
            }
            contribution = value
            offset = cached.processedOffset
        } else {
            contribution = CodexFileContribution()
            offset = 0
        }

        let newOffset = try LocalUsageScanner.forEachJSONLine(
            in: file,
            fromOffset: offset
        ) { object in
            guard let date = LocalUsageScanner.recordDate(in: object) else {
                return
            }
            if let total = TokenLogParser.codexSessionTotal(in: object) {
                if date < windowStart {
                    contribution.baseline = max(contribution.baseline, total)
                } else {
                    contribution.sessionMaximum = max(
                        contribution.sessionMaximum,
                        total
                    )
                }
            }
            if date >= windowStart,
               let snapshot = TokenLogParser.codexPlanUsage(in: object),
               contribution.newestPlanUsage == nil
                || date > contribution.newestPlanUsage!.date {
                contribution.newestPlanUsage = (
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
        store(
            key: cacheKey,
            signature: signature,
            windowStart: windowStart,
            processedOffset: newOffset,
            contribution: .codex(contribution)
        )
        return contribution
    }

    static func tokenContribution(
        for file: URL,
        provider: ProviderID,
        windowStart: Date
    ) throws -> TokenFileContribution {
        let signature = fileSignature(file)
        let path = file.standardizedFileURL.path
        let cacheKey = "\(provider.rawValue)|\(path)"
        let cached = lock.withLock { entries[cacheKey] }
        var contribution: TokenFileContribution
        var offset: UInt64
        if let cached,
           cached.windowStart == windowStart,
           cached.size <= signature.size,
           case let .tokens(value) = cached.contribution {
            if cached.size == signature.size,
               cached.modifiedAt == signature.modifiedAt {
                return value
            }
            contribution = value
            offset = cached.processedOffset
        } else {
            contribution = TokenFileContribution()
            offset = 0
        }

        let newOffset = try LocalUsageScanner.forEachJSONLine(
            in: file,
            fromOffset: offset
        ) { object in
            guard let date = LocalUsageScanner.recordDate(in: object),
                  date >= windowStart else {
                return
            }
            let usage = provider == .claude
                ? TokenLogParser.claudeUsage(in: object)
                : TokenLogParser.genericUsage(in: object)
            guard let usage else { return }
            let key = usage.identifier
                ?? "\(path):\(contribution.records.count)"
            contribution.records[key] = max(
                contribution.records[key] ?? 0,
                usage.tokens
            )
        }
        store(
            key: cacheKey,
            signature: signature,
            windowStart: windowStart,
            processedOffset: newOffset,
            contribution: .tokens(contribution)
        )
        return contribution
    }

    static func jsonContribution(
        for file: URL,
        windowStart: Date
    ) throws -> TokenFileContribution {
        let signature = fileSignature(file)
        let path = file.standardizedFileURL.path
        let cacheKey = "json|\(path)"
        if let cached = lock.withLock({ entries[cacheKey] }),
           cached.windowStart == windowStart,
           cached.size == signature.size,
           cached.modifiedAt == signature.modifiedAt,
           case let .tokens(value) = cached.contribution {
            return value
        }

        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data)
        var records: [String: Int] = [:]
        LocalUsageScanner.collectGenericUsage(
            from: object,
            file: file,
            inheritedDate: nil,
            windowStart: windowStart,
            records: &records
        )
        let contribution = TokenFileContribution(records: records)
        store(
            key: cacheKey,
            signature: signature,
            windowStart: windowStart,
            processedOffset: UInt64(signature.size),
            contribution: .tokens(contribution)
        )
        return contribution
    }

    private static func fileSignature(_ file: URL) -> FileSignature {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: file.path
        )
        return FileSignature(
            path: file.standardizedFileURL.path,
            modifiedAt: attributes?[.modificationDate] as? Date
                ?? .distantPast,
            size: (attributes?[.size] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func store(
        key: String,
        signature: FileSignature,
        windowStart: Date,
        processedOffset: UInt64,
        contribution: FileContribution
    ) {
        lock.withLock {
            entries[key] = IncrementalFileEntry(
                windowStart: windowStart,
                modifiedAt: signature.modifiedAt,
                size: signature.size,
                processedOffset: processedOffset,
                contribution: contribution
            )
            if entries.count > 500 {
                entries = Dictionary(
                    uniqueKeysWithValues: entries.suffix(400)
                )
            }
        }
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
