import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Immutable HTTP request passed to a Jev transport.
///
/// The headers include the bearer credential. Transports must not log this value.
public struct JevHTTPRequest: Sendable, Equatable {
    /// Official Jev API endpoint.
    public let url: URL

    /// HTTP method used for this request.
    public let method: String

    /// HTTP headers, including the bearer credential.
    public let headers: [String: String]

    /// JSON request body.
    public let body: Data

    /// Per-request timeout in seconds.
    public let timeout: TimeInterval

    /// Creates a transport request.
    public init(url: URL, method: String, headers: [String: String], body: Data, timeout: TimeInterval) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// HTTP response consumed by a ``JevHTTPTransport``.
public struct JevHTTPResponse: Sendable, Equatable {
    /// HTTP status code returned by the server.
    public let statusCode: Int

    /// Response headers returned by the server.
    public let headers: [String: String]

    /// Response body bytes.
    public let body: Data

    /// Creates a transport response.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Injectable asynchronous transport used by ``JevDecisionBackend``.
public protocol JevHTTPTransport: Sendable {
    /// Sends one request and returns its HTTP response.
    func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse
}

/// URLSession-based transport with ephemeral, cookie-free requests and redirects disabled.
public actor URLSessionJevHTTPTransport: JevHTTPTransport {
    private let session: URLSession

    /// Creates an ephemeral session with cookies, caching, and redirects disabled.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: JevRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
        try Task.checkCancellation()

        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let session = self.session
        let cancellation = JevURLSessionTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: JevDecisionBackendError.malformedResponse)
                        return
                    }
                    let headers = Dictionary(
                        response.allHeaderFields.compactMap { key, value -> (String, String)? in
                            guard let name = key as? String else { return nil }
                            return (name, String(describing: value))
                        },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    continuation.resume(returning: JevHTTPResponse(
                        statusCode: response.statusCode,
                        headers: headers,
                        body: data ?? Data()
                    ))
                }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Errors raised while configuring or calling the TypeSafe System One API.
public enum JevDecisionBackendError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No explicit key was supplied and `TYPESAFE_API_KEY` is unset or invalid.
    case missingAPIKey

    /// The model identifier or request timeout is invalid.
    case invalidConfiguration(String)

    /// The prompt cannot be represented by a TypeSafe primitive.
    case unsupportedPrompt(String)

    /// The request could not be encoded as JSON.
    case requestEncodingFailed

    /// TypeSafe returned a non-success HTTP status.
    case httpFailure(statusCode: Int)

    /// The response does not satisfy the TypeSafe primitive contract.
    case malformedResponse

    public var description: String {
        switch self {
        case .missingAPIKey:
            "Set TYPESAFE_API_KEY or pass apiKey when creating JevDecisionBackend."
        case let .invalidConfiguration(message):
            "Invalid Jev backend configuration: \(message)"
        case let .unsupportedPrompt(message):
            "Unsupported Jev decision prompt: \(message)"
        case .requestEncodingFailed:
            "Could not encode the Jev request."
        case let .httpFailure(statusCode):
            "TypeSafe returned HTTP \(statusCode); the decision was not completed."
        case .malformedResponse:
            "TypeSafe returned a response that does not match the requested decision."
        }
    }
}

/// TypeSafe Jev backend for Noul, Choice, and Score decisions.
///
/// The API key is read from `TYPESAFE_API_KEY` unless supplied explicitly. Requests are sent only
/// to the official HTTPS endpoint, redirects are rejected, and response bodies are never included
/// in errors. No retries or live requests happen during initialization.
public struct JevDecisionBackend: DecisionBackend {
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let questionID = "swiftdecision"

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let transport: any JevHTTPTransport

    /// Creates a Jev backend.
    ///
    /// - Parameters:
    ///   - apiKey: TypeSafe API key. When omitted, `TYPESAFE_API_KEY` is read from the environment.
    ///   - model: TypeSafe model identifier. Defaults to `jev-latest`.
    ///   - timeout: Per-request timeout in seconds.
    ///   - transport: HTTP transport. The default uses URLSession; inject a mock for offline tests.
    public init(
        apiKey: String? = nil,
        model: String = "jev-latest",
        timeout: TimeInterval = 10,
        transport: any JevHTTPTransport = URLSessionJevHTTPTransport()
    ) throws {
        let resolvedAPIKey = apiKey ?? ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
        guard let resolvedAPIKey,
              !resolvedAPIKey.isEmpty,
              resolvedAPIKey.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
        else {
            throw JevDecisionBackendError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JevDecisionBackendError.invalidConfiguration("model must be nonempty")
        }
        guard timeout.isFinite, timeout > 0 else {
            throw JevDecisionBackendError.invalidConfiguration("timeout must be finite and positive")
        }
        self.apiKey = resolvedAPIKey
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    /// Sends one typed decision and maps its probability distribution to prompt option order.
    public func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        try Task.checkCancellation()
        try validate(prompt)

        let question = questionPayload(for: prompt)
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: [
                    "model": model,
                    "state": ["context": prompt.context],
                    "questions": [Self.questionID: question]
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw JevDecisionBackendError.requestEncodingFailed
        }

        let request = JevHTTPRequest(
            url: Self.endpoint,
            method: "POST",
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json"
            ],
            body: body,
            timeout: timeout
        )
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.statusCode) else {
            throw JevDecisionBackendError.httpFailure(statusCode: response.statusCode)
        }

        let decoded: JevResponse
        do {
            decoded = try JSONDecoder().decode(JevResponse.self, from: response.body)
        } catch {
            throw JevDecisionBackendError.malformedResponse
        }
        guard !decoded.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.answers.count == 1,
              let answer = decoded.answers[Self.questionID],
              answer.type == prompt.kind.rawValue
        else {
            throw JevDecisionBackendError.malformedResponse
        }

        return DecisionPrediction(
            probabilities: try probabilities(for: answer, prompt: prompt),
            modelIdentifier: decoded.model
        )
    }

    private func validate(_ prompt: DecisionPrompt) throws {
        guard !prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.options.count >= 2,
              prompt.options.allSatisfy({ !$0.id.isEmpty && !$0.description.isEmpty }),
              Set(prompt.options.map(\.id)).count == prompt.options.count
        else {
            throw JevDecisionBackendError.unsupportedPrompt("instructions and unique, nonempty options are required")
        }

        switch prompt.kind {
        case .noul:
            guard prompt.options.map(\.id) == ["false", "true"] else {
                throw JevDecisionBackendError.unsupportedPrompt("Noul requires the ordered false and true options")
            }
        case .choice:
            guard prompt.options.count <= 255 else {
                throw JevDecisionBackendError.unsupportedPrompt("Choice supports at most 255 options")
            }
        case .score:
            guard (2 ... 10).contains(prompt.options.count),
                  prompt.options.map(\.id) == prompt.options.indices.map(String.init)
            else {
                throw JevDecisionBackendError.unsupportedPrompt("Score requires 2 to 10 ordered levels with IDs starting at 0")
            }
        }
    }

    private func questionPayload(for prompt: DecisionPrompt) -> [String: Any] {
        let common: [String: Any] = ["instructions": prompt.instructions]
        switch prompt.kind {
        case .noul:
            return common.merging([
                "type": "noul",
                "criteria": Dictionary(uniqueKeysWithValues: prompt.options.map { ($0.id, $0.description) })
            ]) { _, latest in latest }
        case .choice:
            return common.merging([
                "type": "choice",
                "criteria": Dictionary(uniqueKeysWithValues: prompt.options.map { ($0.id, $0.description) })
            ]) { _, latest in latest }
        case .score:
            return common.merging([
                "type": "score",
                "criteria": prompt.options.map(\.description)
            ]) { _, latest in latest }
        }
    }

    private func probabilities(for answer: JevAnswer, prompt: DecisionPrompt) throws -> [Double] {
        switch prompt.kind {
        case .noul:
            guard let probability = answer.noul, probability.isFinite, (0 ... 1).contains(probability) else {
                throw JevDecisionBackendError.malformedResponse
            }
            return [1 - probability, probability]
        case .choice:
            guard let choice = answer.choice,
                  let confidence = answer.confidence,
                  confidence.isFinite,
                  (0 ... 1).contains(confidence),
                  let rawProbabilities = answer.probabilities,
                  Set(rawProbabilities.keys) == Set(prompt.options.map(\.id))
            else {
                throw JevDecisionBackendError.malformedResponse
            }
            let values = try orderedProbabilities(rawProbabilities, options: prompt.options)
            try validateDistribution(values)
            guard let selectedProbability = rawProbabilities[choice],
                  selectedProbability == values.max()
            else {
                throw JevDecisionBackendError.malformedResponse
            }
            return values
        case .score:
            guard let score = answer.score,
                  score.isFinite,
                  let confidence = answer.confidence,
                  confidence.isFinite,
                  (0 ... 1).contains(confidence),
                  let rawProbabilities = answer.probabilities,
                  let legend = answer.legend
            else {
                throw JevDecisionBackendError.malformedResponse
            }
            let expectedIDs = prompt.options.indices.map(String.init)
            guard Set(rawProbabilities.keys) == Set(expectedIDs),
                  Set(legend.keys) == Set(expectedIDs),
                  zip(expectedIDs, prompt.options).allSatisfy({ legend[$0.0] == $0.1.description })
            else {
                throw JevDecisionBackendError.malformedResponse
            }
            let values = try orderedProbabilities(rawProbabilities, options: prompt.options)
            try validateDistribution(values)
            let expectedScore = values.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
            guard (0 ... Double(values.count - 1)).contains(score), abs(score - expectedScore) <= 0.02 else {
                throw JevDecisionBackendError.malformedResponse
            }
            return values
        }
    }

    private func orderedProbabilities(
        _ probabilities: [String: Double],
        options: [DecisionOption]
    ) throws -> [Double] {
        let values = options.compactMap { probabilities[$0.id] }
        guard values.count == options.count,
              values.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
        else {
            throw JevDecisionBackendError.malformedResponse
        }
        return values
    }

    private func validateDistribution(_ values: [Double]) throws {
        guard abs(values.reduce(0, +) - 1) <= 0.01 else {
            throw JevDecisionBackendError.malformedResponse
        }
    }
}

private struct JevResponse: Decodable {
    let model: String
    let answers: [String: JevAnswer]
}

private struct JevAnswer: Decodable {
    let type: String
    let noul: Double?
    let choice: String?
    let score: Double?
    let confidence: Double?
    let probabilities: [String: Double]?
    let legend: [String: String]?
}

private final class JevRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Protects URLSessionTask access between cancellation and task creation.
private final class JevURLSessionTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    // SAFETY: Both fields are accessed only while `lock` is held. URLSessionTask cancellation is
    // thread-safe, so copying the task under the lock and cancelling it after unlocking is safe.
    func install(_ task: URLSessionTask) {
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel { self.task = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
