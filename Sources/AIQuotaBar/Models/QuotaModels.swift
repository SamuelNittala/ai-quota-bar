import Foundation

/// A single quota row displayed under a provider or profile (for example, one agy model group).
public struct QuotaEntry: Codable, Sendable, Equatable {
    public let label: String
    public let fiveHourUsedPct: Double?
    public let weeklyUsedPct: Double?
    public let fiveHourResetAt: Date?
    public let weeklyResetAt: Date?

    public init(
        label: String,
        fiveHourUsedPct: Double? = nil,
        weeklyUsedPct: Double? = nil,
        fiveHourResetAt: Date? = nil,
        weeklyResetAt: Date? = nil
    ) {
        self.label = label
        self.fiveHourUsedPct = fiveHourUsedPct
        self.weeklyUsedPct = weeklyUsedPct
        self.fiveHourResetAt = fiveHourResetAt
        self.weeklyResetAt = weeklyResetAt
    }
}

/// Typed failure states surfaced in the menu bar and dropdown.
public enum ProviderError: Error, Codable, Sendable, Equatable {
    case missingCredentials(String)
    case keychainInteractionRequired(service: String)
    case tokenExpired(String)
    case httpError(statusCode: Int, body: String)
    case networkError(String)
    case timeout
    case parseError(String)

    public var userMessage: String {
        switch self {
        case .missingCredentials(let detail):
            return detail
        case .keychainInteractionRequired(let service):
            return "Keychain authorization needed (\(service))"
        case .tokenExpired(let detail):
            return detail
        case .httpError(let statusCode, _):
            return "HTTP \(statusCode)"
        case .networkError(let detail):
            return detail
        case .timeout:
            return "Timed out"
        case .parseError(let detail):
            return "Parse error: \(detail)"
        }
    }
}

/// Normalized output returned by each quota fetcher and persisted in StateCache.
public struct ProviderResult: Codable, Sendable, Equatable {
    public let providerId: String
    public let displayName: String
    public let entries: [QuotaEntry]
    public let fetchedAt: Date
    public let isStale: Bool
    public let error: ProviderError?

    public init(
        providerId: String,
        displayName: String,
        entries: [QuotaEntry],
        fetchedAt: Date,
        isStale: Bool = false,
        error: ProviderError? = nil
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.entries = entries
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.error = error
    }
}

/// Common interface implemented by each provider/profile fetcher.
public protocol QuotaProvider: Sendable {
    var providerId: String { get }
    var displayName: String { get }
    func fetch() async -> ProviderResult
}

/// Dependency-injection seam for HTTP requests.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default URLSession-backed HTTPClient using 6s request and resource timeouts.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = 6.0) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Dependency-injection seam for macOS Keychain lookups.
public protocol KeychainReader: Sendable {
    func readGenericPassword(service: String, allowUI: Bool) throws -> Data
}

/// Dependency-injection seam for running short-lived subprocesses (such as codex app-server).
public protocol ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdinLines: [String],
        stopWhenLineMatches: @escaping @Sendable (String) -> Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> [String]
}
