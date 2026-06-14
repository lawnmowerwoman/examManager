import Foundation

/// Manages system-wide HTTP/HTTPS proxy settings via `networksetup`,
/// mirroring exactly what the legacy shell script did.
public struct NetworkProxyManager {
    private static let networksetupPath = ExamManagerPaths.networksetupBinary.path

    public enum ActivationMode: Sendable {
        case internalProxy
        case tinyproxy
        case fallback
    }

    public static let proxyHost = "127.0.0.1"
    public static let proxyPort = 8888
    public static let fallbackWebPort = 80
    public static let fallbackSecurePort = 443

    /// Bypass domains applied whenever the proxy is active.
    public static let bypassDomains = ["127.0.0.1", "localhost", "*.local", "169.254/16", "10/8", "17/8"]

    /// Bypass domains applied when the proxy is removed (minimal set).
    public static let bypassDomainsOff = ["*.local", "169.254/16"]

    public init() {}

    // MARK: – Public API

    /// Enables the proxy on every active network interface.
    public func enable(mode: ActivationMode, whitelistDomains: [String] = []) throws {
        let interfaces = try activeInterfaces()
        let bypassDomains = bypassDomains(for: mode, whitelistDomains: whitelistDomains)

        for iface in interfaces {
            let ports = ports(for: mode)
            try run(Self.networksetupPath, "-setwebproxy",          iface, Self.proxyHost, "\(ports.web)")
            try run(Self.networksetupPath, "-setsecurewebproxy",    iface, Self.proxyHost, "\(ports.secure)")
            try run(Self.networksetupPath, "-setwebproxystate",     iface, "on")
            try run(Self.networksetupPath, "-setsecurewebproxystate", iface, "on")
            try run(Self.networksetupPath, "-setproxybypassdomains", iface, bypassDomains)
        }
    }

    /// Disables the proxy on every active network interface.
    public func disable() throws {
        let interfaces = try activeInterfaces()
        for iface in interfaces {
            try run(Self.networksetupPath, "-setwebproxystate",       iface, "off")
            try run(Self.networksetupPath, "-setsecurewebproxystate", iface, "off")
            try run(Self.networksetupPath, "-setproxybypassdomains",  iface, Self.bypassDomainsOff)
        }
    }

    /// Returns true when at least one active service currently points to the
    /// local exam-mode proxy endpoints.
    public func isEnabled() -> Bool {
        guard let interfaces = try? activeInterfaces() else { return false }

        for iface in interfaces {
            guard
                let web = try? proxySettings(flag: "-getwebproxy", interface: iface),
                let secure = try? proxySettings(flag: "-getsecurewebproxy", interface: iface)
            else {
                continue
            }

            let usesExamProxy =
                web.enabled &&
                secure.enabled &&
                web.server == Self.proxyHost &&
                secure.server == Self.proxyHost &&
                [Self.proxyPort, Self.fallbackWebPort].contains(web.port) &&
                [Self.proxyPort, Self.fallbackSecurePort].contains(secure.port)

            if usesExamProxy {
                return true
            }
        }

        return false
    }

    // MARK: – Helpers

    /// Returns all network service names that are not disabled.
    private func activeInterfaces() throws -> [String] {
        let output = try shell("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.contains("service is disabled") }
    }

    private func ports(for mode: ActivationMode) -> (web: Int, secure: Int) {
        switch mode {
        case .internalProxy, .tinyproxy:
            return (Self.proxyPort, Self.proxyPort)
        case .fallback:
            return (Self.fallbackWebPort, Self.fallbackSecurePort)
        }
    }

    private func bypassDomains(for mode: ActivationMode, whitelistDomains: [String]) -> [String] {
        switch mode {
        case .internalProxy, .tinyproxy:
            return deduplicated(Self.bypassDomains + managedBypassDomains(from: whitelistDomains))
        case .fallback:
            return deduplicated(Self.bypassDomains + whitelistDomains)
        }
    }

    private func managedBypassDomains(from whitelistDomains: [String]) -> [String] {
        let defaultWildcards = Set(["*.jamfcloud.com", "*.apple.com", "*.icloud.com"])
        var selected: [String] = []

        if let jamfHost = whitelistDomains.first(where: { !$0.hasPrefix("*.") && !$0.contains("/") && !$0.isEmpty }) {
            selected.append(jamfHost)
        }

        selected.append(contentsOf: whitelistDomains.filter { defaultWildcards.contains($0) })
        return deduplicated(selected)
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func proxySettings(flag: String, interface: String) throws -> ProxySettings {
        let output = try shell("/usr/sbin/networksetup", [flag, interface])
        var enabled = false
        var server = ""
        var port = 0

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.localizedCaseInsensitiveContains("yes")
            } else if trimmed.hasPrefix("Server:") {
                server = trimmed.replacingOccurrences(of: "Server:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("Port:") {
                let raw = trimmed.replacingOccurrences(of: "Port:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                port = Int(raw) ?? 0
            }
        }

        return ProxySettings(enabled: enabled, server: server, port: port)
    }

    private struct ProxySettings {
        let enabled: Bool
        let server: String
        let port: Int
    }

    // MARK: – Process helpers

    /// Runs a command with a flat list of arguments.
    @discardableResult
    private func run(_ executable: String, _ args: String...) throws -> String {
        try shell(executable, args)
    }

    /// Runs a command where the last argument is a list (e.g. bypass domains).
    @discardableResult
    private func run(_ executable: String, _ flag: String, _ iface: String, _ list: [String]) throws -> String {
        var args = [flag, iface]
        args.append(contentsOf: list)
        return try shell(executable, args)
    }

    @discardableResult
    private func shell(_ executable: String, _ args: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        try process.run()
        process.waitUntilExit()

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw NetworkProxyError.commandFailed(
                executable: executable,
                args: args,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}

public enum NetworkProxyError: Error, CustomStringConvertible {
    case commandFailed(executable: String, args: [String], status: Int32, output: String)

    public var description: String {
        switch self {
        case let .commandFailed(exe, args, status, out):
            return "\(exe) \(args.joined(separator: " ")) exited \(status): \(out)"
        }
    }
}
