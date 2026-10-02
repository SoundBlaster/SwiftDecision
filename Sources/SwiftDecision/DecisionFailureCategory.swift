/// Provider-independent failure categories. Classification does not authorize retries or fallback.
public enum DecisionFailureCategory: Sendable, Equatable {
    case cancelled
    case timedOut
    case transport
    case rateLimited
    case serviceUnavailable
    case permanent

    /// Whether a later attempt may succeed. Cancellation is never transient.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .transport, .rateLimited, .serviceUnavailable: true
        case .cancelled, .permanent: false
        }
    }

    /// Classifies engine failures; provider adapters may refine other errors.
    public static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? DecisionError, case .timedOut = error { return .timedOut }
        return .permanent
    }
}
