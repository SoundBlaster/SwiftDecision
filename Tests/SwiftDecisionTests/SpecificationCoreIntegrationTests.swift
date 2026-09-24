import Foundation
import SpecificationCore
import SwiftDecision
import XCTest

final class SpecificationCoreIntegrationTests: XCTestCase {
    private actor BackendStartSignal {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        func markStarted() {
            started = true
            continuation?.resume()
            continuation = nil
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

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

    func testOrderedTraceMergesLifecycleAndSpecificationEventsByTimelinePosition() async throws {
        let engine = DecisionEngine(backend: FixedDecisionBackend(probabilities: [0.1, 0.9]))

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        let records = result.orderedTrace.records
        let sequences = records.compactMap { $0.position?.sequence }
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)

        let lifecycleStages = records.compactMap { record -> DecisionTraceEvent.Stage? in
            guard case let .lifecycle(event) = record else { return nil }
            return event.stage
        }
        XCTAssertEqual(lifecycleStages, [.requestValidated, .policySelected, .inferenceStarted,
                                         .inferenceCompleted, .outputValidated, .resolved])

        let specificationEvents = records.compactMap { record -> SpecificationTraceEvent? in
            guard case let .specification(event) = record else { return nil }
            return event
        }
        XCTAssertEqual(specificationEvents.count, result.specificationTrace.count)
        for event in specificationEvents {
            let start = try XCTUnwrap(event.startPosition)
            let completion = try XCTUnwrap(event.completionPosition)
            XCTAssertLessThanOrEqual(start.sequence, completion.sequence)
        }

        let requestValidation = try XCTUnwrap(specificationEvents.first { $0.name == "request validation" })
        let requestValidationCompletion = try XCTUnwrap(requestValidation.completionPosition)
        let requestValidated = try XCTUnwrap(records.compactMap { record -> DecisionTraceEvent? in
            guard case let .lifecycle(event) = record, event.stage == .requestValidated else { return nil }
            return event
        }.first)
        XCTAssertLessThan(requestValidationCompletion.sequence, requestValidated.position.sequence)

        let backendPrediction = try XCTUnwrap(specificationEvents.first { $0.name == "backend prediction" })
        let backendStart = try XCTUnwrap(backendPrediction.startPosition)
        let backendCompletion = try XCTUnwrap(backendPrediction.completionPosition)
        let inferenceStarted = try XCTUnwrap(records.compactMap { record -> DecisionTraceEvent? in
            guard case let .lifecycle(event) = record, event.stage == .inferenceStarted else { return nil }
            return event
        }.first)
        let inferenceCompleted = try XCTUnwrap(records.compactMap { record -> DecisionTraceEvent? in
            guard case let .lifecycle(event) = record, event.stage == .inferenceCompleted else { return nil }
            return event
        }.first)
        XCTAssertLessThan(inferenceStarted.position.sequence, backendStart.sequence)
        XCTAssertLessThan(backendStart.sequence, backendCompletion.sequence)
        XCTAssertLessThan(backendCompletion.sequence, inferenceCompleted.position.sequence)
    }

    func testDecisionTraceHandlerMatchesSuccessfulResultTimeline() async throws {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            decisionTraceHandler: { recorder.append($0) }
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots[0].records.compactMap { $0.position?.sequence },
            result.orderedTrace.records.compactMap { $0.position?.sequence }
        )
    }

    func testChoiceAndScoreResultsIncludeSpecificationCoreTrace() async throws {
        let engine = DecisionEngine(backend: FixedDecisionBackend(probabilities: [0.1, 0.9]))
        let choice = try await engine.choice(
            instructions: "Choose a team.",
            context: "A fixture request.",
            options: [
                ChoiceOption(label: "support", description: "Product support."),
                ChoiceOption(label: "billing", description: "Billing questions."),
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
        let decisionTraceRecorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            configuration: .init(traceMode: .disabled),
            specificationTraceHandler: { recorder.append($0) },
            decisionTraceHandler: { decisionTraceRecorder.append($0) }
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        XCTAssertTrue(result.trace.isEmpty)
        XCTAssertTrue(result.specificationTrace.isEmpty)
        XCTAssertTrue(recorder.batches().isEmpty)
        XCTAssertTrue(result.orderedTrace.records.isEmpty)
        XCTAssertTrue(decisionTraceRecorder.snapshots().isEmpty)
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

    func testAcceptanceTraceShowsConfidenceRejectionAfterProbabilityPasses() async throws {
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.45, 0.55]),
            configuration: .init(policies: .init(noul: .init(minimumProbability: 0.5, minimumConfidence: 0.5)))
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        XCTAssertNil(result.value)
        XCTAssertTrue(result.specificationTrace.contains {
            $0.name == "minimum probability" && $0.outcome == .satisfied
        })
        XCTAssertTrue(result.specificationTrace.contains {
            $0.name == "minimum confidence" && $0.outcome == .unsatisfied
        })
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

    func testDecisionTraceHandlerReceivesTimelineWhenBackendFails() async {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: ClosureDecisionBackend { _ in throw FixtureBackendError.failed },
            decisionTraceHandler: { recorder.append($0) }
        )

        do {
            _ = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")
            XCTFail("Expected backend error")
        } catch is FixtureBackendError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].records.contains { record in
            guard case let .lifecycle(event) = record else { return false }
            return event.stage == .inferenceStarted
        })
        XCTAssertTrue(snapshots[0].records.contains { record in
            guard case let .specification(event) = record else { return false }
            if case .failed = event.outcome {
                return event.name == "backend prediction"
            }
            return false
        })
    }

    func testDecisionTraceHandlerReceivesEmptySnapshotForEarlyFailure() async {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            decisionTraceHandler: { recorder.append($0) }
        )

        do {
            _ = try await engine.choice(
                instructions: "Choose a team.",
                context: "A fixture request.",
                options: [
                    ChoiceOption(label: "same", description: "First."),
                    ChoiceOption(label: "same", description: "Second."),
                ]
            )
            XCTFail("Expected invalid request")
        } catch is DecisionError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].records.isEmpty)
    }

    func testDecisionTraceHandlerRunsForAbstentionAndFallback() async throws {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.51, 0.49]),
            configuration: .init(
                policies: .init(noul: .init(minimumProbability: 0.8, minimumConfidence: 0))
            ),
            decisionTraceHandler: { recorder.append($0) }
        )

        let abstained = try await engine.noul(statement: "Is it urgent?", context: "Unclear.")
        let fallback = try await engine.noul(
            statement: "Is it urgent?",
            context: "Unclear.",
            fallback: false
        )

        XCTAssertNil(abstained.value)
        XCTAssertEqual(fallback.value, false)
        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 2)
        let resolvedDetails = snapshots.map { snapshot in
            snapshot.records.compactMap { record -> String? in
                guard case let .lifecycle(event) = record, event.stage == .resolved else { return nil }
                return event.detail
            }.first
        }
        XCTAssertEqual(resolvedDetails, ["abstained", "fallback"])
    }

    func testDecisionTraceHandlerKeepsRequestValidationFailureDetails() async {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            decisionTraceHandler: { recorder.append($0) }
        )

        do {
            _ = try await engine.noul(statement: "   ", context: "A fixture request.")
            XCTFail("Expected invalid request")
        } catch is DecisionError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].records.contains { record in
            guard case let .specification(event) = record else { return false }
            return event.name == "request validation" && event.outcome == .unsatisfied
        })
        XCTAssertFalse(snapshots[0].records.contains { record in
            guard case let .lifecycle(event) = record else { return false }
            return event.stage == .requestValidated
        })
    }

    func testDecisionTraceHandlerReceivesPartialSnapshotWhenCancelled() async throws {
        let started = BackendStartSignal()
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: ClosureDecisionBackend { _ in
                await started.markStarted()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return DecisionPrediction(probabilities: [0.1, 0.9], modelIdentifier: "fixture")
            },
            decisionTraceHandler: { recorder.append($0) }
        )
        let task = Task {
            try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")
        }

        await started.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].records.contains { record in
            guard case let .lifecycle(event) = record else { return false }
            return event.stage == .inferenceStarted
        })
        let cancelledBackend = try XCTUnwrap(snapshots[0].records.compactMap { record -> SpecificationTraceEvent? in
            guard case let .specification(event) = record, event.name == "backend prediction" else { return nil }
            return event
        }.first)
        XCTAssertEqual(cancelledBackend.outcome, .cancelled)
        XCTAssertNotNil(cancelledBackend.startPosition)
        XCTAssertNotNil(cancelledBackend.completionPosition)
    }

    func testConcurrentDecisionsHaveIndependentOrderedTimelines() async throws {
        let recorder = DecisionTraceSnapshotRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            decisionTraceHandler: { recorder.append($0) }
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    _ = try await engine.noul(
                        id: "request-\(index)",
                        statement: "Is it urgent?",
                        context: "A fixture request."
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshots = recorder.snapshots()
        XCTAssertEqual(snapshots.count, 12)
        for snapshot in snapshots {
            let positions = snapshot.records.compactMap { $0.position?.sequence }
            XCTAssertFalse(positions.isEmpty)
            XCTAssertEqual(positions, positions.sorted())
            XCTAssertEqual(Set(positions).count, positions.count)
            XCTAssertEqual(positions.first, 1)

            let specificationEvents = snapshot.records.compactMap { record -> SpecificationTraceEvent? in
                guard case let .specification(event) = record else { return nil }
                return event
            }
            let ids = Set(specificationEvents.map(\.id))
            XCTAssertTrue(specificationEvents.allSatisfy { event in
                guard let parentID = event.parentID else { return true }
                return ids.contains(parentID)
            })
        }
    }

    func testSpecificationTraceHandlerCoversEarlyValidationFailures() async {
        let recorder = SpecificationTraceEventRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.1, 0.9]),
            specificationTraceHandler: { recorder.append($0) }
        )
        let options = [
            ChoiceOption(label: "support", description: "Support."),
            ChoiceOption(label: "billing", description: "Billing."),
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

private final class DecisionTraceSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshots: [DecisionTraceSnapshot] = []

    func append(_ snapshot: DecisionTraceSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        storedSnapshots.append(snapshot)
    }

    func snapshots() -> [DecisionTraceSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshots
    }
}

private struct FixedDecisionBackend: DecisionBackend {
    let probabilities: [Double]

    func predict(for _: DecisionPrompt) async throws -> DecisionPrediction {
        DecisionPrediction(probabilities: probabilities, modelIdentifier: "fixture")
    }
}
