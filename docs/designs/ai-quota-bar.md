# AI Quota Menu Bar App (`agy`, `claude`, `codex`)

*   **Author:** Samuel Nittala
*   **Status:** Proposed
*   **Date:** 2026-11-14

--------------------------------------------------------------------------------

## Overview

A lightweight macOS menu bar application built in Swift (`NSStatusItem`) and developed under `~/personal` that gives the user a single-click view of their remaining 5-hour and weekly usage quotas across `claude` (including any configured additional `CLAUDE_CONFIG_DIR` profiles such as `ccp`), `codex`, and `agy` (with each `agy` model group displayed separately). It reuses the machine's existing CLI logins, performs zero background polling, refreshes immediately when clicked, and displays a red menu bar indicator whenever any active provider or profile fails to fetch.

## The Problem

Checking remaining rate-limit quotas across `claude`, `codex`, and `agy` currently requires opening each coding agent interactively and typing `/usage` or `/status`. This is slow, interrupts active work, and forces the user to remember three separate workflows just to see whether a 5-hour or weekly cap is close to exhaustion.

At the same time, none of the three installed CLIs (`/Users/samuelnittala/.local/bin/agy`, `claude`, `codex`) expose a non-interactive CLI subcommand for quota inspection, and existing third-party menu bar tools either poll in the background, omit `agy`, or require a second click inside a dropdown to trigger a manual refresh.

## Goals

*   **Single-click visibility:** Clicking the menu bar icon immediately fetches current 5-hour and weekly percentage-used quotas for `claude` (and any configured extra `CLAUDE_CONFIG_DIR` profiles such as `ccp`), `codex`, and each `agy` model group separately.
*   **Zero background polling:** The app only queries providers when the user clicks the menu bar item (or launches the app), avoiding idle network traffic and unnecessary rate-limit pressure.
*   **Reuse existing logins:** Authenticate using the credentials already stored by the local `claude`, `codex`, and `agy` CLIs without requiring separate API keys or manual token copying.
*   **Preserve CLI sessions:** Never rotate or refresh OAuth refresh tokens inside the menu bar app, preventing accidental logouts of the underlying CLIs.
*   **Explicit failure visibility:** Flip the menu bar indicator to a red error state whenever any provider fails to fetch, while showing per-provider error details and the last-known cached values (marked stale) in the dropdown.

## Non-Goals

*   **Cost or token spend analytics:** No dollar spend tracking, per-project breakdowns, or historical usage charts.
*   **Background daemon or notifications:** No periodic background timers, `launchd` polling agents, or system notifications.
*   **In-app login or token refresh:** If a CLI session expires, the app reports the error and instructs the user to re-authenticate in that CLI rather than running an OAuth flow.
*   **Cross-platform support:** macOS only.

## Open Questions

*   **`agy` quota window structure:** Does `cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` expose both 5-hour and weekly windows per model group, or only a single quota window with a reset timestamp?
*   **Project directory name:** Confirm the exact folder name under `~/personal` (tentatively `~/personal/ai-quota-bar`).

## Critical User Journeys (CUJs)

### CUJ 1: Check Current Quotas on Click

*   **Given**: The app is running in the macOS menu bar and the user is logged into `claude` (plus any configured extra profiles like `ccp`), `codex`, and `agy` locally.
*   **When**: The user clicks the menu bar item.
*   **Then**: The app triggers parallel fetches across all active providers/profiles, updates the dropdown within the per-provider timeout budget, displays 5-hour and weekly percentage-used values (plus reset times) for each configured Claude profile, `codex`, and each `agy` model group separately, and shows a normal (non-red) status indicator.

### CUJ 2: Provider Fetch Fails, Offline, or Token Expired

*   **Given**: The app is running in the macOS menu bar, and one provider's token is expired, its endpoint returns an error/timeout, or the machine is offline.
*   **When**: The user clicks the menu bar item.
*   **Then**: The menu bar indicator turns red, healthy providers still show their fresh percentages, and the failing provider displays a clear actionable error (for example, `login expired — run claude`) alongside its last-known cached values labeled `stale`.

## Technical Plan (Architecture)

The app is a single-target Swift macOS menu bar executable (`LSUIElement = true`, no Dock icon) built with `AppKit` (`NSStatusItem` + `NSMenu`) and Swift concurrency (`async/await` + `withThrowingTaskGroup`). Using `NSMenu` with `NSMenuDelegate` (`menuWillOpen(_:)`) or a click handler on `NSStatusBarButton` triggers a refresh immediately when the user clicks the menu bar icon, updates the menu items in place as results arrive, and avoids background timers.

```text
  [User clicks NSStatusItem]
             |
             v
    [QuotaCoordinator]  <--- reads ---> ~/.config/ai-quota-bar/config.json (optional extra profiles)
     (TaskGroup, 8s cap) <-- reads/writes --> ~/.cache/ai-quota-bar/state.json
      /       |        \
     v        v         v
[Claude*]  [Codex]    [Agy]
Fetcher(s) Fetcher    Fetcher
  |           |          |
  |           |          +--> HTTP: cloudcode-pa.googleapis.com (~/.gemini/oauth_creds.json)
  |           |               Fallback: PTY /usage scrape (timeout + SIGKILL)
  |           |
  |           +--> Subprocess: codex app-server (JSON-RPC account/rateLimits/read)
  |                Fallback: newest ~/.codex/sessions/**/rollout-*.jsonl
  |
  +--> 1..N instances: default (~/.claude) + configured CLAUDE_CONFIG_DIR profiles (e.g. ccp -> ~/.claude-personal)
       HTTP: api.anthropic.com/api/oauth/usage (profile-scoped Keychain item)
       Fallback: profile-keyed statusline rate_limits cache
```

### Core Components & Data Model

*   **`QuotaSnapshot` (normalized output contract):** Each fetcher returns one `ProviderResult` containing `providerName`, `entries: [QuotaEntry]` (one entry per active Claude profile, one for `codex`, and one per model group for `agy`), `fetchedAt: Date`, `isStale: Bool`, and `error: ProviderError?`. Each `QuotaEntry` holds `label`, `fiveHourUsedPct: Double?`, `weeklyUsedPct: Double?`, `fiveHourResetAt: Date?`, and `weeklyResetAt: Date?`.
*   **`ProfileDiscovery` / `AppConfig`:** Resolves `~` dynamically via `FileManager.default.homeDirectoryForCurrentUser` (never hardcoding `/Users/<name>`). Always includes the default `claude` profile (`~/.claude`). Optional extra `CLAUDE_CONFIG_DIR` profiles (such as `ccp` pointing to `~/.claude-personal`) are loaded from `~/.config/ai-quota-bar/config.json` (or auto-discovered from `~/.claude-*` directories that contain a `.claude.json` if no config overrides them). Unconfigured or absent secondary directories are never treated as failures for other users.
*   **`QuotaCoordinator`:** Enforces a short cooldown (15 seconds) against rapid accidental clicks, runs all active fetchers concurrently in a `TaskGroup`, merges fresh results with `~/.cache/ai-quota-bar/state.json`, and computes the menu bar status. If any active fetcher returns an error or falls back to stale cache, the status bar indicator switches to red (`NSColor.systemRed` dot/badge).
*   **`ClaudeFetcher(profileLabel, configDir)`:** Instantiated once for `~/.claude` and once per configured extra profile (e.g., `ccp` for `~/.claude-personal`). Reads that profile's OAuth access token from macOS Keychain (`Claude Code-credentials` for `~/.claude`, and the `CLAUDE_CONFIG_DIR`-scoped Keychain service item for secondary directories) and sends `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20` (2.5s connect timeout, 6s total timeout). If Keychain/HTTP fails, falls back to reading a profile-keyed `rate_limits` cache file written by `statusline-command.sh` (marked `stale`). Never calls the OAuth token-refresh endpoint.
*   **`CodexFetcher`:** Resolves `codex` dynamically via explicit `PATH` (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:...`), spawns `codex app-server`, sends JSON-RPC `initialize` + `account/rateLimits/read` over stdin/stdout, parses `primary` (5-hour) and `secondary` (weekly) percentages, and terminates the process group (`SIGTERM` then `SIGKILL` after 500ms) within a 6s budget. Falls back to the latest `rate_limits` record in `~/.codex/sessions` (marked `stale`).
*   **`AgyFetcher`:** Reads the Google OAuth access token from `~/.gemini/oauth_creds.json` and calls `cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`, grouping model remaining fractions by model family and converting to percentage used (`100 - remainingPct`). Falls back to a hard-timed PTY `/usage` scrape (8s cap with process-group kill) only if the HTTP path fails or lacks required windows. Never refreshes tokens in-app.
*   **`StatusMenuController`:** Owns the `NSStatusItem` and `NSMenu`. Clicking the status bar item immediately shows cached/loading state and starts `QuotaCoordinator.refresh()`. Updates the menu bar title/icon (red on any error) and renders separate sections for each active Claude profile (e.g., `Claude`, `ccp`), `Codex`, and each `Agy` model group with reset countdowns, `fetchedAt` timestamps, and actionable error messages (e.g., `Login expired — run claude`).

### Signing & Environment Constraints

*   **Stable code signing:** Because `ClaudeFetcher` reads a macOS Keychain item created by Claude Code, the `.app` bundle must be signed with a stable local signing identity (e.g., a self-signed macOS Code Signing certificate in Login Keychain or Apple Development cert) so rebuilds do not re-trigger Keychain permission dialogs.
*   **No hardcoded user paths:** All home-relative paths (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.cache`, `~/.config`) are resolved dynamically via `FileManager.default.homeDirectoryForCurrentUser`.
*   **No background polling:** No `Timer` or `NSBackgroundActivityScheduler` is registered; refreshes occur only on app launch and user click.

## Alternatives Considered

### Alternative A: SwiftBar / xbar Plugin

*   **Pros:** Zero Swift/Xcode build setup; a single Python script handles parallel fetching and menu rendering.
*   **Cons:** Neither SwiftBar nor xbar executes a plugin script when the user clicks the menu bar icon—they always show cached output and require a second click on a `Refresh` item inside the dropdown.
*   **Reason for Rejection:** Rejected by author: 2-click manual refresh breaks the single-click check workflow, so a custom Swift `NSStatusItem` app was chosen instead.

### Alternative B: Adopt Existing Tools (`ClaudeBar` or `usage-bar`)

*   **Pros:** Off-the-shelf UI and pre-solved `claude` / `codex` endpoint parsing.
*   **Cons:** `usage-bar` is a SwiftBar script that omits `agy`, while `ClaudeBar` is a broader SwiftUI app with background polling rather than a minimal on-click tool in `~/personal`.
*   **Reason for Rejection:** Rejected as a standalone solution because neither covers all four requirements (`claude`, extra `CLAUDE_CONFIG_DIR` profiles, `codex`, and per-group `agy` on click only).

### Alternative C: PTY Scraping `/usage` for All Three CLIs

*   **Pros:** Uses the user-facing TUI output directly without relying on internal HTTP endpoints or `codex app-server`.
*   **Cons:** Full TUI startup takes 2–10+ seconds per CLI, breaks on terminal layout changes, and risks leaving orphaned child processes or triggering trust/login prompts.
*   **Reason for Rejection:** Rejected as primary data path due to latency and fragility; retained only as a hard-timed last-resort fallback for `agy` if its HTTP endpoint cannot supply the needed windows.

### Alternative D: Hardcoding Secondary Claude Profiles (`ccp`)

*   **Pros:** Simpler startup with no config file or directory discovery logic.
*   **Cons:** Any user without `~/.claude-personal` would hit a permanent missing-credential failure and red menu bar indicator.
*   **Reason for Rejection:** Rejected by author: secondary `CLAUDE_CONFIG_DIR` profiles must be configurable or auto-discovered and skipped when absent.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Security & Privacy:** OAuth tokens read from macOS Keychain or `~/.gemini/oauth_creds.json` are kept strictly in memory for the duration of the HTTP request and never written to `~/.cache/ai-quota-bar/state.json` or logs. The app never calls OAuth token-refresh endpoints, avoiding refresh-token rotation conflicts with the CLIs.
*   **Performance & Latency:** All active fetchers execute concurrently in a `TaskGroup` with a 2.5s connect timeout and 6–8s total timeout, bounding worst-case click-to-render latency. A 15-second cooldown prevents accidental rapid-click loops from hitting provider HTTP 429 rate limits.
*   **Signing & Operability:** The app bundle must be signed with a stable local code-signing identity so macOS Keychain ACLs do not re-prompt after every rebuild.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

All project files live under `~/personal/ai-quota-bar/` as a Swift Package Manager macOS executable package plus a bundle/sign script.

#### 1. `~/personal/ai-quota-bar/Package.swift` (Create)

*   **Type / Scope:** Swift Package Manager manifest (`swift-tools-version: 5.10`, macOS 13+ platform target).
*   **Proposed Changes:** Defines the `AIQuotaBar` executable target (`Sources/AIQuotaBar`) and `AIQuotaBarTests` unit test target (`Tests/AIQuotaBarTests`), with zero external third-party dependencies (Foundation + AppKit + Security frameworks only).

#### 2. `~/personal/ai-quota-bar/Resources/Info.plist` (Create)

*   **Type / Scope:** macOS app bundle metadata.
*   **Proposed Changes:** Sets `CFBundleIdentifier` (`com.samuelnittala.ai-quota-bar`), `LSUIElement = true` (menu bar agent with no Dock icon), and `LSMinimumSystemVersion` (`13.0`).

#### 3. `~/personal/ai-quota-bar/scripts/build-app.sh` (Create)

*   **Type / Scope:** Local build, bundle, and signing script.
*   **Proposed Changes:** Runs `swift build -c release`, assembles `build/AIQuotaBar.app/Contents/{MacOS,Resources}`, copies `Info.plist`, and signs the `.app` bundle with a stable local `CODESIGN_IDENTITY` (defaulting to a local Code Signing certificate in Login Keychain) so macOS Keychain ACLs persist across rebuilds.

#### 4. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Models/QuotaModels.swift` (Create)

*   **Type / Scope:** Core data structures and error types.
*   **Proposed Changes:** Defines `QuotaEntry` (`label`, `fiveHourUsedPct: Double?`, `weeklyUsedPct: Double?`, `fiveHourResetAt: Date?`, `weeklyResetAt: Date?`), `ProviderResult` (`providerId`, `displayName`, `entries: [QuotaEntry]`, `fetchedAt: Date`, `isStale: Bool`, `error: ProviderError?`), `ProviderError` (`.missingCredentials`, `.tokenExpired`, `.networkError`, `.timeout`, `.parseError`), and `QuotaProvider` protocol (`fetch() async -> ProviderResult`).

#### 5. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Config/ProfileDiscovery.swift` (Create)

*   **Type / Scope:** Home-relative path resolution and Claude profile discovery.
*   **Proposed Changes:** Resolves `~` dynamically via `FileManager.default.homeDirectoryForCurrentUser`. Always registers the default `claude` profile (`~/.claude`). Reads optional `~/.config/ai-quota-bar/config.json` (`extraClaudeProfiles: [{ label, configDir }]`), or auto-discovers `~/.claude-*` directories containing `.claude.json`. Skips absent secondary directories cleanly so single-account users never see false errors.

#### 6. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Cache/StateCache.swift` (Create)

*   **Type / Scope:** Last-known quota persistence.
*   **Proposed Changes:** Reads and writes `~/.cache/ai-quota-bar/state.json` atomically (`Codable`), storing the latest successful `ProviderResult` per `providerId` (without storing any tokens or secrets). Supplies stale fallback entries when a live probe fails or the machine is offline.

#### 7. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Fetchers/ClaudeFetcher.swift` (Create)

*   **Type / Scope:** Claude OAuth usage fetcher (instantiated per discovered Claude profile).
*   **Proposed Changes:** Looks up the profile's OAuth token from macOS Keychain (`Security` framework `SecItemCopyMatching` for `Claude Code-credentials` on `~/.claude`, or the `CLAUDE_CONFIG_DIR`-hashed Keychain service name for secondary profiles), calls `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` (2.5s connect timeout, 6s total timeout), and parses 5-hour and 7-day utilization percentages + reset timestamps. Falls back to profile-keyed statusline cache if available; never calls OAuth token-refresh endpoints.

#### 8. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Fetchers/CodexFetcher.swift` (Create)

*   **Type / Scope:** Codex `app-server` JSON-RPC fetcher + session-log fallback.
*   **Proposed Changes:** Locates `codex` using an explicit `PATH` (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`), spawns `codex app-server` in its own process group (`setpgid`), writes JSON-RPC `initialize` and `account/rateLimits/read` to stdin, parses `primary` (5-hour) and `secondary` (weekly) `usedPercent` + `resetsAt`, and terminates the process group (`SIGTERM`, then `SIGKILL` after 500ms) under a 6s timeout. Falls back to the latest `rate_limits` entry in `~/.codex/sessions/**/rollout-*.jsonl` (marked `stale`).

#### 9. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Fetchers/AgyFetcher.swift` (Create)

*   **Type / Scope:** Antigravity Cloud Code API fetcher + PTY fallback.
*   **Proposed Changes:** Reads the Google OAuth access token from `~/.gemini/oauth_creds.json`, sends `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` (2.5s connect timeout, 6s total timeout), groups models by model family, and converts remaining fractions to percentage used (`100 - remaining * 100`) per group. If the HTTP endpoint fails or does not expose required windows, falls back to a hard-timed (8s) PTY `/usage` scrape with guaranteed process-group cleanup. Never refreshes OAuth tokens in-app.

#### 10. `~/personal/ai-quota-bar/Sources/AIQuotaBar/Coordinator/QuotaCoordinator.swift` (Create)

*   **Type / Scope:** Parallel refresh orchestration, cooldown, and error aggregation.
*   **Proposed Changes:** Enforces a 15-second cooldown between live refreshes (returning cached results with cooldown timestamp if clicked repeatedly), runs all active fetchers concurrently via `withTaskGroup`, merges failures with `StateCache` stale values, and exposes `hasAnyFailure: Bool` to drive the red menu bar indicator.

#### 11. `~/personal/ai-quota-bar/Sources/AIQuotaBar/UI/StatusMenuController.swift` & `main.swift` (Create)

*   **Type / Scope:** `NSApplication` entry point (`LSUIElement`), `NSStatusItem`, and `NSMenu` rendering.
*   **Proposed Changes:** Initializes `NSStatusItem` with a compact title/icon (switching to `NSColor.systemRed` indicator whenever `hasAnyFailure` is true). Registers `NSMenuDelegate.menuWillOpen(_:)` so clicking the menu bar item immediately triggers `QuotaCoordinator.refresh()` and updates menu rows in place: separate sections for each Claude profile, `Codex`, and each `Agy` model group (5h %, weekly %, reset countdown, `fetchedAt` timestamp, and actionable error text when failed), plus `Quit`.

#### 12. `~/personal/ai-quota-bar/Tests/AIQuotaBarTests/QuotaTests.swift` (Create)

*   **Type / Scope:** Unit test suite.
*   **Proposed Changes:** Tests JSON parsing for `claude`, `codex`, and `agy` payloads (including per-model-group grouping), `ProfileDiscovery` skipping absent secondary directories, `QuotaCoordinator` 15s cooldown and `hasAnyFailure` red-state aggregation, and `StateCache` round-trip/stale fallback behavior.

#### 13. `~/personal/ai-quota-bar/README.md` (Create)

*   **Type / Scope:** Project setup and usage documentation.
*   **Proposed Changes:** Documents the endpoint spike check, local code-signing setup (`build-app.sh`), optional `~/.config/ai-quota-bar/config.json` schema for extra `CLAUDE_CONFIG_DIR` profiles, and troubleshooting for expired CLI logins.

### Verification Plan

*   **Pre-implementation Spike (Gate before Stage 2):** Run three manual read-only probes in terminal (`curl` against Anthropic `oauth/usage`, `codex app-server` `account/rateLimits/read`, and `curl` against `cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`) to confirm exact JSON fields—especially whether `agy` exposes both 5-hour and weekly windows per model group.
*   **Compilation/Build:** `swift build -c release` and `./scripts/build-app.sh` succeed with zero errors/warnings.
*   **Unit Tests:** `swift test` passes all tests in `AIQuotaBarTests` covering response parsing, profile discovery, cooldown, stale cache fallback, and red-state aggregation.
*   **Manual Integration Checks:**
    1. Click menu bar item -> verify parallel refresh completes within 6–8s, showing `claude`, configured extra profiles (e.g., `ccp`), `codex`, and each `agy` model group separately.
    2. Rebuild via `./scripts/build-app.sh` and relaunch -> verify Keychain does not re-prompt once trusted.
    3. Simulate offline / expired token / slow probe -> verify menu bar indicator turns red, healthy providers stay green/fresh, failing provider shows stale values + error message, and no orphaned `codex` or `agy` child processes remain (`ps`).

--------------------------------------------------------------------------------

*Drafted with EGM*
