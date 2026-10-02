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
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "slow")
        })
        let budget = try DecisionBudget(timeout: 0.3)
        _ = try await engine.noul(statement: "first", context: "context", budget: budget)
        do {
            _ = try await engine.noul(statement: "second", context: "context", budget: budget)
            XCTFail("Expected shared timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
    }

    func testConfigurationTimeoutRemainsACeiling() async throws {
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return DecisionPrediction(probabilities: [0, 1], modelIdentifier: "slow")
        }, configuration: .init(timeout: 0.01))
        do {
            _ = try await engine.noul(statement: "question", context: "context",
                budget: DecisionBudget(timeout: 10))
            XCTFail("Expected per-inference timeout")
        } catch { XCTAssertEqual(error as? DecisionError, .timedOut) }
    }

    func testFailureCategoriesDoNotTreatCancellationAsTransient() {
        XCTAssertEqual(DecisionFailureCategory.classify(CancellationError()), .cancelled)
        XCTAssertEqual(DecisionFailureCategory.classify(DecisionError.timedOut), .timedOut)
        XCTAssertFalse(DecisionFailureCategory.cancelled.isTransient)
        XCTAssertFalse(DecisionFailureCategory.permanent.isTransient)
    }
}
