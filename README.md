# AI Meter

AI Meter is a native macOS menu-bar utility for viewing locally measured AI
token usage across ChatGPT/OpenAI, Claude, Gemini, Cursor, and GitHub Copilot.

## What it measures

- Codex plan usage from provider-reported 5-hour and weekly quota snapshots in
  local session logs, including reset times and detected plan tier.
- Claude plan usage from the installed Claude Code client's `/usage` screen,
  including session and weekly windows, reset times, and detected plan tier.
- OpenAI token usage from local Codex session logs.
- Claude usage from local Claude project logs.
- Gemini, Cursor, and Copilot usage when compatible JSON/JSONL token metadata
  is available in their local folders or in a custom folder you configure.

AI Meter keeps provider-reported plan usage separate from locally measured
tokens. When a client does not expose trustworthy plan quota data, the app says
so explicitly and can optionally show a user-configured fallback budget.

Automatic refresh runs while AI Meter is open and defaults to every minute.
The interval can be changed to 30 seconds, 1 minute, 5 minutes, or 15 minutes
from Settings. Opening the menu also refreshes data that is more than 15 seconds
old.

The menu bar shows compact icons and remaining-usage bars for providers with
live quota data. This display can be disabled from General settings.

## Build

```sh
swift test
./scripts/package_app.sh
./scripts/package_installer.sh
```

Build outputs:

- `dist/AI Meter.app`
- `dist/AI Meter-0.1.0.pkg`

The installer places AI Meter in `/Applications`. Remove it with:

```sh
./scripts/uninstall_app.sh
```

For a public release, provide Apple Developer signing identities:

```sh
APP_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example (TEAMID)" \
./scripts/package_installer.sh
```
