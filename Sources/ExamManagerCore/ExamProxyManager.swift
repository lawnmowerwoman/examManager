import Foundation

/// Lifecycle manager for the built-in Swift exam proxy.
public final class ExamProxyManager {
    public struct ActivationResult: Sendable {
        public let mode: NetworkProxyManager.ActivationMode
        public let whitelistDomains: [String]
        public let tinyproxyInstalled: Bool
        public let tinyproxyVersion: String?

        public init(
            mode: NetworkProxyManager.ActivationMode,
            whitelistDomains: [String],
            tinyproxyInstalled: Bool,
            tinyproxyVersion: String?
        ) {
            self.mode = mode
            self.whitelistDomains = whitelistDomains
            self.tinyproxyInstalled = tinyproxyInstalled
            self.tinyproxyVersion = tinyproxyVersion
        }
    }

    private let logger: PlistStoreLogger?
    private let server: ExamProxyServer
    private let whitelistManager: ExamWhitelistManager

    public init(
        logger: PlistStoreLogger? = nil,
        server: ExamProxyServer? = nil
    ) {
        self.logger = logger
        self.server = server ?? ExamProxyServer(logger: logger)
        self.whitelistManager = ExamWhitelistManager(logger: logger)
    }

    public func enable(
        jamfProURL: String,
        profileWhitelist: [String] = [],
        verboseLogging: Bool = false
    ) throws -> ActivationResult {
        let whitelistDomains = try whitelistManager.prepareWhitelist(
            jamfProURL: jamfProURL,
            backend: .internalProxy,
            profileEntries: profileWhitelist
        )

        let tinyproxyInstalled = FileManager.default.fileExists(atPath: ExamManagerPaths.tinyproxyBinary.path)
        let tinyproxyVersion = tinyproxyInstalled ? installedTinyproxyVersion() : nil

        let configuration = try makeConfiguration(
            allowedHosts: whitelistDomains,
            verboseLogging: verboseLogging
        )

        do {
            try server.start(configuration: configuration)
            logger?.warn("[ExamProxyManager] Built-in proxy enabled")
            return ActivationResult(
                mode: .internalProxy,
                whitelistDomains: whitelistDomains,
                tinyproxyInstalled: tinyproxyInstalled,
                tinyproxyVersion: tinyproxyVersion
            )
        } catch {
            logger?.warn("[ExamProxyManager] Built-in proxy failed to start: \(error) – fallback mode")
            return ActivationResult(
                mode: .fallback,
                whitelistDomains: whitelistDomains,
                tinyproxyInstalled: tinyproxyInstalled,
                tinyproxyVersion: tinyproxyVersion
            )
        }
    }

    public func prepareProxylessActivation(
        jamfProURL: String,
        profileWhitelist: [String] = []
    ) throws -> ActivationResult {
        let whitelistDomains = try whitelistManager.prepareWhitelist(
            jamfProURL: jamfProURL,
            backend: .internalProxy,
            profileEntries: profileWhitelist
        )

        let tinyproxyInstalled = FileManager.default.fileExists(atPath: ExamManagerPaths.tinyproxyBinary.path)
        let tinyproxyVersion = tinyproxyInstalled ? installedTinyproxyVersion() : nil

        logger?.warn("[ExamProxyManager] Proxyless fallback prepared")
        return ActivationResult(
            mode: .fallback,
            whitelistDomains: whitelistDomains,
            tinyproxyInstalled: tinyproxyInstalled,
            tinyproxyVersion: tinyproxyVersion
        )
    }

    public func disable() {
        do {
            try server.stop()
            logger?.warn("[ExamProxyManager] Built-in proxy disabled")
        } catch ExamProxyServer.ProxyError.notRunning {
            // no-op
        } catch {
            logger?.warn("[ExamProxyManager] Failed to stop built-in proxy cleanly: \(error)")
        }
    }

    @discardableResult
    public func reloadAllowlist(
        jamfProURL: String,
        profileWhitelist: [String] = [],
        verboseLogging: Bool = false
    ) throws -> [String] {
        let whitelistDomains = try whitelistManager.prepareWhitelist(
            jamfProURL: jamfProURL,
            backend: .internalProxy,
            profileEntries: profileWhitelist
        )

        let configuration = try makeConfiguration(
            allowedHosts: whitelistDomains,
            verboseLogging: verboseLogging
        )
        server.reload(configuration: configuration)
        logger?.warn("[ExamProxyManager] Built-in proxy allowlist reloaded")
        return whitelistDomains
    }

    public func makeConfiguration(
        allowedHosts: [String],
        verboseLogging: Bool = false
    ) throws -> ExamProxyConfiguration {
        ExamProxyConfiguration(
            bindHost: NetworkProxyManager.proxyHost,
            bindPort: NetworkProxyManager.proxyPort,
            allowedHosts: allowedHosts,
            blockPageURL: nil,
            allowedConnectPorts: [443],
            maxConcurrentConnections: 100,
            verboseLogging: verboseLogging
        )
    }

    private func installedTinyproxyVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExamManagerPaths.tinyproxyBinary.path)
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}
