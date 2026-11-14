import Foundation

/// Runs all active QuotaProviders in parallel with single-flight coalescing
/// and progressive per-provider updates so fast fetchers are never blocked by slow ones.
public actor QuotaCoordinator {
    private let providers: [QuotaProvider]
    private let stateCache: StateCache
    private var inFlightTask: Task<[ProviderResult], Never>?
    private var latestResults: [ProviderResult]

    public init(providers: [QuotaProvider], stateCache: StateCache) {
        self.providers = providers
        self.stateCache = stateCache
        self.latestResults = providers.compactMap { stateCache.cachedResult(for: $0.providerId) }
    }

    public var hasAnyFailure: Bool {
        latestResults.contains { $0.error != nil }
    }

    public func cachedSnapshot() -> [ProviderResult] {
        latestResults
    }

    /// Refreshes all providers concurrently; concurrent callers await the active TaskGroup.
    /// `onUpdate` is called progressively as each provider finishes.
    public func refresh(onUpdate: (@Sendable ([ProviderResult]) -> Void)? = nil) async -> [ProviderResult] {
        if let existing = inFlightTask {
            return await existing.value
        }

        let order = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($0.element.providerId, $0.offset) })
        let initialById = Dictionary(uniqueKeysWithValues: latestResults.map { ($0.providerId, $0) })

        let task = Task<[ProviderResult], Never> {
            var currentById = initialById
            return await withTaskGroup(of: ProviderResult.self, returning: [ProviderResult].self) { group in
                for provider in providers {
                    group.addTask {
                        await provider.fetch()
                    }
                }
                for await liveResult in group {
                    let mergedOne = stateCache.mergeAndPersist(liveResults: [liveResult])
                    if let updated = mergedOne.first {
                        currentById[updated.providerId] = updated
                    }
                    let ordered = currentById.values.sorted {
                        (order[$0.providerId] ?? Int.max) < (order[$1.providerId] ?? Int.max)
                    }
                    onUpdate?(ordered)
                }
                return currentById.values.sorted {
                    (order[$0.providerId] ?? Int.max) < (order[$1.providerId] ?? Int.max)
                }
            }
        }

        inFlightTask = task
        let merged = await task.value
        latestResults = merged
        inFlightTask = nil
        return merged
    }
}
