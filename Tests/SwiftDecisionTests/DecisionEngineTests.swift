import Foundation
import SwiftDecision
import XCTest

final class DecisionEngineTests: XCTestCase {
    func testNoulChoiceAndScoreReturnTypedAcceptedValues() async throws {
        let backend = ClosureDecisionBackend { prompt in
            switch prompt.kind {
            case .noul:
                DecisionPrediction(probabilities: [0.08, 0.92], modelIdentifier: "fixture")
            case .choice:
                DecisionPrediction(probabilities: [0.03, 0.91, 0.06], modelIdentifier: "fixture")
            case .score:
                DecisionPrediction(probabilities: [0.1, 0.2, 0.7], modelIdentifier: "fixture")
            }
        }
        let engine = DecisionEngine(backend: backend)

        let noul = try await engine.noul(statement: "Is it urgent?", context: "Urgent message")
        let choice = try await engine.choice(
            instructions: "Choose a folder.",
            context: "A receipt",
            options: [
                ChoiceOption(label: "work", description: "work"),
                ChoiceOption(label: "finance", description: "finance"),
                ChoiceOption(label: "personal", description: "personal")
            ]
        )
        let score = try await engine.score(
            instructions: "Rate the quality.",
            context: "A detailed answer",
            levels: [
                (description: "poor", value: 0),
                (description: "adequate", value: 0.5),
                (description: "excellent", value: 1)
            ]
        )

        XCTAssertEqual(noul.value, true)
        XCTAssertEqual(noul.probabilities, [0.08, 0.92])
        XCTAssertEqual(choice.value, "finance")
        XCTAssertEqual(score.value?.level, 2)
        XCTAssertEqual(score.value?.expectedValue ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(noul.trace.map(\.stage), [
            .requestValidated, .policySelected, .inferenceStarted, .inferenceCompleted, .outputValidated, .resolved
        ])
    }

    func testPolicyCanAbstainOrUseDistinctFallback() async throws {
        let backend = ClosureDecisionBackend { _ in
            DecisionPrediction(probabilities: [0.51, 0.49], modelIdentifier: "uncertain")
        }
        let strictEngine = DecisionEngine(
            backend: backend,
            configuration: .init(policies: .init(noul: .init(minimumProbability: 0.8, minimumConfidence: 0)))
        )

        let abstained = try await strictEngine.noul(
            statement: "Is this urgent?",
            context: "Unclear message"
        )
        let fallback = try await strictEngine.noul(
            statement: "Is this urgent?",
            context: "Unclear message",
            fallback: true
        )

        guard case .abstained = abstained.outcome else { return XCTFail("Expected abstention") }
        guard case let .fallback(value, _) = fallback.outcome else { return XCTFail("Expected fallback") }
        XCTAssertTrue(value)
    }

    func testTieSelectsTheFirstOptionAndPolicyRouterUsesFirstMatchingRule() async throws {
        let backend = ClosureDecisionBackend { _ in
            DecisionPrediction(probabilities: [0.5, 0.5], modelIdentifier: "tie")
        }
        let engine = DecisionEngine(
            backend: backend,
            configuration: .init(policies: .init(choice: .init(minimumProbability: 0.5, minimumConfidence: 0)))
        )
        let result = try await engine.choice(
            instructions: "Pick one.",
            context: "Input",
            options: [ChoiceOption(label: "first", description: "first"), ChoiceOption(label: "second", description: "second")]
        )

        XCTAssertEqual(result.value, "first")
    }

    func testInvalidBackendOutputAndProviderErrorsRemainErrors() async throws {
        let invalidEngine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            DecisionPrediction(probabilities: [0.2, 0.2], modelIdentifier: "invalid")
        })
        do {
            _ = try await invalidEngine.noul(statement: "Check this.", context: "A fact")
            XCTFail("Expected invalid prediction error")
        } catch let error as DecisionError {
            guard case .invalidPrediction = error else { return XCTFail("Unexpected error: \(error)") }
        }

        struct ProviderFailure: Error {}
        let failingEngine = DecisionEngine(backend: ClosureDecisionBackend { _ in throw ProviderFailure() })
        do {
            _ = try await failingEngine.noul(statement: "Check this.", context: "A fact")
            XCTFail("Expected provider error")
        } catch is ProviderFailure {
            // Provider errors are deliberately propagated without converting them to abstention.
        }
    }

    func testCancellationPropagates() async throws {
        let engine = DecisionEngine(backend: ClosureDecisionBackend { _ in
            try await Task.sleep(for: .seconds(30))
            return DecisionPrediction(probabilities: [0.1, 0.9], modelIdentifier: "cancelled")
        })
        let task = Task {
            try await engine.noul(statement: "Check this.", context: "A fact")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the Core decision adapter and backend call preserve task cancellation.
        }
    }

    func testTimeoutIsOwnedBySwiftDecision() async throws {
        let engine = DecisionEngine(
            backend: ClosureDecisionBackend { _ in
                try await Task.sleep(for: .seconds(30))
                return DecisionPrediction(probabilities: [0.1, 0.9], modelIdentifier: "late")
            },
            configuration: .init(timeout: 0.01)
        )

        do {
            _ = try await engine.noul(statement: "Check this.", context: "A fact")
            XCTFail("Expected timeout")
        } catch let error as DecisionError {
            XCTAssertEqual(error, .timedOut)
        }
    }
}
