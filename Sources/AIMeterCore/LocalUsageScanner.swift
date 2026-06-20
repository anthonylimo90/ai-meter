import Darwin
import Foundation

public enum LocalUsageScanner {
    private static let maximumJSONDocumentSize = 25_000_000
    private static let maximumLineSize = 8_000_000

    public static func results(
        configurations: [ProviderConfiguration]
    ) -> AsyncStream<ScanResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: ScanResult?.self) { group in
                    for configuration in configurations {
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            return scan(configuration: configuration)
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
        configurations: [ProviderConfiguration]
    ) async -> [ScanResult] {
        var resultsByProvider: [ProviderID: ScanResult] = [:]
        for await result in results(configurations: configurations) {
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
        claudeStatuslineUsage: @Sendable () -> PlanUsageSnapshot? = {
            ClaudeStatuslineUsage.read()
        }
    ) -> ScanResult {
        let windowStart = Calendar.current.date(
            byAdding: .hour,
            value: -max(configuration.windowHours, 1),
            to: configuration.nextResetAt
        ) ?? .distantPast

        let roots = (rootsOverride ?? resolvedRoots(for: configuration))
            .map { UsagePathResolver.canonicalURL(for: $0.path) }
        let inventory: UsageFileInventory
        do {
            inventory = try DirectoryInventoryCache.inventory(
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
            guard !roots.isEmpty else {
                return ScanResult(
                    provider: configuration.id,
                    tokens: 0,
                    availability: .unavailable,
                    detail: "No local data folder is available"
                )
            }
            let tokenScan = scanClaude(
                files: inventory.files,
                after: windowStart,
                inventoryWarnings: inventory.warningCount
            )
            // Plan quota comes from Claude Code's status-line `rate_limits`,
            // captured locally by the AI Meter helper. Without that setup,
            // Claude is token-only like the other providers.
            if let snapshot = claudeStatuslineUsage()?.active(at: now) {
                return scanResult(
                    configuration: configuration,
                    tokenScan: tokenScan,
                    planReadResult: .measured(snapshot),
                    hasRoots: true
                )
            }
            return scanResult(
                configuration: configuration,
                tokenScan: tokenScan,
                planReadResult: PlanUsageReadResult(
                    status: .unavailable(
                        "Provider-reported plan usage is not exposed"
                    )
                ),
                hasRoots: true
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
            let scan = scanCodex(
                files: inventory.files,
                after: windowStart,
                inventoryWarnings: inventory.warningCount
            )
            let planUsage = scan.planUsage?.active(at: now)
            return scanResult(
                configuration: configuration,
                tokenScan: scan.tokenScan,
                planReadResult: PlanUsageReadResult(
                    status: planUsage == nil
                        ? .unavailable("No active Codex plan limits were found")
                        : .measured,
                    snapshot: planUsage
                ),
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
                files: inventory.files,
                provider: configuration.id,
                after: windowStart,
                inventoryWarnings: inventory.warningCount
            )
            return scanResult(
                configuration: configuration,
                tokenScan: tokenScan,
                planReadResult: PlanUsageReadResult(
                    status: .unavailable(
                        "Provider-reported plan usage is not exposed"
                    )
                ),
                hasRoots: true
            )
        }
    }

    private static func resolvedRoots(
        for configuration: ProviderConfiguration
    ) -> [URL] {
        UsagePathResolver.existingRoots(
            builtInPaths: configuration.id.builtInPaths,
            customPath: configuration.customPath
        )
    }

    fileprivate static func usageInventory(
        in roots: [URL],
        modifiedAfter windowStart: Date
    ) throws -> UsageFileInventory {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        var filesByPath: [String: URL] = [:]
        var warningCount = 0

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ) else {
                continue
            }

            if !isDirectory.boolValue {
                let canonical = UsagePathResolver.canonicalURL(for: root.path)
                let pathExtension = canonical.pathExtension.lowercased()
                guard UsagePathResolver.supportedExtensions.contains(
                    pathExtension
                ) else {
                    warningCount += 1
                    continue
                }
                let values = try? canonical.resourceValues(forKeys: Set(keys))
                if pathExtension == "json",
                   (values?.fileSize ?? 0) > maximumJSONDocumentSize {
                    warningCount += 1
                    continue
                }
                filesByPath[canonical.path] = canonical
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
                let pathExtension = fileURL.pathExtension.lowercased()
                guard UsagePathResolver.supportedExtensions.contains(
                    pathExtension
                ) else {
                    continue
                }
                let canonical = UsagePathResolver.canonicalURL(for: fileURL.path)
                let values = try? canonical.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                if pathExtension == "json",
                   (values?.fileSize ?? 0) > maximumJSONDocumentSize {
                    warningCount += 1
                    continue
                }
                guard (values?.contentModificationDate ?? .distantPast) >= windowStart else {
                    continue
                }
                filesByPath[canonical.path] = canonical
            }
        }

        return UsageFileInventory(
            files: filesByPath.values.sorted { $0.path < $1.path },
            warningCount: warningCount
        )
    }

    private static func scanResult(
        configuration: ProviderConfiguration,
        tokenScan: TokenScan,
        planReadResult: PlanUsageReadResult,
        hasRoots: Bool
    ) -> ScanResult {
        let planUsage = planReadResult.snapshot
        let availability: UsageAvailability
        if tokenScan.breakdown.totalTokens > 0 {
            availability = .measured
        } else if tokenScan.failedFiles > 0 && tokenScan.readableFiles == 0 {
            availability = .failed
        } else {
            availability = .unavailable
        }

        var detail: String
        if planUsage != nil && tokenScan.breakdown.totalTokens > 0 {
            detail = "\(configuration.id.sourceLabel): provider-reported plan limits and local tokens"
        } else if planUsage != nil {
            detail = "Provider-reported plan limits detected; no recent local token data"
        } else if tokenScan.breakdown.totalTokens > 0 {
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
        if tokenScan.warningCount > 0 {
            detail += "; skipped \(tokenScan.warningCount) oversized or unsupported "
                + (tokenScan.warningCount == 1 ? "record" : "records")
        }

        return ScanResult(
            provider: configuration.id,
            tokenBreakdown: tokenScan.breakdown,
            availability: availability,
            detail: detail,
            planUsage: planUsage,
            planUsageStatus: planReadResult.status,
            hasWarnings: tokenScan.failedFiles > 0 || tokenScan.warningCount > 0,
            modelName: tokenScan.modelName
        )
    }

    private static func scanCodex(
        files: [URL],
        after windowStart: Date,
        inventoryWarnings: Int
    ) -> CodexScan {
        var totalBreakdown = TokenBreakdown.zero
        var newestPlanUsage: (date: Date, snapshot: PlanUsageSnapshot)?
        var newestModel: (date: Date, modelName: String)?
        var readableFiles = 0
        var failedFiles = 0
        var warningCount = inventoryWarnings
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
                warningCount += contribution.warningCount
                totalBreakdown += contribution.windowBreakdown
                if let model = contribution.newestModel,
                   newestModel == nil || model.date > newestModel!.date {
                    newestModel = model
                }
            } catch {
                failedFiles += 1
            }
        }

        let tokenScan = TokenScan(
            breakdown: totalBreakdown,
            candidateFiles: candidateFiles.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles,
            warningCount: warningCount,
            modelName: newestModel?.modelName
        )
        guard let latest = newestPlanUsage?.snapshot else {
            return CodexScan(tokenScan: tokenScan, planUsage: nil)
        }
        return CodexScan(
            tokenScan: tokenScan,
            planUsage: latest
        )
    }

    private static func scanClaude(
        files: [URL],
        after windowStart: Date,
        inventoryWarnings: Int
    ) -> TokenScan {
        var messageTotals: [String: TokenBreakdown] = [:]
        var modelCounts: [String: Int] = [:]
        var readableFiles = 0
        var failedFiles = 0
        var warningCount = inventoryWarnings
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
                for (key, record) in contribution.records {
                    messageTotals[key] = preferredBreakdown(
                        current: messageTotals[key],
                        candidate: record.breakdown
                    )
                    if let modelName = record.modelName {
                        modelCounts[modelName, default: 0] += 1
                    }
                }
                readableFiles += 1
                warningCount += contribution.warningCount
            } catch {
                failedFiles += 1
            }
        }

        return TokenScan(
            breakdown: messageTotals.values.reduce(.zero, +),
            candidateFiles: candidateFiles.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles,
            warningCount: warningCount,
            modelName: mostCommonModel(in: modelCounts)
        )
    }

    private static func scanGeneric(
        files: [URL],
        provider: ProviderID,
        after windowStart: Date,
        inventoryWarnings: Int
    ) -> TokenScan {
        var records: [String: TokenBreakdown] = [:]
        var modelCounts: [String: Int] = [:]
        var readableFiles = 0
        var failedFiles = 0
        var warningCount = inventoryWarnings

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
                    for (key, record) in contribution.records {
                        records[key] = preferredBreakdown(
                            current: records[key],
                            candidate: record.breakdown
                        )
                        if let modelName = record.modelName {
                            modelCounts[modelName, default: 0] += 1
                        }
                    }
                    warningCount += contribution.warningCount
                } else if pathExtension == "json" {
                    let contribution = try IncrementalFileCache.jsonContribution(
                        for: file,
                        windowStart: windowStart
                    )
                    for (key, record) in contribution.records {
                        records[key] = preferredBreakdown(
                            current: records[key],
                            candidate: record.breakdown
                        )
                        if let modelName = record.modelName {
                            modelCounts[modelName, default: 0] += 1
                        }
                    }
                }
                readableFiles += 1
            } catch {
                failedFiles += 1
            }
        }

        return TokenScan(
            breakdown: records.values.reduce(.zero, +),
            candidateFiles: files.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles,
            warningCount: warningCount,
            modelName: mostCommonModel(in: modelCounts)
        )
    }

    fileprivate static func collectGenericUsage(
        from object: Any,
        file: URL,
        inheritedDate: Date?,
        windowStart: Date,
        records: inout [String: TokenUsageRecord]
    ) {
        if let dictionary = object as? [String: Any] {
            let date = recordDate(in: dictionary) ?? inheritedDate
            if let date,
               date >= windowStart,
               let usage = TokenLogParser.genericUsage(in: dictionary) {
                let key = usage.identifier ?? "\(file.path):\(records.count)"
                records[key] = preferredRecord(
                    current: records[key],
                    candidate: TokenUsageRecord(
                        breakdown: usage.breakdown,
                        modelName: usage.modelName
                    )
                )
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
    ) throws -> JSONLineReadResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: offset)
        var pending = Data()
        var processedOffset = offset
        var skippedOversizedRecords = 0
        var discardingOversizedRecord = false
        while let chunk = try handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                if discardingOversizedRecord {
                    discardingOversizedRecord = false
                } else if line.count > maximumLineSize {
                    skippedOversizedRecords += 1
                } else {
                    parseJSONLine(Data(line), body: body)
                }
                processedOffset += UInt64(newline + 1)
                pending.removeSubrange(...newline)
            }
            if pending.count > maximumLineSize {
                if !discardingOversizedRecord {
                    skippedOversizedRecords += 1
                }
                processedOffset += UInt64(pending.count)
                pending.removeAll(keepingCapacity: true)
                discardingOversizedRecord = true
            }
        }
        if !pending.isEmpty {
            if discardingOversizedRecord || pending.count > maximumLineSize {
                if !discardingOversizedRecord {
                    skippedOversizedRecords += 1
                }
                processedOffset += UInt64(pending.count)
            } else if parseJSONLine(pending, body: body) {
                processedOffset += UInt64(pending.count)
            }
        }
        return JSONLineReadResult(
            processedOffset: processedOffset,
            skippedOversizedRecords: skippedOversizedRecords
        )
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

private func preferredBreakdown(
    current: TokenBreakdown?,
    candidate: TokenBreakdown
) -> TokenBreakdown {
    guard let current else { return candidate }
    if candidate.totalTokens > current.totalTokens {
        return candidate
    }
    if candidate.totalTokens == current.totalTokens,
       candidate.splitTokenCount > current.splitTokenCount {
        return candidate
    }
    return current
}

private func preferredRecord(
    current: TokenUsageRecord?,
    candidate: TokenUsageRecord
) -> TokenUsageRecord {
    guard let current else { return candidate }
    let breakdown = preferredBreakdown(
        current: current.breakdown,
        candidate: candidate.breakdown
    )
    let modelName = candidate.modelName ?? current.modelName
    return TokenUsageRecord(breakdown: breakdown, modelName: modelName)
}

private func mostCommonModel(in counts: [String: Int]) -> String? {
    counts
        .sorted {
            if $0.value == $1.value {
                return $0.key < $1.key
            }
            return $0.value > $1.value
        }
        .first?
        .key
}

private struct TokenScan: Sendable {
    let breakdown: TokenBreakdown
    let candidateFiles: Int
    let readableFiles: Int
    let failedFiles: Int
    let warningCount: Int
    let modelName: String?
}

private struct UsageFileInventory: Sendable {
    let files: [URL]
    let warningCount: Int
}

private struct JSONLineReadResult: Sendable {
    let processedOffset: UInt64
    let skippedOversizedRecords: Int
}

private struct CodexScan: Sendable {
    let tokenScan: TokenScan
    let planUsage: PlanUsageSnapshot?
}

private struct FileSignature: Hashable, Sendable {
    let path: String
    let modifiedAt: Date
    let size: Int
    let device: UInt64
    let inode: UInt64
}

private struct InventoryCacheKey: Hashable, Sendable {
    let roots: [String]
    let windowStart: Date
}

private struct DirectoryInventoryEntry: Sendable {
    let createdAt: Date
    let inventory: UsageFileInventory
}

private enum DirectoryInventoryCache {
    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var entries: [InventoryCacheKey: DirectoryInventoryEntry] = [:]

    static func inventory(
        in roots: [URL],
        modifiedAfter windowStart: Date
    ) throws -> UsageFileInventory {
        ensureWatchers(for: roots)
        let normalizedWindowStart = windowStart.roundedDownToMinute
        let key = InventoryCacheKey(
            roots: roots.map(\.standardizedFileURL.path).sorted(),
            windowStart: normalizedWindowStart
        )
        if let cached = lock.withLock({ entries[key] }),
           Date().timeIntervalSince(cached.createdAt) < 5 {
            return cached.inventory
        }
        let inventory = try LocalUsageScanner.usageInventory(
            in: roots,
            modifiedAfter: windowStart
        )
        lock.withLock {
            entries[key] = DirectoryInventoryEntry(
                createdAt: .now,
                inventory: inventory
            )
            if entries.count > 20 {
                let now = Date()
                entries = entries.filter {
                    now.timeIntervalSince($0.value.createdAt) < 30
                }
            }
        }
        return inventory
    }

    private static func ensureWatchers(for roots: [URL]) {
        cleanupWatchers()
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

    private static func cleanupWatchers() {
        lock.withLock {
            let missingPaths = watchers.keys.filter {
                !FileManager.default.fileExists(atPath: $0)
            }
            for path in missingPaths {
                watchers[path]?.cancel()
                watchers.removeValue(forKey: path)
                entries = entries.filter { !$0.key.roots.contains(path) }
            }
            if watchers.count > 50 {
                let activeRoots = Set(entries.flatMap(\.key.roots))
                let inactivePaths = watchers.keys.filter {
                    !activeRoots.contains($0)
                }
                for path in inactivePaths {
                    watchers[path]?.cancel()
                    watchers.removeValue(forKey: path)
                }
            }
        }
    }

    nonisolated(unsafe)
    private static var watchers: [
        String: DispatchSourceFileSystemObject
    ] = [:]
}

private extension Date {
    var roundedDownToMinute: Date {
        Date(timeIntervalSince1970: floor(timeIntervalSince1970 / 60) * 60)
    }
}

private struct CodexFileContribution: Sendable {
    var baseline = 0
    var sessionMaximum = TokenBreakdown.zero
    var newestPlanUsage: (
        date: Date,
        snapshot: PlanUsageSnapshot
    )?
    var newestModel: (
        date: Date,
        modelName: String
    )?
    var warningCount = 0

    var windowBreakdown: TokenBreakdown {
        let total = max(sessionMaximum.totalTokens - baseline, 0)
        if baseline == 0, sessionMaximum.hasDetailedSplit {
            return sessionMaximum
        }
        return .aggregate(total)
    }
}

private struct TokenFileContribution: Sendable {
    var records: [String: TokenUsageRecord] = [:]
    var warningCount = 0
}

private struct TokenUsageRecord: Sendable {
    var breakdown: TokenBreakdown
    var modelName: String?
}

private enum FileContribution: Sendable {
    case codex(CodexFileContribution)
    case tokens(TokenFileContribution)
}

private struct IncrementalFileEntry: Sendable {
    let windowStart: Date
    let signature: FileSignature
    let processedOffset: UInt64
    let headLength: UInt64
    let headFingerprint: UInt64
    let boundaryFingerprint: UInt64
    let contribution: FileContribution
}

private final class FileLockEntry: @unchecked Sendable {
    let lock = NSLock()
    var users = 0
}

private enum IncrementalFileCache {
    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var entries: [String: IncrementalFileEntry] = [:]
    nonisolated(unsafe)
    private static var fileLocks: [String: FileLockEntry] = [:]

    static func codexContribution(
        for file: URL,
        windowStart: Date
    ) throws -> CodexFileContribution {
        let path = UsagePathResolver.canonicalURL(for: file.path).path
        let cacheKey = "\(ProviderID.openAI.rawValue)|\(path)"
        return try withFileLock(for: cacheKey) {
            let signature = try fileSignature(file)
            let cached = lock.withLock { entries[cacheKey] }
            var contribution: CodexFileContribution
            var offset: UInt64
            if let cached,
               try canReuse(
                   cached,
                   for: file,
                   signature: signature,
                   windowStart: windowStart
               ),
               case let .codex(value) = cached.contribution {
                if cached.signature.size == signature.size,
                   cached.signature.modifiedAt == signature.modifiedAt {
                    return value
                }
                contribution = value
                offset = cached.processedOffset
            } else {
                contribution = CodexFileContribution()
                offset = 0
            }

            let readResult = try LocalUsageScanner.forEachJSONLine(
                in: file,
                fromOffset: offset
            ) { object in
                guard let date = LocalUsageScanner.recordDate(in: object) else {
                    return
                }
                if let breakdown = TokenLogParser.codexSessionBreakdown(
                    in: object
                ) {
                    if date < windowStart {
                        contribution.baseline = max(
                            contribution.baseline,
                            breakdown.totalTokens
                        )
                    } else if breakdown.totalTokens
                        > contribution.sessionMaximum.totalTokens
                        || (
                            breakdown.totalTokens
                                == contribution.sessionMaximum.totalTokens
                            && breakdown.splitTokenCount
                                > contribution.sessionMaximum.splitTokenCount
                        ) {
                        contribution.sessionMaximum = breakdown
                    }
                }
                if date >= windowStart,
                   let modelName = TokenLogParser.modelName(in: object),
                   contribution.newestModel == nil
                    || date > contribution.newestModel!.date {
                    contribution.newestModel = (date, modelName)
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
            contribution.warningCount += readResult.skippedOversizedRecords
            try store(
                key: cacheKey,
                file: file,
                windowStart: windowStart,
                processedOffset: readResult.processedOffset,
                contribution: .codex(contribution)
            )
            return contribution
        }
    }

    static func tokenContribution(
        for file: URL,
        provider: ProviderID,
        windowStart: Date
    ) throws -> TokenFileContribution {
        let path = UsagePathResolver.canonicalURL(for: file.path).path
        let cacheKey = "\(provider.rawValue)|\(path)"
        return try withFileLock(for: cacheKey) {
            let signature = try fileSignature(file)
            let cached = lock.withLock { entries[cacheKey] }
            var contribution: TokenFileContribution
            var offset: UInt64
            if let cached,
               try canReuse(
                   cached,
                   for: file,
                   signature: signature,
                   windowStart: windowStart
               ),
               case let .tokens(value) = cached.contribution {
                if cached.signature.size == signature.size,
                   cached.signature.modifiedAt == signature.modifiedAt {
                    return value
                }
                contribution = value
                offset = cached.processedOffset
            } else {
                contribution = TokenFileContribution()
                offset = 0
            }

            let readResult = try LocalUsageScanner.forEachJSONLine(
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
                contribution.records[key] = preferredRecord(
                    current: contribution.records[key],
                    candidate: TokenUsageRecord(
                        breakdown: usage.breakdown,
                        modelName: usage.modelName
                    )
                )
            }
            contribution.warningCount += readResult.skippedOversizedRecords
            try store(
                key: cacheKey,
                file: file,
                windowStart: windowStart,
                processedOffset: readResult.processedOffset,
                contribution: .tokens(contribution)
            )
            return contribution
        }
    }

    static func jsonContribution(
        for file: URL,
        windowStart: Date
    ) throws -> TokenFileContribution {
        let path = UsagePathResolver.canonicalURL(for: file.path).path
        let cacheKey = "json|\(path)"
        return try withFileLock(for: cacheKey) {
            let signature = try fileSignature(file)
            if let cached = lock.withLock({ entries[cacheKey] }),
               cached.windowStart == windowStart,
               cached.signature == signature,
               case let .tokens(value) = cached.contribution {
                return value
            }

            let data = try Data(
                contentsOf: file,
                options: [.mappedIfSafe, .uncached]
            )
            try Task.checkCancellation()
            let object = try JSONSerialization.jsonObject(with: data)
            var records: [String: TokenUsageRecord] = [:]
            LocalUsageScanner.collectGenericUsage(
                from: object,
                file: file,
                inheritedDate: nil,
                windowStart: windowStart,
                records: &records
            )
            let contribution = TokenFileContribution(records: records)
            try store(
                key: cacheKey,
                file: file,
                windowStart: windowStart,
                processedOffset: UInt64(signature.size),
                contribution: .tokens(contribution)
            )
            return contribution
        }
    }

    private static func fileSignature(_ file: URL) throws -> FileSignature {
        let canonical = UsagePathResolver.canonicalURL(for: file.path)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        return FileSignature(
            path: canonical.path,
            modifiedAt: attributes[.modificationDate] as? Date
                ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private static func store(
        key: String,
        file: URL,
        windowStart: Date,
        processedOffset: UInt64,
        contribution: FileContribution
    ) throws {
        let signature = try fileSignature(file)
        let headLength = UInt64(min(signature.size, 4_096))
        let headFingerprint = try fingerprint(
            file,
            endingAt: headLength
        )
        let boundaryFingerprint = try fingerprint(
            file,
            endingAt: processedOffset
        )
        lock.withLock {
            entries[key] = IncrementalFileEntry(
                windowStart: windowStart,
                signature: signature,
                processedOffset: processedOffset,
                headLength: headLength,
                headFingerprint: headFingerprint,
                boundaryFingerprint: boundaryFingerprint,
                contribution: contribution
            )
            if entries.count > 500 {
                let existingEntries = entries.filter {
                    FileManager.default.fileExists(
                        atPath: $0.value.signature.path
                    )
                }
                entries = Dictionary(
                    uniqueKeysWithValues: existingEntries
                        .sorted {
                            $0.value.signature.modifiedAt
                                > $1.value.signature.modifiedAt
                        }
                        .prefix(400)
                        .map { ($0.key, $0.value) }
                )
                fileLocks = fileLocks.filter {
                    $0.value.users > 0 || entries[$0.key] != nil
                }
            }
        }
    }

    private static func canReuse(
        _ cached: IncrementalFileEntry,
        for file: URL,
        signature: FileSignature,
        windowStart: Date
    ) throws -> Bool {
        guard cached.windowStart == windowStart,
              cached.signature.device == signature.device,
              cached.signature.inode == signature.inode,
              cached.signature.size <= signature.size,
              cached.processedOffset <= UInt64(signature.size)
        else {
            return false
        }
        let currentHead = try fingerprint(
            file,
            endingAt: cached.headLength
        )
        guard currentHead == cached.headFingerprint else {
            return false
        }
        if cached.signature.size == signature.size {
            guard cached.signature.modifiedAt == signature.modifiedAt else {
                return false
            }
        }
        let currentBoundary = try fingerprint(
            file,
            endingAt: cached.processedOffset
        )
        return currentBoundary == cached.boundaryFingerprint
    }

    private static func fingerprint(
        _ file: URL,
        endingAt endOffset: UInt64
    ) throws -> UInt64 {
        let length = min(endOffset, 4_096)
        guard length > 0 else { return 14_695_981_039_346_656_037 }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: endOffset - length)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        return data.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    private static func withFileLock<T>(
        for key: String,
        _ body: () throws -> T
    ) rethrows -> T {
        let fileLockEntry = lock.withLock {
            if let existing = fileLocks[key] {
                existing.users += 1
                return existing
            }
            let created = FileLockEntry()
            created.users = 1
            fileLocks[key] = created
            return created
        }
        defer {
            lock.withLock {
                fileLockEntry.users -= 1
                if fileLockEntry.users == 0, entries[key] == nil {
                    fileLocks.removeValue(forKey: key)
                }
            }
        }
        return try fileLockEntry.lock.withLock(body)
    }
}

struct ParsedTokenUsage: Equatable, Sendable {
    let identifier: String?
    let breakdown: TokenBreakdown
    let modelName: String?

    init(
        identifier: String?,
        breakdown: TokenBreakdown,
        modelName: String? = nil
    ) {
        self.identifier = identifier
        self.breakdown = breakdown
        self.modelName = modelName
    }

    init(identifier: String?, tokens: Int) {
        self.identifier = identifier
        self.breakdown = .aggregate(tokens)
        self.modelName = nil
    }

    var tokens: Int {
        breakdown.totalTokens
    }
}

enum TokenLogParser {
    static func codexSessionTotal(in object: [String: Any]) -> Int? {
        codexSessionBreakdown(in: object)?.totalTokens
    }

    static func codexSessionBreakdown(in object: [String: Any]) -> TokenBreakdown? {
        guard
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let totalUsage = info["total_token_usage"] as? [String: Any]
        else {
            return nil
        }
        let explicitTotal = integer(in: totalUsage, keys: ["total_tokens"])
        let breakdown = tokenBreakdown(in: totalUsage)
        if breakdown.totalTokens > 0 {
            return breakdown
        }
        guard let explicitTotal else { return nil }
        return .aggregate(explicitTotal)
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

        let breakdown = TokenBreakdown(
            inputTokens: sum(in: usage, keys: ["input_tokens"]),
            outputTokens: sum(in: usage, keys: ["output_tokens"]),
            cacheWriteTokens: sum(
                in: usage,
                keys: ["cache_creation_input_tokens"]
            ),
            cacheReadTokens: sum(in: usage, keys: ["cache_read_input_tokens"])
        )
        guard breakdown.totalTokens > 0 else { return nil }

        let identifier = message["id"] as? String
            ?? object["requestId"] as? String
            ?? object["uuid"] as? String
        return ParsedTokenUsage(
            identifier: identifier,
            breakdown: breakdown,
            modelName: modelName(in: object)
                ?? string(in: message, keys: modelNameKeys)
        )
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
            var breakdown = tokenBreakdown(in: usage)
            if breakdown.totalTokens == 0, let explicitTotal {
                breakdown = .aggregate(explicitTotal)
            } else if let explicitTotal,
                      explicitTotal > breakdown.totalTokens {
                breakdown.otherTokens += explicitTotal - breakdown.totalTokens
            }
            guard breakdown.totalTokens > 0 else { continue }

            let identifier = object["id"] as? String
                ?? object["uuid"] as? String
                ?? object["requestId"] as? String
                ?? object["request_id"] as? String
            return ParsedTokenUsage(
                identifier: identifier,
                breakdown: breakdown,
                modelName: modelName(in: object)
                    ?? string(in: usage, keys: modelNameKeys)
            )
        }

        return nil
    }

    static func modelName(in object: [String: Any]) -> String? {
        if let direct = string(in: object, keys: modelNameKeys) {
            return direct
        }
        let nestedKeys = ["payload", "message", "request", "metadata", "info"]
        for key in nestedKeys {
            if let nested = object[key] as? [String: Any],
               let model = modelName(in: nested) {
                return model
            }
        }
        return nil
    }

    private static let modelNameKeys = [
        "model",
        "modelName",
        "model_name",
        "model_id",
        "modelSlug",
        "model_slug",
        "engine"
    ]

    private static func tokenBreakdown(
        in usage: [String: Any]
    ) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: sum(
                in: usage,
                keys: [
                    "input_tokens",
                    "prompt_tokens",
                    "inputTokenCount",
                    "promptTokenCount"
                ]
            ),
            outputTokens: sum(
                in: usage,
                keys: [
                    "output_tokens",
                    "completion_tokens",
                    "outputTokenCount",
                    "candidatesTokenCount"
                ]
            ),
            cachedInputTokens: sum(
                in: usage,
                keys: [
                    "cached_input_tokens",
                    "cachedInputTokens",
                    "cachedContentTokenCount"
                ]
            ),
            cacheWriteTokens: sum(
                in: usage,
                keys: [
                    "cache_creation_input_tokens",
                    "cacheWriteTokens"
                ]
            ),
            cacheReadTokens: sum(
                in: usage,
                keys: [
                    "cache_read_input_tokens",
                    "cacheReadTokens"
                ]
            )
        )
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

    private static func string(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
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
