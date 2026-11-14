import Foundation
import XCTest
@testable import AIQuotaBar

private struct MockHTTPClient: HTTPClient {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private struct MockKeychainReader: KeychainReader {
    let result: Result<Data, Error>

    func readGenericPassword(service: String, allowUI: Bool) throws -> Data {
        try result.get()
    }
}

private struct MockQuotaProvider: QuotaProvider {
    let providerId: String
    let displayName: String
    let delayNs: UInt64
    let resultFactory: @Sendable () -> ProviderResult

    func fetch() async -> ProviderResult {
        if delayNs > 0 {
            try? await Task.sleep(nanoseconds: delayNs)
        }
        return resultFactory()
    }
}

final class QuotaTests: XCTestCase {
    func testKeychainServiceNameDerivationMatchesClaudeCode() {
        let defaultSvc = ProfileDiscovery.keychainServiceName(
            forConfigDir: "/Users/samuelnittala/.claude",
            isDefault: true
        )
        XCTAssertEqual(defaultSvc, "Claude Code-credentials")

        let personalSvc = ProfileDiscovery.keychainServiceName(
            forConfigDir: "/Users/samuelnittala/.claude-personal",
            isDefault: false
        )
        XCTAssertEqual(personalSvc, "Claude Code-credentials-4546af99")
    }

    func testProfileDiscoverySkipsMissingAndMalformedConfig() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let initial = ProfileDiscovery.discoverClaudeProfiles(homeDirectory: tmp)
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial[0].id, "claude")

        let configDir = tmp.appendingPathComponent(".config/ai-quota-bar")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configURL = configDir.appendingPathComponent("config.json")
        try Data("{bad json".utf8).write(to: configURL)
        XCTAssertEqual(ProfileDiscovery.discoverClaudeProfiles(homeDirectory: tmp).count, 1)

        let personalDir = tmp.appendingPathComponent(".claude-personal")
        try FileManager.default.createDirectory(at: personalDir, withIntermediateDirectories: true)
        let validJSON = """
        {
          "extraClaudeProfiles": [
            { "label": "ccp", "configDir": "~/.claude-personal" },
            { "label": "missing", "configDir": "~/.claude-missing" }
          ]
        }
        """
        try Data(validJSON.utf8).write(to: configURL)

        let discovered = ProfileDiscovery.discoverClaudeProfiles(homeDirectory: tmp)
        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(discovered[1].label, "ccp")
        XCTAssertEqual(discovered[1].configDir, personalDir.path)
    }

    func testStateCacheRoundTripAndStaleMerge() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cacheURL = tmp.appendingPathComponent(".cache/ai-quota-bar/state.json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cache = StateCache(fileURL: cacheURL)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let good = ProviderResult(
            providerId: "claude",
            displayName: "Claude",
            entries: [QuotaEntry(label: "Claude", fiveHourUsedPct: 7.0, weeklyUsedPct: 45.0)],
            fetchedAt: t0
        )
        let saved = cache.mergeAndPersist(liveResults: [good])
        XCTAssertFalse(saved[0].isStale)
        XCTAssertNil(saved[0].error)

        let reloaded = StateCache(fileURL: cacheURL)
        let failedLive = ProviderResult(
            providerId: "claude",
            displayName: "Claude",
            entries: [],
            fetchedAt: t0.addingTimeInterval(60),
            error: .networkError("offline")
        )
        let merged = reloaded.mergeAndPersist(liveResults: [failedLive])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isStale)
        XCTAssertEqual(merged[0].fetchedAt, t0)
        XCTAssertEqual(merged[0].entries, good.entries)
        XCTAssertEqual(merged[0].error, .networkError("offline"))

        try Data("not-json".utf8).write(to: cacheURL)
        let corruptReloaded = StateCache(fileURL: cacheURL)
        XCTAssertNil(corruptReloaded.cachedResult(for: "claude"))
    }

    func testClaudeFetcherSuccessAndErrorMapping() async {
        let profile = ClaudeProfile(
            id: "claude",
            label: "Claude",
            configDir: "/tmp/.claude",
            keychainService: "Claude Code-credentials"
        )
        let secret = Data(#"{"claudeAiOauth":{"accessToken":"tok-123"}}"#.utf8)
        let usageJSON = Data(#"{"five_hour":{"utilization":7.0,"resets_at":"2026-11-14T15:00:00Z"},"seven_day":{"utilization":45.0,"resets_at":"2026-11-18T08:00:00Z"}}"#.utf8)

        let fetcher = ClaudeFetcher(
            profile: profile,
            httpClient: MockHTTPClient { req in
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
                XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (usageJSON, resp)
            },
            keychainReader: MockKeychainReader(result: .success(secret))
        )

        let ok = await fetcher.fetch()
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.entries.first?.fiveHourUsedPct, 7.0)
        XCTAssertEqual(ok.entries.first?.weeklyUsedPct, 45.0)

        let expiredFetcher = ClaudeFetcher(
            profile: profile,
            httpClient: MockHTTPClient { req in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            },
            keychainReader: MockKeychainReader(result: .success(secret))
        )
        let expired = await expiredFetcher.fetch()
        XCTAssertEqual(expired.error, .tokenExpired("Login expired — run claude"))

        let aclFetcher = ClaudeFetcher(
            profile: profile,
            httpClient: MockHTTPClient { _ in fatalError("should not call HTTP") },
            keychainReader: MockKeychainReader(result: .failure(ProviderError.keychainInteractionRequired(service: "Claude Code-credentials")))
        )
        let aclResult = await aclFetcher.fetch()
        XCTAssertEqual(aclResult.error, .keychainInteractionRequired(service: "Claude Code-credentials"))

        // Cooldown prevents repeated HTTP calls within 60s
        let countLock = NSLock()
        var httpCalls = 0
        let cooldownFetcher = ClaudeFetcher(
            profile: profile,
            httpClient: MockHTTPClient { req in
                countLock.withLock { httpCalls += 1 }
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (usageJSON, resp)
            },
            keychainReader: MockKeychainReader(result: .success(secret)),
            cooldownSeconds: 60
        )
        _ = await cooldownFetcher.fetch()
        _ = await cooldownFetcher.fetch()
        XCTAssertEqual(countLock.withLock { httpCalls }, 1)
    }

    func testCodexFetcherParsesRateLimits() throws {
        let lines = [
            #"{"id":1,"result":{"userAgent":"probe"}}"#,
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1795176531},"secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1794680000}}}}"#
        ]
        let entry = try CodexFetcher.parseLines(lines)
        XCTAssertEqual(entry.weeklyUsedPct, 4)
        XCTAssertEqual(entry.fiveHourUsedPct, 12)
        XCTAssertEqual(entry.weeklyResetAt?.timeIntervalSince1970, 1795176531)
        XCTAssertEqual(entry.fiveHourResetAt?.timeIntervalSince1970, 1794680000)
    }

    func testAgyFetcherParsesCapturedUsageFixtureAndRejectsBlank() throws {
        let fixture = """
        \u{1B}[32mGEMINI MODELS\u{1B}[0m
          Models within this group: Gemini 4 Hydrogen, Gemini 3.8 Flash
          Weekly Limit Remaining
         [████████████████████████████████████████████████░░] 96.70%
         Refreshes in 166h 58m
          Five Hour Limit Remaining
         [████████████████████████████████████████████░░░░░░] 88.44%
         Refreshes in 3h 58m

        CLAUDE AND GPT MODELS
          Weekly Limit Remaining
         [██████████████████████████████████████████████████] 99.80%
         Refreshes in 138h 32m
          Five Hour Limit Remaining
         [██████████████████████████████████████████████████] 100.00%
         Quota available

        GEMINI 4 ARGON
          Gemini 4 Argon Weekly Limit
         [██████████████████████████████████████████████████] 100.00%
         Quota available
        """
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = try AgyFetcher.parseUsageOutput(fixture, now: now)
        XCTAssertEqual(entries.count, 3)

        XCTAssertEqual(entries[0].label, "Gemini Models")
        XCTAssertEqual(entries[0].weeklyUsedPct ?? -1, 3.30, accuracy: 0.01)
        XCTAssertEqual(entries[0].fiveHourUsedPct ?? -1, 11.56, accuracy: 0.01)

        XCTAssertEqual(entries[1].label, "Claude & GPT")
        XCTAssertEqual(entries[1].weeklyUsedPct ?? -1, 0.20, accuracy: 0.01)
        XCTAssertEqual(entries[1].fiveHourUsedPct ?? -1, 0.0, accuracy: 0.01)

        XCTAssertEqual(entries[2].label, "Gemini 4 Argon")
        XCTAssertEqual(entries[2].weeklyUsedPct ?? -1, 0.0, accuracy: 0.01)
        XCTAssertNil(entries[2].fiveHourUsedPct)

        XCTAssertThrowsError(try AgyFetcher.parseUsageOutput("Not signed in", now: now))
    }

    func testQuotaCoordinatorSingleFlightAndFailureAggregation() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = StateCache(fileURL: tmp.appendingPathComponent("state.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lock = NSLock()
        var callCount = 0

        let p1 = MockQuotaProvider(providerId: "claude", displayName: "Claude", delayNs: 80_000_000) {
            lock.withLock { callCount += 1 }
            return ProviderResult(
                providerId: "claude",
                displayName: "Claude",
                entries: [QuotaEntry(label: "Claude", fiveHourUsedPct: 10, weeklyUsedPct: 20)],
                fetchedAt: Date()
            )
        }
        let p2 = MockQuotaProvider(providerId: "agy", displayName: "Antigravity", delayNs: 20_000_000) {
            ProviderResult(
                providerId: "agy",
                displayName: "Antigravity",
                entries: [],
                fetchedAt: Date(),
                error: .timeout
            )
        }

        let coordinator = QuotaCoordinator(providers: [p1, p2], stateCache: cache)
        async let r1 = coordinator.refresh()
        async let r2 = coordinator.refresh()
        let (res1, res2) = await (r1, r2)

        XCTAssertEqual(res1, res2)
        XCTAssertEqual(lock.withLock { callCount }, 1)
        let anyFailed = await coordinator.hasAnyFailure
        XCTAssertTrue(anyFailed)
    }
}
