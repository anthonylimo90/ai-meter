import Darwin
import Foundation

public enum LocalUsageScanner {
    private static let maximumJSONDocumentSize = 25_000_000
    private static let maximumLineSize = 8_000_000

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
                                        : PlanUsageReadResult(
                                            status: .notRequested
                                        )
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
        claudeUsage: @Sendable () -> PlanUsageReadResult = {
            ClaudeUsageProbe.fetch()
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
            let tokenScan = scanClaude(
                files: inventory.files,
                after: windowStart,
                inventoryWarnings: inventory.warningCount
            )
            let rawPlanReadResult = claudeUsage()
            let activePlanUsage = rawPlanReadResult.snapshot?.active(at: now)
            let planStatus: PlanUsageReadStatus
            if rawPlanReadResult.status == .measured, activePlanUsage == nil {
                planStatus = .unavailable(
                    "Claude plan limits have expired"
                )
            } else {
                planStatus = rawPlanReadResult.status
            }
            return scanResult(
                configuration: configuration,
                tokenScan: tokenScan,
                planReadResult: PlanUsageReadResult(
                    status: planStatus,
                    snapshot: activePlanUsage
                ),
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
                let canonical = UsagePathResolver.canonicalURL(for: fileURL.path)
                let pathExtension = canonical.pathExtension.lowercased()
                guard UsagePathResolver.supportedExtensions.contains(
                    pathExtension
                ) else {
                    continue
                }
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
        if tokenScan.warningCount > 0 {
            detail += "; skipped \(tokenScan.warningCount) oversized or unsupported "
                + (tokenScan.warningCount == 1 ? "record" : "records")
        }

        return ScanResult(
            provider: configuration.id,
            tokens: tokenScan.tokens,
            availability: availability,
            detail: detail,
            planUsage: planUsage,
            planUsageStatus: planReadResult.status,
            hasWarnings: tokenScan.failedFiles > 0 || tokenScan.warningCount > 0
        )
    }

    private static func scanCodex(
        files: [URL],
        after windowStart: Date,
        inventoryWarnings: Int
    ) -> CodexScan {
        var total = 0
        var newestPlanUsage: (date: Date, snapshot: PlanUsageSnapshot)?
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
            failedFiles: failedFiles,
            warningCount: warningCount
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
        var messageTotals: [String: Int] = [:]
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
                for (key, tokens) in contribution.records {
                    messageTotals[key] = max(messageTotals[key] ?? 0, tokens)
                }
                readableFiles += 1
                warningCount += contribution.warningCount
            } catch {
                failedFiles += 1
            }
        }

        return TokenScan(
            tokens: messageTotals.values.reduce(0, +),
            candidateFiles: candidateFiles.count,
            readableFiles: readableFiles,
            failedFiles: failedFiles,
            warningCount: warningCount
        )
    }

    private static func scanGeneric(
        files: [URL],
        provider: ProviderID,
        after windowStart: Date,
        inventoryWarnings: Int
    ) -> TokenScan {
        var records: [String: Int] = [:]
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
                    for (key, tokens) in contribution.records {
                        records[key] = max(records[key] ?? 0, tokens)
                    }
                    warningCount += contribution.warningCount
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
            failedFiles: failedFiles,
            warningCount: warningCount
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

private struct TokenScan: Sendable {
    let tokens: Int
    let candidateFiles: Int
    let readableFiles: Int
    let failedFiles: Int
    let warningCount: Int
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
        let key = InventoryCacheKey(
            roots: roots.map(\.standardizedFileURL.path).sorted(),
            windowStart: windowStart
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
                entries = entries.filter {
                    Date().timeIntervalSince($0.value.createdAt) < 30
                }
            }
        }
        return inventory
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
    var warningCount = 0
}

private struct TokenFileContribution: Sendable {
    var records: [String: Int] = [:]
    var warningCount = 0
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
                contribution.records[key] = max(
                    contribution.records[key] ?? 0,
                    usage.tokens
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
            var records: [String: Int] = [:]
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
