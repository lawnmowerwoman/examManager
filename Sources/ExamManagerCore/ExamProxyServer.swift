import Foundation
import Network

/// First runnable built-in proxy listener dedicated to exam mode.
///
/// This stage deliberately accepts connections and returns deterministic dummy
/// responses. Real CONNECT tunneling and HTTP forwarding will be added in the
/// next iterations.
public final class ExamProxyServer {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    public enum ProxyError: Error, CustomStringConvertible {
        case alreadyRunning
        case notRunning
        case notImplemented(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "Exam proxy is already running"
            case .notRunning:
                return "Exam proxy is not running"
            case .notImplemented(let message):
                return message
            }
        }
    }

    private let logger: PlistStoreLogger?
    private let queue = DispatchQueue(label: "de.twocent.exam.proxy.listener")
    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private var activeHTTPForwarders: [UUID: ExamProxyHTTPForwarder] = [:]
    private var activeTunnels: [UUID: ExamProxyTunnel] = [:]
    private(set) public var state: State = .stopped
    private(set) public var configuration: ExamProxyConfiguration?

    public init(logger: PlistStoreLogger? = nil) {
        self.logger = logger
    }

    public func start(configuration: ExamProxyConfiguration) throws {
        guard case .stopped = state else {
            throw ProxyError.alreadyRunning
        }

        let listener = try makeListener(configuration: configuration)
        self.configuration = configuration
        state = .starting
        self.listener = listener
        installHandlers(on: listener)
        log("Exam proxy listener starting on \(configuration.bindHost):\(configuration.bindPort)")
        listener.start(queue: queue)
    }

    public func stop() throws {
        switch state {
        case .stopped:
            throw ProxyError.notRunning
        case .starting, .running, .stopping, .failed:
            state = .stopping
            log("Exam proxy listener stop requested")
            listener?.cancel()
            listener = nil

            for connection in activeConnections.values {
                connection.cancel()
            }
            activeConnections.removeAll()

            for forwarder in activeHTTPForwarders.values {
                forwarder.stop()
            }
            activeHTTPForwarders.removeAll()

            for tunnel in activeTunnels.values {
                tunnel.stop()
            }
            activeTunnels.removeAll()

            configuration = nil
            state = .stopped
        }
    }

    public func reload(configuration: ExamProxyConfiguration) {
        self.configuration = configuration
        log("Exam proxy configuration reloaded")
    }

    private func log(_ message: String) {
        logger?.warn("[ExamProxyServer] \(message)")
    }

    private func makeListener(configuration: ExamProxyConfiguration) throws -> NWListener {
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.bindPort)) else {
            throw ProxyError.notImplemented("Invalid proxy bind port \(configuration.bindPort)")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.bindHost),
            port: port
        )

        return try NWListener(using: parameters)
    }

    private func installHandlers(on listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }

            switch newState {
            case .ready:
                self.state = .running
                self.log("Exam proxy listener is ready")
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
                self.log("Exam proxy listener failed: \(error.localizedDescription)")
            case .cancelled:
                self.state = .stopped
                self.log("Exam proxy listener cancelled")
            case .waiting(let error):
                self.log("Exam proxy listener waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accept(connection: connection)
        }
    }

    private func accept(connection: NWConnection) {
        if let configuration, activeConnections.count >= configuration.maxConcurrentConnections {
            log("Connection limit reached (\(configuration.maxConcurrentConnections)) – rejecting proxy client")
            let response = makeOverloadedResponse()
            connection.start(queue: queue)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let identifier = UUID()
        activeConnections[identifier] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                self.logVerbose("Accepted proxy client \(identifier.uuidString)")
                self.receiveRequest(
                    on: connection,
                    identifier: identifier
                )
            case .failed(let error):
                self.logVerbose("Proxy client \(identifier.uuidString) failed: \(error.localizedDescription)")
                self.finish(connection: connection, identifier: identifier)
            case .cancelled:
                self.activeConnections.removeValue(forKey: identifier)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveRequest(
        on connection: NWConnection,
        identifier: UUID
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.logVerbose("Proxy client \(identifier.uuidString) receive error: \(error.localizedDescription)")
                self.finish(connection: connection, identifier: identifier)
                return
            }

            guard let data, !data.isEmpty else {
                self.logVerbose("Proxy client \(identifier.uuidString) closed before sending a request")
                self.finish(connection: connection, identifier: identifier)
                return
            }

            guard let configuration = self.configuration else {
                self.log("Proxy configuration missing while handling \(identifier.uuidString)")
                self.finish(connection: connection, identifier: identifier)
                return
            }

            let allowlist = ExamProxyAllowlist(entries: configuration.allowedHosts)
            let handler = ExamProxyConnectionHandler(allowlist: allowlist)

            guard let request = handler.parseRequest(from: data) else {
                let response = self.makeParseFailureResponse()
                self.send(response, on: connection, identifier: identifier)
                return
            }

            let decision = handler.evaluate(request)
            self.logDecision(decision, for: request)
            switch handler.plan(for: request, configuration: configuration) {
            case .forwardHTTP(let request):
                self.startHTTPForwarding(
                    clientConnection: connection,
                    identifier: identifier,
                    request: request,
                    initialData: data
                )
            case .respond(let response):
                self.send(response, on: connection, identifier: identifier)
            case .tunnel(let host, let port):
                let prefetchedData = self.trailingPayload(afterHeadersIn: data)
                self.startTunnel(
                    clientConnection: connection,
                    identifier: identifier,
                    host: host,
                    port: port,
                    initialClientData: prefetchedData
                )
            }
        }
    }

    private func send(_ response: Data, on connection: NWConnection, identifier: UUID) {
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }

            if let error {
                self.logVerbose("Proxy client \(identifier.uuidString) send error: \(error.localizedDescription)")
            }

            self.finish(connection: connection, identifier: identifier)
        })
    }

    private func finish(connection: NWConnection, identifier: UUID) {
        connection.cancel()
        activeConnections.removeValue(forKey: identifier)
        activeHTTPForwarders.removeValue(forKey: identifier)
        activeTunnels.removeValue(forKey: identifier)
    }

    private func makeParseFailureResponse() -> Data {
        Data(
            """
            HTTP/1.1 400 Bad Request\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: 28\r
            Connection: close\r
            \r
            Unable to parse proxy request
            """.utf8
        )
    }

    private func makeOverloadedResponse() -> Data {
        let body = "Exam proxy is temporarily busy\n"
        return Data(
            """
            HTTP/1.1 503 Service Unavailable\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """.utf8
        )
    }

    private func logDecision(_ decision: ExamProxyConnectionHandler.Decision, for request: ExamProxyRequest) {
        switch request.kind {
        case .http(let method, let targetURL, _):
            logVerbose("HTTP \(method) \(targetURL.absoluteString) -> \(decision)")
        case .connect(let host, let port):
            logVerbose("CONNECT \(host):\(port) -> \(decision)")
        case .unsupported(let firstLine):
            logVerbose("Unsupported request \(firstLine) -> \(decision)")
        }
    }

    private func startHTTPForwarding(
        clientConnection: NWConnection,
        identifier: UUID,
        request: ExamProxyRequest,
        initialData: Data
    ) {
        guard case .http(_, let targetURL, _) = request.kind else {
            let response = makeParseFailureResponse()
            send(response, on: clientConnection, identifier: identifier)
            return
        }

        logVerbose("Opening HTTP forwarder to \(targetURL.absoluteString)")

        let forwarder = ExamProxyHTTPForwarder(
            clientConnection: clientConnection,
            request: request,
            initialRequestData: initialData,
            queue: queue,
            timeoutInterval: configuration?.ioTimeout ?? 30,
            logger: { [weak self] message in
                self?.logVerbose("HTTP \(identifier.uuidString): \(message)")
            },
            completion: { [weak self] in
                guard let self else { return }
                self.logVerbose("HTTP forwarder \(identifier.uuidString) finished")
                self.activeHTTPForwarders.removeValue(forKey: identifier)
                self.activeConnections.removeValue(forKey: identifier)
            }
        )

        activeHTTPForwarders[identifier] = forwarder
        forwarder.start()
    }

    private func startTunnel(
        clientConnection: NWConnection,
        identifier: UUID,
        host: String,
        port: Int,
        initialClientData: Data
    ) {
        logVerbose("Opening CONNECT tunnel to \(host):\(port)")

        let tunnel = ExamProxyTunnel(
            clientConnection: clientConnection,
            host: host,
            port: port,
            initialClientData: initialClientData,
            queue: queue,
            timeoutInterval: configuration?.ioTimeout ?? 30,
            logger: { [weak self] message in
                self?.logVerbose("Tunnel \(identifier.uuidString): \(message)")
            },
            completion: { [weak self] in
                guard let self else { return }
                self.logVerbose("CONNECT tunnel \(identifier.uuidString) finished")
                self.activeTunnels.removeValue(forKey: identifier)
                self.activeConnections.removeValue(forKey: identifier)
            }
        )

        activeTunnels[identifier] = tunnel
        tunnel.start()
    }

    private func trailingPayload(afterHeadersIn data: Data) -> Data {
        guard let range = data.range(of: Data([13, 10, 13, 10])) ?? data.range(of: Data([10, 10])) else {
            return Data()
        }

        let trailingStart = range.upperBound
        guard trailingStart < data.endIndex else {
            return Data()
        }

        return Data(data[trailingStart...])
    }

    private func logVerbose(_ message: String) {
        guard configuration?.verboseLogging == true else { return }
        log(message)
    }
}
