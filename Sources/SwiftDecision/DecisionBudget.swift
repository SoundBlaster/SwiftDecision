import Foundation

/// A monotonic deadline shared by all inferences in one logical operation.
/// Create a fresh budget per operation; copies preserve the same deadline.
public struct DecisionBudget: Sendable {
    let deadline: TimeInterval
    let clock: any DecisionClock

    /// Starts the budget immediately. Zero means already expired.
    ///
    /// The engine uses this clock for both remaining time and timeout waiting when the budget is
    /// supplied, even if the engine was created with a different clock.
    public init(timeout: TimeInterval, clock: any DecisionClock = SystemDecisionClock()) throws {
        guard timeout.isFinite, timeout >= 0 else {
            throw DecisionError.invalidRequest("budget must be a finite, nonnegative number of seconds")
        }
        self.clock = clock
        deadline = clock.now + timeout
    }

    /// Seconds remaining, clamped to zero. Reading does not reset the budget.
    public var remainingTime: TimeInterval {
        max(0, deadline - clock.now)
    }
}
