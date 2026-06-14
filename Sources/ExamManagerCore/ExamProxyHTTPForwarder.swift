import Darwin
import Foundation
import Network

/// Minimal HTTP forwarder for proxy-style requests.
///
/// The upstream leg intentionally uses a raw POSIX TCP socket instead of
/// `NWConnection` so the daemon's own outbound traffic cannot re-enter the
/// system proxy path while exam mode is active.
public final class ExamProxyHTTPForwarder {
    public typealias Logger = @Sendable (String) -> Void
    public typealias Completion = @Sendable () -> Void

    private let clientConnection: NWConnection
    private let request: ExamProxyRequest
    private let initialRequestData: Data
    private let queue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let timeoutInterval: TimeInterval
    private let logger: Logger?
    private let completion: Completion
    private let lock = NSLock()
    private var finished = false
    private var remainingRequestBodyBytes = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var socketFD: Int32 = -1
    private var socketReadSource: DispatchSourceRead?

    public init(
        clientConnection: NWConnection,
        request: ExamProxyRequest,
        initialRequestData: Data,
        queue: DispatchQueue,
        timeoutInterval: TimeInterval,
        logger: Logger? = nil,
        completion: @escaping Completion
    ) {
        self.clientConnection = clientConnection
        self.request = request
        self.initialRequestData = initialRequestData
        self.queue = queue
        self.ioQueue = DispatchQueue(label: "de.twocent.exam.proxy.http.\(UUID().uuidString)")
        self.timeoutInterval = timeoutInterval
        self.logger = logger
        self.completion = completion
    }

    public func start() {
        scheduleIdleTimeout()
        ioQueue.async { [weak self] in
            self?.connectAndSendInitialRequest()
        }
    }

    public func stop() {
        finish()
    }

    private func connectAndSendInitialRequest() {
        do {
            let preparation = try prepareUpstreamRequest()
            remainingRequestBodyBytes = preparation.remainingBodyBytes

            guard case .http(_, let targetURL, _) = request.kind else {
                throw PreparationError.invalidRequest
            }

            let host = targetURL.host ?? "127.0.0.1"
            let port = targetURL.port ?? 80
            socketFD = try openConnectedSocket(host: host, port: port)
            logger?("HTTP upstream is ready")

            try writeAll(preparation.data)
            scheduleIdleTimeout()

            if remainingRequestBodyBytes > 0 {
                receiveAdditionalRequestBody()
            } else {
                startReceivingResponse()
            }
        } catch {
            logger?("HTTP upstream setup failed: \(error.localizedDescription)")
            sendFailureAndFinish()
        }
    }

    private func receiveAdditionalRequestBody() {
        guard remainingRequestBodyBytes > 0 else {
            startReceivingResponse()
            return
        }

        clientConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: min(remainingRequestBodyBytes, 65_536)
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger?("Receiving additional HTTP request body failed: \(error.localizedDescription)")
                self.finish()
                return
            }

            guard let data, !data.isEmpty else {
                self.logger?("HTTP request body ended before declared Content-Length was satisfied")
                self.finish()
                return
            }

            self.ioQueue.async { [weak self] in
                guard let self else { return }

                do {
                    try self.writeAll(data)
                    self.remainingRequestBodyBytes -= data.count
                    self.scheduleIdleTimeout()

                    if isComplete || self.remainingRequestBodyBytes <= 0 {
                        self.startReceivingResponse()
                    } else {
                        self.receiveAdditionalRequestBody()
                    }
                } catch {
                    self.logger?("Forwarding HTTP request body failed: \(error.localizedDescription)")
                    self.finish()
                }
            }
        }
    }

    private func startReceivingResponse() {
        installSocketReadSource()
    }

    private func installSocketReadSource() {
        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: ioQueue)
        socketReadSource = readSource

        readSource.setEventHandler { [weak self] in
            self?.readFromUpstream()
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
                    self.logger?("Sending HTTP response to client failed: \(error.localizedDescription)")
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

        logger?("Receiving upstream HTTP response failed: \(String(cString: strerror(code)))")
        finish()
    }

    private func prepareUpstreamRequest() throws -> (data: Data, remainingBodyBytes: Int) {
        guard
            let headerEndRange = findHeaderDelimiter(in: initialRequestData),
            let headerText = String(data: initialRequestData[..<headerEndRange.upperBound], encoding: .utf8),
            case .http(let method, let targetURL, let version) = request.kind
        else {
            throw PreparationError.invalidRequest
        }

        let normalizedHeaders = headerText.replacingOccurrences(of: "\r\n", with: "\n")
        let headerLines = normalizedHeaders.components(separatedBy: "\n")
        guard !headerLines.isEmpty else {
            throw PreparationError.invalidRequest
        }

        let bodyData = initialRequestData[headerEndRange.upperBound...]
        let forwardedPath = makeOriginFormPath(for: targetURL)
        var forwardedLines = ["\(method) \(forwardedPath) \(version)"]
        var sawHost = false
        var contentLength = 0

        for line in headerLines.dropFirst() {
            if line.isEmpty {
                continue
            }

            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let headerName = parts[0].trimmingCharacters(in: .whitespaces)
            let headerValue = parts[1].trimmingCharacters(in: .whitespaces)
            let lowercasedName = headerName.lowercased()

            switch lowercasedName {
            case "proxy-connection", "connection":
                continue
            case "host":
                sawHost = true
                forwardedLines.append("Host: \(makeHostHeaderValue(for: targetURL))")
            case "content-length":
                contentLength = Int(headerValue) ?? 0
                forwardedLines.append("\(headerName): \(headerValue)")
            default:
                forwardedLines.append("\(headerName): \(headerValue)")
            }
        }

        if !sawHost {
            forwardedLines.append("Host: \(makeHostHeaderValue(for: targetURL))")
        }

        forwardedLines.append("Connection: close")

        let headerPayload = forwardedLines.joined(separator: "\r\n") + "\r\n\r\n"
        var forwardedData = Data(headerPayload.utf8)
        forwardedData.append(bodyData)

        let remainingBodyBytes = max(contentLength - bodyData.count, 0)
        return (forwardedData, remainingBodyBytes)
    }

    private func findHeaderDelimiter(in data: Data) -> Range<Data.Index>? {
        if let range = data.range(of: Data([13, 10, 13, 10])) {
            return range
        }

        return data.range(of: Data([10, 10]))
    }

    private func makeOriginFormPath(for url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            return "\(path)?\(query)"
        }

        return path
    }

    private func makeHostHeaderValue(for url: URL) -> String {
        guard let host = url.host else {
            return "localhost"
        }

        if let port = url.port, port != 80 {
            return "\(host):\(port)"
        }

        return host
    }

    private func writeAll(_ data: Data) throws {
        guard socketFD >= 0 else {
            throw HTTPForwarderError.socketUnavailable
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

                throw HTTPForwarderError.writeFailed(code: errno)
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
            throw HTTPForwarderError.addressResolutionFailed(message: String(cString: gai_strerror(status)))
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

        throw HTTPForwarderError.connectFailed(code: errno)
    }

    private func sendFailureAndFinish() {
        let response = Data(
            """
            HTTP/1.1 502 Bad Gateway\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: 42\r
            Connection: close\r
            \r
            Unable to forward HTTP request upstream.
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
            self.logger?("HTTP forwarder timed out after \(Int(self.timeoutInterval))s of inactivity")
            self.finish()
        }
        timeoutWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
}

private enum PreparationError: Error {
    case invalidRequest
}

private enum HTTPForwarderError: LocalizedError {
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
