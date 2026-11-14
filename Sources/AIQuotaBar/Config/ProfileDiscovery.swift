import CryptoKit
import Foundation

/// Represents a single Claude CLI configuration profile (default or CLAUDE_CONFIG_DIR).
public struct ClaudeProfile: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let configDir: String
    public let keychainService: String

    public init(id: String, label: String, configDir: String, keychainService: String) {
        self.id = id
        self.label = label
        self.configDir = configDir
        self.keychainService = keychainService
    }
}

private struct AppConfigFile: Codable {
    struct ExtraProfile: Codable {
        let label: String
        let configDir: String
    }
    let extraClaudeProfiles: [ExtraProfile]?
}

/// Discovers active Claude profiles from ~/.claude and optional ~/.config/ai-quota-bar/config.json.
public enum ProfileDiscovery {
    public static func defaultHomeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Expands a leading `~` or `~/` against the provided home directory.
    public static func expandTilde(_ path: String, homeDirectory: URL = defaultHomeDirectory()) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).path
        }
        return path
    }

    /// Computes Claude Code's Keychain service name for a config directory.
    /// Default `~/.claude` uses `Claude Code-credentials`; custom `CLAUDE_CONFIG_DIR`
    /// appends the first 8 lowercase hex characters of SHA-256(expandedPath).
    public static func keychainServiceName(forConfigDir expandedPath: String, isDefault: Bool) -> String {
        if isDefault {
            return "Claude Code-credentials"
        }
        let normalized = expandedPath.hasSuffix("/") && expandedPath.count > 1
            ? String(expandedPath.dropLast())
            : expandedPath
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Loads the default `~/.claude` profile plus any valid extra profiles in `config.json`.
    public static func discoverClaudeProfiles(
        homeDirectory: URL = defaultHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [ClaudeProfile] {
        let defaultDir = homeDirectory.appendingPathComponent(".claude").path
        var profiles = [
            ClaudeProfile(
                id: "claude",
                label: "Claude",
                configDir: defaultDir,
                keychainService: keychainServiceName(forConfigDir: defaultDir, isDefault: true)
            )
        ]

        let configURL = homeDirectory
            .appendingPathComponent(".config")
            .appendingPathComponent("ai-quota-bar")
            .appendingPathComponent("config.json")

        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(AppConfigFile.self, from: data),
              let extras = decoded.extraClaudeProfiles else {
            return profiles
        }

        for extra in extras {
            let trimmedLabel = extra.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else { continue }
            let expanded = expandTilde(extra.configDir, homeDirectory: homeDirectory)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let slug = trimmedLabel.lowercased().replacingOccurrences(of: " ", with: "-")
            profiles.append(
                ClaudeProfile(
                    id: "claude-\(slug)",
                    label: trimmedLabel,
                    configDir: expanded,
                    keychainService: keychainServiceName(forConfigDir: expanded, isDefault: false)
                )
            )
        }

        return profiles
    }
}
