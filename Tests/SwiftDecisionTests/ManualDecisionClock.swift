import Foundation
import SwiftDecision

/// A manually advanced clock; registration callbacks let tests synchronize without sleeping.
/// SAFETY: All mutable state is private and accessed under `lock`. Continuations and callbacks
/// are resumed/invoked after releasing the lock, and no lock is held across suspension.
final class ManualDecisionClock: DecisionClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval = 100
    private var sleepers: [UUID: Sleeper] = [:]
    private let onSleep: @Sendable (TimeInterval) -> Void

    init(onSleep: @escaping @Sendable (TimeInterval) -> Void = { _ in }) {
        self.onSleep = onSleep
    }

    var now: TimeInterval { withLock { currentTime } }
    var pendingSleepCount: Int { withLock { sleepers.count } }

    func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediateResult: Result<Void, Error>? = withLock {
                    // Cancellation before registration is visible on this same task. Cancellation
                    // after this check removes the registered sleeper under the same lock.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= currentTime { return .success(()) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                } else {
                    onSleep(deadline)
                }
            }
        } onCancel: {
            let sleeper = self.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by interval: TimeInterval) {
        precondition(interval.isFinite && interval >= 0)
        let ready = withLock {
            currentTime += interval
            let ready = sleepers.filter { $0.value.deadline <= currentTime }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
