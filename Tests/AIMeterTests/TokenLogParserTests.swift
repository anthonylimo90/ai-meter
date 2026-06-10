import XCTest
@testable import AIMeterCore

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
}
