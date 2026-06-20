import Foundation

/// Installs (and removes) the AI Meter status-line helper into Claude Code's
/// `settings.json`. Claude Code invokes the configured `statusLine` command with
/// session JSON on stdin; our helper persists the `rate_limits` for AI Meter and
/// then forwards the same input to whatever status line was there before, so the
/// user's existing status line keeps working. Fully reversible.
public enum ClaudeStatuslineInstaller {
    public struct Paths: Sendable {
        public var settings: URL
        public var supportDir: URL

        public init(settings: URL, supportDir: URL) {
            self.settings = settings
            self.supportDir = supportDir
        }

        public var helper: URL {
            supportDir.appendingPathComponent("claude-usage-capture.sh")
        }
        public var previousCommand: URL {
            supportDir.appendingPathComponent("prev-statusline")
        }
        public var statusLineBackup: URL {
            supportDir.appendingPathComponent("statusline-backup.json")
        }
        public var captured: URL {
            supportDir.appendingPathComponent("claude-statusline.json")
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

    private static let marker = "claude-usage-capture.sh"

    public static func isEnabled(paths: Paths = .default) -> Bool {
        guard
            let settings = try? readSettings(paths.settings),
            let statusLine = settings["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String
        else {
            return false
        }
        return command.contains(marker)
    }

    public static func enable(paths: Paths = .default) throws {
        try FileManager.default.createDirectory(
            at: paths.supportDir,
            withIntermediateDirectories: true
        )
        try writeHelper(to: paths.helper)

        var settings = (try? readSettings(paths.settings)) ?? [:]
        let current = settings["statusLine"] as? [String: Any]

        // Idempotent: if already pointed at our helper, leave the saved previous
        // command untouched so we don't capture ourselves as the predecessor.
        if (current?["command"] as? String)?.contains(marker) != true {
            let previous: String
            if current?["type"] as? String == "command",
               let command = current?["command"] as? String {
                previous = command
            } else {
                previous = ""
            }
            try Data(previous.utf8).write(to: paths.previousCommand)
            try backUpStatusLine(current, to: paths.statusLineBackup)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": "sh '\(paths.helper.path)'"
        ]
        try writeSettings(settings, to: paths.settings)
    }

    public static func disable(paths: Paths = .default) throws {
        if var settings = try? readSettings(paths.settings) {
            let installedCommand = (settings["statusLine"] as? [String: Any])?[
                "command"
            ] as? String
            let isInstalled = installedCommand?.contains(marker) == true

            if let backup = restoredStatusLine(from: paths.statusLineBackup) {
                if backup["__absent__"] as? Bool == true {
                    settings.removeValue(forKey: "statusLine")
                } else {
                    settings["statusLine"] = backup
                }
                try writeSettings(settings, to: paths.settings)
            } else if isInstalled {
                // No backup but our helper is clearly installed: remove it.
                settings.removeValue(forKey: "statusLine")
                try writeSettings(settings, to: paths.settings)
            }
        }
        for url in [
            paths.helper,
            paths.previousCommand,
            paths.statusLineBackup,
            paths.captured
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func restoredStatusLine(from url: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return object
    }

    // MARK: - Helpers

    private static func backUpStatusLine(
        _ statusLine: [String: Any]?,
        to url: URL
    ) throws {
        let payload: Any = statusLine ?? ["__absent__": true]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted]
        )
        try data.write(to: url)
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

    private static func writeHelper(to url: URL) throws {
        try Data(helperScript.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    /// POSIX-sh helper. Only overwrites the captured file when `rate_limits` is
    /// present, so the last-known value survives sessions that haven't made
    /// their first API call yet. Best-effort — never blocks the status line.
    static let helperScript = """
    #!/bin/sh
    # AI Meter — Claude usage capture. Persists Claude Code's status-line
    # rate_limits so AI Meter can show live Claude plan usage, then forwards the
    # same input to your previous status line. Safe to remove from AI Meter.
    dir="$HOME/.config/ai-meter"
    input=$(cat)
    mkdir -p "$dir" 2>/dev/null
    tmp="$dir/claude-statusline.json.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
      rl=$(printf '%s' "$input" | jq -c 'select(.rate_limits) | {rate_limits}' 2>/dev/null)
      if [ -n "$rl" ]; then
        printf '%s' "$rl" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/claude-statusline.json" 2>/dev/null
      fi
    else
      case "$input" in
        *'"rate_limits"'*)
          printf '%s' "$input" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/claude-statusline.json" 2>/dev/null ;;
      esac
    fi
    prev="$dir/prev-statusline"
    if [ -s "$prev" ]; then
      printf '%s' "$input" | sh -c "$(cat "$prev")"
    fi
    """
}
