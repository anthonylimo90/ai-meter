# AI Meter Reliability and Public Release Remediation

Status: Implemented; signed release validation pending  
Target release: 0.2.0  
Last updated: June 14, 2026

## 1. Purpose

This specification defines the work required to resolve the issues found in the
June 2026 critical code review and prepare AI Meter for dependable public use.

The work covers:

1. Correct scanning of large local session files.
2. Honest handling of stale or failed provider quota checks.
3. Signed, hardened, notarized, and universal public packages.
4. Immediate reconciliation when providers are enabled or disabled.
5. Correct incremental parsing after log rewrites or rotation.
6. Deduplication of overlapping and equivalent scan paths.
7. Deterministic snapshots that never expose a developer's real usage.
8. Continuous integration for builds, tests, packaging, and architecture checks.
9. A documented and validated development toolchain.
10. Safer custom-path selection and validation.
11. Centralized version metadata and a proper application icon.
12. Explicit Intel and Apple Silicon support.

## 2. Goals

- Never silently omit valid usage because a line-oriented log grew large.
- Never present expired or failed quota data as live provider data.
- Keep provider rows synchronized with the user's settings.
- Preserve the performance benefit of incremental parsing without sacrificing
  correctness after file replacement or rewriting.
- Produce public artifacts that pass macOS Gatekeeper checks.
- Make repository screenshots deterministic and safe to publish.
- Make every supported behavior testable in CI.
- Keep the app local-first and avoid adding telemetry or provider credentials.

## 3. Non-Goals

- Adding remote provider APIs or OAuth integrations.
- Estimating subscription quotas when a provider does not expose them.
- Supporting macOS versions earlier than macOS 14.
- Sandboxing the app in this release.
- Redesigning the menu-bar interface.
- Changing the meaning of locally measured token totals.

## 4. Product and Engineering Decisions

### 4.1 Supported Platforms

- Minimum operating system remains macOS 14.
- Public releases will be universal binaries containing `arm64` and `x86_64`.
- Local developer builds may target only the host architecture.

### 4.2 Test Framework

- Keep XCTest for this release.
- Full Xcode with Swift 6.2 and a matching macOS SDK is required to run tests.
- Command Line Tools alone may build the executables but are not considered a
  complete contributor environment because they may not include XCTest.
- CI is the authoritative clean-environment test result.

### 4.3 Quota Failure Behavior

- A provider-reported quota is live only while at least one reported window has
  a future reset date.
- If a Claude quota check is intentionally skipped because of rate limiting, an
  active previous quota may be retained.
- If a Claude quota check is attempted and fails or produces no parseable quota,
  the previous quota must not remain presented as live.
- Expired persisted quota windows are removed during launch before menu-bar
  status is calculated.

### 4.4 Public and Developer Packages

- Developer packaging may use ad-hoc signing.
- Public release packaging must require Developer ID application and installer
  identities, hardened runtime, timestamping, notarization, and stapling.
- A release command must fail closed when any required identity, credential,
  architecture, signature, or notarization check is missing.

## 5. Functional Requirements

### R1. Large and Line-Oriented Usage Files

#### Problem

The scanner currently excludes every file larger than 25 MB. Codex and Claude
JSONL sessions can legitimately grow beyond that threshold, causing token and
quota data to disappear.

#### Required Behavior

- Apply the 25 MB whole-file limit only to `.json` files that are loaded into
  memory as a complete document.
- Do not reject `.jsonl` or `.log` files based on total file size.
- Continue reading `.jsonl` and `.log` files incrementally in bounded chunks.
- Add a maximum individual record size, initially 8 MB, to prevent an invalid
  file without line breaks from growing the pending buffer without bound.
- Skip an oversized individual record, continue at the next newline, and report
  a warning for that file.
- Apply extension and size validation when the configured root is a direct file,
  not only when enumerating a directory.
- Surface skipped oversized JSON documents and records through `hasWarnings`
  and a useful source-detail message.

#### Acceptance Criteria

- A valid 30 MB JSONL file contributes its records.
- A valid record appended after the file exceeds 25 MB is detected on refresh.
- A JSON document over 25 MB is skipped without loading the entire file.
- An oversized JSONL record does not cause unbounded memory growth.
- Other valid records in the same file still contribute after an oversized
  record is skipped.

### R2. Provider Quota Freshness and Failure States

#### Problem

Previous Claude quota data is retained whenever a new scan returns no quota,
including after a forced probe fails. Persisted expired windows can also appear
as live immediately after launch.

#### Required Behavior

- Replace the current implicit optional-quota behavior with an explicit probe
  outcome:

```swift
enum PlanUsageReadStatus: Sendable, Equatable {
    case notRequested
    case measured
    case unavailable(String)
    case failed(String)
}
```

- Add the outcome to `ScanResult`.
- Have `ClaudeUsageProbe` distinguish:
  - executable not found;
  - successful quota parse;
  - timeout or process failure;
  - output received but quota format was not recognized.
- Preserve prior Claude quota only for `.notRequested`.
- Clear prior Claude quota for `.unavailable` and `.failed`.
- Filter expired windows before storing, restoring, displaying, or exposing a
  reading to the menu bar.
- If one window is expired and another remains active, retain only the active
  window.
- Do not count a provider as a detected quota unless an active window exists.
- Include quota failure or unavailability in the provider's source detail
  without marking valid local token data as unavailable.

#### Acceptance Criteria

- A failed forced Claude refresh removes the prior live meter.
- A rate-limited refresh preserves an unexpired prior Claude meter.
- An expired persisted meter is absent immediately after launch.
- An expired primary window does not hide a still-active secondary window.
- Local Claude token totals remain visible when quota probing fails.

### R3. Release Packaging and Gatekeeper

#### Problem

Current packaging permits unsigned installers, ad-hoc app signatures, a single
architecture, and ignored signature failures.

#### Required Behavior

- Separate developer packaging from public release packaging through an
  explicit mode or dedicated release script.
- Public release mode must require:
  - `APP_SIGN_IDENTITY`;
  - `INSTALLER_SIGN_IDENTITY`;
  - a configured `notarytool` keychain profile or equivalent credentials.
- Build `arm64` and `x86_64` executables and combine them into a universal
  executable.
- Sign the app with:
  - Developer ID Application identity;
  - hardened runtime;
  - secure timestamp.
- Sign the installer with a Developer ID Installer identity.
- Submit the installer with `notarytool`, wait for acceptance, and staple the
  ticket.
- Validate all release artifacts:
  - `codesign --verify --deep --strict`;
  - `codesign -dv` reports Developer ID and runtime signing;
  - `pkgutil --check-signature` succeeds;
  - `spctl` accepts the app and installer;
  - `stapler validate` succeeds;
  - `lipo -archs` contains `arm64 x86_64`;
  - required resources and metadata are present.
- Never suppress a public-release signature or validation failure.
- Preserve the SwiftPM resource bundle in the app and verify provider images can
  be loaded from the packaged artifact.

#### Acceptance Criteria

- Developer packaging remains usable without Apple credentials.
- Release packaging exits before producing a publishable artifact when a
  credential is absent.
- A completed release package installs and launches on both supported
  architectures.
- Gatekeeper accepts a downloaded, stapled installer without manual overrides.

### R4. Provider Configuration Reconciliation

#### Problem

Disabled providers remain in `readings` until the app relaunches because refresh
only scans enabled configurations and never removes existing rows.

#### Required Behavior

- Introduce one reconciliation method that aligns readings with the current
  enabled provider configurations.
- Call reconciliation when:
  - a provider's enabled state changes;
  - configurations are restored to defaults;
  - configurations are loaded;
  - a refresh begins and ends.
- Remove a disabled provider from:
  - `readings`;
  - `refreshingProviders`;
  - `staleProviders`.
- Add a newly enabled provider immediately with a waiting-for-refresh state.
- Ignore a scan result if its provider was disabled while the scan was running.
- Preserve provider ordering according to `ProviderID.allCases`.

#### Acceptance Criteria

- Disabling a provider removes its row without relaunching or refreshing.
- Enabling a provider adds a placeholder row immediately.
- A late result from a disabled provider cannot reinsert its row.
- Restore Defaults yields exactly the default enabled-provider rows.

### R5. Incremental Cache Correctness

#### Problem

The incremental cache assumes files only append. In-place rewrites, replacement,
or rotation at the same path can retain stale contributions and resume from an
invalid offset.

#### Required Behavior

- Extend file identity beyond path, size, and modification time.
- Store:
  - file-system identity when available;
  - size and modification date;
  - a bounded fingerprint of the beginning of the file;
  - a bounded fingerprint around the previous processed offset.
- Reuse an incremental contribution only when:
  - the configured window is unchanged;
  - file identity is unchanged;
  - size has not decreased;
  - stored fingerprints still match.
- Fully reparse when:
  - the file identity changes;
  - size decreases;
  - modification changes without growth;
  - either fingerprint differs;
  - the prior offset is beyond the current file.
- Serialize cache updates per provider and canonical file path so cancelled and
  overlapping scans cannot overwrite a newer contribution with an older one.
- Keep cache memory bounded and remove entries for files that no longer exist.

#### Acceptance Criteria

- Pure appends continue to parse only new bytes.
- A same-size rewrite replaces the old total.
- A larger rewritten file does not combine old and new records.
- Rotation to a new file at the same path resets the contribution.
- Concurrent refreshes leave the cache in the state of the newest complete
  parse.

### R6. Canonical Path and File Deduplication

#### Problem

Built-in and custom roots can overlap. The same file may therefore appear more
than once and Codex contributions can be summed repeatedly.

#### Required Behavior

- Normalize roots by:
  - expanding a leading `~`;
  - standardizing path components;
  - resolving symbolic links where possible.
- Remove duplicate roots before inventory.
- Deduplicate inventory results by canonical file URL.
- Treat a parent root and child root as one logical source for files they share.
- Use canonical file paths in incremental cache keys.
- Keep deterministic file ordering after deduplication.

#### Acceptance Criteria

- Adding the built-in folder as the extra folder does not change totals.
- Adding a parent of a built-in folder does not change totals.
- A symlink and its target do not double-count the same file.
- Deduplication applies to every provider, not only Codex.

### R7. Deterministic and Private Snapshots

#### Problem

The snapshot executable loads real preferences and scans live local logs. The
result is nondeterministic and can expose personal usage in committed images.

#### Required Behavior

- Make fixture-based rendering the default.
- Add fixed preview configurations and readings covering:
  - live primary and secondary quota windows;
  - local-token-only usage;
  - unavailable data;
  - stale or failed data;
  - settings values.
- Use a fixed reference date for reset labels.
- Do not read UserDefaults, local provider folders, or Claude Code in fixture
  mode.
- Permit live rendering only through an explicit `--live` option.
- Add an obvious console warning when `--live` is used.
- Regenerate `implementation.png` and `settings.png` from fixtures.
- Keep personal absolute paths, real plan usage, and real token totals out of
  tracked snapshot artifacts.

#### Acceptance Criteria

- Two fixture snapshot runs produce the same logical content.
- Fixture mode succeeds on a machine without provider clients or usage logs.
- Fixture mode does not start the Claude executable.
- Tracked screenshots contain only documented fixture values.

### R8. Continuous Integration

#### Required Behavior

- Add a pull-request and branch workflow using a macOS runner with full Xcode.
- The validation workflow must:
  - select and report the Xcode and Swift versions;
  - run `swift test`;
  - run a debug and release build;
  - run shell syntax checks;
  - create a developer package;
  - validate the app bundle, Info.plist, resource bundle, and executable;
  - generate fixture snapshots;
  - run `git diff --check`.
- Add a tag-triggered or manually dispatched release workflow that:
  - verifies the tag matches the centralized app version;
  - builds the universal artifact;
  - signs, notarizes, staples, and validates it;
  - publishes checksums with the release artifact.
- Keep signing and notarization credentials in repository secrets.
- Do not make forks require release secrets to run ordinary validation.
- Configure the validation workflow as a required branch-protection check on the
  public repository.

#### Acceptance Criteria

- A clean pull request cannot merge with failing tests or packaging validation.
- Release jobs fail closed when signing or notarization fails.
- CI artifacts clearly distinguish developer builds from public releases.

### R9. Development Toolchain Contract

#### Required Behavior

- Document that full Xcode, not only Command Line Tools, is required for tests.
- State the required Swift language/toolchain version and macOS minimum.
- Add a preflight script that reports:
  - selected developer directory;
  - Swift version;
  - whether XCTest can be imported;
  - whether required packaging commands are available.
- Give actionable remediation when `xcode-select` points at Command Line Tools.
- Keep build commands usable in workspace-local caches where possible.

#### Acceptance Criteria

- A contributor can determine why tests cannot run before waiting for a build.
- README development instructions match CI and the preflight script.
- The documented setup can run the complete test suite.

### R10. Custom Usage Path Selection and Validation

#### Required Behavior

- Keep the editable path field and add a Browse button using a native file or
  folder picker.
- Accept an absolute path or a path beginning with `~`.
- Reject relative paths and unsupported direct-file extensions.
- Show inline states for:
  - no custom path;
  - valid readable directory;
  - valid readable supported file;
  - missing path;
  - unreadable path;
  - unsupported file type.
- Normalize a selected path before persistence.
- Do not require security-scoped bookmarks while the app remains unsandboxed.
- Do not prevent saving other provider settings because one path is invalid;
  simply exclude the invalid path from scans and explain why.

#### Acceptance Criteria

- Users can select a directory without manually typing it.
- Invalid custom paths never make a built-in source stop scanning.
- Path validation and scanner path resolution share the same normalization
  implementation.

### R11. Version Metadata and Application Icon

#### Required Behavior

- Create one tracked version source containing:
  - semantic app version;
  - numeric build number.
- Read that source from app and installer packaging.
- Remove duplicated hard-coded version defaults from packaging scripts.
- Display the bundled version and build in About settings.
- Name installer output from the centralized version.
- Change README artifact examples to avoid a stale hard-coded version.
- Add an original AI Meter application icon:
  - retain a 1024-by-1024 source asset;
  - generate or commit an `.icns` file;
  - include it in the app bundle;
  - set the appropriate Info.plist icon key.

#### Acceptance Criteria

- Updating the version source changes app and installer metadata together.
- A release tag/version mismatch fails CI.
- Finder, Installer, and About settings show the expected icon and version.

### R12. Architecture Support

#### Required Behavior

- Public app and installer payloads must contain a universal executable.
- Developer builds default to the host architecture unless universal output is
  explicitly requested.
- Architecture validation must run after copying and signing the final app, not
  only against intermediate binaries.
- Document Apple Silicon and Intel support in the README.

#### Acceptance Criteria

- `lipo -archs` on the final release executable reports both architectures.
- The release artifact is smoke-tested on both architecture classes before
  publishing 0.2.0.

## 6. Proposed Code Organization

The implementation should keep changes within existing ownership boundaries:

| Area | Primary files |
| --- | --- |
| Inventory, parsing, cache, canonical paths | `Sources/AIMeterCore/LocalUsageScanner.swift` |
| Probe result modeling and quota freshness | `Sources/AIMeterCore/Models.swift`, `Sources/AIMeterCore/ClaudeUsageProbe.swift` |
| Provider reconciliation and persistence | `Sources/AIMeterUI/UsageStore.swift` |
| Path picker, validation, About metadata | `Sources/AIMeterUI/SettingsView.swift` |
| Deterministic fixtures and rendering | `Sources/AIMeterSnapshot/AIMeterSnapshot.swift` plus a small fixture file |
| Unit and integration tests | `Tests/AIMeterTests/` |
| Build, signing, notarization | `scripts/` |
| CI | `.github/workflows/` |
| Version and icon assets | a small `Config/` or `Resources/` addition |

Avoid splitting the scanner into many abstractions solely for file length.
Extraction is justified for shared path normalization, inventory results,
fixture data, and release validation because those have distinct contracts.

## 7. Test Matrix

| Area | Required coverage |
| --- | --- |
| Large files | JSONL above 25 MB, append above threshold, oversized line, oversized JSON |
| Quota freshness | skipped probe, successful probe, failed forced probe, expired persisted windows, partial active windows |
| Provider toggles | disable, enable, restore defaults, disable during refresh |
| Cache | append, truncate, same-size rewrite, larger rewrite, replacement inode, concurrent scans |
| Paths | duplicate root, parent/child roots, symlink, direct file, invalid custom path |
| Persistence | sanitized quota restore, enabled-provider restore, versioned model decoding |
| Snapshots | fixture-only default, no process launch, no local-folder access |
| Packaging | resources, plist, icon, version, signatures, notarization, architectures |
| UI | path validation states and provider row reconciliation |

Tests that alter files should use isolated temporary directories and deterministic
timestamps. Tests must not read a contributor's real provider folders.

## 8. Implementation Order

### Phase 1: Correctness Foundation

1. Add shared path normalization and inventory deduplication.
2. Correct large-file handling and bounded line parsing.
3. Harden incremental cache invalidation and serialization.
4. Add scanner and cache tests.

### Phase 2: State Honesty

1. Add explicit plan-usage probe outcomes.
2. Sanitize active quota windows at load and merge boundaries.
3. Reconcile readings with enabled configurations.
4. Add state and persistence tests.

### Phase 3: Deterministic Development Assets

1. Add fixture stores and fixed clock input.
2. Make snapshot rendering fixture-first.
3. Regenerate tracked screenshots.
4. Add custom-path picker and validation.

### Phase 4: Public Release Pipeline

1. Centralize version metadata.
2. Add the application icon.
3. Build universal developer and release artifacts.
4. Add strict signing, notarization, stapling, and validation.
5. Add CI and release workflows.
6. Update public documentation.

Each phase must leave the project buildable. Scanner and state behavior should
not be combined into one unreviewable change.

## 9. Migration and Compatibility

- Existing provider configurations remain decodable.
- New persisted fields must use defaults so 0.1.x preferences continue loading.
- Existing cached readings may be loaded, but expired plan windows are removed.
- Incremental file caches are process-local and require no disk migration.
- The version source begins at the next intended release version, 0.2.0, once
  implementation starts.

## 10. Release Definition of Done

The remediation is complete when:

- Every R1-R12 acceptance criterion is satisfied.
- The full XCTest suite passes in CI.
- A clean release build contains no personal usage data.
- The final app contains `arm64` and `x86_64`.
- The app and installer are signed with the expected Developer ID identities.
- Apple notarization is accepted and stapled.
- Gatekeeper validation succeeds on a downloaded artifact.
- Installation, launch, refresh, settings, and uninstall smoke tests pass.
- README requirements and installation instructions match the shipped artifact.
- No P1 or P2 findings from this review remain open.

## 11. References

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Configuring the hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 12. Implementation Status

The remediation code, tests, deterministic fixtures, documentation, packaging
validation, and CI/release workflows are implemented for version 0.2.0.

Locally verified:

- Debug build.
- Test source parsing.
- Deterministic byte-identical popover and settings snapshots.
- App bundle assembly, resources, icon, version metadata, and ad-hoc signing.
- Script syntax, workflow YAML parsing, and formatting checks.

External validation still required:

- Full XCTest execution under full Xcode in CI.
- Universal `arm64` and `x86_64` build under full Xcode.
- Developer ID signing, notarization, stapling, and Gatekeeper assessment using
  the release credentials.
