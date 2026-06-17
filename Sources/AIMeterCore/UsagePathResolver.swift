import Foundation

public enum UsagePathValidation: Equatable, Sendable {
    case empty
    case validFile(String)
    case validDirectory(String)
    case relativePath
    case missing(String)
    case unreadable(String)
    case unsupportedFileType(String)

    public var isValid: Bool {
        switch self {
        case .empty, .validFile, .validDirectory:
            true
        case .relativePath, .missing, .unreadable, .unsupportedFileType:
            false
        }
    }
}

public enum UsagePathResolver {
    public static let supportedExtensions = Set(["json", "jsonl", "log"])

    public static func validate(_ rawPath: String) -> UsagePathValidation {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard
            trimmed.hasPrefix("/")
                || trimmed == "~"
                || trimmed.hasPrefix("~/")
        else {
            return .relativePath
        }

        let url = canonicalURL(for: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return .missing(url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unreadable(url.path)
        }
        if isDirectory.boolValue {
            return .validDirectory(url.path)
        }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return .unsupportedFileType(url.pathExtension.lowercased())
        }
        return .validFile(url.path)
    }

    public static func canonicalURL(for rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
                + String(trimmed.dropFirst())
        } else {
            expanded = trimmed
        }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    public static func normalizedPath(_ rawPath: String) -> String? {
        switch validate(rawPath) {
        case let .validFile(path), let .validDirectory(path):
            path
        case .empty, .relativePath, .missing, .unreadable,
             .unsupportedFileType:
            nil
        }
    }

    static func existingRoots(
        builtInPaths: [String],
        customPath: String
    ) -> [URL] {
        var paths = builtInPaths
        switch validate(customPath) {
        case let .validFile(path), let .validDirectory(path):
            paths.append(path)
        case .empty, .relativePath, .missing, .unreadable,
             .unsupportedFileType:
            break
        }

        var rootsByPath: [String: URL] = [:]
        for path in paths {
            let url = canonicalURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            rootsByPath[url.path] = url
        }

        let sorted = rootsByPath.values.sorted {
            $0.path.count == $1.path.count
                ? $0.path < $1.path
                : $0.path.count < $1.path.count
        }
        var retained: [URL] = []
        for root in sorted {
            if retained.contains(where: { contains(root, within: $0) }) {
                continue
            }
            retained.append(root)
        }
        return retained
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return candidate.path == root.path
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
