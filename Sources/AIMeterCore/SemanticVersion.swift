import Foundation

/// A minimal `major.minor.patch` version used to compare the running build
/// against the latest published release. Pre-release and build metadata are
/// intentionally ignored: AI Meter publishes plain `vMAJOR.MINOR.PATCH` tags.
public struct SemanticVersion: Comparable, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = max(major, 0)
        self.minor = max(minor, 0)
        self.patch = max(patch, 0)
    }

    /// Parses strings such as `1.2.3`, `v0.3.0`, `2.1`, or `4`. A leading `v`
    /// and any pre-release/build suffix (after `-` or `+`) are dropped. Missing
    /// trailing components default to zero. Returns `nil` when no leading
    /// numeric component is present.
    public init?(_ rawValue: String) {
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }
        // Drop SemVer pre-release / build metadata.
        let core = trimmed.prefix { $0 == "." || $0.isNumber }
        let components = core.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            let firstComponent = components.first,
            let major = Int(firstComponent)
        else {
            return nil
        }
        func component(at index: Int) -> Int {
            guard index < components.count else { return 0 }
            return Int(components[index]) ?? 0
        }
        self.init(
            major: major,
            minor: component(at: 1),
            patch: component(at: 2)
        )
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}
