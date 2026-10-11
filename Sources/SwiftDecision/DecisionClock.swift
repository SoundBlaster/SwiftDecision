import Foundation

/// Monotonic time and cancellable waiting used for decision deadlines.
///
/// Values from `now` and `sleep(until:)` must use the same epoch, measured in seconds.
/// Implementations must be thread-safe, must never move time backwards, and must respond to
/// task cancellation. Waiting for a deadline that has passed returns immediately.
public protocol DecisionClock: Sendable {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}

/// The production decision clock, backed by system uptime rather than calendar time.
public struct SystemDecisionClock: DecisionClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        let remaining = deadline - now
        guard remaining > 0 else { return }
        let nanoseconds = UInt64(min(remaining * 1_000_000_000, Double(Int64.max)))
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
