#if SWIFTDECISION_MLX
import Foundation
import SwiftDecision
import XCTest

@available(macOS 14, iOS 17, *)
final class LayaParityTests: XCTestCase {
    private struct ReferenceDocument: Decodable {
        let noul: ReferenceCase
        let choice: ReferenceCase
        let score: ReferenceCase
    }

    private struct ReferenceCase: Decodable {
        let selectedOptionID: String
        let probabilities: [Double]
    }

    func testFixedNoulChoiceAndScoreInputsMatchPythonLayaReference() async throws {
        guard let checkpointPath = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_CHECKPOINT"] else {
            throw XCTSkip("Set SWIFTDECISION_LAYA_CHECKPOINT to run local model parity")
        }
        guard let referencePath = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_REFERENCE_JSON"] else {
            throw XCTSkip("Set SWIFTDECISION_LAYA_REFERENCE_JSON to Python Laya-MLX probability outputs")
        }
        let reference = try JSONDecoder().decode(
            ReferenceDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: referencePath))
        )
        let precisionName = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_PRECISION"] ?? "float32"
        let precision: LayaPrecision = precisionName == "float16" ? .float16 : .float32
        let tolerance = precision == .float16 ? 0.02 : 0.0001
        let backend = try LayaMLXBackend(
            checkpointAt: URL(fileURLWithPath: checkpointPath),
            precision: precision
        )
        let cases: [(DecisionPrompt, ReferenceCase)] = [
            (
                DecisionPrompt(
                    id: "parity-noul",
                    kind: .noul,
                    instructions: "Is the service outage affecting every customer?",
                    context: "The status page reports that all customers are unable to sign in.",
                    options: [
                        DecisionOption(id: "false", description: "no: the outage is limited"),
                        DecisionOption(id: "true", description: "yes: all customers are affected")
                    ]
                ),
                reference.noul
            ),
            (
                DecisionPrompt(
                    id: "parity-choice",
                    kind: .choice,
                    instructions: "Choose the best team to handle this customer message.",
                    context: "My invoice contains a duplicate charge from yesterday.",
                    options: [
                        DecisionOption(id: "support", description: "support: account access or product use"),
                        DecisionOption(id: "billing", description: "billing: invoices, refunds, or charges"),
                        DecisionOption(id: "sales", description: "sales: plan selection or purchasing")
                    ]
                ),
                reference.choice
            ),
            (
                DecisionPrompt(
                    id: "parity-score",
                    kind: .score,
                    instructions: "Rate how completely the response answers the question.",
                    context: "Question: How do I reset my password? Response: Open Settings, choose Security, and select Reset Password.",
                    options: [
                        DecisionOption(id: "0", description: "level 0: does not answer the question"),
                        DecisionOption(id: "1", description: "level 1: partially answers the question"),
                        DecisionOption(id: "2", description: "level 2: fully answers the question")
                    ]
                ),
                reference.score
            )
        ]

        for (prompt, expected) in cases {
            let actual = try await backend.predict(for: prompt)
            XCTAssertEqual(actual.probabilities.count, expected.probabilities.count, prompt.id)
            let selectedIndex = actual.probabilities.indices.max {
                actual.probabilities[$0] < actual.probabilities[$1]
            }!
            XCTAssertEqual(prompt.options[selectedIndex].id, expected.selectedOptionID, prompt.id)
            for (actualProbability, expectedProbability) in zip(actual.probabilities, expected.probabilities) {
                XCTAssertEqual(actualProbability, expectedProbability, accuracy: tolerance, prompt.id)
            }
        }
    }
}
#endif
