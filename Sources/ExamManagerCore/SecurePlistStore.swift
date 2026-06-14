import Darwin
import Foundation

/// Copied and adapted from the Notary project so this repository stays self-contained
/// until we extract a shared infrastructure package.
public final class SecurePlistStore<Value: Codable> {

    public enum StoreError: Error, CustomStringConvertible {
        case encodeFailed(Error)
        case decodeFailed(Error)
        case writeFailed(Error)
        case invalidDirectory(URL)
        case cannotEnsureDirectory(URL, Error)
        case cannotApplyAttributes(URL, Error)
        case lockFailed(URL, Error)

        public var description: String {
            switch self {
            case .encodeFailed(let error):
                return "Encode failed: \(error)"
            case .decodeFailed(let error):
                return "Decode failed: \(error)"
            case .writeFailed(let error):
                return "Write failed: \(error)"
            case .invalidDirectory(let url):
                return "Invalid directory: \(url.path)"
            case .cannotEnsureDirectory(let url, let error):
                return "Cannot ensure directory \(url.path): \(error)"
            case .cannotApplyAttributes(let url, let error):
                return "Cannot apply file attributes \(url.path): \(error)"
            case .lockFailed(let url, let error):
                return "Lock failed for \(url.path): \(error)"
            }
        }
    }

    private let rootURL: URL
    private let fallbackURLFactory: () -> URL
    private let logger: PlistStoreLogger?
    private let encoder: PropertyListEncoder
    private let decoder = PropertyListDecoder()
    private var didWarnAboutFallback = false

    public init(
        rootURL: URL,
        fallbackURLFactory: @escaping () -> URL,
        logger: PlistStoreLogger? = nil
    ) {
        self.rootURL = rootURL
        self.fallbackURLFactory = fallbackURLFactory
        self.logger = logger

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
    }

    private var isRoot: Bool {
        geteuid() == 0
    }

    public var effectiveURL: URL {
        if isRoot {
            return rootURL
        }

        let fallbackURL = fallbackURLFactory()
        if !didWarnAboutFallback {
            logger?.warn("Not running as root; using fallback plist path: \(fallbackURL.path)")
            didWarnAboutFallback = true
        }
        return fallbackURL
    }

    public func load() throws -> Value? {
        let url = effectiveURL
        let lock = FileLock(targetURL: url)
        do {
            try lock.lock(timeoutSeconds: 5)
        } catch {
            throw StoreError.lockFailed(url, error)
        }
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw StoreError.decodeFailed(error)
        }
    }

    public func save(_ value: Value) throws {
        let url = effectiveURL
        let directory = url.deletingLastPathComponent()
        try ensureDirectoryExists(directory)

        let lock = FileLock(targetURL: url)
        do {
            try lock.lock(timeoutSeconds: 5)
        } catch {
            throw StoreError.lockFailed(url, error)
        }
        defer { lock.unlock() }

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreError.encodeFailed(error)
        }

        do {
            try atomicWrite(data: data, to: url)
            try applySecureAttributes(to: url)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error)
        }
    }

    public func delete() throws {
        let url = effectiveURL
        let lock = FileLock(targetURL: url)
        do {
            try lock.lock(timeoutSeconds: 5)
        } catch {
            throw StoreError.lockFailed(url, error)
        }
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }

    public func enforceSecurityIfPresent() throws {
        let url = effectiveURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try applySecureAttributes(to: url)
    }

    private func ensureDirectoryExists(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StoreError.invalidDirectory(directory)
            }
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.cannotEnsureDirectory(directory, error)
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL, options: [.completeFileProtectionUnlessOpen])
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw StoreError.writeFailed(error)
        }
    }

    private func applySecureAttributes(to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o600)
        ]

        if isRoot {
            attributes[.ownerAccountID] = NSNumber(value: 0)
            attributes[.groupOwnerAccountID] = NSNumber(value: 0)
        }

        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw StoreError.cannotApplyAttributes(url, error)
        }
    }

    private final class FileLock {
        private let lockURL: URL
        private var fileDescriptor: Int32 = -1

        init(targetURL: URL) {
            self.lockURL = targetURL.appendingPathExtension("lock")
        }

        func lock(timeoutSeconds: TimeInterval?) throws {
            fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fileDescriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            guard let timeoutSeconds else {
                if flock(fileDescriptor, LOCK_EX) != 0 {
                    let error = errno
                    close(fileDescriptor)
                    fileDescriptor = -1
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
                }
                return
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while true {
                if try tryLockOnce() {
                    return
                }

                if Date() >= deadline {
                    close(fileDescriptor)
                    fileDescriptor = -1
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
                }

                usleep(50_000)
            }
        }

        private func tryLockOnce() throws -> Bool {
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return true
            }

            if errno == EWOULDBLOCK {
                return false
            }

            let error = errno
            close(fileDescriptor)
            fileDescriptor = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }

        func unlock() {
            guard fileDescriptor >= 0 else {
                return
            }
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }

        deinit {
            unlock()
        }
    }
}
