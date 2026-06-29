# Claude Code Hooks Integration — Implementation Plan

Status: draft / proposal
Scope: four additive features inspired by `m1ckc3s/claude-status-bar`, layered
on AI Meter's existing local-first, ToS-compliant architecture.

## Motivation

AI Meter reads *what AI usage cost* by scanning local client records on a fixed
1/5/15-minute timer ([`UsageStore.scheduleAutoRefresh`](../Sources/AIMeterUI/UsageStore.swift)).
`claude-status-bar` reads *what Claude Code is doing right now* by registering
Claude Code **hooks** that write small JSON state files the app polls. The two
are orthogonal signals. Adopting hooks lets us:

1. Refresh the instant a turn ends instead of up to an interval late (live cost).
2. Attribute cost to the live session / project (per-session view).
3. Distribute the Claude helper as a Claude Code plugin (lower-friction install).
4. Surface "a session is blocked waiting for you" in the menu bar.

Hooks are a documented, local, credential-free channel — the same ToS posture as
the existing status-line helper. Cost data stays sourced from the JSONL parser;
hooks only act as a **refresh trigger** and **session-attribution** layer.

Reference: https://docs.claude.com/en/docs/claude-code/hooks

---

## Shared substrate (Phase 0) — `ClaudeHooksInstaller`

All four features sit on one new, reversible installer that merges hook entries
into `~/.claude/settings.json`, modeled directly on `ClaudeStatuslineInstaller`.

### New file: `Sources/AIMeterCore/ClaudeHooksInstaller.swift`

Mirrors the existing installer's contract:

```swift
public enum ClaudeHooksInstaller {
    public struct Paths: Sendable {
        public var settings: URL        // ~/.claude/settings.json
        public var supportDir: URL      // ~/.config/ai-meter
        public var hookScript: URL      // supportDir/claude-activity-hook.sh
        public var sessionsDir: URL     // supportDir/sessions
        public var activityTouch: URL   // supportDir/activity.touch
        public static var `default`: Paths { ... }
    }
    public static func isEnabled(paths: Paths = .default) -> Bool
    public static func enable(paths: Paths = .default) throws
    public static func disable(paths: Paths = .default) throws
}
```

### settings.json merge format

Claude Code's `hooks` key is an object keyed by event name; each value is an
array of `{ matcher?, hooks: [{ type, command }] }`. We **append** our entries,
never overwrite, and tag every command with the marker `claude-activity-hook.sh`
so `disable` can filter out exactly our entries and drop now-empty arrays.

```jsonc
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command",
      "command": "sh '/Users/me/.config/ai-meter/claude-activity-hook.sh' start" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command",
      "command": "sh '.../claude-activity-hook.sh' end" }] }],
    "Stop":         [{ "hooks": [{ "type": "command",
      "command": "sh '.../claude-activity-hook.sh' stop" }] }],
    "Notification": [{ "hooks": [{ "type": "command",
      "command": "sh '.../claude-activity-hook.sh' notify" }] }]
  }
}
```

Reuse verbatim from `ClaudeStatuslineInstaller`: atomic `replaceItemAt` writes,
`0o755` helper perms, `createDirectory(withIntermediateDirectories:)`, and the
backup-before-merge discipline. `enable` must be **idempotent** (re-running does
not duplicate entries — filter our marker first, then append).

### The hook script (`claude-activity-hook.sh`)

POSIX sh, jq-optional (same dual-path style as `helperScript`). Reads Claude's
stdin JSON (`session_id`, `transcript_path`, `cwd`, `hook_event_name`), then:

- `start` → write `sessions/<sanitized-session-id>.json`
  `{ state:"active", project, sessionId, transcript, cwd, pid, startedAt, ts }`
- `stop`  → update that file to `state:"idle"`, then `touch activity.touch`
- `notify`→ set `state:"awaiting"` (permission/input) in the session file
- `end`   → delete the session file, then `touch activity.touch`

Must be near-instant and never block Claude (best-effort, all writes `2>/dev/null`).
We deliberately **omit** `PreToolUse`/`PostToolUse` — they fire on every tool call
and we don't need per-tool granularity, only turn boundaries. Quieter and cheaper
than status-bar's approach.

### Tests

`Tests/AIMeterTests/ClaudeHooksInstallerTests.swift`: enable into an empty
settings file; enable when unrelated user hooks already exist (preserved);
double-enable is idempotent; disable removes only our entries and empty arrays;
disable restores a pristine file. Reuse the temp-dir `Paths` injection pattern
already used for the status-line installer tests.

---

## Phase 1 — Event-driven refresh (highest leverage)

Goal: when a Claude turn ends, AI Meter rescans within ~1–2 s instead of waiting
for the timer. Lets us also lengthen the idle timer → better battery than today.

### New file: `Sources/AIMeterUI/ActivityWatcher.swift`

A `@MainActor` helper that watches `~/.config/ai-meter` for changes to
`activity.touch` and invokes a debounced callback.

```swift
@MainActor
final class ActivityWatcher {
    init(directory: URL, debounce: Duration = .seconds(2),
         onActivity: @escaping @MainActor () -> Void)
    func start(); func stop()
}
```

Implementation: `DispatchSource.makeFileSystemObjectSource` on a file descriptor
for the **directory** (watching the dir, not the file, survives the
`mv -f`/recreate that touch performs). Coalesce bursts with the debounce so a
`stop`+`end` pair fires one refresh. Fall back to no-op if the fd can't open.

### Wiring in `UsageStore`

- Add `@ObservationIgnored private var activityWatcher: ActivityWatcher?`.
- In `startAutoRefresh()`, if hooks are enabled, create and `start()` the watcher
  with `onActivity: { [weak self] in Task { await self?.refresh(coalescing: true) } }`.
  `refresh(coalescing:)` already de-dupes against an in-flight scan (line 260),
  so a timer tick and a hook firing at once collapse to one scan.
- Use a **narrow** refresh on hook events: pass `includeRollup` off so the
  ~30-day rollup scan doesn't run on every turn — the existing
  `rollupMinInterval` guard (line 18) already gates that; no change needed since
  `performRefresh` recomputes `includeRollup` itself.
- When hooks are enabled, raise the idle auto-refresh interval (the watcher
  covers liveness). Add a `UsageRefreshPolicy.hooksIdleInterval` (e.g. 900 s) and
  pick it in `automaticInterval(...)` when `hooksEnabled` is true.

### Settings UI

`SettingsView.swift`: a toggle "Live updates from Claude Code (installs a local
hook)" next to the existing status-line toggle, calling a new
`store.setClaudeHooksEnabled(_:)` that mirrors `setClaudeStuslineEnabled` —
enable/disable the installer, surface errors via a `claudeHooksError` string,
start/stop the watcher.

### Acceptance

Run a Claude Code turn; AI Meter's "last updated" and cost numbers move within a
couple of seconds of the turn finishing, with no timer tick in between. Toggling
the feature off restores pure-timer behavior and removes the hook from
settings.json.

### Risk / mitigation

- Many rapid turns → debounce + `coalescing` cap scans to one in-flight at a time.
- Watcher leak → `stop()` in `disable` path and on store teardown.
- No regression when hooks disabled: watcher simply never starts.

---

## Phase 2 — Per-session / per-project cost attribution

Goal: show "this session: $0.42 · project `ai-meter`" — far more compelling for a
*cost* tool than aggregate-only. Builds on the `sessions/*.json` files Phase 0
already writes.

### Model additions: `Sources/AIMeterCore/Models.swift`

```swift
public struct SessionActivity: Codable, Sendable, Identifiable {
    public var id: String          // sanitized session id
    public var project: String     // basename of cwd
    public var transcriptPath: String?
    public var state: State        // active | awaiting | idle
    public var startedAt: Date
    public var lastSeen: Date
}
```

### New file: `Sources/AIMeterCore/SessionActivityStore.swift`

Pure reader over `sessions/*.json`: `read(paths:) -> [SessionActivity]`, dropping
stale files (`lastSeen` older than, say, 12 h) to self-heal after crashes — the
same age-out idea status-bar relies on. No writes; the hook script owns writes.

### Cost attribution

The JSONL parser in [`LocalUsageScanner`](../Sources/AIMeterCore/LocalUsageScanner.swift)
already reads Claude's transcript records. Two options, smallest first:

- **v1 (cheap):** show live sessions with their state/project and the *current
  window* cost we already compute, not a true per-session split. Ships value with
  near-zero parser change.
- **v2 (full):** key token aggregation by `session_id` (Claude's JSONL lines
  carry it) so each `SessionActivity` gets its own `TokenBreakdown` → reuse
  `TokenCostEstimator` for a real per-session dollar figure. This is the larger
  change; scope it behind v1.

Recommend shipping v1 first; gate v2 on whether the JSONL lines reliably carry a
session id that matches the hook's `session_id` (verify before committing).

### UI

`MeterPopover.swift`: a collapsible "Active sessions" section under the Claude
row when `SessionActivityStore.read()` is non-empty — project name, a state dot
(active/awaiting/idle), and the cost figure (window cost in v1, per-session in v2).

### Acceptance

Two concurrent Claude sessions in different projects each appear with the right
project name and state; closing one removes it within a refresh.

---

## Phase 3 — Distribute the helper as a Claude Code plugin

Goal: a one-command install path for the Claude-side helpers (status-line + hooks)
without the GUI, matching how status-bar ships. The macOS app stays the primary
product and keeps its in-app installer; the plugin is a parallel install surface
that writes the same files to the same paths.

### New directory: `.claude-plugin/`

```
.claude-plugin/
  plugin.json          # manifest: name, version, description, author
  marketplace.json     # so `claude plugin marketplace add anthonylimo90/ai-meter` works
hooks/
  hooks.json           # event → ${CLAUDE_PLUGIN_ROOT}/hooks/claude-activity-hook.sh
  claude-activity-hook.sh
  claude-usage-capture.sh   # the existing status-line helper, shared source
```

`hooks.json` references `${CLAUDE_PLUGIN_ROOT}` (the var Claude Code sets for
plugins) instead of an absolute path. **Single-source the shell scripts**: the
Swift installer currently embeds `helperScript` as a string literal
([line 191](../Sources/AIMeterCore/ClaudeStatuslineInstaller.swift)). To avoid
drift, move both scripts to `hooks/*.sh` as the canonical copy and have the build
(`scripts/package_app.sh`) embed them into the app bundle / generate the Swift
constant from the file. Then plugin and app ship byte-identical helpers.

### Constraints

- Plugin installs to `${CLAUDE_PLUGIN_ROOT}`; confirm it still writes captured
  state to the app's expected `~/.config/ai-meter/...` paths (the scripts already
  hardcode `$HOME/.config/ai-meter`, so this holds).
- The app's `isEnabled` checks look for the marker in settings.json `statusLine`/
  `hooks`; a plugin install registers hooks differently (plugin manifest, not
  user settings.json). Add a secondary detection path: presence + freshness of
  `claude-statusline.json` / `sessions/*.json` ⇒ treat as "active (via plugin)"
  and show that in Settings instead of offering the in-app toggle.

### Acceptance

`claude plugin marketplace add anthonylimo90/ai-meter && claude plugin install
ai-meter` produces live Claude usage and session files the running app picks up,
with no GUI install step. README gains a short "Install via Claude Code plugin"
section.

### Note

Lower priority than 1–2: it's a distribution convenience, not new capability, and
it introduces a second install path to keep in sync. Do it after the script
single-sourcing in Phase 0/1 lands, so there's one helper to package.

---

## Phase 4 — Surface "awaiting permission/input"

Goal: a menu-bar signal when a session is blocked on you. Orthogonal to cost but
cheap once Phase 0 + Phase 2 exist (the `notify` hook already sets
`state:"awaiting"`).

### Implementation

- `UsageStore`: derive `var blockedSessionCount: Int` from
  `SessionActivityStore.read()` filtered to `state == .awaiting`.
- `menuBarTitle` (line 161): when `blockedSessionCount > 0`, prefer a distinct
  glyph/text (e.g. "⏳ waiting") over the "N low" cost summary, matching
  status-bar's priority rule (awaiting is never hidden behind active).
- `MeterPopover`: the awaiting session's row gets a yellow state dot and a
  "waiting for you" label.

### Caveats

`Notification` fires for several reasons (idle prompt, permission, etc.). If we
need to distinguish *permission specifically*, evaluate the dedicated
`PermissionRequest` hook event and add a `permreq` branch to the script. Verify
the event exists in the installed Claude Code version before relying on it;
degrade gracefully (treat any `notify` as "awaiting") if not.

### Acceptance

Trigger a tool that needs permission; the menu bar shows the waiting state within
the debounce window and clears when you respond.

---

## Phase 5 — Live activity mascot ("the buddy")

Goal: a small mascot — the **Meter Buddy**, a gauge-faced sprite — that **animates
while an AI is working** and settles to idle when it stops, mirroring
`claude-status-bar`'s animated icon but extended across providers and fused with
AI Meter's quota awareness. See the Pencil mocks `Mascot States` and
`Mascot — Live Activity` for the visual design.

### Activity model

Add a per-provider activity signal to the store:

```swift
enum ActivityState: Equatable { case idle, active(since: Date), awaiting }
// UsageStore: var providerActivity: [ProviderID: ActivityState]
```

**Two signal sources — "Claude or another AI works":**
- **Claude Code (`claude`, and Cursor-hosted Claude):** precise — the Phase 0
  hooks write `state.d/<session>.json` on `SessionStart`/`Stop`/`Notification`.
  This is the authoritative active/idle/awaiting edge.
- **Codex / Gemini / Copilot (no official hooks):** *inferred* — extend
  `ActivityWatcher` (Phase 1) to also watch each provider's known record dirs
  (`ProviderID.builtInPaths`, already resolved by `UsagePathResolver`). A write
  within the last ~20 s ⇒ `active`; quiet ⇒ settle to `idle`. Approximate but
  real, and it reuses paths the scanner already knows. This is what lets the
  buddy react to "another AI," not just Claude.

Both collapse into one mascot state with a clear priority:
`awaiting > active > low > idle` for the **face**, while the **tint** (ring +
glow) follows the most-recently-active provider's `accentColor` — switching to
the orange/red health color if that same provider is also running low.

### Mascot states (face)

`idle` (rest) · `active` (animated loop) · `low` (concerned, when a pinned quota
crosses threshold and nothing is active) · `refreshing` (spin, during a scan).
`active` is provider-tinted: green while Codex runs, orange while Claude runs, etc.

### The animation

- A `MascotView` (SwiftUI `Canvas`/`Shape`) parameterized by `(state, tint, phase)`.
- Drive `phase` with `TimelineView(.animation(minimumInterval: 1/20))` **only when
  `state == .active`** — a ~0.6 s loop interpolating bob, eye movement, mouth
  shape, and glow intensity, with an occasional blink. When not active, render a
  single static frame and tear the timeline down (no idle redraws → no battery
  cost).
- **On stop:** hold `active` ~1.5 s, then ease to `idle` (avoids flicker between
  back-to-back turns).
- Same `MascotView` renders at popover-header size (~42–56 px) and menu-bar size
  (~18–20 px); the menu-bar buddy is the optional prefix glyph from Phase 4's
  pinned-meter row.

### Guardrails (stricter than status-bar)

- **Reduce Motion** → static "active" glyph (glow on, no motion). Mandatory.
- Animate **only while active**; never loop in idle.
- Low frame-rate (~20 fps cap) and timeline torn down when idle.
- The buddy **accompanies, never replaces**, the numbers.
- Menu-bar mascot is **opt-in** (`Show mascot` in Settings, default off).

### Wiring

`ActivityWatcher` (Phase 1) gains a second watch set (provider record dirs) and
emits `(ProviderID, active/idle)` edges → `UsageStore.providerActivity` →
`MascotView` tint/state. No new data source beyond Phases 0–1.

### Acceptance

Start a Claude Code turn: the buddy animates within the debounce window, tinted
Claude-orange, and settles ~1.5 s after the turn ends. Run a Codex command with no
hooks installed: the buddy animates green from record-file writes alone. With
Reduce Motion on, the buddy shows a static active glyph and never animates.

---

## Sequencing & effort

| Phase | Feature | Depends on | Rough size |
|-------|---------|-----------|-----------|
| 0 | `ClaudeHooksInstaller` + hook script + tests | — | M |
| 1 | Event-driven refresh (`ActivityWatcher`) | 0 | M |
| 2 | Per-session attribution (v1) | 0 | M (v2: L) |
| 3 | Plugin distribution | 0, script single-sourcing | S–M |
| 4 | Awaiting-permission signal | 0, 2 | S |
| 5 | Live activity mascot (`MascotView` + provider-dir watch) | 0, 1 | M |

Recommended order: **0 → 1 → 2(v1) → 4 → 5 → 3**, with 2(v2) and 3 as follow-ups.
Phase 1 alone is the highest value-to-risk change and is independently shippable.
Phase 5 is the marquee delight feature but depends on the Phase 1 activity signal,
so it sequences after the plumbing is proven.

## Cross-cutting

- **Privacy:** all new files are local under `~/.config/ai-meter`; no new network
  calls. Update `PRIVACY.md` to list the hook + `sessions/` directory, matching
  status-bar's explicit framing.
- **Reversibility:** `disable` must leave settings.json byte-clean (only our
  marked entries removed) and delete `sessions/`, `activity.touch`, and the hook
  script — same guarantee the status-line installer gives today.
- **No-Claude-Code machines:** every path is opt-in and degrades to current
  timer-only behavior when hooks aren't installed.
