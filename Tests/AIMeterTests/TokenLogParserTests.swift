import XCTest
@testable import AIMeterCore
@testable import AIMeterUI

final class TokenLogParserTests: XCTestCase {
    func testCodexUsesCumulativeSessionTotal() throws {
        let object: [String: Any] = [
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 900,
                        "output_tokens": 100,
                        "total_tokens": 1_000
                    ],
                    "last_token_usage": [
                        "total_tokens": 250
                    ]
                ]
            ]
        ]

        XCTAssertEqual(TokenLogParser.codexSessionTotal(in: object), 1_000)
    }

    func testCodexReadsProviderReportedPlanWindows() throws {
        let object: [String: Any] = [
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "plan_type": "plus",
                    "primary": [
                        "used_percent": 47.0,
                        "window_minutes": 300,
                        "resets_at": 1_781_098_692
                    ],
                    "secondary": [
                        "used_percent": 12.0,
                        "window_minutes": 10_080,
                        "resets_at": 1_781_261_559
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(TokenLogParser.codexPlanUsage(in: object))

        XCTAssertEqual(snapshot.source, .providerReported)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].label, "5-hour")
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 53)
        XCTAssertEqual(snapshot.windows[1].label, "Weekly")
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 88)
    }

    func testClaudeCountsCacheAndDeduplicatesByMessageIdentifier() throws {
        let object: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": "message-1",
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 20,
                    "cache_creation_input_tokens": 30,
                    "cache_read_input_tokens": 40
                ]
            ]
        ]

        XCTAssertEqual(
            TokenLogParser.claudeUsage(in: object),
            ParsedTokenUsage(identifier: "message-1", tokens: 100)
        )
    }

    func testClaudeUsageProbeParsesSessionAndWeeklyQuota() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Nairobi")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 6,
                day: 10,
                hour: 19
            )
        )!
        let output = """
        Claude Code v2.1.169
        Claude Max
        Current session
        █████████████████████████   50% used
        Resets 9pm (Africa/Nairobi)

        Current week (all models)
        ███████▌   15% used
        Resets Jun 12 at 12pm (Africa/Nairobi)
        """

        let snapshot = try XCTUnwrap(
            ClaudeUsageProbe.parse(
                terminalOutput: output,
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 50)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 85)
        XCTAssertEqual(
            calendar.component(.hour, from: snapshot.windows[0].resetsAt),
            21
        )
        XCTAssertEqual(
            calendar.component(.day, from: snapshot.windows[1].resetsAt),
            12
        )
    }

    func testClaudeUsageProbeParsesTerminalDiffArtifacts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Nairobi")!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 6,
                day: 12,
                hour: 14
            )
        )!
        let output = """
        ClaudeMax
        Currensession
        ██████████████████████████████████████████████100%used
        Rsets 3:20pm(Africa/Nairbi)

        Current week (all modes)
        ███      6%used
        ResetsJun19at12pm(Africa/Nairobi)
        """

        let snapshot = try XCTUnwrap(
            ClaudeUsageProbe.parse(
                terminalOutput: output,
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 0)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 94)
        XCTAssertEqual(
            calendar.component(.hour, from: snapshot.windows[0].resetsAt),
            15
        )
        XCTAssertEqual(
            calendar.component(.day, from: snapshot.windows[1].resetsAt),
            19
        )
    }

    func testGenericUsageSupportsGeminiMetadata() throws {
        let object: [String: Any] = [
            "id": "gemini-1",
            "usageMetadata": [
                "promptTokenCount": 120,
                "candidatesTokenCount": 30,
                "cachedContentTokenCount": 10
            ]
        ]

        XCTAssertEqual(
            TokenLogParser.genericUsage(in: object),
            ParsedTokenUsage(identifier: "gemini-1", tokens: 160)
        )
    }

    func testDefaultBudgetsDoNotInventProviderLimits() {
        XCTAssertTrue(
            ProviderConfiguration.defaults().allSatisfy { $0.tokenLimit == 0 }
        )
    }

    func testRefreshPolicyMigratesThirtySecondPolling() {
        XCTAssertEqual(UsageRefreshPolicy.normalizedInterval(30), 60)
        XCTAssertEqual(UsageRefreshPolicy.normalizedInterval(0), 300)
        XCTAssertEqual(UsageRefreshPolicy.normalizedInterval(300), 300)
    }

    func testRefreshPolicySlowsDownInLowPowerMode() {
        XCTAssertEqual(
            UsageRefreshPolicy.automaticInterval(
                configured: 60,
                lowPowerMode: true
            ),
            900
        )
        XCTAssertEqual(
            UsageRefreshPolicy.automaticInterval(
                configured: 300,
                lowPowerMode: false
            ),
            300
        )
    }

    func testClaudeQuotaAttemptsAreRateLimitedAfterFailure() {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        XCTAssertFalse(
            UsageRefreshPolicy.shouldAttemptClaudeQuota(
                lastAttempt: now.addingTimeInterval(-60),
                now: now,
                force: false
            )
        )
        XCTAssertTrue(
            UsageRefreshPolicy.shouldAttemptClaudeQuota(
                lastAttempt: now.addingTimeInterval(-901),
                now: now,
                force: false
            )
        )
        XCTAssertTrue(
            UsageRefreshPolicy.shouldAttemptClaudeQuota(
                lastAttempt: now,
                now: now,
                force: true
            )
        )
    }

    func testClaudeQuotaIsAvailableWithoutLocalLogFolders() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .claude,
            now: now,
            windowHours: 24
        )
        let snapshot = PlanUsageSnapshot(
            source: .providerReported,
            planName: "Max",
            windows: [
                PlanUsageWindow(
                    label: "5-hour",
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3_600)
                )
            ],
            observedAt: now
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [],
            now: now,
            claudeUsage: { snapshot }
        )

        XCTAssertEqual(result.planUsage, snapshot)
        XCTAssertEqual(result.availability, .unavailable)
        XCTAssertTrue(result.detail.contains("Provider-reported"))
    }

    func testCodexSubtractsPreWindowCumulativeBaseline() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .openAI,
            now: now,
            windowHours: 2
        )
        let windowStart = configuration.nextResetAt.addingTimeInterval(-7_200)
        let file = try temporaryFile(
            named: "codex.jsonl",
            lines: [
                try codexRecord(
                    timestamp: windowStart.addingTimeInterval(-60),
                    totalTokens: 1_000
                ),
                try codexRecord(
                    timestamp: windowStart.addingTimeInterval(60),
                    totalTokens: 1_240
                )
            ]
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(result.tokens, 240)
        XCTAssertEqual(result.availability, .measured)
    }

    func testGenericScannerNormalizesMillisecondTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let windowStart = configuration.nextResetAt.addingTimeInterval(-7_200)
        let file = try temporaryFile(
            named: "gemini.jsonl",
            lines: [
                try genericRecord(
                    timestamp: windowStart.addingTimeInterval(-60),
                    tokens: 900,
                    id: "old",
                    milliseconds: true
                ),
                try genericRecord(
                    timestamp: windowStart.addingTimeInterval(60),
                    tokens: 125,
                    id: "recent",
                    milliseconds: true
                )
            ]
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(result.tokens, 125)
    }

    func testGenericScannerExcludesRecordsWithoutTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .cursor,
            now: now,
            windowHours: 2
        )
        let windowStart = configuration.nextResetAt.addingTimeInterval(-7_200)
        let undated = try jsonString([
            "id": "undated",
            "usage": ["total_tokens": 999]
        ])
        let dated = try genericRecord(
            timestamp: windowStart.addingTimeInterval(60),
            tokens: 50,
            id: "dated"
        )
        let file = try temporaryFile(
            named: "cursor.jsonl",
            lines: [undated, dated]
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(result.tokens, 50)
    }

    func testGenericScannerKeepsValidResultsWhenAnotherFileFails() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .copilot,
            now: now,
            windowHours: 2
        )
        let windowStart = configuration.nextResetAt.addingTimeInterval(-7_200)
        let validFile = try temporaryFile(
            named: "valid.json",
            contents: try genericRecord(
                timestamp: windowStart.addingTimeInterval(60),
                tokens: 75,
                id: "valid"
            )
        )
        let invalidFile = try temporaryFile(
            named: "invalid.json",
            contents: "{not valid json"
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [validFile, invalidFile],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(result.tokens, 75)
        XCTAssertEqual(result.availability, .measured)
        XCTAssertTrue(result.hasWarnings)
        XCTAssertTrue(result.detail.contains("skipped 1 unreadable file"))
    }

    func testGenericScannerReadsOnlyAppendedJSONLLines() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let windowStart = configuration.nextResetAt.addingTimeInterval(-7_200)
        let file = try temporaryFile(
            named: "append.jsonl",
            lines: [
                try genericRecord(
                    timestamp: windowStart.addingTimeInterval(60),
                    tokens: 40,
                    id: "first"
                )
            ]
        )

        let first = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )
        try append(
            try genericRecord(
                timestamp: windowStart.addingTimeInterval(120),
                tokens: 60,
                id: "second"
            ) + "\n",
            to: file
        )
        let second = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(first.tokens, 40)
        XCTAssertEqual(second.tokens, 100)
    }

    func testProviderUsageRoundTripsForLaunchPersistence() throws {
        let usage = ProviderUsage(
            id: .openAI,
            tier: "Plus",
            usedTokens: 123,
            tokenLimit: 456,
            resetAt: Date(timeIntervalSince1970: 1_781_100_000),
            availability: .measured,
            sourceDetail: "Cached reading",
            planUsage: PlanUsageSnapshot(
                source: .providerReported,
                planName: "Plus",
                windows: [
                    PlanUsageWindow(
                        label: "5-hour",
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: Date(
                            timeIntervalSince1970: 1_781_103_600
                        )
                    )
                ]
            )
        )

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(
            ProviderUsage.self,
            from: data
        )

        XCTAssertEqual(decoded, usage)
    }

    func testGenericScannerParsesFinalLineWithoutTrailingNewline() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .cursor,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "final-line.jsonl",
            contents: try genericRecord(
                timestamp: now,
                tokens: 88,
                id: "final"
            )
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now,
            claudeUsage: { nil }
        )

        XCTAssertEqual(result.tokens, 88)
    }

    private func configuration(
        id: ProviderID,
        now: Date,
        windowHours: Int
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            id: id,
            isEnabled: true,
            tier: id.defaultTier,
            tokenLimit: 0,
            windowHours: windowHours,
            nextResetAt: now.addingTimeInterval(3_600),
            customPath: ""
        )
    }

    private func codexRecord(
        timestamp: Date,
        totalTokens: Int
    ) throws -> String {
        try jsonString([
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "total_tokens": totalTokens
                    ]
                ]
            ]
        ])
    }

    private func genericRecord(
        timestamp: Date,
        tokens: Int,
        id: String,
        milliseconds: Bool = false
    ) throws -> String {
        let rawTimestamp = timestamp.timeIntervalSince1970
            * (milliseconds ? 1_000 : 1)
        return try jsonString([
            "id": id,
            "timestamp": rawTimestamp,
            "usage": ["total_tokens": tokens]
        ])
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func temporaryFile(
        named name: String,
        lines: [String]
    ) throws -> URL {
        try temporaryFile(
            named: name,
            contents: lines.joined(separator: "\n") + "\n"
        )
    }

    private func temporaryFile(
        named name: String,
        contents: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func append(_ contents: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
