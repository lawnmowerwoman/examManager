import Foundation

public struct TinyproxyArtifact: Codable, Sendable, Equatable {
    public let version: String
    public let url: URL
    public let sha256: String

    public init(version: String, url: URL, sha256: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
    }
}
