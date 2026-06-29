import XCTest
@testable import AIMeterCore

final class ProviderActivityResolverTests: XCTestCase {
    func testProviderForChangedPathMatchesOwningRoot() {
        let roots: [ProviderID: [URL]] = [
            .openAI: [URL(fileURLWithPath: "/home/u/.codex/sessions")],
            .claude: [URL(fileURLWithPath: "/home/u/.claude/projects")]
        ]
        XCTAssertEqual(
            ProviderActivityResolver.provider(
                forChangedPath: "/home/u/.codex/sessions/2026/06/rollout.jsonl",
                roots: roots
            ),
            .openAI
        )
        XCTAssertEqual(
            ProviderActivityResolver.provider(
                forChangedPath: "/home/u/.claude/projects/proj/x.jsonl",
                roots: roots
            ),
            .claude
        )
        XCTAssertNil(
            ProviderActivityResolver.provider(
                forChangedPath: "/home/u/.gemini/history/y.json",
                roots: roots
            )
        )
    }

    func testProviderForChangedPathPrefersLongestPrefix() {
        // A nested custom root should win over a broader one.
        let roots: [ProviderID: [URL]] = [
            .gemini: [URL(fileURLWithPath: "/home/u/.gemini")],
            .cursor: [URL(fileURLWithPath: "/home/u/.gemini/cursor-export")]
        ]
        XCTAssertEqual(
            ProviderActivityResolver.provider(
                forChangedPath: "/home/u/.gemini/cursor-export/a.json",
                roots: roots
            ),
            .cursor
        )
    }

    func testProviderForChangedPathDoesNotMatchSiblingPrefix() {
        // "/a/.codex" must not match a sibling "/a/.codex-backup".
        let roots: [ProviderID: [URL]] = [
            .openAI: [URL(fileURLWithPath: "/a/.codex")]
        ]
        XCTAssertNil(
            ProviderActivityResolver.provider(
                forChangedPath: "/a/.codex-backup/x.jsonl",
                roots: roots
            )
        )
    }

    func testMostRecentlyActivePicksFreshestWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let activity: [ProviderID: Date] = [
            .openAI: now.addingTimeInterval(-10),
            .claude: now.addingTimeInterval(-60),
            .gemini: now.addingTimeInterval(-300) // outside the 90s window
        ]
        XCTAssertEqual(
            ProviderActivityResolver.mostRecentlyActive(activity, now: now),
            .openAI
        )
    }

    func testMostRecentlyActiveIsNilWhenAllStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let activity: [ProviderID: Date] = [
            .openAI: now.addingTimeInterval(-1_000)
        ]
        XCTAssertNil(
            ProviderActivityResolver.mostRecentlyActive(activity, now: now)
        )
    }
}
