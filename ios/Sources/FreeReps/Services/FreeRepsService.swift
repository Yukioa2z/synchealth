import Foundation

/// Errors from SyncHealth HTTP communication.
enum FreeRepsError: LocalizedError, Equatable {
    case invalidURL
    case missingToken
    case httpError(statusCode: Int)
    case decodingError(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The SyncHealth receiver must be a valid absolute HTTPS URL."
        case .missingToken:
            return "Enter the Health token in Settings before syncing."
        case .httpError(let code):
            return "The SyncHealth receiver returned HTTP \(code)."
        case .decodingError(let message):
            return "The SyncHealth acknowledgement could not be decoded: \(message)"
        case .connectionFailed(let message):
            return "Could not reach the SyncHealth receiver: \(message)"
        }
    }
}

/// Acknowledgement returned by SyncHealth after processing an ingest payload.
struct IngestAcknowledgement: Codable, Equatable {
    let points: Int
}

/// Lightweight HTTP client for the single SyncHealth ingest endpoint.
actor FreeRepsService {
    typealias TokenProvider = () throws -> String?

    private let session: URLSession
    private let endpointURL: URL?
    private let tokenProvider: TokenProvider

    init(
        config: FreeRepsConfig,
        session: URLSession? = nil,
        tokenProvider: @escaping TokenProvider = { try HealthTokenStore.shared.load() }
    ) {
        self.endpointURL = try? config.validatedEndpointURL()
        self.tokenProvider = tokenProvider

        if let session {
            self.session = session
        } else {
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = 120
            sessionConfig.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: sessionConfig)
        }
    }

    /// Encodes and POSTs a FreeReps/HAE-compatible payload to the SyncHealth receiver.
    func ingest(_ payload: FreeRepsPayload) async throws -> IngestAcknowledgement {
        try await ingest(encodedPayload: JSONEncoder().encode(payload))
    }

    /// POSTs an already encoded payload. The durable queue uses this path for retries.
    func ingest(encodedPayload: Data) async throws -> IngestAcknowledgement {
        guard let endpointURL else {
            throw FreeRepsError.invalidURL
        }
        guard let storedToken = try tokenProvider() else {
            throw FreeRepsError.missingToken
        }
        let token = storedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw FreeRepsError.missingToken
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Health-Token")
        request.httpBody = encodedPayload

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw FreeRepsError.connectionFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            throw FreeRepsError.httpError(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(IngestAcknowledgement.self, from: data)
        } catch {
            throw FreeRepsError.decodingError(error.localizedDescription)
        }
    }
    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw FreeRepsError.connectionFailed(error.localizedDescription)
        }
    }
}
