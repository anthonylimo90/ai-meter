import Foundation

/// One live Claude Code session, as recorded by the activity hook under
/// `~/.config/ai-meter/sessions/<id>.json`.
public struct SessionActivity: Sendable, Equatable, Identifiable {
    public let id: String
    public let project: String
    public let kind: ActivityKind
    public let timestamp: Date

    public init(id: String, project: String, kind: ActivityKind, timestamp: Date) {
        self.id = id
        self.project = project
        self.kind = kind
        self.timestamp = timestamp
    }
}

public enum ActivityKind: String, Sendable {
    case active
    case awaiting
    case idle
}

/// Reads the session files the activity hook writes and collapses them into a
/// single activity signal. Pure reader — the hook owns all writes. Stale files
/// (e.g. from a session that crashed without firing `SessionEnd`) age out so a
/// dead "active" file never pins the mascot on forever.
public enum SessionActivityStore {
    public static func read(
        directory: URL = ClaudeHooksInstaller.Paths.default.sessionsDir,
        now: Date = .now,
        staleAfter: TimeInterval = 12 * 3_600
    ) -> [SessionActivity] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var result: [SessionActivity] = []
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let sessionId = object["sessionId"] as? String,
                let stateString = object["state"] as? String,
                let kind = ActivityKind(rawValue: stateString)
            else {
                continue
            }
            let timestamp = (object["ts"] as? Double)
                .map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            if now.timeIntervalSince(timestamp) > staleAfter { continue }
            result.append(
                SessionActivity(
                    id: sessionId,
                    project: object["project"] as? String ?? "",
                    kind: kind,
                    timestamp: timestamp
                )
            )
        }
        return result
    }

    /// Collapse sessions into one activity kind. `active` is honored only while
    /// fresh — a session left "active" by a crash decays to idle after
    /// `activeFreshness`, so the buddy doesn't animate forever.
    public static func aggregate(
        _ sessions: [SessionActivity],
        now: Date = .now,
        activeFreshness: TimeInterval = 300
    ) -> ActivityKind {
        if sessions.contains(where: { $0.kind == .awaiting }) {
            return .awaiting
        }
        if sessions.contains(where: {
            $0.kind == .active && now.timeIntervalSince($0.timestamp) <= activeFreshness
        }) {
            return .active
        }
        return .idle
    }
}

/// What the mascot should show. Pure value so it's testable and shared between
/// the popover and (later) the menu bar.
public struct MascotStatus: Sendable, Equatable {
    public enum Face: String, Sendable {
        case idle
        case active
        case awaiting
        case refreshing
        case low
    }

    public var face: Face
    /// Provider whose accent tints the buddy; `nil` uses the default teal.
    public var tint: ProviderID?

    public init(face: Face, tint: ProviderID? = nil) {
        self.face = face
        self.tint = tint
    }

    public static let idle = MascotStatus(face: .idle)
}
