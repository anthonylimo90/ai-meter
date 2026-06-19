# Agent Notes

## Project

AI Meter is a Swift Package for a macOS menu bar app. The default branch is `main`.

## Local Toolchain

This machine runs macOS 27 beta and should use the bundled tools from Xcode 27 beta:

```zsh
xcode-select -p
# /Applications/Xcode-beta.app/Contents/Developer

xcodebuild -version
# Xcode 27.0
# Build version 27A5194q

swift --version
# Apple Swift version 6.4
# Target: arm64-apple-macosx27.0.0
```

If the active developer directory points at `/Library/Developer/CommandLineTools`, switch it before building:

```zsh
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

## Validation

Use SwiftPM directly:

```zsh
swift build
swift test
```

As of June 19, 2026, `swift test` passes with Xcode 27 beta: 31 tests, 0 failures.

`scripts/preflight.sh` currently has a brittle standalone `swiftc -typecheck` probe for `XCTest`. It can report `XCTest is unavailable` under Xcode 27 beta even though `swift test` works. Treat `swift test` as the authoritative test validation until the preflight script is fixed.

If codesigning a generated `.xctest` bundle fails with `resource fork, Finder information, or similar detritus not allowed`, clear extended attributes from build output and rerun:

```zsh
xattr -rc .build/out .build 2>/dev/null || true
swift test
```
