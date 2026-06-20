import XCTest
@testable import AIMeterCore

final class UpdateCheckerTests: XCTestCase {

    // MARK: - SemanticVersion parsing

    func testSemanticVersionParsesTagAndPartialStrings() {
        XCTAssertEqual(SemanticVersion("v0.3.0"), SemanticVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(SemanticVersion("0.3.0"), SemanticVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("4"), SemanticVersion(major: 4, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion("  v2.5.7  "), SemanticVersion(major: 2, minor: 5, patch: 7))
    }

    func testSemanticVersionDropsPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemanticVersion("v1.2.3-beta.1"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("1.2.3+build.9"), SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    func testSemanticVersionRejectsNonNumericStrings() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testSemanticVersionComparisonIsNumericNotLexical() {
        XCTAssertTrue(SemanticVersion("0.3.0")! < SemanticVersion("0.3.1")!)
        XCTAssertTrue(SemanticVersion("0.3.0")! < SemanticVersion("0.4.0")!)
        XCTAssertTrue(SemanticVersion("0.9.0")! < SemanticVersion("0.10.0")!)
        XCTAssertTrue(SemanticVersion("0.3.0")! < SemanticVersion("1.0.0")!)
        XCTAssertEqual(SemanticVersion("0.3.0")!, SemanticVersion("0.3.0")!)
    }

    // MARK: - Release decoding

    func testDecodesLatestReleasePayload() throws {
        let release = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.4.0"))
        XCTAssertEqual(release.tagName, "v0.4.0")
        XCTAssertFalse(release.isDraft)
        XCTAssertFalse(release.isPrerelease)
        XCTAssertEqual(release.packageAsset?.name, "AI.Meter-0.4.0.pkg")
        XCTAssertEqual(release.checksumsAsset?.name, "SHA256SUMS")
        XCTAssertEqual(
            release.packageAsset?.downloadURL.absoluteString,
            "https://github.com/anthonylimo90/ai-meter/releases/download/v0.4.0/AI.Meter-0.4.0.pkg"
        )
    }

    // MARK: - Evaluation

    func testEvaluateOffersNewerRelease() throws {
        let release = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.4.0"))
        let result = try UpdateChecker.evaluate(
            release: release,
            currentVersion: SemanticVersion("0.3.0")!
        )
        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(update.version, SemanticVersion("0.4.0")!)
        XCTAssertEqual(update.tag, "v0.4.0")
        XCTAssertEqual(update.releaseNotes, "Menu bar improvements")
        XCTAssertNotNil(update.packageURL)
        XCTAssertNotNil(update.checksumsURL)
    }

    func testEvaluateReportsUpToDateForSameOrOlderRelease() throws {
        let release = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.3.0"))
        XCTAssertEqual(
            try UpdateChecker.evaluate(release: release, currentVersion: SemanticVersion("0.3.0")!),
            .upToDate
        )
        XCTAssertEqual(
            try UpdateChecker.evaluate(release: release, currentVersion: SemanticVersion("0.4.0")!),
            .upToDate
        )
    }

    func testEvaluateIgnoresDraftsAndPreReleases() throws {
        let draft = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.9.0", draft: true))
        let pre = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.9.0", prerelease: true))
        XCTAssertEqual(
            try UpdateChecker.evaluate(release: draft, currentVersion: SemanticVersion("0.3.0")!),
            .upToDate
        )
        XCTAssertEqual(
            try UpdateChecker.evaluate(release: pre, currentVersion: SemanticVersion("0.3.0")!),
            .upToDate
        )
    }

    func testEvaluateThrowsOnUnreadableTag() throws {
        let release = try GitHubRelease.decode(from: Self.releaseJSON(tag: "release-candidate"))
        XCTAssertThrowsError(
            try UpdateChecker.evaluate(release: release, currentVersion: SemanticVersion("0.3.0")!)
        ) { error in
            XCTAssertEqual(error as? UpdateCheckError, .unreadableVersion("release-candidate"))
        }
    }

    func testCheckerUsesInjectedFetcher() async throws {
        let release = try GitHubRelease.decode(from: Self.releaseJSON(tag: "v0.5.0"))
        let checker = UpdateChecker(fetcher: StubFetcher(release: release))
        let result = try await checker.check(currentVersion: SemanticVersion("0.3.0")!)
        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(update.version, SemanticVersion("0.5.0")!)
    }

    // MARK: - Checksum parsing and hashing

    func testParseExpectedHashHandlesShasumFormat() {
        let contents = "78cf1fb21faadbd47e710e488b20ace370748d25b6b2e583ae6bb81844288e1d  dist/AI Meter-0.3.0.pkg\n"
        XCTAssertEqual(
            UpdatePackageDownloader.parseExpectedHash(from: contents),
            "78cf1fb21faadbd47e710e488b20ace370748d25b6b2e583ae6bb81844288e1d"
        )
    }

    func testParseExpectedHashRejectsNonHexAndEmpty() {
        XCTAssertNil(UpdatePackageDownloader.parseExpectedHash(from: "no checksum here\n"))
        // 64 characters but not hexadecimal.
        let notHex = String(repeating: "z", count: 64)
        XCTAssertNil(UpdatePackageDownloader.parseExpectedHash(from: "\(notHex)  file.pkg"))
    }

    func testSha256HexMatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aimeter-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try UpdatePackageDownloader.sha256Hex(ofFileAt: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Fixtures

    private struct StubFetcher: ReleaseFetching {
        let release: GitHubRelease
        func fetchLatestRelease() async throws -> GitHubRelease { release }
    }

    private static func releaseJSON(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false
    ) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/anthonylimo90/ai-meter/releases/tag/\(tag)",
          "body": "Menu bar improvements",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "assets": [
            {
              "name": "AI.Meter-\(version).pkg",
              "browser_download_url": "https://github.com/anthonylimo90/ai-meter/releases/download/\(tag)/AI.Meter-\(version).pkg"
            },
            {
              "name": "SHA256SUMS",
              "browser_download_url": "https://github.com/anthonylimo90/ai-meter/releases/download/\(tag)/SHA256SUMS"
            }
          ]
        }
        """
        return Data(json.utf8)
    }
}
