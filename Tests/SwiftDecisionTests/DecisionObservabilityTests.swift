import Foundation
import SwiftDecision
import Testing

@Suite("Decision observability")
struct DecisionObservabilityTests {
    @Test("Trace collection can be disabled while metrics remain available")
    func traceModeCanDisableEventsAndStillReportMetrics() async throws {
        let recorder = MetricsRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.05, 0.95]),
            configuration: .init(traceMode: .disabled),
            metricsHandler: { recorder.record($0) }
        )

        let result = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")

        #expect(result.value == true)
        #expect(result.probabilities == [0.05, 0.95])
        #expect(result.trace.isEmpty)

        let metrics = recorder.snapshot()
        #expect(metrics.count == 1)
        #expect(metrics.first?.kind == .noul)
        #expect(metrics.first?.status == .accepted)
        #expect(metrics.first?.durationSeconds ?? -1 >= 0)
    }

    @Test("Metrics distinguish abstention fallback and failed calls")
    func metricsReportDecisionStatusesAndValidationFailures() async throws {
        let recorder = MetricsRecorder()
        let engine = DecisionEngine(
            backend: FixedDecisionBackend(probabilities: [0.51, 0.49]),
            configuration: .init(
                policies: .init(noul: .init(minimumProbability: 0.8, minimumConfidence: 0))
            ),
            metricsHandler: { recorder.record($0) }
        )

        let abstained = try await engine.noul(statement: "Is it urgent?", context: "Unclear.")
        let fallback = try await engine.noul(statement: "Is it urgent?", context: "Unclear.", fallback: true)
        #expect(abstained.value == nil)
        #expect(fallback.value == true)

        await #expect(throws: DecisionError.self) {
            _ = try await engine.choice(
                instructions: "Choose a label.",
                context: "Invalid duplicate labels.",
                options: [
                    ChoiceOption(label: "same", description: "First."),
                    ChoiceOption(label: "same", description: "Second.")
                ]
            )
        }

        let metrics = recorder.snapshot()
        #expect(metrics.map(\.status) == [.abstained, .fallback, .failed])
        #expect(metrics.map(\.kind) == [.noul, .noul, .choice])
        #expect(metrics.allSatisfy { $0.durationSeconds >= 0 })
    }

    @Test("Provider errors remain errors and produce a failed metric")
    func providerErrorsAreReportedWithoutBeingConverted() async throws {
        let recorder = MetricsRecorder()
        let engine = DecisionEngine(
            backend: ClosureDecisionBackend { _ in throw FixtureBackendError.failed },
            metricsHandler: { recorder.record($0) }
        )

        await #expect(throws: FixtureBackendError.self) {
            _ = try await engine.noul(statement: "Is it urgent?", context: "A fixture request.")
        }

        #expect(recorder.snapshot().map(\.status) == [.failed])
    }
}

private struct FixedDecisionBackend: DecisionBackend {
    let probabilities: [Double]

    func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        DecisionPrediction(probabilities: probabilities, modelIdentifier: "fixture")
    }
}

private enum FixtureBackendError: Error {
    case failed
}

/// Test-only recorder; all mutable state is accessed while holding the private lock.
private final class MetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMetrics: [DecisionMetric] = []

    func record(_ metric: DecisionMetric) {
        lock.lock()
        defer { lock.unlock() }
        storedMetrics.append(metric)
    }

    func snapshot() -> [DecisionMetric] {
        lock.lock()
        defer { lock.unlock() }
        return storedMetrics
    }
}
