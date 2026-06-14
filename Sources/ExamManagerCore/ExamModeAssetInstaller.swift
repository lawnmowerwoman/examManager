import Foundation

/// Installs bundled exam-mode web assets into the managed runtime directory.
///
/// The assets are part of the signed build output so they can be packaged and
/// notarized together with the daemon instead of being generated ad hoc.
///
/// TODO: Remove the copy step once the built-in Swift proxy replaces the
/// external tinyproxy process. At that point the deny page and illustration can
/// be referenced directly from bundled resources instead of being materialized
/// into `/Library/Management/lib/tinyproxy`.
struct ExamModeAssetInstaller {
    enum AssetError: Error, CustomStringConvertible {
        case missingBundledAsset(String)
        case copyFailed(String, Error)

        var description: String {
            switch self {
            case .missingBundledAsset(let name):
                return "Bundled asset missing: \(name)"
            case .copyFailed(let name, let error):
                return "Failed to copy bundled asset \(name): \(error)"
            }
        }
    }

    private static let assets: [(resource: String, ext: String)] = [
        ("default", "html"),
        ("websperre", "svg")
    ]

    static func bundledAssetURL(resource: String, ext: String) throws -> URL {
        guard let bundledURL = Bundle.module.url(forResource: resource, withExtension: ext) else {
            throw AssetError.missingBundledAsset("\(resource).\(ext)")
        }
        return bundledURL
    }

    static func bundledBlockPageURL() throws -> URL {
        try bundledAssetURL(resource: "default", ext: "html")
    }

    static func bundledSVGMarkup() throws -> String {
        let url = try bundledAssetURL(resource: "websperre", ext: "svg")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func installAssets(into directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for asset in assets {
            let bundledURL = try bundledAssetURL(resource: asset.resource, ext: asset.ext)

            let targetURL = directory.appendingPathComponent("\(asset.resource).\(asset.ext)")

            do {
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: bundledURL, to: targetURL)
            } catch {
                throw AssetError.copyFailed("\(asset.resource).\(asset.ext)", error)
            }
        }
    }

    /// Migration helper for the future built-in Swift proxy.
    ///
    /// Today the allowlist still lives under the tinyproxy-specific path
    /// `/Library/Management/lib/tinyproxy/whitelist`. Once the internal proxy
    /// replaces tinyproxy, the canonical location should become the neutral path
    /// `/Library/Management/whitelist`.
    ///
    /// This helper is intentionally not called yet. It is the planned one-time
    /// migration step for systems where an older tinyproxy-based installation
    /// already created the legacy whitelist file.
    static func migrateWhitelistForBuiltInProxyIfNeeded() throws {
        let fileManager = FileManager.default
        let legacyURL = ExamManagerPaths.whitelist
        let targetURL = ExamManagerPaths.managedWhitelist

        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        guard !fileManager.fileExists(atPath: targetURL.path) else { return }

        try fileManager.copyItem(at: legacyURL, to: targetURL)
    }
}
