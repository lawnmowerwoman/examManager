import Foundation

/// Shared allowlist writer for both proxy backends.
///
/// The manager preserves custom entries already present on disk while
/// refreshing the managed Jamf / Apple defaults at the top of the file.
public struct ExamWhitelistManager {
    public enum Backend: Sendable {
        case internalProxy
        case tinyproxy
    }

    private let logger: PlistStoreLogger?

    public init(logger: PlistStoreLogger? = nil) {
        self.logger = logger
    }

    @discardableResult
    public func prepareWhitelist(
        jamfProURL: String,
        backend: Backend,
        profileEntries: [String] = []
    ) throws -> [String] {
        let targetURL = runtimeWhitelistURL(for: backend)
        let fileManager = FileManager.default

        if backend == .internalProxy {
            try? ExamModeAssetInstaller.migrateWhitelistForBuiltInProxyIfNeeded()
        }

        if backend == .tinyproxy, let parentDirectory = targetURL.deletingLastPathComponent() as URL? {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        let managedEntries = managedEntries(jamfProURL: jamfProURL)
        let customEntries = customEntries(
            from: sourceWhitelistURL(for: backend),
            managedEntries: managedEntries,
            profileEntries: profileEntries
        )
        let normalized = deduplicated((managedEntries + customEntries).map(normalize))
            .filter { !$0.isEmpty }

        if backend == .tinyproxy {
            try normalized.joined(separator: "\n").write(to: targetURL, atomically: true, encoding: .utf8)
            logger?.warn("[ExamWhitelistManager] Wrote \(normalized.count) whitelist entries to \(targetURL.path)")
        } else {
            logger?.warn("[ExamWhitelistManager] Prepared \(normalized.count) effective whitelist entries for the built-in proxy")
        }
        return normalized
    }

    private func customEntries(from targetURL: URL, managedEntries: [String], profileEntries: [String]) -> [String] {
        let normalizedProfileEntries = profileEntries
            .map(normalize)
            .filter { !$0.isEmpty }

        let existingLines = loadExistingLines(from: targetURL)
        if !normalizedProfileEntries.isEmpty {
            logger?.warn("[ExamWhitelistManager] Merging \(normalizedProfileEntries.count) allowlist entries from the managed profile with \(existingLines.count) file-based entries from \(targetURL.path)")
        } else if !existingLines.isEmpty {
            logger?.warn("[ExamWhitelistManager] No managed-profile allowlist found – using \(existingLines.count) file-based entries from \(targetURL.path)")
        }
        return deduplicated(normalizedProfileEntries + existingLines)
            .filter { !managedEntries.contains($0) }
    }

    private func runtimeWhitelistURL(for backend: Backend) -> URL {
        switch backend {
        case .internalProxy:
            return ExamManagerPaths.managedWhitelist
        case .tinyproxy:
            return ExamManagerPaths.whitelist
        }
    }

    private func sourceWhitelistURL(for backend: Backend) -> URL {
        switch backend {
        case .internalProxy, .tinyproxy:
            return ExamManagerPaths.managedWhitelist
        }
    }

    private func loadExistingLines(from url: URL) -> [String] {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let existing = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }

        return existing
            .components(separatedBy: "\n")
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    private func managedEntries(jamfProURL: String) -> [String] {
        let normalizedJamf = normalize(jamfProURL)
        var entries = [normalizedJamf, "*.jamfcloud.com", "*.wandera.com", "*.apple.com", "*.icloud.com"]

        if normalizedJamf.localizedCaseInsensitiveContains("kssrt") {
            entries.append(contentsOf: [
                "files.schule.local",
                "ad.kss-rt.logodidact.net",
                "*.kss-rt.logodidact.net",
                "*.logodidact.net"
            ])
        }

        return deduplicated(entries.map(normalize))
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
