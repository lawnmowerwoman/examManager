import Foundation

/// Configuration for the future built-in exam proxy.
///
/// This type is intentionally small and purpose-built. It represents only the
/// runtime parameters we currently need for exam mode, not a generic proxy
/// configuration language.
public struct ExamProxyConfiguration: Sendable, Equatable {
    public let bindHost: String
    public let bindPort: Int
    public let allowedHosts: [String]
    public let blockPageURL: URL?
    public let allowedConnectPorts: Set<Int>
    public let ioTimeout: TimeInterval
    public let maxConcurrentConnections: Int
    public let verboseLogging: Bool

    public init(
        bindHost: String = "127.0.0.1",
        bindPort: Int = 8888,
        allowedHosts: [String],
        blockPageURL: URL? = nil,
        allowedConnectPorts: Set<Int> = [443],
        ioTimeout: TimeInterval = 30,
        maxConcurrentConnections: Int = 64,
        verboseLogging: Bool = false
    ) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.allowedHosts = allowedHosts
        self.blockPageURL = blockPageURL
        self.allowedConnectPorts = allowedConnectPorts
        self.ioTimeout = ioTimeout
        self.maxConcurrentConnections = maxConcurrentConnections
        self.verboseLogging = verboseLogging
    }
}
