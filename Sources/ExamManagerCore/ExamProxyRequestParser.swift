import Foundation

/// Minimal parser scaffold for proxy request prefaces.
///
/// The current implementation is intentionally forgiving and only extracts the
/// basic request shape so we can build the rest of the proxy architecture first.
public struct ExamProxyRequestParser {
    public init() {}

    public func parse(firstLine: String, headers: [String: String] = [:]) -> ExamProxyRequest {
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: " ")

        guard parts.count >= 2 else {
            return ExamProxyRequest(kind: .unsupported(firstLine: trimmed), headers: headers, rawFirstLine: trimmed)
        }

        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.1"

        if method == "CONNECT" {
            let segments = target.split(separator: ":", maxSplits: 1).map(String.init)
            if segments.count == 2, let port = Int(segments[1]) {
                return ExamProxyRequest(
                    kind: .connect(host: segments[0], port: port),
                    headers: headers,
                    rawFirstLine: trimmed
                )
            }
        }

        if let url = URL(string: target), url.scheme != nil {
            return ExamProxyRequest(
                kind: .http(method: method, targetURL: url, version: version),
                headers: headers,
                rawFirstLine: trimmed
            )
        }

        if let url = makeOriginFormURL(target: target, headers: headers) {
            return ExamProxyRequest(
                kind: .http(method: method, targetURL: url, version: version),
                headers: headers,
                rawFirstLine: trimmed
            )
        }

        return ExamProxyRequest(kind: .unsupported(firstLine: trimmed), headers: headers, rawFirstLine: trimmed)
    }

    private func makeOriginFormURL(target: String, headers: [String: String]) -> URL? {
        guard target.hasPrefix("/") else { return nil }
        guard let hostHeader = hostHeader(in: headers), !hostHeader.isEmpty else { return nil }

        let hostAndPort = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = inferredScheme(for: hostAndPort)
        return URL(string: "\(scheme)://\(hostAndPort)\(target)")
    }

    private func hostHeader(in headers: [String: String]) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare("Host") == .orderedSame {
            return value
        }
        return nil
    }

    private func inferredScheme(for hostHeader: String) -> String {
        if hostHeader.hasSuffix(":443") {
            return "https"
        }
        return "http"
    }
}
