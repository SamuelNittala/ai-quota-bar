import Foundation
import LocalAuthentication
import Security

/// Production KeychainReader backed by `/usr/bin/security find-generic-password`
/// so macOS checks the Keychain ACL against Apple's signed `security` binary.
public struct SecurityKeychainReader: KeychainReader {
    public init() {}

    public func readGenericPassword(service: String, allowUI: Bool) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProviderError.missingCredentials("Failed to run /usr/bin/security: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            let trimmed = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let data = trimmed.data(using: .utf8), !data.isEmpty else {
                throw ProviderError.missingCredentials("Empty Keychain item for \(service)")
            }
            return data
        }

        if process.terminationStatus == 44 {
            let cmd = service == "Claude Code-credentials" ? "claude" : "profile CLI"
            throw ProviderError.missingCredentials("Not logged in — run \(cmd)")
        }

        let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
        throw ProviderError.missingCredentials("Keychain error (\(process.terminationStatus)): \(errText)")
    }
}

private struct ClaudeKeychainPayload: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
    }
    let claudeAiOauth: OAuth?
}

private struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?
}

/// Fetches 5-hour and weekly utilization for a single Claude CLI profile.
public final class ClaudeFetcher: QuotaProvider, @unchecked Sendable {
    public let providerId: String
    public let displayName: String
    private let profile: ClaudeProfile
    private let httpClient: HTTPClient
    private let keychainReader: KeychainReader
    private let now: @Sendable () -> Date

    public init(
        profile: ClaudeProfile,
        httpClient: HTTPClient = URLSessionHTTPClient(timeoutSeconds: 6.0),
        keychainReader: KeychainReader = SecurityKeychainReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerId = profile.id
        self.displayName = profile.label
        self.profile = profile
        self.httpClient = httpClient
        self.keychainReader = keychainReader
        self.now = now
    }

    public func fetch() async -> ProviderResult {
        let fetchedAt = now()
        do {
            let secretData = try keychainReader.readGenericPassword(
                service: profile.keychainService,
                allowUI: false
            )
            let token = try Self.extractAccessToken(from: secretData)

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let (data, response) = try await httpClient.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return fail(.networkError("Invalid HTTP response"), at: fetchedAt)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                let cmd = profile.id == "claude" ? "claude" : profile.label
                return fail(.tokenExpired("Login expired — run \(cmd)"), at: fetchedAt)
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return fail(.httpError(statusCode: http.statusCode, body: String(body.prefix(120))), at: fetchedAt)
            }

            let entry = try Self.parseUsageResponse(data, label: profile.label)
            return ProviderResult(
                providerId: providerId,
                displayName: displayName,
                entries: [entry],
                fetchedAt: fetchedAt
            )
        } catch let err as ProviderError {
            return fail(err, at: fetchedAt)
        } catch let err as URLError where err.code == .timedOut {
            return fail(.timeout, at: fetchedAt)
        } catch {
            return fail(.networkError(error.localizedDescription), at: fetchedAt)
        }
    }

    public static func extractAccessToken(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ClaudeKeychainPayload.self, from: data)
        guard let token = decoded.claudeAiOauth?.accessToken, !token.isEmpty else {
            throw ProviderError.missingCredentials("Missing claudeAiOauth.accessToken")
        }
        return token
    }

    public static func parseUsageResponse(_ data: Data, label: String) throws -> QuotaEntry {
        let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        guard decoded.five_hour != nil || decoded.seven_day != nil else {
            throw ProviderError.parseError("Missing five_hour and seven_day fields")
        }
        return QuotaEntry(
            label: label,
            fiveHourUsedPct: decoded.five_hour?.utilization,
            weeklyUsedPct: decoded.seven_day?.utilization,
            fiveHourResetAt: decoded.five_hour?.resets_at.flatMap(parseISO8601),
            weeklyResetAt: decoded.seven_day?.resets_at.flatMap(parseISO8601)
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: value) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: value)
    }

    private func fail(_ error: ProviderError, at date: Date) -> ProviderResult {
        ProviderResult(
            providerId: providerId,
            displayName: displayName,
            entries: [],
            fetchedAt: date,
            isStale: false,
            error: error
        )
    }
}
