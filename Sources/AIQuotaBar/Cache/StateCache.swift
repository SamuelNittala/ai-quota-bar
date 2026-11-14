import Foundation

private struct CachePayload: Codable {
    var results: [String: ProviderResult]
}

/// Atomically persists the last successful ProviderResult per providerId to ~/.cache/ai-quota-bar/state.json.
public final class StateCache: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedResults: [String: ProviderResult]

    public init(
        fileURL: URL = StateCache.defaultCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.cachedResults = Self.loadFromDisk(fileURL: fileURL, fileManager: fileManager)
    }

    public static func defaultCacheURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".cache")
            .appendingPathComponent("ai-quota-bar")
            .appendingPathComponent("state.json")
    }

    private static func loadFromDisk(fileURL: URL, fileManager: FileManager) -> [String: ProviderResult] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CachePayload.self, from: data) else {
            return [:]
        }
        return payload.results
    }

    public func cachedResult(for providerId: String) -> ProviderResult? {
        lock.withLock { cachedResults[providerId] }
    }

    /// Merges a live result with cached entries on failure, or updates the cache on success.
    public func mergeAndPersist(liveResults: [ProviderResult]) -> [ProviderResult] {
        lock.withLock {
            var merged: [ProviderResult] = []
            var didUpdateCache = false

            for live in liveResults {
                if live.error == nil {
                    let clean = ProviderResult(
                        providerId: live.providerId,
                        displayName: live.displayName,
                        entries: live.entries,
                        fetchedAt: live.fetchedAt,
                        isStale: false,
                        error: nil
                    )
                    cachedResults[live.providerId] = clean
                    merged.append(clean)
                    didUpdateCache = true
                } else if let prior = cachedResults[live.providerId] {
                    merged.append(
                        ProviderResult(
                            providerId: live.providerId,
                            displayName: live.displayName,
                            entries: prior.entries,
                            fetchedAt: prior.fetchedAt,
                            isStale: true,
                            error: live.error
                        )
                    )
                } else {
                    merged.append(live)
                }
            }

            if didUpdateCache {
                saveToDiskLocked()
            }
            return merged
        }
    }

    private func saveToDiskLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(CachePayload(results: cachedResults)) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
