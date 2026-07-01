import XCTest
@testable import AIMeterCore
@testable import AIMeterUI

final class DisplaySessionsTests: XCTestCase {
    @MainActor
    func testDisplaySessionsSortsAwaitingBeforeActiveBeforeIdle() {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let store = UsageStore(previewReadings: [], lastUpdated: now)
        store.sessionActivities = [
            SessionActivity(id: "idle", project: "z", kind: .idle, timestamp: now),
            SessionActivity(id: "active", project: "y", kind: .active, timestamp: now),
            SessionActivity(id: "awaiting", project: "x", kind: .awaiting, timestamp: now)
        ]

        XCTAssertEqual(
            store.displaySessions.map(\.id),
            ["awaiting", "active", "idle"]
        )
    }

    @MainActor
    func testDisplaySessionsBreaksTiesByMostRecentFirst() {
        let now = Date(timeIntervalSince1970: 1_781_100_000)
        let store = UsageStore(previewReadings: [], lastUpdated: now)
        store.sessionActivities = [
            SessionActivity(
                id: "older",
                project: "a",
                kind: .active,
                timestamp: now.addingTimeInterval(-60)
            ),
            SessionActivity(
                id: "newer",
                project: "b",
                kind: .active,
                timestamp: now
            )
        ]

        XCTAssertEqual(store.displaySessions.map(\.id), ["newer", "older"])
    }

    @MainActor
    func testDisplaySessionsEmptyWhenNoSessions() {
        let store = UsageStore(previewReadings: [], lastUpdated: .now)
        XCTAssertTrue(store.displaySessions.isEmpty)
    }
}
