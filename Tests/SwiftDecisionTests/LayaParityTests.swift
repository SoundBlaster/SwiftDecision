#if SWIFTDECISION_MLX
import Foundation
@testable import SwiftDecision
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

    func testOptionTokenBudgetTruncatesAndRejectsOversizedOptionSets() throws {
        let source = (0 ..< 4).map { [$0] + Array(repeating: 99, count: 20) }
        let fitted = try LayaOptionTokenBudget.fit(source, headMaximumLength: 24)

        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.count }, 8)
        XCTAssertEqual(fitted.map(\.first), source.map(\.first))
        XCTAssertTrue(fitted.allSatisfy { !$0.isEmpty })

        XCTAssertThrowsError(try LayaOptionTokenBudget.fit(
            Array(repeating: [1], count: 9),
            headMaximumLength: 24
        ))
    }

    func testFixedNoulChoiceAndScoreInputsRunOnLocalCheckpoint() async throws {
        guard let checkpointPath = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_CHECKPOINT"] else {
            throw XCTSkip("Set SWIFTDECISION_LAYA_CHECKPOINT to run native Laya integration tests")
        }
        let reference: ReferenceDocument?
        if let referencePath = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_REFERENCE_JSON"] {
            reference = try JSONDecoder().decode(
                ReferenceDocument.self,
                from: Data(contentsOf: URL(fileURLWithPath: referencePath))
            )
        } else {
            reference = nil
        }
        let precisionName = ProcessInfo.processInfo.environment["SWIFTDECISION_LAYA_PRECISION"]
            ?? (reference == nil ? "float16" : "float32")
        let precision: LayaPrecision = precisionName == "float16" ? .float16 : .float32
        let tolerance = precision == .float16 ? 0.02 : 0.0001
        let backend = try LayaMLXBackend(
            checkpointAt: URL(fileURLWithPath: checkpointPath),
            precision: precision
        )
        let cases: [(DecisionPrompt, ReferenceCase?)] = [
            (
                DecisionPrompt(
                    id: "parity-noul",
                    kind: .noul,
                    instructions: "Is the service outage affecting every customer?",
                    context: "The status page reports that all customers are unable to sign in.",
                    options: [
                        DecisionOption(id: "false", description: "false: no, the statement does not hold"),
                        DecisionOption(id: "true", description: "true: yes, the statement holds")
                    ]
                ),
                reference?.noul
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
                reference?.choice
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
                reference?.score
            )
        ]

        for (prompt, expected) in cases {
            let actual = try await backend.predict(for: prompt)
            XCTAssertEqual(actual.probabilities.count, prompt.options.count, prompt.id)
            XCTAssertTrue(actual.probabilities.allSatisfy { $0.isFinite && $0 >= 0 }, prompt.id)
            XCTAssertEqual(actual.probabilities.reduce(0, +), 1, accuracy: 0.01, prompt.id)
            XCTAssertEqual(actual.modelIdentifier, "laya-mlx", prompt.id)
            guard let expected else { continue }
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
