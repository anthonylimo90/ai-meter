# AI Meter In-App Update Plan

Status: Phase 1 shipped in 0.4.0; Phase 2 (Sparkle) implemented for 0.5.0
Target release: 0.4.0 (Phase 1), 0.5.0 (Phase 2)
Last updated: June 20, 2026

## 0. Decisions and status

- Phase 1 (on-demand GitHub Releases checker) shipped in 0.4.0 and is now
  superseded.
- Phase 2 uses **Sparkle** with **EdDSA** signatures. The appcast is published
  to **GitHub Pages** at `https://anthonylimo90.github.io/ai-meter/appcast.xml`.
- The update artifact is a **zipped `.app`** for silent in-place updates.
- The EdDSA private key lives in the GitHub Actions secret
  `SPARKLE_ED_PRIVATE_KEY`; the public key is embedded as `SUPublicEDKey`.
- **One-time manual step:** enable GitHub Pages for the `gh-pages` branch
  (Settings > Pages > Deploy from a branch > `gh-pages` / root) after the first
  release creates that branch.

## 1. Purpose

AI Meter is distributed as a `.pkg` through GitHub Releases. Once installed,
there is no way for an existing installation to learn that a newer release
exists or to update to it. This document defines the work to add an in-app
update capability.

The work is delivered in two phases:

1. A lightweight, on-demand "Check for Updates" against the GitHub Releases
   API that notifies the user and hands off to the standard installer.
2. A secure, self-contained auto-updater built on Sparkle with EdDSA-signed
   appcast feeds, replacing the Phase 1 network check.

## 2. Constraints and findings

These shaped the design and must hold for any implementation.

- The application is **not sandboxed** (no entitlements file; ad-hoc signed in
  `scripts/package_app.sh`). It may make network requests and replace files in
  `/Applications` without sandbox restrictions.
- The application is a menu-bar agent (`LSUIElement`), bundle identifier
  `com.anthonylimo.aimeter`.
- The running app can read its own version from `Info.plist`
  (`CFBundleShortVersionString`, populated from `Config/version.env`
  `APP_VERSION`).
- Releases are public, so the unauthenticated GitHub API
  (`/repos/anthonylimo90/ai-meter/releases/latest`, 60 requests/hour per IP) is
  sufficient for on-demand checks.
- GitHub rewrites spaces in uploaded asset file names to dots: the release asset
  is `AI.Meter-0.3.0.pkg`, not `AI Meter-0.3.0.pkg`. Asset matching must be by
  `.pkg` suffix, not exact name.
- Current `.pkg` artifacts are **unsigned and un-notarized**.

## 3. Authenticity model

Detecting a newer version is trivial; trusting the downloaded artifact is the
hard part. The release ships a `SHA256SUMS` file alongside the `.pkg`, but
because that hash lives in the same release, it only detects corruption — not a
tampered or compromised release, where an attacker rewrites both the artifact
and the checksum.

Real authenticity requires a signature anchored to a key that is not shipped
beside the artifact. The chosen direction is **Sparkle with EdDSA**: Sparkle
signs each update with a private key held only as a CI secret, the app embeds
the matching public key, and Sparkle verifies the signature before installing.
This works even though the build is unsigned and un-notarized, and requires no
paid Apple Developer account.

Phase 1 verifies only the SHA-256 against the release `SHA256SUMS`. This is a
deliberate interim measure and is labeled as such in the UI and code; it is
superseded by EdDSA verification in Phase 2.

## 4. Phase 1 — Lightweight update checker (interim)

Intentionally thin: Sparkle provides its own update window in Phase 2, so Phase
1 does not build a custom download or progress interface that would be
discarded.

### 4.1 Scope

- `SemanticVersion` value type: parse a release tag (`v0.3.0` -> `0.3.0`) and
  compare against the running version. Reused in Phase 2. Unit-tested.
- `UpdateChecker` service: `URLSession` GET of the latest release, decoding
  `tag_name`, `html_url`, `body` (release notes), and assets. Resolves the
  `.pkg` asset by suffix. Produces an `UpdateCheckResult` of either
  "up to date" or "update available" with the version, notes, and URLs.
- `UsageStore` integration: a `checkForUpdates()` entry point and observable
  state (`availableUpdate`, `isCheckingForUpdates`, `updateError`,
  `lastUpdateCheck`).
- `SettingsView`: a row showing the current version, a "Check for Updates"
  button, and the last-checked time.
- `MeterPopover` footer: an unobtrusive "Update available" affordance shown only
  when a newer version exists. Selecting it downloads the `.pkg` to a temporary
  directory, verifies its SHA-256 against `SHA256SUMS`, and opens it so the user
  completes the standard installer. No privileged code.
- Tests: version comparison and release-JSON parsing against a checked-in
  fixture. No live network access in tests.
- `README.md`: disclose the on-demand update check in the privacy section. This
  is the application's first network request.

### 4.2 Out of scope for Phase 1

- Background or scheduled update polling.
- Automatic download and installation.
- A custom progress or release-notes window.

## 5. Phase 2 — Sparkle with EdDSA

### 5.1 Application

- Add Sparkle through SwiftPM (`sparkle-project/Sparkle`).
- Wire `SPUStandardUpdaterController` and route the existing "Check for Updates"
  controls to Sparkle. Retire the Phase 1 network call; retain `SemanticVersion`
  and the version row.
- Add `Info.plist` keys in `scripts/package_app.sh`: `SUFeedURL`,
  `SUPublicEDKey`, and Sparkle's installer-service keys.
- Generate an EdDSA key pair once. The private key is stored as a GitHub Actions
  secret; the public key is embedded in the bundle.

### 5.2 Release and continuous integration

- Produce a zipped `.app` asset (`AI Meter-X.Y.Z.zip`); Sparkle updates app
  bundles rather than installer packages. `release.yml` already uploads a `.zip`
  asset when present.
- Run Sparkle's `sign_update` over the zip to obtain the EdDSA signature, then
  generate or append the `<item>` entry to `appcast.xml`.
- Host the appcast at a stable URL so `SUFeedURL` never changes.
- Continue shipping the `.pkg` for first-time installations.

## 6. Sequencing and open items

- Reusable across phases: `SemanticVersion`, the Settings version row, and the
  "update available" UI slot.
- Discarded after Phase 2: the `UpdateChecker` network call and SHA-256
  verification, both superseded by Sparkle.
- To decide before Phase 2:
  - Appcast hosting location (GitHub Pages is the leading option versus a pinned
    `raw.githubusercontent.com` URL).
  - EdDSA private-key custody (GitHub Actions secret).
- Orthogonal and parkable: adding Developer ID notarization later would also
  remove the current Gatekeeper "unidentified developer" install warning. It is
  not required for Sparkle.

## 7. Privacy

- The Phase 1 check is on demand only; no background polling.
- A GitHub API request transmits only the client IP address and a User-Agent
  string. No usage data, account data, or identifiers are sent.
- The behavior is documented in `README.md` so the local-first, no-telemetry
  positioning remains accurate.
