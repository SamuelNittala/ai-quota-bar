# AI Quota Menu Bar App (`agy`, `claude`, `codex`)

*   **Author:** Samuel Nittala
*   **Status:** Approved
*   **Date:** 2026-11-14

--------------------------------------------------------------------------------

## Overview

A macOS menu bar application built in Swift (`NSStatusItem`) that gives the user a single-click view of remaining 5-hour and weekly usage quotas across `claude` (including any configured `CLAUDE_CONFIG_DIR` profiles such as `ccp`), `codex`, and `agy` (Antigravity CLI, with each model group displayed separately). It reuses the machine's existing CLI logins, performs zero background polling, refreshes on click, and shows a red menu bar indicator whenever any active provider or profile fails to fetch.

## The Problem

Checking remaining rate-limit quotas across `claude`, `codex`, and `agy` currently requires opening each coding agent interactively and typing `/usage` or `/status`, which interrupts active work and forces three separate workflows just to see whether a 5-hour or weekly cap is close to exhaustion.

None of the three installed CLIs (`agy`, `claude`, `codex`) expose a non-interactive subcommand for quota inspection, and existing third-party menu bar tools either poll in the background, omit `agy`, or require a second click inside a dropdown to trigger a manual refresh.

## Goals

*   **Single-click visibility:** Clicking the menu bar icon immediately fetches current 5-hour and weekly percentage-used quotas for `claude` (and any configured extra `CLAUDE_CONFIG_DIR` profiles such as `ccp`), `codex`, and each `agy` model group separately.
*   **Zero background polling:** The app only queries providers when the user clicks the menu bar item (or launches the app), avoiding idle network traffic and extra quota-endpoint requests.
*   **Reuse existing logins:** Authenticate using the credentials already stored by the local `claude`, `codex`, and `agy` CLIs without requiring separate API keys or manual token copying.
*   **Preserve CLI sessions:** Never rotate or refresh OAuth refresh tokens inside the menu bar app, preventing accidental logouts of the underlying CLIs.
*   **Explicit failure visibility:** Flip the menu bar indicator to a red error state whenever any provider fails to fetch, while showing per-provider remediation details and the last-known cached values (marked `stale`) in the dropdown.

## Non-Goals

*   **Cost or token spend analytics:** No dollar spend tracking, per-project breakdowns, or historical usage charts.
*   **Background daemon or notifications:** No periodic background timers, `launchd` polling agents, or system notifications.
*   **In-app login or token refresh:** If a CLI session expires, the app reports the error and instructs the user to re-authenticate in that CLI rather than running an OAuth flow.
*   **Cross-platform support:** macOS only.

## Critical User Journeys (CUJs)

### CUJ 1: Check Current Quotas on Click

*   **Given:** The app is running in the macOS menu bar and the user is logged into `claude` (plus any configured extra profiles like `ccp`), `codex`, and `agy` locally.
*   **When:** The user clicks the menu bar item.
*   **Then:** The app triggers parallel fetches across all active providers and profiles, updates the dropdown within 8 seconds, displays 5-hour and weekly percentage-used values (plus reset times) for each configured Claude profile, `codex`, and each `agy` model group separately, and shows a normal (non-red) status indicator.

### CUJ 2: Provider Fetch Fails, Offline, or Token Expired

*   **Given:** The app is running in the macOS menu bar, and one provider's token is expired, its endpoint returns an error or timeout, or the machine is offline.
*   **When:** The user clicks the menu bar item.
*   **Then:** The menu bar indicator turns red, succeeding providers retain their fresh percentages, and the failing provider displays an actionable remediation message (for example, `login expired — run claude`) alongside its last-known cached values labeled `stale`.

## Technical Plan (Architecture)

The app is a single-target Swift macOS menu bar executable (`LSUIElement = true`, no Dock icon) built with `AppKit` (`NSStatusItem` and `NSMenu`) and Swift concurrency (`async/await` and `withTaskGroup`). `NSMenuDelegate.menuWillOpen(_:)` triggers a refresh immediately when the user clicks the menu bar icon, dispatches `NSMenuItem` updates on `RunLoop.main.perform(inModes: [.common])` so AppKit's `NSEventTrackingRunLoopMode` does not stall UI updates, and uses single-flight coalescing rather than background timers or cooldowns.

```text
  [User clicks NSStatusItem]
             |
             v
    [QuotaCoordinator]  <--- reads ---> ~/.config/ai-quota-bar/config.json (optional extra profiles)
     (Single-flight     <-- reads/writes --> ~/.cache/ai-quota-bar/state.json (atomic)
      TaskGroup, 8s cap)
      /       |        \
     v        v         v
[Claude*]  [Codex]    [Agy]
Fetcher(s) Fetcher    Fetcher
  |           |          |
  |           |          +--> PTY /usage scrape (8s timeout + SIGTERM/SIGKILL)
  |           |
  |           +--> Subprocess: codex app-server (JSON-RPC account/rateLimits/read)
  |
  +--> 1..N instances: default (~/.claude) + configured CLAUDE_CONFIG_DIR profiles
       HTTP: GET https://api.anthropic.com/api/oauth/usage (Keychain, kSecUseAuthenticationUIFail)
```

### Core Components & Data Model

*   **`ProviderResult` (normalized output contract):** Each fetcher returns one `ProviderResult` containing `providerId`, `displayName`, `entries: [QuotaEntry]` (one entry per active Claude profile, one for `codex`, and one per model group for `agy`), `fetchedAt: Date`, `isStale: Bool`, and `error: ProviderError?`. Each `QuotaEntry` holds `label`, `fiveHourUsedPct: Double?`, `weeklyUsedPct: Double?`, `fiveHourResetAt: Date?`, and `weeklyResetAt: Date?`.
*   **`ProfileDiscovery`:** Resolves `~` dynamically via `FileManager.default.homeDirectoryForCurrentUser`. Always includes the default `claude` profile (`~/.claude`). Optional extra `CLAUDE_CONFIG_DIR` profiles (such as `ccp` pointing to `~/.claude-personal`) are loaded only if `~/.config/ai-quota-bar/config.json` exists and is valid; absent secondary directories are skipped without error.
*   **`QuotaCoordinator`:** Uses single-flight coalescing (`inFlightTask`) so concurrent clicks await an already-running refresh instead of spawning duplicate `TaskGroup`s or blocking immediate retries after CLI re-login. Merges fresh results with `~/.cache/ai-quota-bar/state.json` (written atomically) and sets `hasAnyFailure` to `true` whenever any active provider returns `error != nil` (even when `StateCache` supplies stale values).
*   **`ClaudeFetcher(profileLabel, configDir)`:** Instantiated once for `~/.claude` and once per configured extra profile. Reads the profile's OAuth access token from macOS Keychain using `kSecUseAuthenticationUIFail` (service `Claude Code-credentials` for `~/.claude`, and `Claude Code-credentials-<first 8 lowercase hex chars of SHA-256(expanded configDir)>` for secondary directories; JSON path `claudeAiOauth.accessToken`), and sends `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20` (`timeoutIntervalForRequest = 6.0`, `timeoutIntervalForResource = 6.0`). Parses `five_hour: { utilization, resets_at }` and `seven_day: { utilization, resets_at }` (ISO-8601). On `errSecInteractionNotAllowed`, surfaces an `Authorize Keychain access…` menu action so Keychain prompts never block `NSMenu` tracking.
*   **`CodexFetcher`:** Resolves `codex` via explicit `PATH` (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`), spawns `codex app-server` in an isolated process group (`setpgid`), exchanges newline-delimited JSON-RPC (`initialize` -> `notifications/initialized` -> `account/rateLimits/read`), maps `result.rateLimits.primary` / `secondary` by `windowDurationMins` (`300` for 5-hour, `10080` for weekly) using `usedPercent` and `resetsAt` (Unix epoch seconds), and terminates the process group (`SIGTERM`, then `SIGKILL` after 500ms) within a 6s budget.
*   **`AgyFetcher`:** Because `agy` keeps quota in memory only and external calls to `daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` return `HTTP 403 PERMISSION_DENIED`, `AgyFetcher` resolves `agy` via the explicit `PATH`, spawns `agy` in a pseudo-terminal (`posix_openpt` / `forkpty`) with `TIOCSWINSZ` set to `80x120` (so all model groups render without pagination), sends `/usage`, strips ANSI escape sequences, parses each group (`GEMINI MODELS`, `CLAUDE AND GPT MODELS`, `GEMINI 4 ARGON` where 5-hour is optional), converts `Remaining` percentages to used (`100.0 - remainingPct`), and terminates the process group (`SIGTERM`, then `SIGKILL` after 500ms) under an 8s timeout. Parse failures return an explicit error (never `0%`) and fall back to `StateCache`.
*   **`StatusMenuController`:** Owns the `NSStatusItem` and `NSMenu`. Clicking the status bar item opens the menu with cached values immediately, starts `QuotaCoordinator.refresh()`, and applies updates via `RunLoop.main.perform(inModes: [.common])`. Switches the status bar indicator to `NSColor.systemRed` when `hasAnyFailure` is `true`, and renders separate sections for each Claude profile, `Codex`, and each `Agy` model group with reset countdowns, `fetchedAt` timestamps, and remediation text.

## Risks & Mitigations

*   **Undocumented Anthropic `oauth/usage` endpoint changes:** `api.anthropic.com/api/oauth/usage` is not a public stable API and can change schema or return `401`/`403`. *Mitigation:* Isolate parsing inside `ClaudeFetcher`, preserve the last valid snapshot in `StateCache`, and flip the menu bar indicator red with `.parseError` / `.httpError` details without affecting `CodexFetcher` or `AgyFetcher`.
*   **macOS Keychain ACL prompts on `Claude Code-credentials`:** Keychain items created by `claude` trust the `claude` binary, not `AIQuotaBar`; signing `AIQuotaBar` with a stable local identity preserves trust across app rebuilds, but first run or `claude` re-login can still require authorization. *Mitigation:* Always query Keychain with `kSecUseAuthenticationUIFail` during `menuWillOpen(_:)`, and expose an `Authorize Keychain access…` menu item that triggers interactive Keychain authorization outside menu tracking.
*   **`agy` PTY `/usage` latency, layout drift, or stray history:** Running `agy` in a PTY adds startup latency, can break if `/usage` formatting changes, and could write empty entries to `~/.gemini/antigravity-cli/conversations/`. *Mitigation:* Bound the PTY probe to 8s with `SIGTERM`/`SIGKILL` process-group teardown, cover `/usage` parsing with a captured screen fixture in unit tests, and validate in Phase 3 whether `/usage` creates stray history (excluding `agy` from v1 via config if it degrades UX).
*   **Concurrent clicks and cache corruption:** Rapid clicks while an 8s `TaskGroup` is running could race on `state.json`. *Mitigation:* Single-flight coalescing in `QuotaCoordinator` plus `Data.write(to:options: .atomic)` in `StateCache`.

## Alternatives Considered

### Alternative A: SwiftBar / xbar Plugin

*   **Pros:** Zero Swift/Xcode build setup; a single Python script handles parallel fetching and menu rendering.
*   **Cons:** Neither SwiftBar nor xbar executes a plugin script when the user clicks the menu bar icon—they always show cached output and require a second click on a `Refresh` item inside the dropdown.
*   **Reason for Rejection:** Rejected because 2-click manual refresh breaks the single-click check workflow, so a custom Swift `NSStatusItem` app was chosen instead.

### Alternative B: Adopt Existing Tools (`ClaudeBar` or `usage-bar`)

*   **Pros:** Off-the-shelf UI and pre-solved `claude` / `codex` endpoint parsing.
*   **Cons:** `usage-bar` is a SwiftBar script that omits `agy`, while `ClaudeBar` is a SwiftUI app with background polling rather than an on-click `NSStatusItem` utility.
*   **Reason for Rejection:** Rejected as a standalone solution because neither covers all requirements (`claude`, extra `CLAUDE_CONFIG_DIR` profiles, `codex`, and per-group `agy` on click only).

### Alternative C: Direct Cloud Code HTTP Call for `agy`

*   **Pros:** Fast HTTP JSON call without PTY startup overhead.
*   **Cons:** Live verification against `daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` using `agy`'s Keychain token (`svce="gemini"`) returned `HTTP 403 PERMISSION_DENIED` for external callers.
*   **Reason for Rejection:** Rejected because external callers are not permitted to call that internal endpoint without spoofing client identity, leaving PTY `/usage` as the only permitted data source for `agy`.

### Alternative D: Hardcoding Secondary Claude Profiles (`ccp`)

*   **Pros:** Simpler startup with no config file logic.
*   **Cons:** Any user without `~/.claude-personal` would hit a permanent missing-credential failure and red menu bar indicator.
*   **Reason for Rejection:** Rejected because secondary `CLAUDE_CONFIG_DIR` profiles must be optional via `config.json` and skipped when absent.

## Non-Functional Requirements

*   **Security & Privacy:** OAuth tokens read from macOS Keychain are kept in memory for the duration of the HTTP request and never written to `~/.cache/ai-quota-bar/state.json` or logs. The app never calls OAuth token-refresh endpoints, avoiding refresh-token rotation conflicts with the CLIs.
*   **Performance & Latency:** All active fetchers execute concurrently in a `TaskGroup` with `timeoutIntervalForRequest = 6.0` / `timeoutIntervalForResource = 6.0` for HTTP and 6–8s timeouts for subprocess/PTY probes, bounding network and subprocess fetch wait time to 8 seconds.
*   **Signing & Operability:** The `.app` bundle must be signed with a stable local code-signing identity so macOS Keychain ACLs do not re-prompt after every rebuild.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

All project files live under `~/personal/ai-quota-bar/`, organized into three incremental phases so the package builds and passes tests after each phase.

### Phase 1: Package Scaffold, Models, Config, and StateCache

*Checkpoint: `swift build` and `swift test` pass for model serialization, `ProfileDiscovery`, and `StateCache`.*

#### 1. `Package.swift` (Create)

*   **Type / Scope:** Swift Package Manager manifest (`swift-tools-version: 5.10`, macOS 13+ platform target).
*   **Proposed Changes:** Defines the `AIQuotaBar` executable target (`Sources/AIQuotaBar`) and `AIQuotaBarTests` unit test target (`Tests/AIQuotaBarTests`), with zero third-party dependencies (Foundation, AppKit, and Security frameworks only).

#### 2. `Sources/AIQuotaBar/Models/QuotaModels.swift` (Create)

*   **Type / Scope:** Core data structures, DI protocols, and error types.
*   **Proposed Changes:**
    *   `QuotaEntry: Codable, Sendable, Equatable` (`label: String`, `fiveHourUsedPct: Double?`, `weeklyUsedPct: Double?`, `fiveHourResetAt: Date?`, `weeklyResetAt: Date?`).
    *   `ProviderError: Error, Codable, Sendable, Equatable` (`.missingCredentials(String)`, `.keychainInteractionRequired(service: String)`, `.tokenExpired(String)`, `.httpError(statusCode: Int, body: String)`, `.networkError(String)`, `.timeout`, `.parseError(String)`).
    *   `ProviderResult: Codable, Sendable, Equatable` (`providerId: String`, `displayName: String`, `entries: [QuotaEntry]`, `fetchedAt: Date`, `isStale: Bool`, `error: ProviderError?`).
    *   `QuotaProvider: Sendable` protocol (`var providerId: String { get }`, `var displayName: String { get }`, `func fetch() async -> ProviderResult`).
    *   DI protocols `HTTPClient`, `KeychainReader`, and `ProcessRunner` for unit testing.

#### 3. `Sources/AIQuotaBar/Config/ProfileDiscovery.swift` (Create)

*   **Type / Scope:** Home-relative path resolution and Claude profile discovery.
*   **Proposed Changes:** Resolves `~` dynamically via `FileManager.default.homeDirectoryForCurrentUser`. Always registers `{ label: "Claude", configDir: "~/.claude", keychainService: "Claude Code-credentials" }`. If `~/.config/ai-quota-bar/config.json` exists, decodes `{ extraClaudeProfiles: [{ label, configDir }] }` (expanding `~` in `configDir`, computing `Claude Code-credentials-<first 8 lowercase hex chars of SHA-256(expandedPath)>`, and logging/ignoring malformed JSON). Absent `config.json` or absent secondary directories are skipped without surfacing errors.

#### 4. `Sources/AIQuotaBar/Cache/StateCache.swift` (Create)

*   **Type / Scope:** Last-known quota persistence.
*   **Proposed Changes:** Creates `~/.cache/ai-quota-bar/` via `createDirectory(withIntermediateDirectories: true)` on write. Reads and atomically writes (`options: .atomic`) `~/.cache/ai-quota-bar/state.json` with schema `{ "results": { "<providerId>": ProviderResult } }`. On corrupt JSON, resets to empty cache. Provides `mergeWithFallback(live: ProviderResult) -> ProviderResult`: when `live.error != nil` and a cached `ProviderResult` exists, retains cached `entries` and `fetchedAt`, sets `isStale = true`, and attaches `live.error`.

### Phase 2: Provider Fetchers and QuotaCoordinator

*Checkpoint: `swift build` and `swift test` pass for all three fetchers (via DI mocks) and `QuotaCoordinator` single-flight behavior.*

#### 5. `Sources/AIQuotaBar/Fetchers/ClaudeFetcher.swift` (Create)

*   **Type / Scope:** Claude OAuth usage fetcher (instantiated per discovered Claude profile).
*   **Proposed Changes:** Queries macOS Keychain via `KeychainReader` (`SecItemCopyMatching` with `kSecUseAuthenticationUIFail`) for the profile's service name; maps `errSecInteractionNotAllowed` to `.keychainInteractionRequired(service:)`. Parses secret JSON `claudeAiOauth.accessToken` and sends `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20` (`timeoutIntervalForRequest = 6.0`, `timeoutIntervalForResource = 6.0`). Parses `five_hour.utilization` / `resets_at` and `seven_day.utilization` / `resets_at` (ISO-8601). Never calls OAuth token-refresh endpoints.

#### 6. `Sources/AIQuotaBar/Fetchers/CodexFetcher.swift` (Create)

*   **Type / Scope:** Codex `app-server` JSON-RPC fetcher.
*   **Proposed Changes:** Locates `codex` via explicit `PATH` (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`), spawns `codex app-server` and isolates its process group via `setpgid(pid, pid)` after `run()`, exchanges newline-delimited JSON-RPC (`initialize` -> `notifications/initialized` -> `account/rateLimits/read`), maps `result.rateLimits.primary` and `secondary` by `windowDurationMins` (`300` -> 5-hour, `10080` -> weekly) using `usedPercent` and `resetsAt` (Unix epoch seconds), and terminates the process group (`SIGTERM`, then `SIGKILL` after 500ms) under a 6s timeout.

#### 7. `Sources/AIQuotaBar/Fetchers/AgyFetcher.swift` (Create)

*   **Type / Scope:** Antigravity PTY `/usage` fetcher.
*   **Proposed Changes:** Locates `agy` via the explicit `PATH`, spawns `agy` in a pseudo-terminal (`posix_openpt` / `forkpty` in its own process group) with `TIOCSWINSZ` set to `80` rows by `120` columns, sends `/usage`, reads until quota output stabilizes or 8s timeout fires, strips ANSI escape codes, parses model-group headers (`GEMINI MODELS`, `CLAUDE AND GPT MODELS`, `GEMINI 4 ARGON`), converts `Remaining` percentages to used (`100.0 - remainingPct`, leaving `fiveHourUsedPct` `nil` when absent), and terminates the process group (`SIGTERM`, then `SIGKILL` after 500ms) on completion, timeout, or cancellation. Returns `.parseError` if output cannot be parsed (never `0%`).

#### 8. `Sources/AIQuotaBar/Coordinator/QuotaCoordinator.swift` (Create)

*   **Type / Scope:** Parallel refresh orchestration, single-flight coalescing, and failure aggregation.
*   **Proposed Changes:** Maintains `inFlightTask: Task<[ProviderResult], Never>?` so concurrent clicks await the active refresh instead of spawning duplicate `TaskGroup`s. Runs all active `QuotaProvider` instances concurrently via `withTaskGroup`, merges failures with `StateCache`, persists fresh results atomically, and computes `hasAnyFailure = results.contains { $0.error != nil }`.

### Phase 3: StatusMenuController UI, Bundle/Signing, and Tests

*Checkpoint: `swift test` passes all unit tests, `./scripts/build-app.sh` produces a signed `.app`, and manual integration checks pass.*

#### 9. `Resources/Info.plist` (Create)

*   **Type / Scope:** macOS app bundle metadata.
*   **Proposed Changes:** Sets `CFBundleIdentifier` (`com.samuelnittala.ai-quota-bar`), `CFBundleExecutable` (`AIQuotaBar`), `CFBundleName` (`AIQuotaBar`), `CFBundlePackageType` (`APPL`), `CFBundleShortVersionString` (`0.1.0`), `CFBundleVersion` (`1`), `LSUIElement = true`, and `LSMinimumSystemVersion` (`13.0`).

#### 10. `scripts/build-app.sh` (Create)

*   **Type / Scope:** Local build, bundle, and signing script.
*   **Proposed Changes:** Runs `swift build -c release`, assembles `build/AIQuotaBar.app/Contents/{MacOS,Resources}`, copies `.build/release/AIQuotaBar` to `Contents/MacOS/AIQuotaBar` and `Resources/Info.plist` to `Contents/Info.plist`, selects `CODESIGN_IDENTITY` (defaulting to the first valid identity from `security find-identity -v -p codesigning` or failing with setup instructions if none exists), and runs `codesign --force --sign "$CODESIGN_IDENTITY" build/AIQuotaBar.app`.

#### 11. `Sources/AIQuotaBar/UI/StatusMenuController.swift` (Create)

*   **Type / Scope:** `NSStatusItem` and `NSMenu` rendering (`@MainActor`).
*   **Proposed Changes:** Initializes `NSStatusItem` with a compact title/icon (switching to `NSColor.systemRed` dot/badge whenever `hasAnyFailure` is `true`). Implements `NSMenuDelegate.menuWillOpen(_:)` to start `QuotaCoordinator.refresh()` and dispatches `NSMenuItem` updates via `RunLoop.main.perform(inModes: [.common])`. Renders separate sections for each Claude profile, `Codex`, and each `Agy` model group (5h %, weekly %, reset countdown, `fetchedAt` timestamp, error remediation text, and an `Authorize Keychain access…` item when `.keychainInteractionRequired` occurs, which prompts interactively outside `menuWillOpen(_:)`), plus `Quit`.

#### 12. `Sources/AIQuotaBar/main.swift` (Create)

*   **Type / Scope:** `NSApplication` entry point.
*   **Proposed Changes:** Configures `NSApplication.shared` with `.accessory` activation policy, initializes `ProfileDiscovery`, `StateCache`, fetchers, `QuotaCoordinator`, and `StatusMenuController`, triggers an initial `refresh()` on launch, and calls `app.run()`.

#### 13. `Tests/AIQuotaBarTests/QuotaTests.swift` (Create)

*   **Type / Scope:** Unit test suite using DI mocks.
*   **Proposed Changes:** Covers:
    *   `ClaudeFetcher`: Keychain JSON parsing, HTTP 200 `five_hour`/`seven_day` parsing, HTTP 401 -> `.tokenExpired`, `errSecInteractionNotAllowed` -> `.keychainInteractionRequired`, malformed JSON -> `.parseError`.
    *   `CodexFetcher`: JSON-RPC `initialize` + `account/rateLimits/read` parsing (`300` vs `10080` mins, nullable `secondary`), timeout -> `.timeout`.
    *   `AgyFetcher`: ANSI stripping and per-model-group parsing against a captured `/usage` screen fixture; malformed screen -> `.parseError` (never `0%`).
    *   `ProfileDiscovery`: missing `config.json` -> default `Claude` only; valid `config.json` -> tilde expansion + 8-char SHA-256 Keychain suffix; malformed `config.json` -> graceful fallback.
    *   `StateCache` and `QuotaCoordinator`: atomic round-trip, corrupt file recovery, stale merge preserving `fetchedAt` + `error`, single-flight coalescing across concurrent `refresh()` calls, and `hasAnyFailure` aggregation.

#### 14. `README.md` (Create)

*   **Type / Scope:** Project setup and usage documentation.
*   **Proposed Changes:** Documents local code-signing setup (`security find-identity -v -p codesigning` and `./scripts/build-app.sh`), example `~/.config/ai-quota-bar/config.json` for extra `CLAUDE_CONFIG_DIR` profiles, Keychain authorization flow, and troubleshooting for expired CLI logins.

### Verification Plan

*   **Compilation and Build:** `swift build -c release` and `./scripts/build-app.sh` succeed with zero errors or warnings.
*   **Unit Tests:** `swift test` passes all tests in `AIQuotaBarTests`.
*   **Manual Integration Checks:**
    1. Click menu bar item -> parallel refresh completes within 8s, showing `Claude`, configured extra profiles (e.g., `ccp`), `Codex`, and each `Agy` model group separately.
    2. Rebuild via `./scripts/build-app.sh` and relaunch -> verify Keychain does not re-prompt once authorized.
    3. Simulate offline / expired token / slow probe -> verify menu bar indicator turns red, succeeding providers retain fresh values, failing provider shows stale values and remediation text, and no orphaned `codex` or `agy` child processes remain (`ps`).
    4. Verify `agy` PTY `/usage` check leaves no stray conversation entries in `~/.gemini/antigravity-cli/conversations/` (if it does, exclude `agy` from v1).

--------------------------------------------------------------------------------

*Drafted with EGM*
