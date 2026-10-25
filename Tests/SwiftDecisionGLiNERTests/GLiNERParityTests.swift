#if SWIFTDECISION_GLINER
import CoreML
import Foundation
import SwiftDecision
@testable import SwiftDecisionGLiNER
import Testing

struct GLiNERParityTests {
    private static let checkpoint = ProcessInfo.processInfo.environment["SWIFTDECISION_GLINER_CHECKPOINT"]

    private struct Reference: Decodable {
        struct Prompt: Decodable {
            let id: String
            let kind: String
            let instructions: String
            let context: String
            let options: [Option]
            let expected: String?
            let category: String
            struct Option: Decodable { let id: String; let description: String }
            var value: DecisionPrompt {
                DecisionPrompt(id: id, kind: DecisionKind(rawValue: kind)!, instructions: instructions,
                               context: context, options: options.map { .init(id: $0.id, description: $0.description) })
            }
        }
        let prompt: Prompt
        let inputIDs: [Int]
        let markerPositions: [Int]
        let probabilities: [Double]
        let coreMLProbabilities: [Double]
    }

    @Test(.enabled(if: checkpoint != nil, "Set SWIFTDECISION_GLINER_CHECKPOINT to explicitly run local inference."))
    func nativeInferenceMatchesPinnedPythonReference() async throws {
        guard #available(macOS 14, iOS 17, *) else {
            Issue.record("GLiNER inference requires macOS 14 or iOS 17")
            return
        }
        let directory = URL(fileURLWithPath: try #require(Self.checkpoint))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf:
            Bundle.module.url(forResource: "reference", withExtension: "json", subdirectory: "Fixtures")!))
        let backend = try await GLiNERCoreMLBackend.load(checkpointAt: directory, computeUnits: .cpuOnly)
        let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("gliner.json"))) as? [String: Any])
        let quantized = metadata["weightBits"] as? Int == 8
        var semanticCorrect = 0
        var semanticCount = 0
        var latencies: [Double] = []
        for reference in references {
            let input = try await backend.encodedInput(for: reference.prompt.value)
            #expect(input.inputIDs == reference.inputIDs, "Tokenizer parity: \(reference.prompt.id)")
            #expect(input.markerPositions == reference.markerPositions)
            let start = ContinuousClock.now
            let result = try await backend.predict(for: reference.prompt.value)
            let duration = start.duration(to: .now).components
            latencies.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            #expect(result.probabilities.count == reference.probabilities.count)
            let expectedProbabilities = quantized ? reference.coreMLProbabilities : reference.probabilities
            for (actual, expected) in zip(result.probabilities, expectedProbabilities) {
                #expect(actual.isFinite && (0 ... 1).contains(actual))
                #expect(abs(actual - expected) < 0.0001, "Core ML runtime parity: \(reference.prompt.id)")
            }
            #expect(abs(result.probabilities.reduce(0, +) - 1) < 1e-6)
            if let expected = reference.prompt.expected {
                semanticCount += 1
                let best = result.probabilities.indices.max { result.probabilities[$0] < result.probabilities[$1] }!
                if reference.prompt.options[best].id == expected { semanticCorrect += 1 }
            }
            print("GLINER \(reference.prompt.id): \(result.probabilities)")
        }
        print("GLINER diagnostic semantic accuracy: \(semanticCorrect)/\(semanticCount); median seconds: \(latencies.sorted()[latencies.count / 2])")

        // Exercise the public typed engine, including its SpecificationCore
        // validation, routing, tracing and acceptance policy.
        let automaticBackend = try await GLiNERCoreMLBackend.load(checkpointAt: directory)
        let engine = DecisionEngine(backend: automaticBackend)
        let yes = try await engine.noul(statement: "The shipment has been delivered.", context: "The shipment was delivered today.")
        #expect(yes.value == true)
        let route = try await engine.choice(instructions: "Route the support message to the correct department.",
                                           context: "I was charged twice for the same order.",
                                           options: [ChoiceOption(label: "technical", description: "Technical support"),
                                                     ChoiceOption(label: "billing", description: "Billing"),
                                                     ChoiceOption(label: "shipping", description: "Shipping")])
        #expect(route.value == "billing")
        #expect(!route.specificationTrace.isEmpty)
        let severity = try await engine.score(
            instructions: "Rate the incident severity using the supplied rubric.",
            context: "All customers are locked out of the service.",
            levels: [(description: "Low: cosmetic issue only", value: 0),
                     (description: "Medium: partial loss of functionality", value: 1),
                     (description: "High: complete service outage", value: 2)]
        )
        #expect(severity.value?.level == 2)
        #expect(try #require(severity.value).expectedValue > 1.8)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.predict(for: references[0].prompt.value)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
#endif
