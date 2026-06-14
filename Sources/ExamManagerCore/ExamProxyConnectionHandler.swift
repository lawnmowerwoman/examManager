import Foundation

/// First per-connection decision helper for the built-in proxy.
///
/// At this stage we do not forward traffic yet. The handler only classifies
/// requests and produces deterministic dummy responses so the socket listener
/// can be exercised safely.
public struct ExamProxyConnectionHandler {
    public enum Decision: Sendable, Equatable {
        case allow
        case deny
        case unsupported
    }

    public enum Plan: Sendable, Equatable {
        case forwardHTTP(request: ExamProxyRequest)
        case tunnel(host: String, port: Int)
        case respond(Data)
    }

    private let allowlist: ExamProxyAllowlist
    private let parser = ExamProxyRequestParser()

    public init(allowlist: ExamProxyAllowlist) {
        self.allowlist = allowlist
    }

    public func parseRequest(from data: Data) -> ExamProxyRequest? {
        let headerData = headerSection(in: data)

        guard let requestText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let normalizedText = requestText.replacingOccurrences(of: "\r\n", with: "\n")
        let headerLines = normalizedText.components(separatedBy: "\n")
        guard let firstLine = headerLines.first, !firstLine.isEmpty else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            if line.isEmpty {
                break
            }

            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        return parser.parse(firstLine: firstLine, headers: headers)
    }

    private func headerSection(in data: Data) -> Data {
        if let range = data.range(of: Data([13, 10, 13, 10])) {
            return Data(data[..<range.lowerBound])
        }

        if let range = data.range(of: Data([10, 10])) {
            return Data(data[..<range.lowerBound])
        }

        return data
    }

    public func evaluate(_ request: ExamProxyRequest) -> Decision {
        switch request.kind {
        case .http(_, let targetURL, _):
            guard let host = targetURL.host else { return .unsupported }
            return allowlist.allows(host: host) ? .allow : .deny
        case .connect(let host, _):
            return allowlist.allows(host: host) ? .allow : .deny
        case .unsupported:
            return .unsupported
        }
    }

    public func plan(for request: ExamProxyRequest, configuration: ExamProxyConfiguration) -> Plan {
        let decision = evaluate(request)

        switch (request.kind, decision) {
        case (.http, .allow):
            return .forwardHTTP(request: request)
        case (.connect(let host, let port), .allow):
            if configuration.allowedConnectPorts.contains(port) {
                return .tunnel(host: host, port: port)
            }

            return .respond(
                makeTextResponse(
                    statusLine: "HTTP/1.1 403 Forbidden",
                    body: "CONNECT to port \(port) is not permitted."
                )
            )
        default:
            return .respond(
                responseData(
                    for: request,
                    decision: decision,
                    configuration: configuration
                )
            )
        }
    }

    public func responseData(
        for request: ExamProxyRequest,
        decision: Decision,
        configuration: ExamProxyConfiguration
    ) -> Data {
        switch (request.kind, decision) {
        case (.http(let method, let targetURL, _), .allow):
            return makeTextResponse(
                statusLine: "HTTP/1.1 501 Not Implemented",
                body: """
                Exam proxy listener is running.
                HTTP forwarding is not implemented yet.
                Method: \(method)
                Target: \(targetURL.absoluteString)
                """
            )
        case (.connect(let host, let port), .allow):
            if configuration.allowedConnectPorts.contains(port) {
                return makeTextResponse(
                    statusLine: "HTTP/1.1 501 Not Implemented",
                    body: """
                    Exam proxy listener is running.
                    CONNECT tunneling is not implemented yet.
                    Target: \(host):\(port)
                    """
                )
            }

            return makeTextResponse(
                statusLine: "HTTP/1.1 403 Forbidden",
                body: "CONNECT to port \(port) is not permitted."
            )
        case (.http, .deny):
            return makeHTMLResponse(
                statusLine: "HTTP/1.1 403 Forbidden",
                html: loadBlockPage(from: configuration.blockPageURL)
            )
        case (.connect(let host, let port), .deny):
            return makeTextResponse(
                statusLine: "HTTP/1.1 403 Forbidden",
                body: "Access denied for CONNECT \(host):\(port)."
            )
        case (.unsupported, _), (_, .unsupported):
            return makeTextResponse(
                statusLine: "HTTP/1.1 501 Not Implemented",
                body: "Unsupported proxy request: \(request.rawFirstLine)"
            )
        }
    }

    private func loadBlockPage(from fileURL: URL?) -> String {
        if
            let fileURL,
            let contents = try? String(contentsOf: fileURL, encoding: .utf8),
            !contents.isEmpty
        {
            return contents
        }

        return makeInlineBlockPage()
    }

    private func makeInlineBlockPage() -> String {
        let svgMarkup = (try? ExamModeAssetInstaller.bundledSVGMarkup()) ?? ""

        return """
        <!doctype html>
        <html lang="de">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Zugriff nicht erlaubt</title>
          <style>
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              background: #f4f7f7;
              color: #17313b;
            }
            .page {
              max-width: 960px;
              margin: 0 auto;
              padding: 32px 24px 48px;
            }
            h1 {
              font-size: 36px;
              margin: 0 0 12px;
            }
            p {
              font-size: 18px;
              line-height: 1.6;
              margin: 0 0 12px;
            }
            .artwork {
              margin: 28px 0;
              border-radius: 18px;
              overflow: hidden;
              background: white;
              box-shadow: 0 12px 40px rgba(23, 49, 59, 0.10);
            }
            .artwork svg {
              display: block;
              width: 100%;
              height: auto;
            }
            .hint {
              margin-top: 20px;
              font-size: 15px;
              color: #53707a;
            }
          </style>
        </head>
        <body>
          <div class="page">
            <h1>Diese Seite ist im Prüfungsmodus nicht freigegeben.</h1>
            <p>Dein Gerät befindet sich aktuell im Exam Mode. Der Internetzugriff ist auf ausdrücklich erlaubte Ziele begrenzt.</p>
            <p>Wenn du glaubst, dass diese Adresse für die Prüfung benötigt wird, wende dich bitte an die Aufsicht.</p>
            <div class="artwork">\(svgMarkup)</div>
            <p class="hint">ExamManager block page delivered by the local exam proxy.</p>
          </div>
        </body>
        </html>
        """
    }

    private func makeTextResponse(statusLine: String, body: String) -> Data {
        let payload = body + "\n"
        let response = """
        \(statusLine)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(payload.utf8.count)\r
        Connection: close\r
        \r
        \(payload)
        """

        return Data(response.utf8)
    }

    private func makeHTMLResponse(statusLine: String, html: String) -> Data {
        let response = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """

        return Data(response.utf8)
    }
}
