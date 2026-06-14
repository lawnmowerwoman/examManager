import Foundation

/// Manages the tinyproxy LaunchDaemon lifecycle and its configuration,
/// ported 1:1 from the original shell script logic.
public struct TinyproxyManager {

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

    // MARK: – Paths (matches ExamManagerPaths + shell script)

    private static let managementDirectory  = ExamManagerPaths.managementDirectory.path
    private static let managementBinDirectory = ExamManagerPaths.managementBinaryDirectory.path
    private static let proxyBinary          = ExamManagerPaths.tinyproxyBinary.path
    private static let proxyConfDirectory   = ExamManagerPaths.tinyproxyConfigDirectory.path
    private static let proxyConfig          = ExamManagerPaths.tinyproxyConfig.path
    private static let whitelist            = ExamManagerPaths.whitelist.path
    private static let defaultErrorFile     = ExamManagerPaths.tinyproxyDefaultErrorPage.path
    /// Label for the tinyproxy LaunchDaemon.
    public static let daemonLabel           = "de.twocent.exam.tinyproxy"
    private static let daemonPlist          = "/Library/LaunchDaemons/\(daemonLabel).plist"

    private let logger: PlistStoreLogger?
    private let whitelistManager: ExamWhitelistManager

    public init(logger: PlistStoreLogger? = nil) {
        self.logger = logger
        self.whitelistManager = ExamWhitelistManager(logger: logger)
    }

    // MARK: – Public API

    /// Full enable sequence matching the shell script `enable` case,
    /// including fallback mode when tinyproxy is missing or cannot be started.
    public func enable(jamfProURL: String, profileWhitelist: [String] = []) throws -> ActivationResult {
        try ensureDirectories()
        let whitelistDomains = try whitelistManager.prepareWhitelist(
            jamfProURL: jamfProURL,
            backend: .tinyproxy,
            profileEntries: profileWhitelist
        )

        let tinyproxyInstalled = FileManager.default.fileExists(atPath: Self.proxyBinary)
        let tinyproxyVersion = tinyproxyInstalled ? installedTinyproxyVersion() : nil

        guard tinyproxyInstalled else {
            logger?.warn("tinyproxy binary missing at \(Self.proxyBinary) – fallback mode")
            return ActivationResult(
                mode: .fallback,
                whitelistDomains: whitelistDomains,
                tinyproxyInstalled: false,
                tinyproxyVersion: nil
            )
        }

        removeQuarantine(Self.proxyBinary)
        try ensureDefaultErrorPage()
        try writeProxyConfig()
        try applyPermissions()

        // Stop any stale instance before (re)starting
        bootoutIfLoaded(plist: Self.daemonPlist, label: Self.daemonLabel)
        try writeTinyproxyDaemonPlist()
        try launchctl("bootstrap", "system", Self.daemonPlist)
        Thread.sleep(forTimeInterval: 2)

        // Verify daemon came up; otherwise keep exam mode via fallback proxy settings.
        if !isDaemonRunning(label: Self.daemonLabel) {
            logger?.warn("tinyproxy LaunchDaemon failed – fallback mode")
            return ActivationResult(
                mode: .fallback,
                whitelistDomains: whitelistDomains,
                tinyproxyInstalled: true,
                tinyproxyVersion: tinyproxyVersion
            )
        }

        logger?.warn("tinyproxy enabled – daemon running")
        return ActivationResult(
            mode: .tinyproxy,
            whitelistDomains: whitelistDomains,
            tinyproxyInstalled: true,
            tinyproxyVersion: tinyproxyVersion
        )
    }

    /// Full disable sequence matching the shell script `disable` case.
    public func disable() throws {
        bootoutIfLoaded(plist: Self.daemonPlist,     label: Self.daemonLabel)
        Thread.sleep(forTimeInterval: 1)
        removeFile(Self.daemonPlist)

        logger?.warn("tinyproxy disabled – daemon stopped")
    }

    @discardableResult
    public func reloadAllowlist(jamfProURL: String, profileWhitelist: [String] = []) throws -> [String] {
        let whitelistDomains = try whitelistManager.prepareWhitelist(
            jamfProURL: jamfProURL,
            backend: .tinyproxy,
            profileEntries: profileWhitelist
        )

        if isDaemonRunning(label: Self.daemonLabel) {
            do {
                try launchctl("kill", "HUP", "system/\(Self.daemonLabel)")
                logger?.warn("tinyproxy received SIGHUP for allowlist reload")
            } catch {
                logger?.warn("tinyproxy SIGHUP reload failed: \(error)")
            }
        } else {
            logger?.warn("tinyproxy allowlist rewritten while daemon is inactive")
        }

        return whitelistDomains
    }

    // MARK: – Setup helpers

    private func ensureDirectories() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.managementBinDirectory) {
            try fm.createDirectory(atPath: Self.managementBinDirectory,
                                   withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: Self.proxyConfDirectory) {
            try fm.createDirectory(atPath: Self.proxyConfDirectory,
                                   withIntermediateDirectories: true)
        }
    }

    private func ensureDefaultErrorPage() throws {
        try ExamModeAssetInstaller.installAssets(into: URL(fileURLWithPath: Self.proxyConfDirectory, isDirectory: true))
    }

    private func writeProxyConfig() throws {
        let config = """
## tinyproxy.conf – managed by exam-manager-daemon
User nobody
Group nobody
Port 8888
Timeout 600
ErrorFile 403 "/Library/Management/lib/tinyproxy/default.html"
    DefaultErrorFile "/Library/Management/lib/tinyproxy/default.html"
LogLevel Info
upstream none "."
MaxClients 100
Allow 127.0.0.1
Allow ::1
ViaProxyName "tinyproxy"
FilterType fnmatch
Filter "/Library/Management/lib/tinyproxy/whitelist"
FilterDefaultDeny Yes
"""
        try config.write(toFile: Self.proxyConfig, atomically: true, encoding: .utf8)
    }

    private func applyPermissions() throws {
        // root:wheel 644 on config files, root:admin 775 on management dir
        try setOwnerAndPermissions(path: Self.whitelist,           uid: 0, gid: 0, mode: 0o644)
        try setOwnerAndPermissions(path: Self.proxyConfig,         uid: 0, gid: 0, mode: 0o644)
        try setOwnerAndPermissions(path: Self.defaultErrorFile,    uid: 0, gid: 0, mode: 0o644)
        try setOwnerAndPermissions(path: Self.managementDirectory, uid: 0, gid: 80, mode: 0o775)

        // Hide the bin and lib subdirectories (chflags hidden)
        hideItem(atPath: Self.managementBinDirectory)
        hideItem(atPath: "\(Self.managementDirectory)/lib")
    }

    // MARK: – LaunchDaemon plists

    private func writeTinyproxyDaemonPlist() throws {
        let dict: NSDictionary = [
            "Label":            Self.daemonLabel,
            "ProgramArguments": [Self.proxyBinary, "-d", "-c", Self.proxyConfig],
            "RunAtLoad":        true,
            "KeepAlive":        true,
            "WorkingDirectory": Self.managementDirectory
        ]
        try writePlist(dict, to: Self.daemonPlist)
    }

    // MARK: – launchctl helpers

    @discardableResult
    private func launchctl(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw TinyproxyError.launchctlFailed(args: args, status: process.terminationStatus, output: output)
        }
        return output
    }

    private func bootoutIfLoaded(plist: String, label: String) {
        guard FileManager.default.fileExists(atPath: plist) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "system", plist]
        try? process.run()
        process.waitUntilExit()
    }

    private func installedTinyproxyVersion() -> String? {
        guard FileManager.default.fileExists(atPath: Self.proxyBinary) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.proxyBinary)
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

    private func isDaemonRunning(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        try? process.run()
        process.waitUntilExit()
        // Exit 0 means the service is known to launchd
        return process.terminationStatus == 0
    }

    // MARK: – File helpers

    private func writePlist(_ dict: NSDictionary, to path: String) throws {
        let url  = URL(fileURLWithPath: path)
        let data = try PropertyListSerialization.data(fromPropertyList: dict,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: url, options: .atomic)
        try setOwnerAndPermissions(path: path, uid: 0, gid: 0, mode: 0o644)
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func removeQuarantine(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    private func setOwnerAndPermissions(path: String, uid: UInt32, gid: UInt32, mode: UInt16) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.setAttributes([
            .ownerAccountID:      NSNumber(value: uid),
            .groupOwnerAccountID: NSNumber(value: gid),
            .posixPermissions:    NSNumber(value: mode)
        ], ofItemAtPath: path)
    }

    private func hideItem(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        p.arguments = ["hidden", path]
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: – Errors

public enum TinyproxyError: Error, CustomStringConvertible {
    case daemonStartFailed
    case launchctlFailed(args: [String], status: Int32, output: String)

    public var description: String {
        switch self {
        case .daemonStartFailed:
            return "tinyproxy LaunchDaemon failed to start – exam mode NOT active"
        case .launchctlFailed(let args, let status, let out):
            return "launchctl \(args.joined(separator: " ")) exited \(status): \(out)"
        }
    }
}
