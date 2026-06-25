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
            ParsedTokenUsage(
                identifier: "message-1",
                breakdown: TokenBreakdown(
                    inputTokens: 10,
                    outputTokens: 20,
                    cacheWriteTokens: 30,
                    cacheReadTokens: 40
                )
            )
        )
    }

    func testClaudeUsageParsesModelName() throws {
        let object: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": "message-1",
                "model": "claude-sonnet-4-6",
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 20
                ]
            ]
        ]

        let usage = try XCTUnwrap(TokenLogParser.claudeUsage(in: object))

        XCTAssertEqual(usage.modelName, "claude-sonnet-4-6")
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
            ParsedTokenUsage(
                identifier: "gemini-1",
                breakdown: TokenBreakdown(
                    inputTokens: 120,
                    outputTokens: 30,
                    cachedInputTokens: 10
                )
            )
        )
    }

    func testGenericExplicitTotalWithoutSplitMapsToOtherTokens() throws {
        let object: [String: Any] = [
            "id": "generic-1",
            "modelName": "custom-model",
            "usage": [
                "totalTokens": 42
            ]
        ]

        let usage = try XCTUnwrap(TokenLogParser.genericUsage(in: object))

        XCTAssertEqual(usage.identifier, "generic-1")
        XCTAssertEqual(usage.breakdown, TokenBreakdown(otherTokens: 42))
        XCTAssertEqual(usage.modelName, "custom-model")
    }

    func testTokenCostEstimatorCalculatesUsdEstimate() throws {
        let rate = TokenCostRate(
            id: "openai-test",
            provider: .openAI,
            modelName: "gpt-test",
            inputPerMillion: 2,
            outputPerMillion: 10,
            cachedInputPerMillion: 0.2,
            cacheWritePerMillion: 3,
            cacheReadPerMillion: 0.5
        )
        let estimate = try XCTUnwrap(
            TokenCostEstimator.estimate(
                breakdown: TokenBreakdown(
                    inputTokens: 1_000_000,
                    outputTokens: 500_000,
                    cachedInputTokens: 1_000_000,
                    cacheWriteTokens: 100_000,
                    cacheReadTokens: 200_000
                ),
                rate: rate,
                modelName: "gpt-test"
            )
        )

        XCTAssertEqual(estimate.currencyCode, "USD")
        XCTAssertEqual(estimate.estimatedAmount, Decimal(string: "7.6"))
        XCTAssertFalse(estimate.isEstimated)
    }

    func testTokenCostEstimatorMarksOtherTokensEstimated() throws {
        let rate = TokenCostRate(
            id: "openai-test",
            provider: .openAI,
            modelName: "gpt-test",
            inputPerMillion: 2,
            outputPerMillion: 10
        )
        let estimate = try XCTUnwrap(
            TokenCostEstimator.estimate(
                breakdown: TokenBreakdown(otherTokens: 500_000),
                rate: rate,
                modelName: nil
            )
        )

        XCTAssertEqual(estimate.estimatedAmount, Decimal(1))
        XCTAssertTrue(estimate.isEstimated)
    }

    func testTokenCostEstimatorReturnsMissingRateReason() throws {
        let estimate = try XCTUnwrap(
            TokenCostEstimator.estimate(
                breakdown: TokenBreakdown(inputTokens: 10),
                rate: nil,
                modelName: nil
            )
        )

        XCTAssertEqual(
            estimate.missingPricingReason,
            "Pricing rate is not configured"
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

    func testClaudeReportsTokensOnlyWithoutPlanQuota() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .claude,
            now: now,
            windowHours: 24
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [],
            now: now,
            claudeStatuslineUsage: { nil }
        )

        // No local folder -> unavailable, and never a provider-reported plan.
        XCTAssertNil(result.planUsage)
        XCTAssertEqual(result.availability, .unavailable)
    }

    func testClaudeStatuslineUsageParsesRateLimits() throws {
        let object: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 23.5,
                    "resets_at": 1_781_103_600
                ],
                "seven_day": [
                    "used_percentage": 41.2,
                    "resets_at": 1_781_600_000
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(
            ClaudeStatuslineUsage.snapshot(
                from: object,
                observedAt: Date(timeIntervalSince1970: 1_781_100_000)
            )
        )

        XCTAssertEqual(snapshot.source, .providerReported)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].label, "5-hour")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 23.5)
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Date(timeIntervalSince1970: 1_781_103_600)
        )
        XCTAssertEqual(snapshot.windows[1].label, "Weekly")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 41.2)
    }

    func testClaudeStatuslineUsageIgnoresMissingRateLimits() {
        // Absent / unsubscribed sessions carry no rate_limits.
        XCTAssertNil(
            ClaudeStatuslineUsage.snapshot(
                from: ["model": ["display_name": "Opus"]],
                observedAt: Date()
            )
        )
    }

    func testClaudeUsesStatuslineRateLimitsForPlanQuota() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .claude,
            now: now,
            windowHours: 24
        )
        let snapshot = PlanUsageSnapshot(
            source: .providerReported,
            planName: nil,
            windows: [
                PlanUsageWindow(
                    label: "5-hour",
                    usedPercent: 30,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3_600)
                ),
                PlanUsageWindow(
                    label: "Weekly",
                    usedPercent: 60,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3_600)
                )
            ],
            observedAt: now
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [URL(fileURLWithPath: NSTemporaryDirectory())],
            now: now,
            claudeStatuslineUsage: { snapshot }
        )

        XCTAssertEqual(result.planUsage?.source, .providerReported)
        XCTAssertEqual(result.planUsage?.windows.count, 2)
        XCTAssertEqual(result.planUsage?.windows.first?.remainingPercent, 70)
    }

    func testStatuslineInstallerWrapsAndRestoresExistingStatusLine() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimeter-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = root.appendingPathComponent("settings.json")
        let original: [String: Any] = [
            "model": "opus",
            "statusLine": [
                "type": "command",
                "command": "bash ~/.claude/statusline-command.sh"
            ]
        ]
        try JSONSerialization.data(withJSONObject: original)
            .write(to: settingsURL)

        let paths = ClaudeStatuslineInstaller.Paths(
            settings: settingsURL,
            supportDir: root.appendingPathComponent("support")
        )

        XCTAssertFalse(ClaudeStatuslineInstaller.isEnabled(paths: paths))

        try ClaudeStatuslineInstaller.enable(paths: paths)
        XCTAssertTrue(ClaudeStatuslineInstaller.isEnabled(paths: paths))
        // Helper installed and executable.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.helper.path))
        // The previous command is preserved for forwarding.
        XCTAssertEqual(
            try String(contentsOf: paths.previousCommand, encoding: .utf8),
            "bash ~/.claude/statusline-command.sh"
        )
        // Unrelated settings keys are preserved.
        let afterEnable = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        XCTAssertEqual(afterEnable?["model"] as? String, "opus")

        try ClaudeStatuslineInstaller.disable(paths: paths)
        XCTAssertFalse(ClaudeStatuslineInstaller.isEnabled(paths: paths))
        let restored = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        let statusLine = restored?["statusLine"] as? [String: Any]
        XCTAssertEqual(
            statusLine?["command"] as? String,
            "bash ~/.claude/statusline-command.sh"
        )
        XCTAssertEqual(restored?["model"] as? String, "opus")
    }

    func testStatuslineInstallerRemovesEntryWhenNonePreexisted() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimeter-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = root.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "opus"])
            .write(to: settingsURL)
        let paths = ClaudeStatuslineInstaller.Paths(
            settings: settingsURL,
            supportDir: root.appendingPathComponent("support")
        )

        try ClaudeStatuslineInstaller.enable(paths: paths)
        XCTAssertTrue(ClaudeStatuslineInstaller.isEnabled(paths: paths))

        try ClaudeStatuslineInstaller.disable(paths: paths)
        let restored = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        XCTAssertNil(restored?["statusLine"])
        XCTAssertEqual(restored?["model"] as? String, "opus")
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
            now: now
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
            now: now
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
            now: now
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
            now: now
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
            now: now
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
            now: now
        )

        XCTAssertEqual(first.tokens, 40)
        XCTAssertEqual(second.tokens, 100)
        XCTAssertEqual(second.tokenBreakdown.otherTokens, 100)
    }

    func testProviderUsageRoundTripsForLaunchPersistence() throws {
        let usage = ProviderUsage(
            id: .openAI,
            tier: "Plus",
            tokenBreakdown: TokenBreakdown(
                inputTokens: 100,
                outputTokens: 23
            ),
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
            ),
            modelName: "gpt-test",
            costEstimate: TokenCostEstimate(
                currencyCode: "USD",
                estimatedAmount: 0.25,
                modelName: "gpt-test",
                isEstimated: false
            )
        )

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(
            ProviderUsage.self,
            from: data
        )

        XCTAssertEqual(decoded, usage)
    }

    func testOldProviderUsageDecodesWithAggregateTokenBreakdown() throws {
        let data = Data(
            """
            {
              "id": "openAI",
              "tier": "Plus",
              "usedTokens": 123,
              "tokenLimit": 0,
              "resetAt": 0,
              "availability": "measured",
              "sourceDetail": "Old cached reading"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: data)

        XCTAssertEqual(decoded.usedTokens, 123)
        XCTAssertEqual(decoded.tokenBreakdown, TokenBreakdown(otherTokens: 123))
        XCTAssertNil(decoded.costEstimate)
    }

    func testOldProviderConfigurationDecodesWithCostTrackingEnabled() throws {
        // Configs written before the cost-tracking field existed should opt in
        // to cost tracking on load, so bundled prices surface out of the box.
        let data = Data(
            """
            {
              "id": "openAI",
              "isEnabled": true,
              "tier": "Plus",
              "tokenLimit": 0,
              "windowHours": 24,
              "nextResetAt": 0,
              "customPath": ""
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            ProviderConfiguration.self,
            from: data
        )

        XCTAssertTrue(decoded.costTrackingEnabled)
        XCTAssertEqual(decoded.defaultModelName, "")
        XCTAssertTrue(decoded.customRates.isEmpty)
    }

    func testProviderConfigurationHonorsExplicitCostTrackingFlag() throws {
        // An explicit stored value must be preserved, not overridden.
        let data = Data(
            """
            {
              "id": "openAI",
              "isEnabled": true,
              "tier": "Plus",
              "tokenLimit": 0,
              "windowHours": 24,
              "nextResetAt": 0,
              "customPath": "",
              "costTrackingEnabled": false
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            ProviderConfiguration.self,
            from: data
        )

        XCTAssertFalse(decoded.costTrackingEnabled)
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
            now: now
        )

        XCTAssertEqual(result.tokens, 88)
    }

    func testLargeJSONLFileStillContributesUsage() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "large.jsonl",
            lines: [
                try genericRecord(
                    timestamp: now,
                    tokens: 125,
                    id: "large-file-record"
                )
            ]
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 30_000_000)
        try handle.close()

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(result.tokens, 125)
        XCTAssertEqual(result.availability, .measured)
        XCTAssertTrue(result.hasWarnings)
    }

    func testOversizedJSONDocumentIsSkippedWithWarning() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .cursor,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(named: "large.json", contents: "{}")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 30_000_000)
        try handle.close()

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(result.tokens, 0)
        XCTAssertTrue(result.hasWarnings)
    }

    func testOversizedJSONLRecordIsSkippedAndScanningContinues() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let validRecord = try genericRecord(
            timestamp: now,
            tokens: 75,
            id: "after-oversized"
        )
        let file = try temporaryFile(
            named: "oversized-record.jsonl",
            contents: String(repeating: "x", count: 8_000_001)
                + "\n"
                + validRecord
                + "\n"
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(result.tokens, 75)
        XCTAssertTrue(result.hasWarnings)
    }

    func testSameSizeRewriteReplacesCachedContribution() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let original = try genericRecord(
            timestamp: now,
            tokens: 40,
            id: "rewrite"
        ) + "\n"
        let replacement = try genericRecord(
            timestamp: now,
            tokens: 90,
            id: "rewrite"
        ) + "\n"
        XCTAssertEqual(original.utf8.count, replacement.utf8.count)
        let file = try temporaryFile(
            named: "rewrite.jsonl",
            contents: original
        )

        let first = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )
        try overwrite(replacement, at: file)
        let second = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(first.tokens, 40)
        XCTAssertEqual(second.tokens, 90)
    }

    func testLargerRewriteDoesNotCombineOldAndNewRecords() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "larger-rewrite.jsonl",
            lines: [
                try genericRecord(timestamp: now, tokens: 40, id: "old")
            ]
        )
        _ = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )
        try overwrite(
            try genericRecord(timestamp: now, tokens: 90, id: "new")
                + "\n{}\n",
            at: file
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(result.tokens, 90)
    }

    func testReplacementAtSamePathInvalidatesCachedContribution() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "replacement.jsonl",
            lines: [
                try genericRecord(timestamp: now, tokens: 40, id: "old")
            ]
        )
        _ = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )
        let replacement = file
            .deletingLastPathComponent()
            .appendingPathComponent("new.jsonl")
        try Data(
            (try genericRecord(timestamp: now, tokens: 95, id: "new") + "\n")
                .utf8
        ).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        XCTAssertEqual(result.tokens, 95)
    }

    func testOverlappingRootsDoNotDoubleCountAFile() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .openAI,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "overlap.jsonl",
            lines: [
                try codexRecord(timestamp: now, totalTokens: 250)
            ]
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file.deletingLastPathComponent(), file],
            now: now
        )

        XCTAssertEqual(result.tokens, 250)
    }

    func testPlanUsageDropsExpiredWindowsOnly() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let snapshot = PlanUsageSnapshot(
            source: .providerReported,
            planName: "Plus",
            windows: [
                PlanUsageWindow(
                    label: "5-hour",
                    usedPercent: 80,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(-1)
                ),
                PlanUsageWindow(
                    label: "Weekly",
                    usedPercent: 20,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(3_600)
                )
            ]
        )

        let active = try XCTUnwrap(snapshot.active(at: now))

        XCTAssertEqual(active.windows.map(\.label), ["Weekly"])
    }

    func testUsagePathValidationRejectsRelativeAndUnsupportedFiles() throws {
        XCTAssertEqual(
            UsagePathResolver.validate("relative/path"),
            .relativePath
        )
        XCTAssertEqual(
            UsagePathResolver.validate("~another-user/usage"),
            .relativePath
        )
        let file = try temporaryFile(named: "usage.txt", contents: "tokens")
        XCTAssertEqual(
            UsagePathResolver.validate(file.path),
            .unsupportedFileType("txt")
        )
    }

    @MainActor
    func testDisablingProviderImmediatelyRemovesReading() {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        var configurations = ProviderConfiguration.defaults(now: now)
        let reading = ProviderUsage(
            id: .openAI,
            tier: "Plus",
            usedTokens: 100,
            tokenLimit: 0,
            resetAt: now.addingTimeInterval(3_600),
            availability: .measured,
            sourceDetail: "Fixture"
        )
        let store = UsageStore(
            previewReadings: [reading],
            previewConfigurations: configurations,
            lastUpdated: now
        )

        let openAIIndex = configurations.firstIndex {
            $0.id == .openAI
        }!
        configurations[openAIIndex].isEnabled = false
        store.configurations = configurations

        XCTAssertFalse(store.readings.contains { $0.id == .openAI })
    }

    @MainActor
    func testEnablingProviderImmediatelyAddsPlaceholderReading() {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        var configurations = ProviderConfiguration.defaults(now: now)
        let cursorIndex = configurations.firstIndex {
            $0.id == .cursor
        }!
        configurations[cursorIndex].isEnabled = false
        let store = UsageStore(
            previewReadings: [],
            previewConfigurations: configurations,
            lastUpdated: now
        )

        configurations[cursorIndex].isEnabled = true
        store.configurations = configurations

        let reading = store.readings.first { $0.id == .cursor }
        XCTAssertEqual(reading?.sourceDetail, "Refresh to scan local records")
    }

    @MainActor
    func testFailedClaudeScanShowsLastKnownTokensWithoutPlan() throws {
        let now = Date()
        let store = claudeStoreWithTokens(now: now)
        store.merge(
            ScanResult(
                provider: .claude,
                tokens: 120,
                availability: .failed,
                detail: "Claude project logs: read error",
                planUsageStatus: .failed("read error")
            )
        )

        let reading = try XCTUnwrap(
            store.readings.first { $0.id == .claude }
        )
        XCTAssertNil(reading.planUsage)
    }

    func testBuiltInPricingMatchesExactAndPrefixModels() {
        // Exact match.
        let opus = BuiltInPricing.rate(for: .claude, modelName: "claude-opus-4-8")
        XCTAssertEqual(opus?.inputPerMillion, 5)
        XCTAssertEqual(opus?.outputPerMillion, 25)

        // Prefix match: real logs append suffixes like "[1m]" or a snapshot date.
        let suffixed = BuiltInPricing.rate(
            for: .claude,
            modelName: "claude-opus-4-8[1m]"
        )
        XCTAssertEqual(suffixed?.modelName, "claude-opus-4-8")

        // Longest-prefix wins over a shorter sibling.
        let codex = BuiltInPricing.rate(
            for: .openAI,
            modelName: "gpt-5.3-codex-preview"
        )
        XCTAssertEqual(codex?.modelName, "gpt-5.3-codex")

        // Gemini logs can prefix the model with "models/".
        let gemini = BuiltInPricing.rate(
            for: .gemini,
            modelName: "models/gemini-2.5-pro"
        )
        XCTAssertEqual(gemini?.modelName, "gemini-2.5-pro")
    }

    func testBuiltInPricingIsProviderScopedAndMissesUnknownModels() {
        // A Claude model must not resolve under the Gemini provider.
        XCTAssertNil(
            BuiltInPricing.rate(for: .gemini, modelName: "claude-opus-4-8")
        )
        // No bundled row is a prefix of this older id.
        XCTAssertNil(
            BuiltInPricing.rate(for: .claude, modelName: "claude-3-opus")
        )
        // Subscription providers carry no per-token bundled price.
        XCTAssertNil(
            BuiltInPricing.rate(for: .cursor, modelName: "claude-opus-4-8")
        )
    }

    func testScannerBucketsUsageIntoDayWeekMonthRollups() throws {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let configuration = configuration(
            id: .gemini,
            now: now,
            windowHours: 2
        )
        let file = try temporaryFile(
            named: "gemini.jsonl",
            lines: [
                // 30 min ago: counts toward day/week/month AND the 2h quota.
                try genericRecord(
                    timestamp: now.addingTimeInterval(-1_800),
                    tokens: 100,
                    id: "recent"
                ),
                // 12h ago: day/week/month, but outside the quota window.
                try genericRecord(
                    timestamp: now.addingTimeInterval(-12 * 3_600),
                    tokens: 200,
                    id: "day"
                ),
                // 3 days ago: week/month only.
                try genericRecord(
                    timestamp: now.addingTimeInterval(-3 * 86_400),
                    tokens: 400,
                    id: "week"
                ),
                // 15 days ago: month only.
                try genericRecord(
                    timestamp: now.addingTimeInterval(-15 * 86_400),
                    tokens: 800,
                    id: "month"
                ),
                // 40 days ago: outside the 30-day read window entirely.
                try genericRecord(
                    timestamp: now.addingTimeInterval(-40 * 86_400),
                    tokens: 1_600,
                    id: "old"
                )
            ]
        )

        let result = LocalUsageScanner.scan(
            configuration: configuration,
            rootsOverride: [file],
            now: now
        )

        let rollup = try XCTUnwrap(result.rollup)
        XCTAssertEqual(rollup.day.totalTokens, 300)
        XCTAssertEqual(rollup.week.totalTokens, 700)
        XCTAssertEqual(rollup.month.totalTokens, 1_500)
        // The headline quota figure stays scoped to the configured window.
        XCTAssertEqual(result.tokens, 100)
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

    @MainActor
    private func claudeStoreWithTokens(now: Date) -> UsageStore {
        let configurations = ProviderConfiguration.defaults(now: now)
        let reading = ProviderUsage(
            id: .claude,
            tier: "Max",
            usedTokens: 100,
            tokenLimit: 0,
            resetAt: now.addingTimeInterval(3_600),
            availability: .measured,
            sourceDetail: "Fixture"
        )
        return UsageStore(
            previewReadings: [reading],
            previewConfigurations: configurations,
            lastUpdated: now
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

    private func overwrite(_ contents: String, at file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer {
            try? handle.close()
        }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: file.path
        )
    }
}
