import Foundation

public struct ConsoleLogger: PlistStoreLogger {
    public init() {}

    public func warn(_ message: String) {
        fputs("warning: \(message)\n", stderr)
    }
}
