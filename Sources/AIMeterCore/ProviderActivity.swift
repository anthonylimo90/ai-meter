import Foundation

/// Resolves which provider is "working right now" from filesystem activity in
/// its local record folders. Claude Code gives a precise signal via hooks; the
/// other tools have no hooks, so we infer activity from recent writes to the
/// record paths the scanner already knows about. Pure, testable helpers — the
/// watching itself lives in `ProviderActivityMonitor`.
public enum ProviderActivityResolver {
    /// Absolute record roots for a provider: its built-in paths plus an optional
    /// user-configured extra path. Tildes are expanded; existence is not checked
    /// here (callers filter when they need real directories).
    public static func roots(
        for provider: ProviderID,
        customPath: String? = nil
    ) -> [URL] {
        var paths = provider.builtInPaths.map { ($0 as NSString).expandingTildeInPath }
        if let customPath,
           !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths.append((customPath as NSString).expandingTildeInPath)
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Which provider a changed file path belongs to, by longest-prefix match so
    /// nested roots resolve to the most specific owner.
    public static func provider(
        forChangedPath path: String,
        roots: [ProviderID: [URL]]
    ) -> ProviderID? {
        var best: (provider: ProviderID, length: Int)?
        for (provider, urls) in roots {
            for url in urls {
                let root = url.path
                let prefix = root.hasSuffix("/") ? root : root + "/"
                guard path == root || path.hasPrefix(prefix) else { continue }
                if best == nil || root.count > best!.length {
                    best = (provider, root.count)
                }
            }
        }
        return best?.provider
    }

    /// The provider that showed activity most recently, within `within` seconds.
    public static func mostRecentlyActive(
        _ lastActive: [ProviderID: Date],
        now: Date = .now,
        within: TimeInterval = 90
    ) -> ProviderID? {
        lastActive
            .filter {
                let age = now.timeIntervalSince($0.value)
                return age >= 0 && age <= within
            }
            .max { $0.value < $1.value }?
            .key
    }
}
