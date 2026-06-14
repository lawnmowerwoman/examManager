import Foundation

/// Lightweight Jamf Pro integration for direct exam-status EA updates.
///
/// This follows the same overall flow used in Notary:
/// 1. OAuth client-credentials token
/// 2. resolve local Jamf Computer ID by serial number
/// 3. resolve EA definition by name
/// 4. PATCH the EA value directly on the inventory record
public final class JamfHelper {
    public struct EAUpdate: Sendable {
        public let computerID: Int
        public let eaID: Int
        public let eaName: String
    }

    public enum JamfError: Error, CustomStringConvertible {
        case notConfigured
        case missingBaseURL
        case requestFailed(String)
        case missingComputerID(String)
        case missingEADefinition(String)
        case updateFailed(Int)

        public var description: String {
            switch self {
            case .notConfigured:
                return "Jamf EA update is not configured"
            case .missingBaseURL:
                return "Jamf Pro URL is not available"
            case .requestFailed(let message):
                return message
            case .missingComputerID(let serial):
                return "Jamf Computer ID not found for serial \(serial)"
            case .missingEADefinition(let name):
                return "Jamf EA definition not found: \(name)"
            case .updateFailed(let status):
                return "Jamf EA update failed with HTTP \(status)"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private struct ComputerInventoryResponse: Decodable {
        let results: [ComputerInventoryItem]
    }

    private struct ComputerInventoryItem: Decodable {
        let id: IntOrString
    }

    private struct EADefinition: Decodable {
        let id: IntOrString
        let name: String
    }

    private struct EAListResponse: Decodable {
        let results: [EADefinition]
    }

    private struct EAPatchBody: Encodable {
        struct EAItem: Encodable {
            let definitionId: Int
            let values: [String]
        }

        let extensionAttributes: [EAItem]
    }

    private let logger = ConsoleLogger()
    private let session: URLSession
    private let queue = DispatchQueue(label: "de.twocent.exam.jamf")
    private let eaUpdateDelayRangeSeconds = 0...10

    private var bearerToken: String?
    private var bearerExpiration: Date?
    private var cachedComputerID: Int?
    private var cachedEAID: Int?
    private var cachedEAName: String?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    public func publishExamState(
        _ state: NotaryExamState,
        completion: @escaping @Sendable (Result<EAUpdate, JamfError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            Task {
                do {
                    let update = try await self.performEAUpdate(for: state)
                    completion(.success(update))
                } catch let error as JamfError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(.requestFailed(String(describing: error))))
                }
            }
        }
    }

    public var jamfProURL: String {
        guard let url = Self.jamfProBaseURL() else { return "" }
        return url.host.map { host in
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        } ?? url.absoluteString
    }

    private func performEAUpdate(for state: NotaryExamState) async throws -> EAUpdate {
        guard let config = Self.configuration() else {
            logger.warn("[JamfHelper] EA configuration missing (clientID=\(Self.managedString(key: "JamfAPIClientID") != nil), secret=\(Self.managedString(key: "JamfAPIClientSecret") != nil), eaName=\(Self.managedString(key: "ExamStatusEAName") != nil), baseURL=\(Self.jamfProBaseURL() != nil))")
            throw JamfError.notConfigured
        }
        guard let baseURL = Self.jamfProBaseURL() else {
            throw JamfError.missingBaseURL
        }

        let token = try await ensureBearerToken(baseURL: baseURL, clientID: config.clientID, clientSecret: config.clientSecret)
        let computerID = try await resolveComputerID(baseURL: baseURL, token: token, preferredID: state.jamfComputerID)
        let eaID = try await resolveEAID(baseURL: baseURL, token: token, eaName: config.eaName, preferredID: state.jamfEAID, preferredName: state.jamfEAName)
        let statusValue = Self.examEAValue(for: state)

        try await applyRandomizedEADelay(statusValue: statusValue)

        let url = baseURL.appendingPathComponent("api/v1/computers-inventory-detail/\(computerID)")
        let body = EAPatchBody(extensionAttributes: [.init(definitionId: eaID, values: [statusValue])])
        let payload = try JSONEncoder().encode(body)
        let response = try await request(
            url: url,
            method: "PATCH",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            body: payload,
            token: token
        )

        guard (200...299).contains(response.statusCode) else {
            throw JamfError.updateFailed(response.statusCode)
        }

        cachedComputerID = computerID
        cachedEAID = eaID
        cachedEAName = config.eaName

        return EAUpdate(computerID: computerID, eaID: eaID, eaName: config.eaName)
    }

    private func applyRandomizedEADelay(statusValue: String) async throws {
        let delaySeconds = Int.random(in: eaUpdateDelayRangeSeconds)
        guard delaySeconds > 0 else {
            logger.warn("[JamfHelper] Publishing EA value '\(statusValue)' without delay")
            return
        }

        logger.warn("[JamfHelper] Delaying EA value '\(statusValue)' by \(delaySeconds)s before Jamf update")
        try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
    }

    private func ensureBearerToken(baseURL: URL, clientID: String, clientSecret: String) async throws -> String {
        if let token = bearerToken, let expiration = bearerExpiration, expiration > Date().addingTimeInterval(3) {
            return token
        }

        let tokenURL = baseURL.appendingPathComponent("api/oauth/token")
        let form = "grant_type=client_credentials&client_id=\(Self.urlEncodeForm(clientID))&client_secret=\(Self.urlEncodeForm(clientSecret))"
        let response = try await request(
            url: tokenURL,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            token: nil
        )

        guard (200...299).contains(response.statusCode) else {
            throw JamfError.requestFailed("Failed to fetch Jamf bearer token (HTTP \(response.statusCode))")
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        bearerToken = decoded.access_token
        bearerExpiration = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        return decoded.access_token
    }

    private func resolveComputerID(baseURL: URL, token: String, preferredID: Int?) async throws -> Int {
        if let preferredID {
            return preferredID
        }
        if let cachedComputerID {
            return cachedComputerID
        }

        let serial = try Self.localSerialNumber()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v3/computers-inventory"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "section", value: "GENERAL"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "page-size", value: "1"),
            URLQueryItem(name: "filter", value: #"hardware.serialNumber=="\#(serial)""#)
        ]

        guard let url = components?.url else {
            throw JamfError.requestFailed("Failed to build computers-inventory URL")
        }

        let response = try await request(
            url: url,
            method: "GET",
            headers: ["Accept": "application/json"],
            body: nil,
            token: token
        )
        guard (200...299).contains(response.statusCode) else {
            throw JamfError.requestFailed("Failed to fetch Jamf Computer ID (HTTP \(response.statusCode))")
        }

        let decoded = try JSONDecoder().decode(ComputerInventoryResponse.self, from: response.body)
        guard let computerID = decoded.results.first?.id.value else {
            throw JamfError.missingComputerID(serial)
        }

        cachedComputerID = computerID
        return computerID
    }

    private func resolveEAID(baseURL: URL, token: String, eaName: String, preferredID: Int?, preferredName: String?) async throws -> Int {
        if preferredName == eaName, let preferredID {
            return preferredID
        }
        if cachedEAName == eaName, let cachedEAID {
            return cachedEAID
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/computer-extension-attributes"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "page-size", value: "200"),
            URLQueryItem(name: "sort", value: "name.asc")
        ]

        guard let url = components?.url else {
            throw JamfError.requestFailed("Failed to build computer-extension-attributes URL")
        }

        let response = try await request(
            url: url,
            method: "GET",
            headers: ["Accept": "application/json"],
            body: nil,
            token: token
        )
        guard (200...299).contains(response.statusCode) else {
            throw JamfError.requestFailed("Failed to fetch EA definitions (HTTP \(response.statusCode))")
        }

        let decoded = try JSONDecoder().decode(EAListResponse.self, from: response.body)
        guard let definition = decoded.results.first(where: { $0.name == eaName }) else {
            throw JamfError.missingEADefinition(eaName)
        }

        let eaID = definition.id.value
        cachedEAID = eaID
        cachedEAName = eaName
        return eaID
    }

    private func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        token: String?
    ) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JamfError.requestFailed("Jamf response was not an HTTPURLResponse")
        }

        if httpResponse.statusCode == 401, token != nil {
            bearerToken = nil
            bearerExpiration = nil
        }

        return (httpResponse.statusCode, data)
    }

    private static func configuration() -> (clientID: String, clientSecret: String, eaName: String)? {
        let environment = ProcessInfo.processInfo.environment

        let clientID = (environment["JAMF_CLIENT_ID"] ?? managedString(key: "JamfAPIClientID"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientSecret = (environment["JAMF_CLIENT_SECRET"] ?? managedString(key: "JamfAPIClientSecret"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eaName = (environment["JAMF_EXAM_STATUS_EA_NAME"] ?? managedString(key: "ExamStatusEAName") ?? "Exam Mode")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clientID.isEmpty, !clientSecret.isEmpty, !eaName.isEmpty else {
            return nil
        }

        return (clientID, clientSecret, eaName)
    }

    private static func managedString(key: String) -> String? {
        let domain = ConfigProfileReader.domain
        let cfKey = key as CFString

        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        if let value = CFPreferencesCopyValue(cfKey, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        for url in managedPreferenceURLs() {
            guard
                let dictionary = NSDictionary(contentsOf: url) as? [String: Any],
                let value = dictionary[key] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            return value
        }

        return nil
    }

    private static func managedPreferenceURLs() -> [URL] {
        let domainName = ConfigProfileReader.domain as String
        let baseURL = URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
        let preferencesURL = URL(fileURLWithPath: "/Library/Preferences", isDirectory: true)
        let fileManager = FileManager.default

        var urls: [URL] = [
            baseURL.appendingPathComponent("\(domainName).plist", isDirectory: false),
            preferencesURL.appendingPathComponent("\(domainName).plist", isDirectory: false)
        ]

        if let contents = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in contents {
                guard
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                else {
                    continue
                }

                urls.append(item.appendingPathComponent("\(domainName).plist", isDirectory: false))
            }
        }

        return urls
    }

    private static func jamfProBaseURL() -> URL? {
        guard let dict = NSDictionary(contentsOfFile: "/Library/Preferences/com.jamfsoftware.jamf.plist") as? [String: Any] else {
            return nil
        }

        let raw = (dict["jss_url"] as? String) ?? (dict["iss_url"] as? String) ?? ""
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http") {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return URL(string: value)
    }

    private static func localSerialNumber() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw JamfError.requestFailed("Failed to read local serial number via ioreg")
        }

        for line in output.components(separatedBy: "\n") {
            if line.contains("IOPlatformSerialNumber") {
                let parts = line.components(separatedBy: "\"")
                if let serial = parts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "=" }) {
                    return serial.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        throw JamfError.requestFailed("Unable to parse local serial number from ioreg output")
    }

    private static func examEAValue(for state: NotaryExamState) -> String {
        switch state.mode {
        case .active:
            return state.proxyMode == .fallback ? "active:fallback" : "active"
        case .inactive:
            return "inactive"
        case .activating:
            return "activating"
        case .deactivating:
            return "deactivating"
        case .error:
            return "error"
        }
    }

    private static func urlEncodeForm(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

private struct IntOrString: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self.value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self),
           let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = intValue
            return
        }

        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Int or String convertible to Int"
            )
        )
    }
}
