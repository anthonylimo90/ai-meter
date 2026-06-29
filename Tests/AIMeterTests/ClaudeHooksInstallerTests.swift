import XCTest
@testable import AIMeterCore

final class ClaudeHooksInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var paths: ClaudeHooksInstaller.Paths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aimeter-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        paths = ClaudeHooksInstaller.Paths(
            settings: tempDir.appendingPathComponent("settings.json"),
            supportDir: tempDir.appendingPathComponent("support")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.settings)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testEnableIntoMissingSettingsRegistersAllEvents() throws {
        try ClaudeHooksInstaller.enable(paths: paths)

        XCTAssertTrue(ClaudeHooksInstaller.isEnabled(paths: paths))
        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        for (event, arg) in ClaudeHooksInstaller.events {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            let command = ((entries[0]["hooks"] as? [[String: Any]])?
                .first?["command"] as? String) ?? ""
            XCTAssertTrue(command.contains(ClaudeHooksInstaller.marker))
            XCTAssertTrue(command.hasSuffix(" \(arg)"))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.hookScript.path)
        )
    }

    func testEnablePreservesExistingUserHooks() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [["type": "command", "command": "echo mine"]]
                ]],
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "echo guard"]]
                ]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: paths.settings)

        try ClaudeHooksInstaller.enable(paths: paths)

        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        // The user's Stop hook survives alongside ours.
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let stopCommands = stop.flatMap { entry in
            (entry["hooks"] as? [[String: Any]])?
                .compactMap { $0["command"] as? String } ?? []
        }
        XCTAssertTrue(stopCommands.contains("echo mine"))
        XCTAssertTrue(stopCommands.contains { $0.contains(ClaudeHooksInstaller.marker) })
        // An unrelated event is left entirely alone.
        XCTAssertNotNil(hooks["PreToolUse"])
    }

    func testEnableIsIdempotent() throws {
        try ClaudeHooksInstaller.enable(paths: paths)
        try ClaudeHooksInstaller.enable(paths: paths)

        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        for (event, _) in ClaudeHooksInstaller.events {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(event) should not stack duplicates")
        }
    }

    func testDisableRemovesOnlyOurEntriesAndArtifacts() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [["type": "command", "command": "echo mine"]]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: paths.settings)

        try ClaudeHooksInstaller.enable(paths: paths)
        try ClaudeHooksInstaller.disable(paths: paths)

        XCTAssertFalse(ClaudeHooksInstaller.isEnabled(paths: paths))
        let hooks = try XCTUnwrap(try readSettings()["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(
            (stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "echo mine"
        )
        // Events we created (with no prior user entry) are removed entirely.
        XCTAssertNil(hooks["SessionStart"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.hookScript.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.activityTouch.path)
        )
    }

    func testDisableLeavesAPristineSettingsFile() throws {
        try ClaudeHooksInstaller.enable(paths: paths)
        try ClaudeHooksInstaller.disable(paths: paths)

        // No user hooks existed, so the whole `hooks` key should be gone.
        let settings = try readSettings()
        XCTAssertNil(settings["hooks"])
    }
}
