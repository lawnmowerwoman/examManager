import Foundation

public struct NotaryExamState: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case inactive
        case activating
        case active
        case deactivating
        case error
    }

    public enum ProxyMode: String, Codable, Sendable {
        case internalProxy
        case tinyproxy
        case fallback
        case unavailable
    }

    public var mode: Mode
    public var exit: Bool
    public var lastCommand: String?
    public var lastProfileEnabled: Bool?
    public var lastChangedAt: Date
    public var tinyproxyInstalled: Bool
    public var tinyproxyVersion: String?
    public var proxyMode: ProxyMode
    public var jamfComputerID: Int?
    public var jamfEAName: String?
    public var jamfEAID: Int?
    public var lastError: String?

    public init(
        mode: Mode = .inactive,
        exit: Bool = false,
        lastCommand: String? = nil,
        lastProfileEnabled: Bool? = nil,
        lastChangedAt: Date = Date(),
        tinyproxyInstalled: Bool = false,
        tinyproxyVersion: String? = nil,
        proxyMode: ProxyMode = .unavailable,
        jamfComputerID: Int? = nil,
        jamfEAName: String? = nil,
        jamfEAID: Int? = nil,
        lastError: String? = nil
    ) {
        self.mode = mode
        self.exit = exit
        self.lastCommand = lastCommand
        self.lastProfileEnabled = lastProfileEnabled
        self.lastChangedAt = lastChangedAt
        self.tinyproxyInstalled = tinyproxyInstalled
        self.tinyproxyVersion = tinyproxyVersion
        self.proxyMode = proxyMode
        self.jamfComputerID = jamfComputerID
        self.jamfEAName = jamfEAName
        self.jamfEAID = jamfEAID
        self.lastError = lastError
    }
}
