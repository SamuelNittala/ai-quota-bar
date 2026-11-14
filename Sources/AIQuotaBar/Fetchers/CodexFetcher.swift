import Darwin
import Foundation

/// Default ProcessRunner using Foundation.Process with isolated process-group teardown.
public struct DefaultProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdinLines: [String],
        stopWhenLineMatches: @escaping @Sendable (String) -> Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.environment = environment

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProviderError.networkError("Failed to launch \(executablePath): \(error.localizedDescription)"))
                    return
                }

                let pid = process.processIdentifier
                _ = setpgid(pid, pid)

                for line in stdinLines {
                    if let data = (line + "\n").data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                    }
                }

                let lock = NSLock()
                var lines: [String] = []
                var buffer = Data()
                var matched = false
                let semaphore = DispatchSemaphore(value: 0)

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        semaphore.signal()
                        return
                    }
                    lock.lock()
                    buffer.append(chunk)
                    while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newlineIdx)
                        buffer.removeSubrange(0...newlineIdx)
                        if let text = String(data: lineData, encoding: .utf8) {
                            lines.append(text)
                            if stopWhenLineMatches(text) {
                                matched = true
                            }
                        }
                    }
                    let done = matched
                    lock.unlock()
                    if done {
                        handle.readabilityHandler = nil
                        semaphore.signal()
                    }
                }

                let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                try? stdinPipe.fileHandleForWriting.close()

                Self.terminateProcessGroup(pid: pid)
                process.waitUntilExit()

                lock.lock()
                let collected = lines
                let didMatch = matched
                lock.unlock()

                if waitResult == .timedOut && !didMatch {
                    continuation.resume(throwing: ProviderError.timeout)
                } else {
                    continuation.resume(returning: collected)
                }
            }
        }
    }

    private static func terminateProcessGroup(pid: pid_t) {
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        for _ in 0..<10 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                return
            }
            usleep(50_000)
        }
        _ = kill(-pid, SIGKILL)
    }
}

private struct CodexRateLimitsRPC: Decodable {
    struct Result: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Int?
                let resetsAt: TimeInterval?
            }
            let primary: Window?
            let secondary: Window?
        }
        let rateLimits: RateLimits?
    }
    let id: Int?
    let result: Result?
}

/// Fetches 5-hour and weekly rate limits via `codex app-server` JSON-RPC.
public final class CodexFetcher: QuotaProvider, @unchecked Sendable {
    public let providerId = "codex"
    public let displayName = "Codex"
    private let processRunner: ProcessRunner
    private let explicitPath: String
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        processRunner: ProcessRunner = DefaultProcessRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        let localBin = homeDirectory.appendingPathComponent(".local/bin").path
        self.explicitPath = "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        self.fileManager = fileManager
        self.now = now
    }

    public func fetch() async -> ProviderResult {
        let fetchedAt = now()
        guard let binary = Self.findExecutable(named: "codex", path: explicitPath, fileManager: fileManager) else {
            return fail(.missingCredentials("codex CLI not found in PATH"), at: fetchedAt)
        }

        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-quota-bar","version":"0.1.0"},"capabilities":{}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#
        let rateLimitsReq = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = explicitPath

        do {
            let lines = try await processRunner.run(
                executablePath: binary,
                arguments: ["app-server"],
                environment: env,
                stdinLines: [initReq, initialized, rateLimitsReq],
                stopWhenLineMatches: { line in
                    line.contains(#""id":2"#) || line.contains(#""id": 2"#)
                },
                timeoutSeconds: 6.0
            )
            let entry = try Self.parseLines(lines)
            return ProviderResult(
                providerId: providerId,
                displayName: displayName,
                entries: [entry],
                fetchedAt: fetchedAt
            )
        } catch let err as ProviderError {
            return fail(err, at: fetchedAt)
        } catch {
            return fail(.networkError(error.localizedDescription), at: fetchedAt)
        }
    }

    public static func parseLines(_ lines: [String]) throws -> QuotaEntry {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(CodexRateLimitsRPC.self, from: data),
                  msg.id == 2,
                  let limits = msg.result?.rateLimits else {
                continue
            }

            var fiveHourPct: Double?
            var weeklyPct: Double?
            var fiveHourReset: Date?
            var weeklyReset: Date?

            for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
                let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                if let mins = window.windowDurationMins, mins <= 360 {
                    fiveHourPct = window.usedPercent
                    fiveHourReset = resetDate
                } else {
                    weeklyPct = window.usedPercent
                    weeklyReset = resetDate
                }
            }

            return QuotaEntry(
                label: "Codex",
                fiveHourUsedPct: fiveHourPct,
                weeklyUsedPct: weeklyPct,
                fiveHourResetAt: fiveHourReset,
                weeklyResetAt: weeklyReset
            )
        }
        throw ProviderError.parseError("No account/rateLimits/read response")
    }

    public static func findExecutable(named name: String, path: String, fileManager: FileManager = .default) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
