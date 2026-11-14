# AIQuotaBar

A macOS menu bar app (`NSStatusItem`) that shows 5-hour and weekly quota usage bars for `claude` (plus optional extra `CLAUDE_CONFIG_DIR` profiles), `codex`, and `agy` (per model group).

## How It Works

- Refreshes on click with zero background polling.
- Streams fast providers (`claude`, `codex`) into the menu immediately without waiting for slower ones (`agy`).
- Reuses your existing local CLI logins:
  - **Claude:** Reads the OAuth token via `/usr/bin/security` and queries `api.anthropic.com/api/oauth/usage`.
  - **Codex:** Queries `codex app-server` (`account/rateLimits/read`) over JSON-RPC.
  - **Antigravity (`agy`):** Runs `/usage` in a pseudo-terminal and parses each model group.
- Turns the menu bar icon red if any provider fails, while keeping last-known cached values (`~/.cache/ai-quota-bar/state.json`) visible.

## Build & Run

```bash
./scripts/build-app.sh
open build/AIQuotaBar.app
```

To package a local `.dmg`:

```bash
VERSION=0.1.0 ./scripts/build-app.sh --dmg
```

## Releases

Pushing a `v*` tag triggers [release.yml](.github/workflows/release.yml) to run tests, build a universal binary, and attach `AIQuotaBar-<version>.dmg` to a GitHub Release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

> Note: Builds without a `Developer ID Application` certificate are ad-hoc signed; after dragging to `/Applications` on another Mac, run `xattr -cr /Applications/AIQuotaBar.app` if Gatekeeper blocks first launch.

## Optional: Multiple Claude Profiles

By default, `AIQuotaBar` checks `~/.claude`. To add extra `CLAUDE_CONFIG_DIR` profiles (such as `ccp`), create `~/.config/ai-quota-bar/config.json`:

```json
{
  "extraClaudeProfiles": [
    { "label": "ccp", "configDir": "~/.claude-personal" }
  ]
}
```

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```
