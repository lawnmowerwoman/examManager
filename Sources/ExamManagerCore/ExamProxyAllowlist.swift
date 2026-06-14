import Foundation

/// Matching helper for the future built-in exam proxy.
///
/// The implementation is intentionally lightweight for now. It mirrors the
/// host-focused allowlist model already used by the current tinyproxy setup.
public struct ExamProxyAllowlist {
    private let entries: [String]

    public init(entries: [String]) {
        self.entries = entries
    }

    public func allows(host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for entry in entries {
            let normalizedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedEntry.isEmpty else { continue }

            if normalizedEntry == normalizedHost {
                return true
            }

            // Very small wildcard approximation for the current allowlist style.
            if normalizedEntry.hasPrefix("*.") {
                let suffix = String(normalizedEntry.dropFirst(1))
                if normalizedHost.hasSuffix(suffix) {
                    return true
                }
            }

             if matchesIPv4Wildcard(host: normalizedHost, pattern: normalizedEntry) {
                 return true
             }
        }

        return false
    }

    private func matchesIPv4Wildcard(host: String, pattern: String) -> Bool {
        let hostOctets = host.split(separator: ".")
        let patternOctets = pattern.split(separator: ".")

        guard hostOctets.count == 4, patternOctets.count == 4 else {
            return false
        }

        for (hostOctet, patternOctet) in zip(hostOctets, patternOctets) {
            let token = patternOctet.lowercased()
            if token == "*" || token == "x" {
                continue
            }

            if hostOctet != patternOctet {
                return false
            }
        }

        return true
    }
}
