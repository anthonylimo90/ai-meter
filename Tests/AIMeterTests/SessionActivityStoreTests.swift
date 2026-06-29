import XCTest
@testable import AIMeterCore

final class SessionActivityStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimeter-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ id: String, state: String, ts: TimeInterval) throws {
        let json = """
        {"state":"\(state)","project":"proj","sessionId":"\(id)","ts":\(Int(ts))}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(id).json"))
    }

    func testReadParsesSessionsAndDropsStale() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        try write("a", state: "active", ts: now.timeIntervalSince1970 - 10)
        try write("b", state: "idle", ts: now.timeIntervalSince1970 - 100)
        try write("old", state: "active", ts: now.timeIntervalSince1970 - 13 * 3_600)

        let sessions = SessionActivityStore.read(directory: dir, now: now)

        XCTAssertEqual(Set(sessions.map(\.id)), ["a", "b"])
        XCTAssertEqual(sessions.first { $0.id == "a" }?.kind, .active)
        XCTAssertEqual(sessions.first { $0.id == "a" }?.project, "proj")
    }

    func testReadOnMissingDirectoryIsEmpty() {
        let missing = dir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(SessionActivityStore.read(directory: missing).isEmpty)
    }

    func testAggregatePrioritizesAwaitingThenActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let active = SessionActivity(id: "1", project: "", kind: .active, timestamp: now)
        let awaiting = SessionActivity(id: "2", project: "", kind: .awaiting, timestamp: now)
        let idle = SessionActivity(id: "3", project: "", kind: .idle, timestamp: now)

        XCTAssertEqual(SessionActivityStore.aggregate([active, idle], now: now), .active)
        XCTAssertEqual(
            SessionActivityStore.aggregate([active, awaiting, idle], now: now),
            .awaiting
        )
        XCTAssertEqual(SessionActivityStore.aggregate([idle], now: now), .idle)
    }

    func testAggregateDecaysStaleActiveToIdle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let staleActive = SessionActivity(
            id: "1",
            project: "",
            kind: .active,
            timestamp: now.addingTimeInterval(-600)
        )
        XCTAssertEqual(
            SessionActivityStore.aggregate([staleActive], now: now, activeFreshness: 300),
            .idle
        )
    }
}
