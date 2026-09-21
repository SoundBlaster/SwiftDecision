import Foundation
import SpecificationCore

/// The family of structured decision requested from a backend.
public enum DecisionKind: String, Sendable, Hashable {
    case noul
    case choice
    case score
}

/// One textual option presented to a decision backend.
public struct DecisionOption: Sendable, Hashable {
    /// Stable option identifier within a prompt.
    public let id: String

    /// Human-readable option description.
    public let description: String

    /// Creates a model-facing option.
    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

/// A fully rendered, backend-independent request.
public struct DecisionPrompt: Sendable, Hashable {
    /// Caller-supplied request identifier, useful for trace correlation.
    public let id: String

    /// Decision mode represented by this prompt.
    public let kind: DecisionKind

    /// Instructions describing the desired decision.
    public let instructions: String

    /// Input state to evaluate.
    public let context: String

    /// Options in the exact order expected in the returned probability vector.
    public let options: [DecisionOption]

    /// Creates a prompt. Structural validation is performed by ``DecisionEngine``.
    public init(
        id: String,
        kind: DecisionKind,
        instructions: String,
        context: String,
        options: [DecisionOption]
    ) {
        self.id = id
        self.kind = kind
        self.instructions = instructions
        self.context = context
        self.options = options
    }
}

/// A probability distribution returned by a decision backend.
public struct DecisionPrediction: Sendable, Hashable {
    /// Probabilities aligned with the prompt's option order.
    public let probabilities: [Double]

    /// Identifier for the model or backend that produced this prediction.
    public let modelIdentifier: String

    /// Creates a prediction. The engine validates that probabilities are finite and normalized.
    public init(probabilities: [Double], modelIdentifier: String) {
        self.probabilities = probabilities
        self.modelIdentifier = modelIdentifier
    }
}

/// An asynchronous source of structured option probabilities.
public protocol DecisionBackend: Sendable {
    /// Evaluates a prompt and returns probabilities in prompt option order.
    func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction
}

/// A deterministic backend adapter useful for offline examples and application-owned providers.
public struct ClosureDecisionBackend: DecisionBackend {
    private let operation: @Sendable (DecisionPrompt) async throws -> DecisionPrediction

    /// Creates a backend around an asynchronous prediction closure.
    public init(
        _ operation: @escaping @Sendable (DecisionPrompt) async throws -> DecisionPrediction
    ) {
        self.operation = operation
    }

    /// Evaluates the supplied prompt with the configured closure.
    public func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        try await operation(prompt)
    }
}

/// Thresholds that determine whether a prediction is accepted or abstained.
public struct DecisionPolicy: Sendable, Hashable {
    /// Minimum probability required for the most likely option.
    public let minimumProbability: Double

    /// Minimum normalized entropy confidence required to accept the result.
    public let minimumConfidence: Double

    /// Creates a policy. Invalid thresholds are rejected when an engine is initialized.
    public init(minimumProbability: Double = 0.55, minimumConfidence: Double = 0.05) {
        self.minimumProbability = minimumProbability
        self.minimumConfidence = minimumConfidence
    }

    fileprivate var isValid: Bool {
        (0 ... 1).contains(minimumProbability) && (0 ... 1).contains(minimumConfidence)
    }
}

/// Policies selected by task kind before inference results are accepted.
public struct DecisionPolicies: Sendable, Hashable {
    /// Policy used for Noul decisions.
    public let noul: DecisionPolicy

    /// Policy used for Choice decisions.
    public let choice: DecisionPolicy

    /// Policy used for Score decisions.
    public let score: DecisionPolicy

    /// Creates a policy set with optional per-kind overrides.
    public init(
        noul: DecisionPolicy = DecisionPolicy(),
        choice: DecisionPolicy = DecisionPolicy(),
        score: DecisionPolicy = DecisionPolicy()
    ) {
        self.noul = noul
        self.choice = choice
        self.score = score
    }

    fileprivate var isValid: Bool { noul.isValid && choice.isValid && score.isValid }
}

/// A stable, content-free event emitted while a decision is evaluated.
public struct DecisionTraceEvent: Sendable, Hashable {
    /// The stage that completed.
    public enum Stage: String, Sendable, Hashable {
        case requestValidated
        case policySelected
        case inferenceStarted
        case inferenceCompleted
        case outputValidated
        case resolved
    }

    /// Completed stage.
    public let stage: Stage

    /// Time at which the stage completed.
    public let timestamp: Date

    /// Optional stage detail that does not contain request contents.
    public let detail: String?

    fileprivate init(_ stage: Stage, detail: String? = nil, timestamp: Date = Date()) {
        self.stage = stage
        self.timestamp = timestamp
        self.detail = detail
    }
}

/// The final state of a typed decision.
public enum DecisionOutcome<Value: Sendable>: Sendable {
    /// The model result satisfied the selected policy.
    case accepted(Value)

    /// The model result did not satisfy policy and no fallback was supplied.
    case abstained(reason: String)

    /// The model result did not satisfy policy and the caller supplied a fallback value.
    case fallback(Value, reason: String)
}

/// A typed result together with its confidence, probability distribution, and trace.
public struct DecisionResult<Value: Sendable>: Sendable {
    /// Accepted, abstained, or fallback result.
    public let outcome: DecisionOutcome<Value>

    /// Probability assigned to the selected option.
    public let confidence: Double

    /// Probabilities aligned to the corresponding request's option order.
    public let probabilities: [Double]

    /// Ordered, content-free execution events.
    public let trace: [DecisionTraceEvent]

    /// Returns the accepted or fallback value, or `nil` after abstention.
    public var value: Value? {
        switch outcome {
        case let .accepted(value), let .fallback(value, _): value
        case .abstained: nil
        }
    }
}

/// A typed option for a Choice decision.
public struct ChoiceOption<Label: Sendable & Hashable>: Sendable {
    /// Application-level value returned when this option wins.
    public let label: Label

    /// Text shown to the model.
    public let description: String

    /// Creates an option with a typed application value and model-facing description.
    public init(label: Label, description: String) {
        self.label = label
        self.description = description
    }
}

/// The continuous expected score and the most likely rubric level.
public struct ScoreValue: Sendable, Hashable {
    /// Zero-based index of the most likely score level.
    public let level: Int

    /// Probability-weighted expected numeric value across all score levels.
    public let expectedValue: Double

    /// Creates a score result.
    public init(level: Int, expectedValue: Double) {
        self.level = level
        self.expectedValue = expectedValue
    }
}

/// Errors raised before or during typed decision orchestration.
public enum DecisionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The request has missing or inconsistent fields.
    case invalidRequest(String)

    /// The prediction does not match the request's option count or probability constraints.
    case invalidPrediction(String)

    /// The configured inference deadline expired.
    case timedOut

    /// A Core routing specification unexpectedly produced no policy.
    case noPolicySelected

    public var description: String {
        switch self {
        case let .invalidRequest(message): "Invalid decision request: \(message)"
        case let .invalidPrediction(message): "Invalid backend prediction: \(message)"
        case .timedOut: "Decision inference timed out."
        case .noPolicySelected: "No decision policy matched the request."
        }
    }
}

/// Races an operation against a deadline without waiting for a cancelled child task to finish.
private final class DecisionTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func value(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let nanoseconds = UInt64(min(timeout * 1_000_000_000, Double(Int64.max)))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }

                let operationTask = Task.detached {
                    do {
                        self.resolve(.success(try await operation()))
                    } catch {
                        self.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    self.resolve(.failure(DecisionError.timedOut))
                }
                install(operationTask: operationTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func install(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        let alreadyResolved = isResolved
        if !alreadyResolved {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
        }
        lock.unlock()

        if alreadyResolved {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    private func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

/// Orchestrates validated asynchronous model decisions through SpecificationCore.
public struct DecisionEngine: Sendable {
    /// Runtime configuration owned by SwiftDecision.
    public struct Configuration: Sendable, Hashable {
        /// Per-kind acceptance policies.
        public let policies: DecisionPolicies

        /// Optional upper bound for one inference call.
        public let timeout: TimeInterval?

        /// Creates runtime configuration.
        public init(policies: DecisionPolicies = DecisionPolicies(), timeout: TimeInterval? = nil) {
            self.policies = policies
            self.timeout = timeout
        }
    }

    private let backend: any DecisionBackend
    private let configuration: Configuration

    /// Creates an engine around any asynchronous decision backend.
    public init(backend: some DecisionBackend, configuration: Configuration = Configuration()) {
        self.backend = backend
        self.configuration = configuration
    }

    /// Evaluates a boolean statement using the fixed option order `[false, true]`.
    public func noul(
        id: String = UUID().uuidString,
        statement: String,
        context: String,
        fallback: Bool? = nil
    ) async throws -> DecisionResult<Bool> {
        let prompt = DecisionPrompt(
            id: id,
            kind: .noul,
            instructions: statement,
            context: context,
            options: [
                DecisionOption(id: "false", description: "false: no, the statement does not hold"),
                DecisionOption(id: "true", description: "true: yes, the statement holds")
            ]
        )
        let value = try await evaluate(prompt, fallbackIndex: fallback.map { $0 ? 1 : 0 })
        return map(value) { $0 == 1 }
    }

    /// Selects one typed label while preserving the caller's option order.
    public func choice<Label: Sendable & Hashable>(
        id: String = UUID().uuidString,
        instructions: String,
        context: String,
        options: [ChoiceOption<Label>],
        fallback: Label? = nil
    ) async throws -> DecisionResult<Label> {
        guard Set(options.map(\.label)).count == options.count else {
            throw DecisionError.invalidRequest("choice labels must be unique")
        }
        let prompt = DecisionPrompt(
            id: id,
            kind: .choice,
            instructions: instructions,
            context: context,
            options: options.enumerated().map {
                DecisionOption(id: String($0.offset), description: $0.element.description)
            }
        )
        let fallbackIndex: Int?
        if let fallback {
            guard let index = options.firstIndex(where: { $0.label == fallback }) else {
                throw DecisionError.invalidRequest("fallback label must match one of the configured options")
            }
            fallbackIndex = index
        } else {
            fallbackIndex = nil
        }
        let selected = try await evaluate(prompt, fallbackIndex: fallbackIndex)
        return map(selected) { options[$0].label }
    }

    /// Scores context against ordered rubric levels and returns the expected numeric value.
    public func score(
        id: String = UUID().uuidString,
        instructions: String,
        context: String,
        levels: [(description: String, value: Double)],
        fallback: ScoreValue? = nil
    ) async throws -> DecisionResult<ScoreValue> {
        guard levels.count >= 2, levels.allSatisfy({ $0.value.isFinite }) else {
            throw DecisionError.invalidRequest("score requires at least two levels with finite numeric values")
        }
        if let fallback, !levels.indices.contains(fallback.level) {
            throw DecisionError.invalidRequest("fallback score level is out of range")
        }
        let prompt = DecisionPrompt(
            id: id,
            kind: .score,
            instructions: instructions,
            context: context,
            options: levels.enumerated().map {
                DecisionOption(id: String($0.offset), description: "level \($0.offset): \($0.element.description)")
            }
        )
        let evaluated = try await evaluate(prompt, fallbackIndex: fallback.map(\.level))
        let mappedOutcome = mapOutcome(evaluated.outcome) { index in
                ScoreValue(
                    level: index,
                    expectedValue: zip(levels, evaluated.probabilities)
                        .reduce(0) { $0 + $1.0.value * $1.1 }
                )
            }
        let outcome: DecisionOutcome<ScoreValue>
        if case let .fallback(_, reason) = mappedOutcome, let fallback {
            outcome = .fallback(fallback, reason: reason)
        } else {
            outcome = mappedOutcome
        }
        return DecisionResult(
            outcome: outcome,
            confidence: evaluated.confidence,
            probabilities: evaluated.probabilities,
            trace: evaluated.trace
        )
    }

    private func evaluate(
        _ prompt: DecisionPrompt,
        fallbackIndex: Int?
    ) async throws -> DecisionResult<Int> {
        try Task.checkCancellation()
        guard configuration.policies.isValid else {
            throw DecisionError.invalidRequest("policy thresholds must be between 0 and 1")
        }
        if let timeout = configuration.timeout, (!timeout.isFinite || timeout < 0) {
            throw DecisionError.invalidRequest("timeout must be a finite, nonnegative number of seconds")
        }

        let requestIsValid = AnyAsyncSpecification<DecisionPrompt> { candidate in
            !candidate.id.isEmpty
                && !candidate.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && candidate.options.count >= 2
                && candidate.options.allSatisfy { !$0.description.isEmpty }
                && Set(candidate.options.map(\.id)).count == candidate.options.count
        }
        guard try await requestIsValid.isSatisfiedBy(prompt) else {
            throw DecisionError.invalidRequest("id, instructions, context, and at least two unique options are required")
        }

        var trace = [DecisionTraceEvent(.requestValidated)]
        let policyRouter = AsyncFirstMatchSpec<DecisionKind, DecisionPolicy>.builder()
            .addPredicate({ $0 == .noul }, result: configuration.policies.noul)
            .addPredicate({ $0 == .choice }, result: configuration.policies.choice)
            .addPredicate({ $0 == .score }, result: configuration.policies.score)
            .build()
        guard let policy = try await policyRouter.decide(prompt.kind) else {
            throw DecisionError.noPolicySelected
        }
        trace.append(DecisionTraceEvent(.policySelected, detail: prompt.kind.rawValue))

        let backendDecision = AnyAsyncDecisionSpec<DecisionPrompt, DecisionPrediction> { [backend, timeout = configuration.timeout] request in
            if let timeout {
                return try await DecisionTimeoutRace<DecisionPrediction>().value(timeout: timeout) {
                    try await backend.predict(for: request)
                }
            }
            return try await backend.predict(for: request)
        }
        trace.append(DecisionTraceEvent(.inferenceStarted, detail: "\(prompt.options.count) options"))
        guard let prediction = try await backendDecision.decide(prompt) else {
            throw DecisionError.invalidPrediction("backend returned no result")
        }
        trace.append(DecisionTraceEvent(.inferenceCompleted, detail: prediction.modelIdentifier))

        let predictionIsValid = AnyAsyncSpecification<DecisionPrediction> { output in
            output.probabilities.count == prompt.options.count
                && output.probabilities.allSatisfy { $0.isFinite && $0 >= 0 }
                && abs(output.probabilities.reduce(0, +) - 1) <= 0.01
        }
        guard try await predictionIsValid.isSatisfiedBy(prediction) else {
            throw DecisionError.invalidPrediction("expected \(prompt.options.count) finite, nonnegative probabilities summing to 1")
        }
        trace.append(DecisionTraceEvent(.outputValidated))

        let selectedIndex = prediction.probabilities.indices.max {
            prediction.probabilities[$0] < prediction.probabilities[$1]
        } ?? 0
        let confidence = prediction.probabilities[selectedIndex]
        let entropyConfidence = normalizedConfidence(prediction.probabilities)
        let reason = "confidence \(confidence) did not satisfy the selected policy"
        let outcome: DecisionOutcome<Int>
        if confidence >= policy.minimumProbability && entropyConfidence >= policy.minimumConfidence {
            outcome = .accepted(selectedIndex)
        } else if let fallbackIndex {
            guard prediction.probabilities.indices.contains(fallbackIndex) else {
                throw DecisionError.invalidRequest("fallback option index is out of range")
            }
            outcome = .fallback(fallbackIndex, reason: reason)
        } else {
            outcome = .abstained(reason: reason)
        }
        trace.append(DecisionTraceEvent(.resolved, detail: outcomeName(outcome)))
        return DecisionResult(
            outcome: outcome,
            confidence: confidence,
            probabilities: prediction.probabilities,
            trace: trace
        )
    }

    private func map<Value: Sendable>(
        _ result: DecisionResult<Int>,
        transform: (Int) -> Value
    ) -> DecisionResult<Value> {
        DecisionResult(
            outcome: mapOutcome(result.outcome, transform: transform),
            confidence: result.confidence,
            probabilities: result.probabilities,
            trace: result.trace
        )
    }

    private func mapOutcome<Value: Sendable>(
        _ outcome: DecisionOutcome<Int>,
        transform: (Int) -> Value
    ) -> DecisionOutcome<Value> {
        switch outcome {
        case let .accepted(value): .accepted(transform(value))
        case let .abstained(reason): .abstained(reason: reason)
        case let .fallback(value, reason): .fallback(transform(value), reason: reason)
        }
    }

    private func outcomeName(_ outcome: DecisionOutcome<Int>) -> String {
        switch outcome {
        case .accepted: "accepted"
        case .abstained: "abstained"
        case .fallback: "fallback"
        }
    }

    private func normalizedConfidence(_ probabilities: [Double]) -> Double {
        guard probabilities.count > 1 else { return 1 }
        let entropy = -probabilities.reduce(0.0) { partial, probability in
            probability > 0 ? partial + probability * log(probability) : partial
        }
        return min(max(1 - entropy / log(Double(probabilities.count)), 0), 1)
    }
}
