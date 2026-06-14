import Darwin
import Foundation
import Network

/// Minimal bidirectional tunnel used for allowed CONNECT requests.
///
/// The upstream leg deliberately uses a raw POSIX TCP socket instead of
/// `NWConnection`. This avoids any chance that the daemon's own upstream
/// traffic re-enters the system proxy path while exam mode is active.
public final class ExamProxyTunnel {
    public typealias Logger = @Sendable (String) -> Void
    public typealias Completion = @Sendable () -> Void

    private let clientConnection: NWConnection
    private let host: String
    private let port: Int
    private let initialClientData: Data
    private let queue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let timeoutInterval: TimeInterval
    private let logger: Logger?
    private let completion: Completion
    private let lock = NSLock()
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var socketFD: Int32 = -1
    private var socketReadSource: DispatchSourceRead?

    public init(
        clientConnection: NWConnection,
        host: String,
        port: Int,
        initialClientData: Data = Data(),
        queue: DispatchQueue,
        timeoutInterval: TimeInterval,
        logger: Logger? = nil,
        completion: @escaping Completion
    ) {
        precondition((1...65_535).contains(port), "CONNECT port must be in the valid TCP range")

        self.clientConnection = clientConnection
        self.host = host
        self.port = port
        self.initialClientData = initialClientData
        self.queue = queue
        self.ioQueue = DispatchQueue(label: "de.twocent.exam.proxy.tunnel.\(UUID().uuidString)")
        self.timeoutInterval = timeoutInterval
        self.logger = logger
        self.completion = completion
    }

    public func start() {
        scheduleIdleTimeout()
        ioQueue.async { [weak self] in
            self?.connectUpstream()
        }
    }

    public func stop() {
        finish()
    }

    private func connectUpstream() {
        do {
            socketFD = try openConnectedSocket(host: host, port: port)
            logger?("CONNECT upstream is ready")
            scheduleIdleTimeout()
            sendConnectEstablished()
        } catch {
            logger?("CONNECT upstream failed: \(error.localizedDescription)")
            sendFailureAndFinish()
        }
    }

    private func sendConnectEstablished() {
        let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }

            if let error {
                self.logger?("Failed to acknowledge CONNECT request: \(error.localizedDescription)")
                self.finish()
                return
            }

            self.forwardInitialClientDataIfNeeded()
        })
    }

    private func forwardInitialClientDataIfNeeded() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            if !self.initialClientData.isEmpty {
                do {
                    try self.writeAll(self.initialClientData)
                } catch {
                    self.logger?("Forwarding buffered CONNECT payload failed: \(error.localizedDescription)")
                    self.finish()
                    return
                }
            }

            self.scheduleIdleTimeout()
            self.startBidirectionalRelay()
        }
    }

    private func startBidirectionalRelay() {
        installSocketReadSource()
        receiveFromClient()
    }

    private func receiveFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger?("Tunnel client->upstream receive error: \(error.localizedDescription)")
                self.finish()
                return
            }

            if let data, !data.isEmpty {
                self.ioQueue.async { [weak self] in
                    guard let self else { return }

                    do {
                        try self.writeAll(data)
                        self.scheduleIdleTimeout()
                        if isComplete {
                            self.finish()
                        } else {
                            self.receiveFromClient()
                        }
                    } catch {
                        self.logger?("Tunnel client->upstream send error: \(error.localizedDescription)")
                        self.finish()
                    }
                }
                return
            }

            if isComplete {
                self.finish()
                return
            }

            self.receiveFromClient()
        }
    }

    private func installSocketReadSource() {
        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: ioQueue)
        socketReadSource = readSource

        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.readFromUpstream()
        }

        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.socketFD >= 0 {
                Darwin.close(self.socketFD)
                self.socketFD = -1
            }
        }

        readSource.resume()
    }

    private func readFromUpstream() {
        guard socketFD >= 0 else {
            finish()
            return
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let bytesRead = recv(socketFD, &buffer, buffer.count, 0)

        if bytesRead > 0 {
            let data = Data(buffer.prefix(Int(bytesRead)))
            scheduleIdleTimeout()
            clientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }

                if let error {
                    self.logger?("Tunnel upstream->client send error: \(error.localizedDescription)")
                    self.finish()
                }
            })
            return
        }

        if bytesRead == 0 {
            finish()
            return
        }

        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
            return
        }

        logger?("Tunnel upstream->client receive error: \(String(cString: strerror(code)))")
        finish()
    }

    private func writeAll(_ data: Data) throws {
        guard socketFD >= 0 else {
            throw TunnelError.socketUnavailable
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: offset)
                let written = Darwin.write(socketFD, pointer, bytesRemaining)

                if written > 0 {
                    offset += written
                    bytesRemaining -= written
                    continue
                }

                if written == -1 && errno == EINTR {
                    continue
                }

                if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                throw TunnelError.writeFailed(code: errno)
            }
        }
    }

    private func openConnectedSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let status = getaddrinfo(host, service, &hints, &result)
        guard status == 0, let first = result else {
            throw TunnelError.addressResolutionFailed(message: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }

        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = pointer {
            let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            if fd >= 0 {
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return fd
                }

                Darwin.close(fd)
            }

            pointer = candidate.pointee.ai_next
        }

        throw TunnelError.connectFailed(code: errno)
    }

    private func sendFailureAndFinish() {
        let response = Data(
            """
            HTTP/1.1 502 Bad Gateway\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: 39\r
            Connection: close\r
            \r
            Unable to establish CONNECT upstream.
            """.utf8
        )

        clientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        let readSource = socketReadSource
        socketReadSource = nil
        let shouldCloseSocket = socketFD >= 0
        lock.unlock()

        guard shouldFinish else { return }

        timeoutWorkItem?.cancel()
        if shouldCloseSocket {
            readSource?.cancel()
            if readSource == nil, socketFD >= 0 {
                Darwin.close(socketFD)
                socketFD = -1
            }
        }
        clientConnection.cancel()
        completion()
    }

    private func scheduleIdleTimeout() {
        guard timeoutInterval > 0 else { return }

        lock.lock()
        timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.logger?("CONNECT tunnel timed out after \(Int(self.timeoutInterval))s of inactivity")
            self.finish()
        }
        timeoutWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
}

private enum TunnelError: LocalizedError {
    case socketUnavailable
    case addressResolutionFailed(message: String)
    case connectFailed(code: Int32)
    case writeFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .socketUnavailable:
            return "Upstream socket is unavailable"
        case .addressResolutionFailed(let message):
            return "Address resolution failed: \(message)"
        case .connectFailed(let code):
            return "Connect failed: \(String(cString: strerror(code)))"
        case .writeFailed(let code):
            return "Write failed: \(String(cString: strerror(code)))"
        }
    }
}
