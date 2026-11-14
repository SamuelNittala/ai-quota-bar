import AppKit
import Foundation

/// Custom NSMenuItem view rendering a label, percentage bar, and reset time.
private final class QuotaBarRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let barViews: [(window: String, pct: Double, reset: Date?)]

    init(entry: QuotaEntry) {
        var rows: [(String, Double, Date?)] = []
        if let five = entry.fiveHourUsedPct {
            rows.append(("5h", five, entry.fiveHourResetAt))
        }
        if let week = entry.weeklyUsedPct {
            rows.append(("7d", week, entry.weeklyResetAt))
        }
        self.barViews = rows

        let rowHeight: CGFloat = CGFloat(max(1, rows.count)) * 22.0 + 24.0
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: rowHeight))
        setupViews(entry: entry)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setupViews(entry: QuotaEntry) {
        titleLabel.stringValue = entry.label
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if barViews.isEmpty {
            metaLabel.stringValue = "No quota data"
            metaLabel.font = .systemFont(ofSize: 11)
            metaLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(metaLabel)
        } else {
            for item in barViews {
                stack.addArrangedSubview(makeWindowRow(window: item.window, pct: item.pct, reset: item.reset))
            }
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    private func makeWindowRow(window: String, pct: Double, reset: Date?) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let winLabel = NSTextField(labelWithString: window)
        winLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        winLabel.textColor = .secondaryLabelColor
        winLabel.translatesAutoresizingMaskIntoConstraints = false

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        track.layer?.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Self.barColor(for: pct).cgColor
        fill.layer?.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let clamped = max(0.0, min(100.0, pct))
        let ratio = CGFloat(clamped / 100.0)

        let pctText = String(format: "%.0f%%", clamped)
        let resetText = reset.map { " · \(Self.resetText($0))" } ?? ""
        let valueLabel = NSTextField(labelWithString: "\(pctText)\(resetText)")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(winLabel)
        container.addSubview(track)
        container.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 262),
            container.heightAnchor.constraint(equalToConstant: 18),

            winLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            winLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            winLabel.widthAnchor.constraint(equalToConstant: 22),

            track.leadingAnchor.constraint(equalTo: winLabel.trailingAnchor, constant: 6),
            track.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 6),
            track.widthAnchor.constraint(equalToConstant: 118),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.02, ratio)),

            valueLabel.leadingAnchor.constraint(equalTo: track.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private static func barColor(for pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 70 { return .systemOrange }
        return .systemGreen
    }

    private static func resetText(_ target: Date) -> String {
        let secs = max(0, Int(target.timeIntervalSinceNow))
        let hrs = secs / 3600
        let mins = (secs % 3600) / 60
        if hrs >= 24 {
            return "\(hrs / 24)d \(hrs % 24)h"
        }
        return hrs > 0 ? "\(hrs)h \(mins)m" : "\(mins)m"
    }
}

/// Owns the NSStatusItem and NSMenu, refreshing on menu open without background polling.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let coordinator: QuotaCoordinator
    private let keychainReader: KeychainReader
    private var currentResults: [ProviderResult] = []
    private var isRefreshing = false

    public init(
        coordinator: QuotaCoordinator,
        keychainReader: KeychainReader = SecurityKeychainReader()
    ) {
        self.coordinator = coordinator
        self.keychainReader = keychainReader
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        self.menu.delegate = self
        self.statusItem.menu = self.menu
        renderStatusButton(hasFailure: false, loading: false)
        rebuildMenu()
    }

    public func triggerInitialRefresh() {
        Task { [weak self] in
            guard let self else { return }
            let cached = await self.coordinator.cachedSnapshot()
            await MainActor.run {
                self.currentResults = cached
                self.rebuildMenu()
            }
            await self.performRefresh()
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        scheduleMenuUpdate()
        let results = await coordinator.refresh { [weak self] partial in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentResults = partial
                    let hasFailure = partial.contains { $0.error != nil }
                    self.renderStatusButton(hasFailure: hasFailure, loading: self.isRefreshing)
                    self.rebuildMenu()
                }
            }
        }
        isRefreshing = false
        currentResults = results
        scheduleMenuUpdate()
    }

    private func scheduleMenuUpdate() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hasFailure = self.currentResults.contains { $0.error != nil }
                self.renderStatusButton(hasFailure: hasFailure, loading: self.isRefreshing)
                self.rebuildMenu()
            }
        }
    }

    private func renderStatusButton(hasFailure: Bool, loading: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = hasFailure ? "exclamationmark.circle.fill" : "chart.bar.fill"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AI Quotas") {
            let config: NSImage.SymbolConfiguration
            if hasFailure {
                config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            } else {
                config = NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)
            }
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
        }
        button.title = loading ? " …" : ""
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if isRefreshing {
            let item = NSMenuItem(title: "Refreshing quotas…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if currentResults.isEmpty && !isRefreshing {
            let empty = NSMenuItem(title: "Click to load quotas", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for result in currentResults {
                appendSection(for: result)
                menu.addItem(.separator())
            }
        }

        let quitItem = NSMenuItem(title: "Quit AIQuotaBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func appendSection(for result: ProviderResult) {
        let headerTitle = result.isStale
            ? "\(result.displayName) (stale · \(Self.relativeTime(result.fetchedAt)))"
            : "\(result.displayName) · \(Self.relativeTime(result.fetchedAt))"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for entry in result.entries {
            let item = NSMenuItem()
            item.view = QuotaBarRowView(entry: entry)
            menu.addItem(item)
        }

        if let error = result.error {
            let errItem = NSMenuItem(title: "  ! \(error.userMessage)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed]
            errItem.attributedTitle = NSAttributedString(string: "  ! \(error.userMessage)", attributes: attrs)
            menu.addItem(errItem)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private static func relativeTime(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}
