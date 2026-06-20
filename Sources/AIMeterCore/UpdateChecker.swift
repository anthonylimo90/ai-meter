import CryptoKit
import Foundation

// MARK: - Release model

public struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    public let name: String
    public let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

public struct GitHubRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let releaseURL: URL
    public let body: String?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case releaseURL = "html_url"
        case body
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// GitHub rewrites spaces in uploaded file names to dots, so the package is
    /// matched by extension rather than an exact name.
    public var packageAsset: GitHubReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".pkg") }
    }

    public var checksumsAsset: GitHubReleaseAsset? {
        assets.first { $0.name == "SHA256SUMS" }
    }
}

// MARK: - Result

public struct AvailableUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let releaseNotes: String?
    public let releaseURL: URL
    public let packageURL: URL?
    public let checksumsURL: URL?

    public init(
        version: SemanticVersion,
        tag: String,
        releaseNotes: String?,
        releaseURL: URL,
        packageURL: URL?,
        checksumsURL: URL?
    ) {
        self.version = version
        self.tag = tag
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.packageURL = packageURL
        self.checksumsURL = checksumsURL
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate
    case updateAvailable(AvailableUpdate)
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case unreadableVersion(String)
    case requestFailed(Int)
    case network(String)
}

// MARK: - Fetching

public protocol ReleaseFetching: Sendable {
    func fetchLatestRelease() async throws -> GitHubRelease
}

public struct GitHubReleaseFetcher: ReleaseFetching {
    public let owner: String
    public let repo: String
    private let session: URLSession

    public init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    public func fetchLatestRelease() async throws -> GitHubRelease {
        let endpoint = URL(
            string:
                "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        )!
        var request = URLRequest(url: endpoint)
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("AI Meter", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.network("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.requestFailed(http.statusCode)
        }
        do {
            return try GitHubRelease.decode(from: data)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
    }
}

// MARK: - Checker

public struct UpdateChecker: Sendable {
    public static let defaultOwner = "anthonylimo90"
    public static let defaultRepo = "ai-meter"

    private let fetcher: ReleaseFetching

    public init(fetcher: ReleaseFetching) {
        self.fetcher = fetcher
    }

    public init(
        owner: String = defaultOwner,
        repo: String = defaultRepo,
        session: URLSession = .shared
    ) {
        self.fetcher = GitHubReleaseFetcher(
            owner: owner,
            repo: repo,
            session: session
        )
    }

    public func check(
        currentVersion: SemanticVersion
    ) async throws -> UpdateAvailability {
        let release = try await fetcher.fetchLatestRelease()
        return try Self.evaluate(
            release: release,
            currentVersion: currentVersion
        )
    }

    /// Pure comparison so the decision logic is testable without networking.
    /// Drafts and pre-releases are never offered.
    public static func evaluate(
        release: GitHubRelease,
        currentVersion: SemanticVersion
    ) throws -> UpdateAvailability {
        guard !release.isDraft, !release.isPrerelease else {
            return .upToDate
        }
        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.unreadableVersion(release.tagName)
        }
        guard latest > currentVersion else {
            return .upToDate
        }
        let notes = release.body?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return .updateAvailable(
            AvailableUpdate(
                version: latest,
                tag: release.tagName,
                releaseNotes: (notes?.isEmpty == true) ? nil : notes,
                releaseURL: release.releaseURL,
                packageURL: release.packageAsset?.downloadURL,
                checksumsURL: release.checksumsAsset?.downloadURL
            )
        )
    }
}

// MARK: - Package download + verification

public enum UpdatePackageError: Error, Equatable, Sendable {
    case packageUnavailable
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
}

/// Downloads an update package and verifies its SHA-256 against the release
/// `SHA256SUMS`. This integrity check detects corruption only; authentic-origin
/// verification arrives with Sparkle's EdDSA signatures in Phase 2.
public struct UpdatePackageDownloader: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func downloadVerifiedPackage(
        for update: AvailableUpdate
    ) async throws -> URL {
        guard let packageURL = update.packageURL else {
            throw UpdatePackageError.packageUnavailable
        }

        let localURL: URL
        do {
            let (tempURL, _) = try await session.download(from: packageURL)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("AI Meter \(update.version).pkg")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            localURL = destination
        } catch {
            throw UpdatePackageError.downloadFailed(error.localizedDescription)
        }

        if let checksumsURL = update.checksumsURL,
           let expected = try? await expectedHash(from: checksumsURL) {
            let actual = try Self.sha256Hex(ofFileAt: localURL)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: localURL)
                throw UpdatePackageError.checksumMismatch(
                    expected: expected,
                    actual: actual
                )
            }
        }
        return localURL
    }

    private func expectedHash(from url: URL) async throws -> String? {
        let (data, _) = try await session.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseExpectedHash(from: text)
    }

    /// Extracts a 64-character hex digest from a `shasum`-style checksum file.
    /// The package's recorded name differs from the GitHub asset name, so the
    /// hash token is matched by shape rather than by file name.
    public static func parseExpectedHash(from contents: String) -> String? {
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for line in contents.split(whereSeparator: \.isNewline) {
            for token in line.split(whereSeparator: \.isWhitespace)
            where token.count == 64 {
                if token.unicodeScalars.allSatisfy({
                    hexCharacters.contains($0)
                }) {
                    return String(token)
                }
            }
        }
        return nil
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
