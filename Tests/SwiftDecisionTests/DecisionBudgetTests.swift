import Foundation
import SwiftDecision
import XCTest

final class DecisionBudgetTests: XCTestCase {
    func testInvalidBudgetsAreRejected() {
        for value in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(try DecisionBudget(timeout: value))
        }
    }

    func testExpiredBudgetSkipsBackendForEveryPrimitive() async throws {
        let backend = ClosureDecisionBackend { _ in
            XCTFail("Expired budget must not call backend")
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "unused")
        }
        let engine = DecisionEngine(backend: backend)
        let budget = try DecisionBudget(timeout: 0)
        do {
            _ = try await engine.noul(statement: "question", context: "context", budget: budget)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
        do {
            _ = try await engine.choice(instructions: "choose", context: "context",
                options: [ChoiceOption(label: 0, description: "zero"), ChoiceOption(label: 1, description: "one")],
                budget: budget)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
        do {
            _ = try await engine.score(instructions: "score", context: "context",
                levels: [("zero", 0), ("one", 1)], budget: budget)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
    }

    func testSharedBudgetDoesNotRestartForSecondInference() async throws {
        let firstSleep = expectation(description: "First backend registered its sleep")
        let secondSleep = expectation(description: "Second backend registered its sleep")
        let clock = ManualDecisionClock { deadline in
            if deadline == 120 { firstSleep.fulfill() }
            if deadline == 140 { secondSleep.fulfill() }
        }
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await clock.sleep(until: clock.now + 20)
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "slow")
        })
        let budget = try DecisionBudget(timeout: 30, clock: clock)
        let first = Task { try await engine.noul(statement: "first", context: "context", budget: budget) }
        guard await XCTWaiter.fulfillment(of: [firstSleep], timeout: 5) == .completed else {
            first.cancel()
            _ = try? await first.value
            return XCTFail("First backend did not start")
        }
        clock.advance(by: 20)
        _ = try await first.value
        XCTAssertEqual(budget.remainingTime, 10)

        let finished = expectation(description: "Shared deadline ends second inference")
        let second = Task {
            defer { finished.fulfill() }
            return try await engine.noul(statement: "second", context: "context", budget: budget)
        }
        guard await XCTWaiter.fulfillment(of: [secondSleep], timeout: 5) == .completed else {
            second.cancel()
            _ = try? await second.value
            return XCTFail("Second backend did not start")
        }
        clock.advance(by: 10)
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        second.cancel() // Also releases waiters if a regression prevents the deadline from firing.
        XCTAssertEqual(completion, .completed)
        do {
            _ = try await second.value
            XCTFail("Expected shared timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
    }

    func testConfigurationTimeoutRemainsACeiling() async throws {
        let started = expectation(description: "Backend registered its sleep")
        let clock = ManualDecisionClock { deadline in
            if deadline == 300 { started.fulfill() }
        }
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await clock.sleep(until: clock.now + 200)
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "slow")
        }, configuration: .init(timeout: 10))
        let finished = expectation(description: "Configuration deadline ends inference")
        let task = Task {
            defer { finished.fulfill() }
            return try await engine.noul(statement: "question", context: "context",
                budget: DecisionBudget(timeout: 100, clock: clock))
        }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Backend did not start")
        }
        clock.advance(by: 10)
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        task.cancel()
        XCTAssertEqual(completion, .completed)
        do {
            _ = try await task.value
            XCTFail("Expected per-inference timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
    }

    func testBudgetCopiesKeepTheInjectedClockAndDeadline() throws {
        let clock = ManualDecisionClock()
        let budget = try DecisionBudget(timeout: 30, clock: clock)
        let copy = budget
        clock.advance(by: 20)
        XCTAssertEqual(budget.remainingTime, 10)
        XCTAssertEqual(copy.remainingTime, 10)
        clock.advance(by: 20)
        XCTAssertEqual(budget.remainingTime, 0)
        XCTAssertEqual(copy.remainingTime, 0)
    }

    func testEngineTimeoutWithoutBudgetUsesInjectedClockAndCleansUpCancellation() async throws {
        let started = expectation(description: "Backend registered its sleep")
        let clock = ManualDecisionClock { deadline in
            if deadline == 300 { started.fulfill() }
        }
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await clock.sleep(until: clock.now + 200)
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "slow")
        }, configuration: .init(timeout: 10), clock: clock)
        let finished = expectation(description: "Engine clock ends inference")
        let task = Task {
            defer { finished.fulfill() }
            return try await engine.noul(statement: "question", context: "context")
        }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Backend did not start")
        }
        clock.advance(by: 10)
        let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        task.cancel()
        XCTAssertEqual(completion, .completed)
        do {
            _ = try await task.value
            XCTFail("Expected engine timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    func testFailureCategoriesDoNotTreatCancellationAsTransient() {
        XCTAssertEqual(DecisionFailureCategory.classify(CancellationError()), .cancelled)
        XCTAssertEqual(DecisionFailureCategory.classify(DecisionError.timedOut), .timedOut)
        XCTAssertFalse(DecisionFailureCategory.cancelled.isTransient)
        XCTAssertFalse(DecisionFailureCategory.permanent.isTransient)
    }
}
