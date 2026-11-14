import Darwin
import Foundation

/// Dependency-injection seam for running an interactive PTY `/usage` scrape.
public protocol PTYRunner: Sendable {
    func runUsage(executablePath: String, environment: [String: String], timeoutSeconds: TimeInterval) async throws -> String
}

/// Default PTYRunner using forkpty + TIOCSWINSZ (80x120) and process-group teardown.
public struct DefaultPTYRunner: PTYRunner {
    public init() {}

    public func runUsage(
        executablePath: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var win = winsize(ws_row: 80, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
                var masterFD: Int32 = -1
                let pid = forkpty(&masterFD, nil, nil, &win)
                if pid < 0 {
                    continuation.resume(throwing: ProviderError.networkError("forkpty failed"))
                    return
                }

                if pid == 0 {
                    for (k, v) in environment {
                        setenv(k, v, 1)
                    }
                    let arg0 = strdup(executablePath)
                    var args: [UnsafeMutablePointer<CChar>?] = [arg0, nil]
                    execv(executablePath, &args)
                    _exit(127)
                }

                _ = setpgid(pid, pid)
                let flags = fcntl(masterFD, F_GETFL, 0)
                _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

                let deadline = Date().addingTimeInterval(timeoutSeconds)
                var output = Data()
                var sentUsage = false
                var sentExit = false
                let start = Date()
                var buffer = [UInt8](repeating: 0, count: 8192)

                while Date() < deadline {
                    var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
                    let polled = poll(&pfd, 1, 150)
                    if polled > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                        let n = read(masterFD, &buffer, buffer.count)
                        if n > 0 {
                            output.append(contentsOf: buffer[0..<n])
                        }
                    }

                    let elapsed = Date().timeIntervalSince(start)
                    let textSoFar = String(data: output, encoding: .utf8) ?? ""

                    if !sentUsage && (elapsed > 3.5 || textSoFar.contains("? for shortcuts")) {
                        let cmd = "/usage\r"
                        _ = cmd.withCString { write(masterFD, $0, strlen($0)) }
                        sentUsage = true
                    }

                    if sentUsage && !sentExit && (textSoFar.contains("Within each group") || elapsed > 7.0) {
                        let exitSeq = "\u{03}\u{03}"
                        _ = exitSeq.withCString { write(masterFD, $0, strlen($0)) }
                        sentExit = true
                        break
                    }
                }

                _ = kill(-pid, SIGTERM)
                var status: Int32 = 0
                var exited = false
                for _ in 0..<6 {
                    if waitpid(pid, &status, WNOHANG) == pid {
                        exited = true
                        break
                    }
                    usleep(50_000)
                }
                if !exited {
                    _ = kill(-pid, SIGKILL)
                    _ = waitpid(pid, &status, 0)
                }
                close(masterFD)

                let text = String(data: output, encoding: .utf8) ?? ""
                if text.isEmpty {
                    continuation.resume(throwing: ProviderError.timeout)
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }
}

/// Fetches Antigravity model-group quotas via PTY `/usage`.
public final class AgyFetcher: QuotaProvider, @unchecked Sendable {
    public let providerId = "agy"
    public let displayName = "Antigravity"
    private let ptyRunner: PTYRunner
    private let explicitPath: String
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        ptyRunner: PTYRunner = DefaultPTYRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ptyRunner = ptyRunner
        let localBin = homeDirectory.appendingPathComponent(".local/bin").path
        self.explicitPath = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        self.fileManager = fileManager
        self.now = now
    }

    public func fetch() async -> ProviderResult {
        let fetchedAt = now()
        guard let binary = CodexFetcher.findExecutable(named: "agy", path: explicitPath, fileManager: fileManager) else {
            return fail(.missingCredentials("agy CLI not found in PATH"), at: fetchedAt)
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = explicitPath
        env["TERM"] = "xterm-256color"

        do {
            let raw = try await ptyRunner.runUsage(executablePath: binary, environment: env, timeoutSeconds: 8.0)
            let entries = try Self.parseUsageOutput(raw, now: fetchedAt)
            return ProviderResult(
                providerId: providerId,
                displayName: displayName,
                entries: entries,
                fetchedAt: fetchedAt
            )
        } catch let err as ProviderError {
            return fail(err, at: fetchedAt)
        } catch {
            return fail(.networkError(error.localizedDescription), at: fetchedAt)
        }
    }

    public static func stripANSI(_ raw: String) -> String {
        let pattern = #"\x1B\[[0-9;?]*[a-zA-Z]|\x1B\][^\x07]*\x07|\r"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: " ")
    }

    public static func parseUsageOutput(_ raw: String, now: Date = Date()) throws -> [QuotaEntry] {
        let clean = stripANSI(raw)
        let lines = clean.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let groupHeaders: [(needle: String, display: String)] = [
            ("GEMINI MODELS", "Gemini Models"),
            ("CLAUDE AND GPT MODELS", "Claude & GPT"),
            ("GEMINI 4 ARGON", "Gemini 4 Argon")
        ]

        var entries: [QuotaEntry] = []
        var currentGroup: String?
        var currentKind: String? // "weekly" or "fiveHour"
        var weeklyUsed: Double?
        var fiveHourUsed: Double?
        var weeklyReset: Date?
        var fiveHourReset: Date?

        func flushGroup() {
            guard let group = currentGroup, weeklyUsed != nil || fiveHourUsed != nil else { return }
            entries.append(
                QuotaEntry(
                    label: group,
                    fiveHourUsedPct: fiveHourUsed,
                    weeklyUsedPct: weeklyUsed,
                    fiveHourResetAt: fiveHourReset,
                    weeklyResetAt: weeklyReset
                )
            )
            weeklyUsed = nil
            fiveHourUsed = nil
            weeklyReset = nil
            fiveHourReset = nil
        }

        let pctRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%"#)
        let refreshRegex = try? NSRegularExpression(pattern: #"Refreshes in\s+(?:(\d+)h\s*)?(?:(\d+)m)?"#)

        for line in lines {
            if let matched = groupHeaders.first(where: { line.contains($0.needle) }) {
                flushGroup()
                currentGroup = matched.display
                currentKind = nil
                continue
            }
            guard currentGroup != nil else { continue }

            if line.contains("Weekly Limit") {
                currentKind = "weekly"
            } else if line.contains("Five Hour Limit") {
                currentKind = "fiveHour"
            }

            if let pctRegex,
               let match = pctRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(match.range(at: 1), in: line),
               let remaining = Double(line[r]) {
                let used = max(0.0, min(100.0, (100.0 - remaining) * 100.0 / 100.0))
                if currentKind == "fiveHour" {
                    fiveHourUsed = used
                } else {
                    weeklyUsed = used
                }
            }

            if let refreshRegex,
               let match = refreshRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                var seconds: TimeInterval = 0
                if let hrRange = Range(match.range(at: 1), in: line), let hrs = Double(line[hrRange]) {
                    seconds += hrs * 3600
                }
                if let minRange = Range(match.range(at: 2), in: line), let mins = Double(line[minRange]) {
                    seconds += mins * 60
                }
                let resetDate = now.addingTimeInterval(seconds)
                if currentKind == "fiveHour" {
                    fiveHourReset = resetDate
                } else {
                    weeklyReset = resetDate
                }
            }
        }
        flushGroup()

        if entries.isEmpty {
            throw ProviderError.parseError("agy unavailable (could not parse /usage)")
        }
        return entries
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
