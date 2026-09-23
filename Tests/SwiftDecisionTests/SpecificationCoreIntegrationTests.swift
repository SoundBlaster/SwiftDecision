import Foundation
import SpecificationCore
import SwiftDecision
import XCTest

final class SpecificationCoreIntegrationTests: XCTestCase {
    func testPackageCanEvaluateCoreAsyncSpecification() async throws {
        let specification = AnyAsyncSpecification<Int> { $0 > 0 }
        let isSatisfied = try await specification.isSatisfiedBy(1)

        XCTAssertTrue(isSatisfied)
    }

    func testPackageCanComposeCoreAsyncSpecificationsIntoDecision() async throws {
        let positive = AnyAsyncSpecification<Int> { $0 > 0 }
        let even = AnyAsyncSpecification<Int> { $0.isMultiple(of: 2) }
        let decision = positive.andAsync(even).returningAsync("accepted")
        let accepted = try await decision.decide(4)
        let rejected = try await decision.decide(3)

        XCTAssertEqual(accepted, "accepted")
        XCTAssertNil(rejected)
    }

    func testPackageCanBuildCoreAsyncFirstMatchDecision() async throws {
        let decision = AsyncFirstMatchSpec<Int, String>.builder()
            .addPredicate({ $0 > 0 }, result: "positive")
            .fallback("other")
            .build()
        let positive = try await decision.decide(1)
        let fallback = try await decision.decide(-1)

        XCTAssertEqual(positive, "positive")
        XCTAssertEqual(fallback, "other")
    }

    func testDecisionResultIncludesSpecificationCoreTrace() async throws {
        let engine = DecisionEngine(backend: FixedDecisionBackend(probabilities: [0.1, 0.9]))

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        XCTAssertEqual(result.value, true)
        XCTAssertFalse(result.trace.isEmpty)
        XCTAssertFalse(result.specificationTrace.isEmpty)
        XCTAssertTrue(result.specificationTrace.contains { $0.outcome == .satisfied })
        XCTAssertTrue(result.specificationTrace.contains { $0.outcome == .skipped })
        XCTAssertTrue(result.specificationTrace.contains { $0.parentID != nil })
        XCTAssertTrue(result.specificationTrace.contains { $0.name == "request validation" })
        XCTAssertTrue(result.specificationTrace.contains { $0.name == "policy routing" })
        XCTAssertTrue(result.specificationTrace.contains { $0.name == "backend prediction" })
        XCTAssertTrue(result.specificationTrace.contains { $0.name == "output validation" })
        XCTAssertTrue(result.specificationTrace.contains {
            $0.name == "acceptance policy" && $0.outcome == .satisfied
        })
    }

    func testChoiceAndScoreResultsIncludeSpecificationCoreTrace() async throws {
        let engine = DecisionEngine(backend: FixedDecisionBackend(probabilities: [0.1, 0.9]))
        let choice = try await engine.choice(
            instructions: "Choose a team.",
            context: "A fixture request.",
            options: [
                ChoiceOption(label: "support", description: "Product support."),
                ChoiceOption(label: "billing", description: "Billing questions.")
            ]
        )
        let score = try await engine.score(
            instructions: "Score the response.",
            context: "A fixture request.",
            levels: [("incomplete", 0), ("complete", 1)]
        )

        XCTAssertEqual(choice.value, "billing")
        XCTAssertFalse(choice.specificationTrace.isEmpty)
        XCTAssertEqual(score.value?.level, 1)
        XCTAssertFalse(score.specificationTrace.isEmpty)
    }

    func testDisabledDecisionTraceSuppressesSpecificationCoreTrace() async throws {
        let recorder = SpecificationTraceEventRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            configuration: .init(traceMode: .disabled),
            specificationTraceHandler: { recorder.append($0) }
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        XCTAssertTrue(result.trace.isEmpty)
        XCTAssertTrue(result.specificationTrace.isEmpty)
        XCTAssertTrue(recorder.batches().isEmpty)
    }

    func testAcceptanceTraceShowsRejectedThresholdAndFallback() async throws {
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.49, 0.51]),
            configuration: .init(policies: .init(noul: .init(minimumProbability: 0.8, minimumConfidence: 0)))
        )

        let result = try await engine.noul(
            statement: "Is it urgent?", context: "A fixture request.", fallback: false
        )

        XCTAssertEqual(result.value, false)
        XCTAssertTrue(result.specificationTrace.contains {
            $0.name == "acceptance policy" && $0.outcome == .unsatisfied
        })
        XCTAssertTrue(result.specificationTrace.contains {
            $0.name == "minimum probability" && $0.outcome == .unsatisfied
        })
        XCTAssertTrue(result.specificationTrace.contains { $0.outcome == .skipped })
    }

    func testSpecificationTraceHandlerMatchesSuccessfulResult() async throws {
        let recorder = SpecificationTraceEventRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            specificationTraceHandler: { recorder.append($0) }
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        let batches = recorder.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.map(\.id), result.specificationTrace.map(\.id))
        XCTAssertEqual(batches.first?.map(\.name), result.specificationTrace.map(\.name))
    }

    func testSpecificationTraceHandlerReceivesEventsWhenBackendFails() async {
        let recorder = SpecificationTraceEventRecorder()
        let engine = DecisionEngine(
            backend: ClosureDecisionBackend { _ in throw FixtureBackendError.failed },
            specificationTraceHandler: { recorder.append($0) }
        )

        do {
            _ = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")
            XCTFail("Expected backend error")
        } catch is FixtureBackendError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.snapshot().contains {
            if case .failed = $0.outcome {
                return true
            }
            return false
        })
    }

    func testSpecificationTraceHandlerCoversEarlyValidationFailures() async {
        let recorder = SpecificationTraceEventRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            specificationTraceHandler: { recorder.append($0) }
        )
        let options = [
            ChoiceOption(label: "support", description: "Support."),
            ChoiceOption(label: "billing", description: "Billing.")
        ]

        for operation in 0 ..< 4 {
            do {
                switch operation {
                case 0:
                    _ = try await engine.choice(
                        instructions: "Choose a team.", context: "A request.",
                        options: [options[0], options[0]]
                    )
                case 1:
                    _ = try await engine.choice(
                        instructions: "Choose a team.", context: "A request.",
                        options: options, fallback: "other"
                    )
                case 2:
                    _ = try await engine.score(
                        instructions: "Score.", context: "A request.", levels: [("only", 1)]
                    )
                default:
                    _ = try await engine.score(
                        instructions: "Score.", context: "A request.",
                        levels: [("low", 0), ("high", 1)],
                        fallback: ScoreValue(level: 2, expectedValue: 0)
                    )
                }
                XCTFail("Expected invalid request")
            } catch is DecisionError {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(recorder.batches().count, 4)
        XCTAssertTrue(recorder.batches().allSatisfy(\.isEmpty))
    }
}

private enum FixtureBackendError: Error {
    case failed
}

private final class SpecificationTraceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpecificationTraceEvent] = []
    private var recordedBatches: [[SpecificationTraceEvent]] = []

    func append(_ newEvents: [SpecificationTraceEvent]) {
        lock.lock()
        defer { lock.unlock() }
        events.append(contentsOf: newEvents)
        recordedBatches.append(newEvents)
    }

    func snapshot() -> [SpecificationTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func batches() -> [[SpecificationTraceEvent]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBatches
    }
}

private struct FixedDecisionBackend: DecisionBackend {
    let probabilities: [Double]

    func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        DecisionPrediction(probabilities: probabilities, modelIdentifier: "fixture")
    }
}
