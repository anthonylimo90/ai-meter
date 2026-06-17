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

TEST_FILE="$(mktemp "$TMPDIR/aimeter-xctest.XXXXXX.swift")"
trap 'rm -f "$TEST_FILE"' EXIT
print 'import XCTest' > "$TEST_FILE"
if ! swiftc -typecheck "$TEST_FILE" >/dev/null 2>&1; then
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
