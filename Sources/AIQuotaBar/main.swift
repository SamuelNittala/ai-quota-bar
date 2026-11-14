import AppKit
import Foundation

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profiles = ProfileDiscovery.discoverClaudeProfiles()
        var providers: [QuotaProvider] = profiles.map { ClaudeFetcher(profile: $0) }
        providers.append(CodexFetcher())
        providers.append(AgyFetcher())

        let stateCache = StateCache()
        let coordinator = QuotaCoordinator(providers: providers, stateCache: stateCache)
        let menuController = StatusMenuController(coordinator: coordinator)
        self.controller = menuController
        menuController.triggerInitialRefresh()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
