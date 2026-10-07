import Foundation
import SwiftDecision
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Immutable HTTP request passed to an OpenAI Decisions transport.
///
/// The headers contain the bearer credential. Transports must not log them.
public struct OpenAIHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data
    public let timeout: TimeInterval

    public init(url: URL, method: String, headers: [String: String], body: Data, timeout: TimeInterval) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// HTTP response consumed by an ``OpenAIHTTPTransport``.
public struct OpenAIHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Injectable asynchronous transport for the OpenAI Decisions API.
public protocol OpenAIHTTPTransport: Sendable {
    func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse
}

/// URLSession transport with ephemeral storage and redirects disabled.
public actor URLSessionOpenAIHTTPTransport: OpenAIHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: OpenAIRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse {
        try Task.checkCancellation()

        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let cancellation = OpenAIURLSessionTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: OpenAIDecisionBackendError.malformedResponse)
                        return
                    }
                    continuation.resume(returning: OpenAIHTTPResponse(
                        statusCode: response.statusCode,
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

/// Errors raised while configuring or calling OpenAI's Decisions API.
public enum OpenAIDecisionBackendError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingAPIKey
    case invalidConfiguration(String)
    case unsupportedPrompt(String)
    case requestEncodingFailed
    case httpFailure(statusCode: Int)
    case refused
    case malformedResponse

    public var description: String {
        switch self {
        case .missingAPIKey:
            "Set OPENAI_API_KEY or pass apiKey when creating OpenAIDecisionsBackend."
        case let .invalidConfiguration(message):
            "Invalid OpenAI Decisions configuration: \(message)"
        case let .unsupportedPrompt(message):
            "Unsupported OpenAI Decisions prompt: \(message)"
        case .requestEncodingFailed:
            "Could not encode the OpenAI Decisions request."
        case let .httpFailure(statusCode):
            "OpenAI returned HTTP \(statusCode); the decision was not completed."
        case .refused:
            "OpenAI declined to answer the decision request."
        case .malformedResponse:
            "OpenAI returned a response that does not match the requested decision."
        }
    }
}

/// Provider adapter for the public-beta OpenAI Decisions API.
///
/// The backend uses the first-party REST contract directly and has no SDK dependency. It maps
/// SwiftDecision's Noul to a `predicate` question, and Choice and Score to their native question
/// types. The engine remains responsible for acceptance policy, abstention, and fallbacks.
public struct OpenAIDecisionsBackend: DecisionBackend {
    private static let questionName = "swiftdecision"

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let transport: any OpenAIHTTPTransport

    /// Creates an OpenAI Decisions backend.
    ///
    /// - Parameters:
    ///   - apiKey: OpenAI API key. When omitted, `OPENAI_API_KEY` is read from the environment.
    ///   - baseURL: HTTPS API root ending before the Decisions path. Defaults to `https://api.openai.com/v1`.
    ///   - model: Decisions-compatible model identifier. Defaults to `gpt-6-luna`.
    ///   - timeout: Per-request timeout in seconds.
    ///   - transport: HTTP transport. Inject a fixture transport for offline integrations.
    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        model: String = "gpt-6-luna",
        timeout: TimeInterval = 10,
        transport: any OpenAIHTTPTransport = URLSessionOpenAIHTTPTransport()
    ) throws {
        let resolvedAPIKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        guard let resolvedAPIKey,
              !resolvedAPIKey.isEmpty,
              resolvedAPIKey.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
        else {
            throw OpenAIDecisionBackendError.missingAPIKey
        }
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw OpenAIDecisionBackendError.invalidConfiguration(
                "baseURL must be an absolute HTTPS URL without credentials, query, or fragment"
            )
        }
        var endpointComponents = components
        endpointComponents.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !endpointComponents.path.isEmpty { endpointComponents.path += "/" }
        endpointComponents.path += "decisions"
        guard let endpoint = endpointComponents.url else {
            throw OpenAIDecisionBackendError.invalidConfiguration("baseURL could not form the Decisions endpoint")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIDecisionBackendError.invalidConfiguration("model must be nonempty")
        }
        guard timeout.isFinite, timeout > 0 else {
            throw OpenAIDecisionBackendError.invalidConfiguration("timeout must be finite and positive")
        }
        self.endpoint = endpoint
        self.apiKey = resolvedAPIKey
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    public func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        try Task.checkCancellation()
        try validate(prompt)

        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: requestPayload(for: prompt),
                options: [.sortedKeys]
            )
        } catch {
            throw OpenAIDecisionBackendError.requestEncodingFailed
        }

        let request = OpenAIHTTPRequest(
            url: endpoint,
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
            throw OpenAIDecisionBackendError.httpFailure(statusCode: response.statusCode)
        }

        let decoded: OpenAIDecisionResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIDecisionResponse.self, from: response.body)
        } catch {
            throw OpenAIDecisionBackendError.malformedResponse
        }
        guard !decoded.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.answers.count == 1,
              let answer = decoded.answers.first,
              answer.name == Self.questionName
        else {
            throw OpenAIDecisionBackendError.malformedResponse
        }

        return DecisionPrediction(
            probabilities: try probabilities(for: answer, prompt: prompt),
            modelIdentifier: decoded.model
        )
    }

    private func validate(_ prompt: DecisionPrompt) throws {
        guard !prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.context.isEmpty,
              prompt.options.count >= 2,
              prompt.options.allSatisfy({ !$0.id.isEmpty && !$0.description.isEmpty }),
              Set(prompt.options.map(\.id)).count == prompt.options.count
        else {
            throw OpenAIDecisionBackendError.unsupportedPrompt(
                "instructions, context, and unique nonempty options are required"
            )
        }

        switch prompt.kind {
        case .noul:
            guard prompt.options.map(\.id) == ["false", "true"] else {
                throw OpenAIDecisionBackendError.unsupportedPrompt(
                    "Noul requires the ordered false and true options"
                )
            }
        case .choice:
            guard prompt.options.count <= 255 else {
                throw OpenAIDecisionBackendError.unsupportedPrompt("Choice supports at most 255 options")
            }
        case .score:
            guard prompt.options.map(\.id) == prompt.options.indices.map(String.init)
            else {
                throw OpenAIDecisionBackendError.unsupportedPrompt(
                    "Score requires ordered levels with IDs starting at 0"
                )
            }
        }
    }

    private func requestPayload(for prompt: DecisionPrompt) -> [String: Any] {
        var question: [String: Any] = [
            "name": Self.questionName,
            "instructions": prompt.instructions
        ]
        switch prompt.kind {
        case .noul:
            question["type"] = "predicate"
        case .choice:
            question["type"] = "choice"
            question["choices"] = prompt.options.map { option in
                ["value": option.id, "description": option.description]
            }
        case .score:
            question["type"] = "score"
            question["levels"] = prompt.options.map { option in
                ["label": option.id, "description": option.description]
            }
        }
        return ["input": prompt.context, "model": model, "questions": [question]]
    }

    private func probabilities(for answer: OpenAIDecisionAnswer, prompt: DecisionPrompt) throws -> [Double] {
        switch (prompt.kind, answer) {
        case let (.noul, .predicate(name, probability)):
            guard name == Self.questionName, probability.isFinite, (0 ... 1).contains(probability) else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            return [1 - probability, probability]

        case let (.choice, .choice(name, selected, confidence, rawProbabilities)):
            guard name == Self.questionName,
                  confidence.isFinite, (0 ... 1).contains(confidence),
                  case let .string(selectedID) = selected
            else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            let values = try orderedChoiceProbabilities(rawProbabilities, options: prompt.options)
            guard let selectedProbability = zip(prompt.options, values)
                .first(where: { $0.0.id == selectedID })?.1,
                  let maximum = values.max(), abs(selectedProbability - maximum) <= 1e-12
            else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            return values

        case let (.score, .score(name, _, confidence, rawProbabilities)):
            guard name == Self.questionName,
                  confidence.isFinite, (0 ... 1).contains(confidence)
            else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            let values = try orderedScoreProbabilities(rawProbabilities, options: prompt.options)
            return values

        case (_, .refusal(_)):
            throw OpenAIDecisionBackendError.refused

        default:
            throw OpenAIDecisionBackendError.malformedResponse
        }
    }

    private func orderedChoiceProbabilities(
        _ probabilities: [OpenAIChoiceProbability],
        options: [DecisionOption]
    ) throws -> [Double] {
        guard probabilities.count == options.count,
              probabilities.allSatisfy({ if case .string = $0.value { true } else { false } })
        else {
            throw OpenAIDecisionBackendError.malformedResponse
        }
        var byID: [String: Double] = [:]
        for item in probabilities {
            guard case let .string(id) = item.value,
                  byID[id] == nil,
                  item.probability.isFinite,
                  (0 ... 1).contains(item.probability)
            else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            byID[id] = item.probability
        }
        guard Set(byID.keys) == Set(options.map(\.id)) else {
            throw OpenAIDecisionBackendError.malformedResponse
        }
        let values = options.compactMap { byID[$0.id] }
        try validateDistribution(values)
        return values
    }

    private func orderedScoreProbabilities(
        _ probabilities: [OpenAIScoreProbability],
        options: [DecisionOption]
    ) throws -> [Double] {
        guard probabilities.count == options.count else {
            throw OpenAIDecisionBackendError.malformedResponse
        }
        var byLabel: [String: Double] = [:]
        for item in probabilities {
            guard byLabel[item.label] == nil,
                  item.probability.isFinite,
                  (0 ... 1).contains(item.probability)
            else {
                throw OpenAIDecisionBackendError.malformedResponse
            }
            byLabel[item.label] = item.probability
        }
        guard Set(byLabel.keys) == Set(options.map(\.id)) else {
            throw OpenAIDecisionBackendError.malformedResponse
        }
        let values = options.compactMap { byLabel[$0.id] }
        try validateDistribution(values)
        return values
    }

    private func validateDistribution(_ values: [Double]) throws {
        guard abs(values.reduce(0, +) - 1) <= 0.01 else {
            throw OpenAIDecisionBackendError.malformedResponse
        }
    }
}

private struct OpenAIDecisionResponse: Decodable {
    let model: String
    let answers: [OpenAIDecisionAnswer]
}

private enum OpenAIDecisionAnswer: Decodable {
    case predicate(name: String?, probability: Double)
    case choice(name: String?, choice: OpenAIChoiceValue, confidence: Double, probabilities: [OpenAIChoiceProbability])
    case score(name: String?, score: Double, confidence: Double, probabilities: [OpenAIScoreProbability])
    case refusal(name: String?)
    case unknown(name: String?)

    var name: String? {
        switch self {
        case let .predicate(name, _), let .choice(name, _, _, _), let .score(name, _, _, _),
             let .refusal(name), let .unknown(name): name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, probability, choice, confidence, probabilities, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        switch try container.decode(String.self, forKey: .type) {
        case "predicate":
            self = .predicate(name: name, probability: try container.decode(Double.self, forKey: .probability))
        case "choice":
            self = .choice(
                name: name,
                choice: try container.decode(OpenAIChoiceValue.self, forKey: .choice),
                confidence: try container.decode(Double.self, forKey: .confidence),
                probabilities: try container.decode([OpenAIChoiceProbability].self, forKey: .probabilities)
            )
        case "score":
            self = .score(
                name: name,
                score: try container.decode(Double.self, forKey: .score),
                confidence: try container.decode(Double.self, forKey: .confidence),
                probabilities: try container.decode([OpenAIScoreProbability].self, forKey: .probabilities)
            )
        case "refusal":
            self = .refusal(name: name)
        default:
            self = .unknown(name: name)
        }
    }
}

private enum OpenAIChoiceValue: Decodable, Equatable {
    case string(String)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            self = .string(string)
        } else {
            self = .boolean(try value.decode(Bool.self))
        }
    }
}

private struct OpenAIChoiceProbability: Decodable {
    let value: OpenAIChoiceValue
    let probability: Double
}

private struct OpenAIScoreProbability: Decodable {
    let label: String
    let probability: Double
    let value: Int64
}

private final class OpenAIRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
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

/// Coordinates cancellation with URLSession task creation.
private final class OpenAIURLSessionTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    // SAFETY: Both fields are accessed only while `lock` is held; URLSessionTask cancellation is thread-safe.
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
