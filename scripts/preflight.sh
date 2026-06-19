#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

print "Developer directory: $(xcode-select -p)"
print "Swift:"
swift --version

missing=0
for command in swift codesign pkgbuild productsign iconutil; do
    if ! command -v "$command" >/dev/null; then
        print -u2 "Missing required command: $command"
        missing=1
    fi
done

TEST_PACKAGE="$(mktemp -d "$TMPDIR/aimeter-xctest.XXXXXX")"
trap 'rm -rf "$TEST_PACKAGE"' EXIT
mkdir -p "$TEST_PACKAGE/Tests/XCTestProbeTests"
cat > "$TEST_PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "XCTestProbe",
    products: [],
    targets: [
        .testTarget(
            name: "XCTestProbeTests",
            path: "Tests/XCTestProbeTests"
        )
    ]
)
SWIFT
cat > "$TEST_PACKAGE/Tests/XCTestProbeTests/XCTestProbeTests.swift" <<'SWIFT'
import XCTest

final class XCTestProbeTests: XCTestCase {
    func testXCTestIsAvailable() {
        XCTAssertTrue(true)
    }
}
SWIFT
if ! swift test --package-path "$TEST_PACKAGE" --list-tests >/dev/null 2>&1; then
    print -u2 ""
    print -u2 "XCTest is unavailable in the selected developer toolchain."
    print -u2 "Install full Xcode and select it with:"
    print -u2 "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    missing=1
else
    print "XCTest: available"
fi

if (( missing )); then
    exit 1
fi

print "AI Meter development toolchain is ready."
