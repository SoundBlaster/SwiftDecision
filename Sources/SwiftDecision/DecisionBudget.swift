import Foundation

/// A monotonic deadline shared by all inferences in one logical operation.
/// Create a fresh budget per operation; copies preserve the same deadline.
public struct DecisionBudget: Sendable {
    private let deadline: TimeInterval

    /// Starts the budget immediately. Zero means already expired.
    public init(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout >= 0 else {
            throw DecisionError.invalidRequest("budget must be a finite, nonnegative number of seconds")
        }
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    /// Seconds remaining, clamped to zero. Reading does not reset the budget.
    public var remainingTime: TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }
}
