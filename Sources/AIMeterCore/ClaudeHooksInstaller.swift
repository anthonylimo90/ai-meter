import Foundation

/// Installs (and removes) AI Meter's Claude Code activity hooks in
/// `settings.json`. Claude Code fires these hooks as a session starts, stops,
/// asks for input, or ends; our script records the activity locally and bumps a
/// touch file so AI Meter can refresh instantly and animate while Claude works.
///
/// This is additive and fully reversible: we only ever append our own marked
/// entries to each event array and remove exactly those on disable, leaving any
/// hooks the user configured untouched. A documented, local, credential-free
/// channel — no network. https://docs.claude.com/en/docs/claude-code/hooks
public enum ClaudeHooksInstaller {
    public struct Paths: Sendable {
        public var settings: URL
        public var supportDir: URL

        public init(settings: URL, supportDir: URL) {
            self.settings = settings
            self.supportDir = supportDir
        }

        public var hookScript: URL {
            supportDir.appendingPathComponent("claude-activity-hook.sh")
        }
        public var sessionsDir: URL {
            supportDir.appendingPathComponent("sessions", isDirectory: true)
        }
        public var activityTouch: URL {
            supportDir.appendingPathComponent("activity.touch")
        }

        public static var `default`: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                settings: home.appendingPathComponent(".claude/settings.json"),
                supportDir: home.appendingPathComponent(".config/ai-meter")
            )
        }
    }

    public enum InstallError: Error, Equatable {
        case settingsUnreadable
        case settingsNotJSON
        case writeFailed
    }

    static let marker = "claude-activity-hook.sh"

    /// Hook events we register and the argument passed to the script for each.
    /// Deliberately turn-level only (no Pre/PostToolUse) — we want session
    /// boundaries, not a fire on every tool call.
    static let events: [(event: String, arg: String)] = [
        ("SessionStart", "start"),
        ("SessionEnd", "end"),
        ("Stop", "stop"),
        ("Notification", "notify")
    ]

    public static func isEnabled(paths: Paths = .default) -> Bool {
        guard
            let settings = try? readSettings(paths.settings),
            let hooks = settings["hooks"] as? [String: Any],
            let stop = hooks["Stop"] as? [[String: Any]]
        else {
            return false
        }
        return stop.contains(where: entryHasMarker)
    }

    public static func enable(paths: Paths = .default) throws {
        try FileManager.default.createDirectory(
            at: paths.sessionsDir,
            withIntermediateDirectories: true
        )
        try writeHookScript(to: paths.hookScript)

        var settings = (try? readSettings(paths.settings)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, arg) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Idempotent: drop any prior AI Meter entry before re-adding, so
            // re-enabling never stacks duplicates.
            entries.removeAll(where: entryHasMarker)
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": "sh '\(paths.hookScript.path)' \(arg)"
                ]]
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        try writeSettings(settings, to: paths.settings)
    }

    public static func disable(paths: Paths = .default) throws {
        if var settings = try? readSettings(paths.settings),
           var hooks = settings["hooks"] as? [String: Any] {
            for (event, _) in events {
                guard var entries = hooks[event] as? [[String: Any]] else {
                    continue
                }
                entries.removeAll(where: entryHasMarker)
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try writeSettings(settings, to: paths.settings)
        }
        try? FileManager.default.removeItem(at: paths.hookScript)
        try? FileManager.default.removeItem(at: paths.sessionsDir)
        try? FileManager.default.removeItem(at: paths.activityTouch)
    }

    // MARK: - Helpers

    /// True when a single event entry contains a command pointing at our script.
    static func entryHasMarker(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            throw InstallError.settingsUnreadable
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let settings = object as? [String: Any]
        else {
            throw InstallError.settingsNotJSON
        }
        return settings
    }

    private static func writeSettings(
        _ settings: [String: Any],
        to url: URL
    ) throws {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            throw InstallError.writeFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic replace so a crash never leaves a half-written settings file.
        let temporary = url.appendingPathExtension("aimeter-tmp")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private static func writeHookScript(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(hookScript.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    /// POSIX-sh hook. Records the session's state under `sessions/` and always
    /// atomically replaces `activity.touch` so a directory watcher fires. jq is
    /// not required — fields are pulled from the flattened stdin JSON with sed,
    /// and the touch (which drives refresh) happens regardless. Best-effort:
    /// every write is guarded and the script never blocks Claude Code.
    static let hookScript = #"""
    #!/bin/sh
    # AI Meter — Claude Code activity hook. Records session activity locally so
    # AI Meter can refresh instantly and animate while Claude works. Writing
    # activity.touch is what wakes AI Meter. Safe to remove from AI Meter.
    event="$1"
    dir="$HOME/.config/ai-meter"
    sessions="$dir/sessions"
    mkdir -p "$sessions" 2>/dev/null
    input=$(cat)
    flat=$(printf '%s' "$input" | tr '\n\r\t' '   ')
    field() {
      printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    }
    sid=$(field session_id)
    cwd=$(field cwd)
    transcript=$(field transcript_path)
    [ -z "$sid" ] && sid="session"
    safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
    project=$(basename "$cwd" 2>/dev/null)
    now=$(date +%s)
    write_state() {
      f="$sessions/$safe.json"
      printf '{"state":"%s","project":"%s","sessionId":"%s","transcript":"%s","cwd":"%s","pid":%s,"ts":%s}\n' \
        "$1" "$project" "$sid" "$transcript" "$cwd" "$PPID" "$now" \
        > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
    }
    case "$event" in
      start)  write_state active ;;
      notify) write_state awaiting ;;
      stop)   write_state idle ;;
      end)    rm -f "$sessions/$safe.json" 2>/dev/null ;;
    esac
    printf '%s' "$now" > "$dir/activity.touch.tmp.$$" 2>/dev/null \
      && mv -f "$dir/activity.touch.tmp.$$" "$dir/activity.touch" 2>/dev/null
    exit 0
    """#
}
