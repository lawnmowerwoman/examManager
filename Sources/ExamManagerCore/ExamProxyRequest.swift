import Foundation

/// Parsed representation of the minimum proxy request shapes we want to support.
public struct ExamProxyRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case http(method: String, targetURL: URL, version: String)
        case connect(host: String, port: Int)
        case unsupported(firstLine: String)
    }

    public let kind: Kind
    public let headers: [String: String]
    public let rawFirstLine: String

    public init(kind: Kind, headers: [String: String] = [:], rawFirstLine: String) {
        self.kind = kind
        self.headers = headers
        self.rawFirstLine = rawFirstLine
    }
}
