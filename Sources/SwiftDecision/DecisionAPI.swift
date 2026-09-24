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

    fileprivate var isValid: Bool {
        noul.isValid && choice.isValid && score.isValid
    }
}

private struct AcceptanceMetrics {
    let probability: Double
    let entropyConfidence: Double
}

/// Controls whether an engine records decision lifecycle and SpecificationCore trace events.
public enum DecisionTraceMode: Sendable, Hashable {
    /// Collect both ordered lifecycle and nested specification events.
    case enabled

    /// Return empty decision and specification traces without recording Core evaluations.
    case disabled
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

    /// Monotonic position assigned within this decision invocation.
    public let position: SpecificationTracePosition

    /// Optional stage detail that does not contain request contents.
    public let detail: String?

    fileprivate init(
        _ stage: Stage,
        detail: String? = nil,
        timestamp: Date = Date(),
        position: SpecificationTracePosition
    ) {
        self.stage = stage
        self.timestamp = timestamp
        self.detail = detail
        self.position = position
    }
}

/// One event source in a merged decision timeline.
public enum DecisionTraceRecord: Sendable {
    /// A SwiftDecision lifecycle checkpoint.
    case lifecycle(DecisionTraceEvent)

    /// A SpecificationCore evaluation event.
    case specification(SpecificationTraceEvent)

    /// The start or point position used to order this record within its invocation.
    public var position: SpecificationTracePosition? {
        switch self {
        case let .lifecycle(event): event.position
        case let .specification(event): event.startPosition
        }
    }
}

/// A merged, invocation-local snapshot of lifecycle checkpoints and specification spans.
public struct DecisionTraceSnapshot: Sendable {
    /// Records ordered by their shared timeline sequence.
    public let records: [DecisionTraceRecord]

    fileprivate init(records: [DecisionTraceRecord]) {
        self.records = records
    }
}

/// A content-free measurement for one completed or failed decision call.
public struct DecisionMetric: Sendable, Hashable {
    /// The final state of the decision call.
    public enum Status: String, Sendable, Hashable {
        /// The result satisfied the selected policy.
        case accepted

        /// The result abstained because it did not satisfy the selected policy.
        case abstained

        /// The fallback value was returned because the result did not satisfy policy.
        case fallback

        /// The call threw an error.
        case failed
    }

    /// Kind of decision evaluated.
    public let kind: DecisionKind

    /// Elapsed monotonic time for validation, inference, and result mapping, in seconds.
    public let durationSeconds: TimeInterval

    /// Final status of the decision call.
    public let status: Status

    fileprivate init(kind: DecisionKind, durationSeconds: TimeInterval, status: Status) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.status = status
    }
}

/// A synchronous, sendable callback for receiving per-decision measurements.
///
/// The callback can be invoked concurrently by simultaneous decisions. Implementations should be
/// thread-safe and return promptly; enqueue work when forwarding measurements to an asynchronous sink.
/// Its execution time is not included in ``DecisionMetric/durationSeconds``.
public typealias DecisionMetricsHandler = @Sendable (DecisionMetric) -> Void

/// A synchronous callback for collecting SpecificationCore events from one decision.
///
/// The callback receives the same events exposed by ``DecisionResult/specificationTrace`` on
/// success. It also receives events when a decision throws; the array is empty if validation
/// fails before a SpecificationCore evaluation. Concurrent decisions can invoke the callback
/// concurrently, so implementations should be thread-safe and return promptly.
public typealias SpecificationTraceHandler = @Sendable ([SpecificationTraceEvent]) -> Void

/// A synchronous, sendable callback for the merged timeline from one decision invocation.
///
/// It runs once for each invocation with tracing enabled, including calls that throw or are
/// cancelled. Calls on one engine can invoke it concurrently. Implementations should be
/// thread-safe and return promptly.
public typealias DecisionTraceHandler = @Sendable (DecisionTraceSnapshot) -> Void

/// The final state of a typed decision.
public enum DecisionOutcome<Value: Sendable>: Sendable {
    /// The model result satisfied the selected policy.
    case accepted(Value)

    /// The model result did not satisfy policy and no fallback was supplied.
    case abstained(reason: String)

    /// The model result did not satisfy policy and the caller supplied a fallback value.
    case fallback(Value, reason: String)
}

/// A typed result together with its confidence, probability distribution, and execution traces.
public struct DecisionResult<Value: Sendable>: Sendable {
    /// Accepted, abstained, or fallback result.
    public let outcome: DecisionOutcome<Value>

    /// Probability assigned to the selected option.
    public let confidence: Double

    /// Probabilities aligned to the corresponding request's option order.
    public let probabilities: [Double]

    /// Ordered, content-free execution events.
    public let trace: [DecisionTraceEvent]

    /// SpecificationCore events for input validation, policy routing, backend evaluation, and output validation.
    /// These events contain no request or result values. A `specificationTraceHandler` also receives
    /// events produced before a decision throws.
    public let specificationTrace: [SpecificationTraceEvent]

    /// Lifecycle and SpecificationCore records merged by their shared monotonic positions.
    /// Core events without an explicit timeline position are omitted from this view.
    public var orderedTrace: DecisionTraceSnapshot {
        makeDecisionTraceSnapshot(lifecycleEvents: trace, specificationEvents: specificationTrace)
    }

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
                        try self.resolve(.success(await operation()))
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

        /// Whether decisions collect lifecycle and SpecificationCore trace events.
        public let traceMode: DecisionTraceMode

        /// Creates runtime configuration.
        ///
        /// - Parameters:
        ///   - policies: Per-kind thresholds used to accept or reject predictions.
        ///   - timeout: Optional upper bound for backend inference.
        ///   - traceMode: Whether to collect lifecycle and SpecificationCore events.
        public init(
            policies: DecisionPolicies = DecisionPolicies(),
            timeout: TimeInterval? = nil,
            traceMode: DecisionTraceMode = .enabled
        ) {
            self.policies = policies
            self.timeout = timeout
            self.traceMode = traceMode
        }
    }

    private let backend: any DecisionBackend
    private let configuration: Configuration
    private let metricsHandler: DecisionMetricsHandler?
    private let specificationTraceHandler: SpecificationTraceHandler?
    private let decisionTraceHandler: DecisionTraceHandler?

    /// Creates an engine around any asynchronous decision backend.
    ///
    /// - Parameters:
    ///   - backend: Provider used to produce decision predictions.
    ///   - configuration: Runtime policies, timeout, and trace collection mode.
    ///   - metricsHandler: Optional callback for content-free measurements of completed or failed calls.
    ///   - specificationTraceHandler: Optional callback for SpecificationCore events, including failed calls.
    ///   - decisionTraceHandler: Optional callback for the merged timeline, including failed calls.
    public init(
        backend: some DecisionBackend,
        configuration: Configuration = Configuration(),
        metricsHandler: DecisionMetricsHandler? = nil,
        specificationTraceHandler: SpecificationTraceHandler? = nil,
        decisionTraceHandler: DecisionTraceHandler? = nil
    ) {
        self.backend = backend
        self.configuration = configuration
        self.metricsHandler = metricsHandler
        self.specificationTraceHandler = specificationTraceHandler
        self.decisionTraceHandler = decisionTraceHandler
    }

    /// Evaluates a boolean statement using the fixed option order `[false, true]`.
    public func noul(
        id: String = UUID().uuidString,
        statement: String,
        context: String,
        fallback: Bool? = nil
    ) async throws -> DecisionResult<Bool> {
        try await withObservability(for: .noul) { traceSession in
            let prompt = DecisionPrompt(
                id: id,
                kind: .noul,
                instructions: statement,
                context: context,
                options: [
                    DecisionOption(id: "false", description: "false: no, the statement does not hold"),
                    DecisionOption(id: "true", description: "true: yes, the statement holds"),
                ]
            )
            let value = try await evaluate(
                prompt,
                fallbackIndex: fallback.map { $0 ? 1 : 0 },
                specificationRecorder: traceSession?.specificationRecorder,
                traceCollector: traceSession?.traceCollector
            )
            return map(value) { $0 == 1 }
        }
    }

    /// Selects one typed label while preserving the caller's option order.
    public func choice<Label: Sendable & Hashable>(
        id: String = UUID().uuidString,
        instructions: String,
        context: String,
        options: [ChoiceOption<Label>],
        fallback: Label? = nil
    ) async throws -> DecisionResult<Label> {
        try await withObservability(for: .choice) { traceSession in
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
            let selected = try await evaluate(
                prompt,
                fallbackIndex: fallbackIndex,
                specificationRecorder: traceSession?.specificationRecorder,
                traceCollector: traceSession?.traceCollector
            )
            return map(selected) { options[$0].label }
        }
    }

    /// Scores context against ordered rubric levels and returns the expected numeric value.
    public func score(
        id: String = UUID().uuidString,
        instructions: String,
        context: String,
        levels: [(description: String, value: Double)],
        fallback: ScoreValue? = nil
    ) async throws -> DecisionResult<ScoreValue> {
        try await withObservability(for: .score) { traceSession in
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
            let evaluated = try await evaluate(
                prompt,
                fallbackIndex: fallback.map(\.level),
                specificationRecorder: traceSession?.specificationRecorder,
                traceCollector: traceSession?.traceCollector
            )
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
                trace: evaluated.trace,
                specificationTrace: evaluated.specificationTrace
            )
        }
    }

    private func withObservability<Value: Sendable>(
        for kind: DecisionKind,
        operation: (DecisionTraceSession?) async throws -> DecisionResult<Value>
    ) async throws -> DecisionResult<Value> {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let traceSession = configuration.traceMode == .enabled ? DecisionTraceSession() : nil
        do {
            let result: DecisionResult<Value>
            if let traceSession {
                result = try await operation(traceSession)
            } else {
                result = try await SpecificationTraceRuntime.withoutRecording {
                    try await operation(nil)
                }
            }
            let durationSeconds = max(ProcessInfo.processInfo.systemUptime - startedAt, 0)
            if let traceSession {
                specificationTraceHandler?(traceSession.specificationRecorder.events)
                decisionTraceHandler?(result.orderedTrace)
            }
            metricsHandler?(DecisionMetric(
                kind: kind,
                durationSeconds: durationSeconds,
                status: metricStatus(for: result.outcome)
            ))
            return result
        } catch {
            let durationSeconds = max(ProcessInfo.processInfo.systemUptime - startedAt, 0)
            if let traceSession {
                specificationTraceHandler?(traceSession.specificationRecorder.events)
                decisionTraceHandler?(traceSession.snapshot())
            }
            metricsHandler?(DecisionMetric(
                kind: kind,
                durationSeconds: durationSeconds,
                status: .failed
            ))
            throw error
        }
    }

    private func metricStatus<Value: Sendable>(for outcome: DecisionOutcome<Value>) -> DecisionMetric.Status {
        switch outcome {
        case .accepted: .accepted
        case .abstained: .abstained
        case .fallback: .fallback
        }
    }

    private func evaluate(
        _ prompt: DecisionPrompt,
        fallbackIndex: Int?,
        specificationRecorder: SpecificationTraceRecorder?,
        traceCollector: DecisionTraceCollector?
    ) async throws -> DecisionResult<Int> {
        try Task.checkCancellation()
        guard configuration.policies.isValid else {
            throw DecisionError.invalidRequest("policy thresholds must be between 0 and 1")
        }
        if let timeout = configuration.timeout, !timeout.isFinite || timeout < 0 {
            throw DecisionError.invalidRequest("timeout must be a finite, nonnegative number of seconds")
        }

        let requestIsValid = AnyAsyncSpecification<DecisionPrompt> { candidate in
            !candidate.id.isEmpty
                && !candidate.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && candidate.options.count >= 2
                && candidate.options.allSatisfy { !$0.description.isEmpty }
                && Set(candidate.options.map(\.id)).count == candidate.options.count
        }.tracedAsync("request validation")
        let isRequestValid: Bool
        if let specificationRecorder {
            isRequestValid = try await SpecificationTraceRuntime.evaluateAsync(
                requestIsValid,
                prompt,
                recordingTo: specificationRecorder
            )
        } else {
            isRequestValid = try await requestIsValid.isSatisfiedBy(prompt)
        }
        guard isRequestValid else {
            throw DecisionError.invalidRequest("id, instructions, context, and at least two unique options are required")
        }

        traceCollector?.record(.requestValidated)
        let policyRouter = AsyncFirstMatchSpec<DecisionKind, DecisionPolicy>.builder()
            .addPredicate({ $0 == .noul }, result: configuration.policies.noul)
            .addPredicate({ $0 == .choice }, result: configuration.policies.choice)
            .addPredicate({ $0 == .score }, result: configuration.policies.score)
            .build()
            .tracedAsync("policy routing")
        let selectedPolicy: DecisionPolicy?
        if let specificationRecorder {
            selectedPolicy = try await SpecificationTraceRuntime.decideAsync(
                policyRouter,
                prompt.kind,
                recordingTo: specificationRecorder
            )
        } else {
            selectedPolicy = try await policyRouter.decide(prompt.kind)
        }
        guard let policy = selectedPolicy else {
            throw DecisionError.noPolicySelected
        }
        traceCollector?.record(.policySelected, detail: prompt.kind.rawValue)

        let backendDecision = AnyAsyncDecisionSpec<DecisionPrompt, DecisionPrediction> { [backend, timeout = configuration.timeout] request in
            if let timeout {
                return try await DecisionTimeoutRace<DecisionPrediction>().value(timeout: timeout) {
                    try await backend.predict(for: request)
                }
            }
            return try await backend.predict(for: request)
        }.tracedAsync("backend prediction")
        traceCollector?.record(.inferenceStarted, detail: "\(prompt.options.count) options")
        let predictionResult: DecisionPrediction?
        if let specificationRecorder {
            predictionResult = try await SpecificationTraceRuntime.decideAsync(
                backendDecision,
                prompt,
                recordingTo: specificationRecorder
            )
        } else {
            predictionResult = try await backendDecision.decide(prompt)
        }
        guard let prediction = predictionResult else {
            throw DecisionError.invalidPrediction("backend returned no result")
        }
        traceCollector?.record(.inferenceCompleted, detail: prediction.modelIdentifier)

        let predictionIsValid = AnyAsyncSpecification<DecisionPrediction> { output in
            output.probabilities.count == prompt.options.count
                && output.probabilities.allSatisfy { $0.isFinite && $0 >= 0 }
                && abs(output.probabilities.reduce(0, +) - 1) <= 0.01
        }.tracedAsync("output validation")
        let isPredictionValid: Bool
        if let specificationRecorder {
            isPredictionValid = try await SpecificationTraceRuntime.evaluateAsync(
                predictionIsValid,
                prediction,
                recordingTo: specificationRecorder
            )
        } else {
            isPredictionValid = try await predictionIsValid.isSatisfiedBy(prediction)
        }
        guard isPredictionValid else {
            throw DecisionError.invalidPrediction("expected \(prompt.options.count) finite, nonnegative probabilities summing to 1")
        }
        traceCollector?.record(.outputValidated)

        let selectedIndex = prediction.probabilities.indices.max {
            prediction.probabilities[$0] < prediction.probabilities[$1]
        } ?? 0
        let confidence = prediction.probabilities[selectedIndex]
        let entropyConfidence = normalizedConfidence(prediction.probabilities)
        let acceptanceMetrics = AcceptanceMetrics(probability: confidence, entropyConfidence: entropyConfidence)
        let meetsMinimumProbability = AnyAsyncSpecification<AcceptanceMetrics> {
            $0.probability >= policy.minimumProbability
        }.tracedAsync("minimum probability")
        let meetsMinimumConfidence = AnyAsyncSpecification<AcceptanceMetrics> {
            $0.entropyConfidence >= policy.minimumConfidence
        }.tracedAsync("minimum confidence")
        let acceptancePolicy = meetsMinimumProbability
            .andAsync(meetsMinimumConfidence)
            .tracedAsync("acceptance policy")
        let isAccepted: Bool
        if let specificationRecorder {
            isAccepted = try await SpecificationTraceRuntime.evaluateAsync(
                acceptancePolicy,
                acceptanceMetrics,
                recordingTo: specificationRecorder
            )
        } else {
            isAccepted = try await acceptancePolicy.isSatisfiedBy(acceptanceMetrics)
        }
        let reason = "confidence \(confidence) did not satisfy the selected policy"
        let outcome: DecisionOutcome<Int>
        if isAccepted {
            outcome = .accepted(selectedIndex)
        } else if let fallbackIndex {
            guard prediction.probabilities.indices.contains(fallbackIndex) else {
                throw DecisionError.invalidRequest("fallback option index is out of range")
            }
            outcome = .fallback(fallbackIndex, reason: reason)
        } else {
            outcome = .abstained(reason: reason)
        }
        traceCollector?.record(.resolved, detail: outcomeName(outcome))
        return DecisionResult(
            outcome: outcome,
            confidence: confidence,
            probabilities: prediction.probabilities,
            trace: traceCollector?.events ?? [],
            specificationTrace: specificationRecorder?.events ?? []
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
            trace: result.trace,
            specificationTrace: result.specificationTrace
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

private final class DecisionTraceSession {
    let timeline: SpecificationTraceTimeline
    let specificationRecorder: SpecificationTraceRecorder
    let traceCollector: DecisionTraceCollector

    init() {
        let timeline = SpecificationTraceTimeline()
        self.timeline = timeline
        specificationRecorder = SpecificationTraceRecorder(timeline: timeline)
        traceCollector = DecisionTraceCollector(timeline: timeline)
    }

    func snapshot() -> DecisionTraceSnapshot {
        makeDecisionTraceSnapshot(
            lifecycleEvents: traceCollector.events,
            specificationEvents: specificationRecorder.events
        )
    }
}

private final class DecisionTraceCollector {
    private let timeline: SpecificationTraceTimeline
    private(set) var events: [DecisionTraceEvent] = []

    init(timeline: SpecificationTraceTimeline) {
        self.timeline = timeline
    }

    func record(_ stage: DecisionTraceEvent.Stage, detail: String? = nil) {
        events.append(DecisionTraceEvent(stage, detail: detail, position: timeline.mark()))
    }
}

private func makeDecisionTraceSnapshot(
    lifecycleEvents: [DecisionTraceEvent],
    specificationEvents: [SpecificationTraceEvent]
) -> DecisionTraceSnapshot {
    let lifecycleRecords = lifecycleEvents.map(DecisionTraceRecord.lifecycle)
    let specificationRecords = specificationEvents.compactMap { event -> DecisionTraceRecord? in
        guard event.startPosition != nil else { return nil }
        return .specification(event)
    }
    let records = (lifecycleRecords + specificationRecords).sorted {
        ($0.position?.sequence ?? .max) < ($1.position?.sequence ?? .max)
    }
    return DecisionTraceSnapshot(records: records)
}
