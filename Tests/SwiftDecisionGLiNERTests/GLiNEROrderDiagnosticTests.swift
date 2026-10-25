#if SWIFTDECISION_GLINER
import CoreML
import Foundation
import SwiftDecision
import SwiftDecisionGLiNER
import Testing

/// A measurement, not an assertion of model quality or calibrated confidence.
struct GLiNEROrderDiagnosticTests {
    private static let checkpoint = ProcessInfo.processInfo.environment["SWIFTDECISION_GLINER_ORDER_CHECKPOINT"]

    @Test(.enabled(if: checkpoint != nil, "Opt in with SWIFTDECISION_GLINER_ORDER_CHECKPOINT."))
    func measureOptionOrderSensitivity() async throws {
        guard #available(macOS 14, iOS 17, *) else { return }
        let backend = try await GLiNERCoreMLBackend.load(
            checkpointAt: URL(fileURLWithPath: try #require(Self.checkpoint)), computeUnits: .cpuOnly)
        let canonical = try await GLiNERCoreMLBackend.load(
            checkpointAt: URL(fileURLWithPath: try #require(Self.checkpoint)), computeUnits: .cpuOnly,
            choiceOrdering: .canonical)
        let cases: [(String, [String], String, String, Bool)] = [
            ("russian-bare", ["Красный", "синий"], "Красный или синий?", "Красный или синий?", true),
            ("english-bare", ["Red", "blue"], "Red or blue?", "Red or blue?", true),
            ("english-fixed-question", ["Red", "blue"], "Red or blue?", "Red or blue?", false),
            ("english-neutral", ["Red", "blue"], "Choose a color.", "No additional observations.", false),
            ("star", ["Hello", "Sun"], "Choose the star", "No additional observations.", false),
            ("star-evidence", ["Hello", "Sun"], "Choose the star", "The Sun is a star. Hello is a greeting.", false),
            ("billing", ["technical", "billing"], "Route the support message to the correct department.", "I was charged twice for the same order.", false),
            ("blue-evidence", ["Red", "blue"], "Choose the color named in the text.", "The only color named in the text is blue.", false),
        ]
        for (name, labels, instructions, context, rewriteQuestion) in cases {
            for semanticIDs in [false, true] {
                for reversed in [false, true] {
                    let ordered = reversed ? Array(labels.reversed()) : labels
                    let question = ordered.joined(separator: name == "russian-bare" ? " или " : " or ") + "?"
                    let prompt = DecisionPrompt(id: name, kind: .choice,
                        instructions: rewriteQuestion ? question : instructions,
                        context: rewriteQuestion ? question : context,
                        options: ordered.enumerated().map {
                            DecisionOption(id: semanticIDs ? $0.element.lowercased() : String($0.offset), description: $0.element)
                        })
                    for (ordering, model) in [("input", backend), ("canonical", canonical)] {
                        let result = try await model.predict(for: prompt)
                        #expect(result.probabilities.count == ordered.count)
                        #expect(result.probabilities.allSatisfy { $0.isFinite && (0 ... 1).contains($0) })
                        let record: [String: Any] = ["case": name, "semanticIDs": semanticIDs,
                            "reversed": reversed, "ordering": ordering, "labels": ordered, "probabilities": result.probabilities]
                        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                        print("GLINER_ORDER " + String(decoding: data, as: UTF8.self))
                    }
                }
            }
        }
    }

    @Test(.enabled(if: checkpoint != nil, "Opt in with SWIFTDECISION_GLINER_ORDER_CHECKPOINT."))
    func canonicalNativeScoresReturnInCallerOrder() async throws {
        guard #available(macOS 14, iOS 17, *) else { return }
        let backend = try await GLiNERCoreMLBackend.load(
            checkpointAt: URL(fileURLWithPath: try #require(Self.checkpoint)), computeUnits: .cpuOnly,
            choiceOrdering: .canonical)
        let labels = ["red", "blue", "green"]
        var reference: [String: Double]?
        for order in [labels, Array(labels.reversed()), ["blue", "red", "green"]] {
            let prompt = DecisionPrompt(id: "native-order", kind: .choice,
                instructions: "Choose a color.", context: "No additional observations.",
                options: order.enumerated().map { .init(id: String($0.offset), description: $0.element) })
            let result = try await backend.predict(for: prompt)
            let mapped = Dictionary(uniqueKeysWithValues: zip(order, result.probabilities))
            if let reference {
                for label in labels {
                    #expect(abs(try #require(mapped[label]) - #require(reference[label])) < 0.000001)
                }
            } else { reference = mapped }
        }
    }
}
#endif
