import Foundation
import CoreFoundation

/// Reads the exam mode state from a managed MDM configuration profile.
///
/// The profile must deploy a key `ExamModeEnabled` (Boolean) under the
/// application domain `de.twocent.exam`. When deployed via Jamf or another
/// MDM the value lands in the managed (any-user / current-host) preference
/// layer, which is the only layer this reader checks.
///
/// Example profile payload:
/// ```xml
/// <key>PayloadType</key>
/// <string>de.twocent.exam</string>
/// <key>ExamModeEnabled</key>
/// <true/>
/// ```
public struct ConfigProfileReader {
    public struct DiagnosticSnapshot: Sendable {
        public let examModeEnabled: String
        public let proxyBackend: String
        public let whitelistCount: Int
        public let sourceDescription: String
    }

    public enum ProxyBackend: String, Sendable {
        case internalProxy = "internal"
        case tinyproxy
        case proxyless
    }

    public static let domain = "de.twocent.exam" as CFString
    public static let key    = "ExamModeEnabled" as CFString
    public static let proxyBackendKey = "ExamProxyBackend" as CFString
    public static let proxyWhitelistKey = "ExamProxyWhitelist" as CFString
    public static let verboseLoggingKey = "ExamVerboseLogging" as CFString

    public init() {}

    /// Returns the current value of `ExamModeEnabled` from the managed
    /// preference layer. Returns `nil` when the key is not present in
    /// any managed layer (profile not deployed or key absent).
    public func readExamModeEnabled() -> Bool? {
        guard let value = Self.managedValue(for: Self.key) else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            let booleanValue = unsafeBitCast(value, to: CFBoolean.self)
            return CFBooleanGetValue(booleanValue)
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        return nil
    }

    /// Convenience: returns `false` when the key is absent (safe default).
    public var examModeEnabled: Bool {
        readExamModeEnabled() ?? false
    }

    public func readProxyBackend() -> ProxyBackend? {
        guard let value = Self.managedValue(for: Self.proxyBackendKey) as? String else {
            return nil
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "internal", "builtin", "built-in", "examproxy":
            return .internalProxy
        case "tinyproxy":
            return .tinyproxy
        case "proxyless", "fallback", "bypass":
            return .proxyless
        default:
            return nil
        }
    }

    /// Defaults to the built-in Swift proxy. `tinyproxy` remains available as
    /// an explicit compatibility override through managed preferences.
    public var proxyBackend: ProxyBackend {
        readProxyBackend() ?? .internalProxy
    }

    public func readProxyWhitelist() -> [String]? {
        guard let values = Self.managedValue(for: Self.proxyWhitelistKey) as? [Any] else {
            return nil
        }

        let normalized = values
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return normalized.isEmpty ? nil : normalized
    }

    public var proxyWhitelist: [String] {
        readProxyWhitelist() ?? []
    }

    public func readVerboseLogging() -> Bool? {
        guard let value = Self.managedValue(for: Self.verboseLoggingKey) else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            let booleanValue = unsafeBitCast(value, to: CFBoolean.self)
            return CFBooleanGetValue(booleanValue)
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        return nil
    }

    public var verboseLogging: Bool {
        readVerboseLogging() ?? false
    }

    public func diagnosticSnapshot() -> DiagnosticSnapshot {
        let examModeValue = Self.debugValueDescription(for: Self.key)
        let backendValue = Self.debugValueDescription(for: Self.proxyBackendKey)
        let whitelistValue = Self.debugArrayCount(for: Self.proxyWhitelistKey)
        let verboseValue = Self.debugValueDescription(for: Self.verboseLoggingKey)
        let sourceDescription = Self.availableManagedPreferencePaths().joined(separator: ", ")

        return DiagnosticSnapshot(
            examModeEnabled: "\(examModeValue)|verbose=\(verboseValue)",
            proxyBackend: backendValue,
            whitelistCount: whitelistValue,
            sourceDescription: sourceDescription.isEmpty ? "none" : sourceDescription
        )
    }

    private static func managedValue(for key: CFString) -> AnyObject? {
        if let cfValue = managedCFPreferenceValue(for: key) {
            return cfValue
        }

        let keyString = key as String
        for url in managedPreferenceURLs() {
            guard
                let dictionary = NSDictionary(contentsOf: url) as? [String: Any],
                let value = dictionary[keyString]
            else {
                continue
            }
            return value as AnyObject
        }

        return nil
    }

    private static func debugValueDescription(for key: CFString) -> String {
        guard let value = managedValue(for: key) else {
            return "nil"
        }

        if let string = value as? String {
            return string
        }

        if let array = value as? [Any] {
            return "array(\(array.count))"
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }

        return String(describing: value)
    }

    private static func debugArrayCount(for key: CFString) -> Int {
        guard let values = managedValue(for: key) as? [Any] else {
            return 0
        }
        return values.compactMap { $0 as? String }.count
    }

    private static func availableManagedPreferencePaths() -> [String] {
        managedPreferenceURLs()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    private static func managedCFPreferenceValue(for key: CFString) -> AnyObject? {
        CFPreferencesSynchronize(
            Self.domain,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )

        return CFPreferencesCopyValue(
            key,
            Self.domain,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )
    }

    private static func managedPreferenceURLs() -> [URL] {
        let domainName = domain as String
        let baseURL = URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
        let preferencesURL = URL(fileURLWithPath: "/Library/Preferences", isDirectory: true)
        let fileManager = FileManager.default

        var urls: [URL] = [
            baseURL.appendingPathComponent("\(domainName).plist", isDirectory: false),
            preferencesURL.appendingPathComponent("\(domainName).plist", isDirectory: false)
        ]

        if let contents = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in contents {
                guard
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                else {
                    continue
                }

                urls.append(item.appendingPathComponent("\(domainName).plist", isDirectory: false))
            }
        }

        return urls
    }
}
