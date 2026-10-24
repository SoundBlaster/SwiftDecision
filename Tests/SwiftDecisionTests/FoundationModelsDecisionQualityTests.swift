#if SWIFTDECISION_FOUNDATION_MODELS && canImport(FoundationModels)
import Foundation
import FoundationModels
import SwiftDecision
import XCTest

final class FoundationModelsDecisionQualityTests: XCTestCase {
    func testFrozenLocalQualityBatch() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTDECISION_FM_QUALITY"] == "1" else { throw XCTSkip("Explicit local evaluation only") }
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("Local model unavailable") }
        let batch = Int(environment["SWIFTDECISION_FM_QUALITY_BATCH"] ?? "0") ?? -1
        let name = environment["SWIFTDECISION_FM_QUALITY_STRATEGY"] ?? "optionAssessment"
        guard ["optionAssessment", "directDistribution"].contains(name) else { return XCTFail("Invalid strategy") }
        let backend = FoundationModelsDecisionBackend(normalization: .sumToOne,
            strategy: name == "optionAssessment" ? .optionAssessment : .directDistribution)
        let engine = DecisionEngine(backend: backend, configuration: .init(timeout: 6))
        let corpus = environment["SWIFTDECISION_FM_QUALITY_CORPUS"] ?? "development"
        guard ["development", "holdout"].contains(corpus) else { return XCTFail("Invalid corpus") }
        let resource = corpus == "holdout" ? "FoundationModelsDecisionHoldout" : "FoundationModelsDecisionQuality"
        let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "jsonl"))
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Sample.self, from: Data($0.utf8))
        }
        guard (0..<((rows.count + 5) / 6)).contains(batch) else { return XCTFail("Invalid batch") }
        let started = ContinuousClock.now
        for sample in rows.dropFirst(batch * 6).prefix(6) {
            guard started.duration(to: .now) < .seconds(35) else { return XCTFail("Batch budget exhausted") }
            let begin = ContinuousClock.now
            var selected: String?
            var probabilities: [Double] = []
            var failure: String?
            do {
                switch sample.kind {
                case "choice":
                    let result = try await engine.choice(instructions: sample.task, context: sample.context,
                        options: sample.options.map { ChoiceOption(label: $0, description: $0) })
                    selected = result.value
                    probabilities = result.probabilities
                case "noul":
                    let result = try await engine.noul(statement: sample.task, context: sample.context)
                    selected = result.value.map { $0 ? "true" : "false" }
                    probabilities = result.probabilities
                case "score":
                    let result = try await engine.score(instructions: sample.task, context: sample.context,
                        levels: sample.options.enumerated().map { (description: $0.element, value: Double($0.offset)) })
                    selected = result.value.map { String($0.level) }
                    probabilities = result.probabilities
                default: return XCTFail("Invalid sample kind")
                }
            } catch let error as DecisionError { failure = error.description }
              catch { failure = String(reflecting: type(of: error)) }
            let expected = sample.expected?.string
            var row: [String: Any] = ["id": sample.id, "kind": sample.kind, "strategy": name, "corpus": corpus,
                "selected": selected ?? "abstained", "expected": expected ?? "abstained",
                "probabilities": probabilities, "duration": String(describing: begin.duration(to: .now))]
            if let failure { row["errorType"] = failure }
            if name == "optionAssessment" {
                XCTAssertNil(failure, "Generation/format failure for \(sample.id)")
                if let selected { XCTAssertEqual(selected, expected, "Wrong accepted answer for \(sample.id)") }
                if expected == nil { XCTAssertNil(selected, "Undecidable sample must abstain: \(sample.id)") }
            }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("FM_QUALITY " + String(decoding: data, as: UTF8.self))
        }
    }

    private struct Sample: Decodable {
        let id: String
        let kind: String
        let task: String
        let context: String
        let options: [String]
        let expected: Expected?
    }
    private enum Expected: Decodable {
        case text(String)
        case boolean(Bool)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .boolean(value) }
            else { self = .text(try container.decode(String.self)) }
        }
        var string: String { switch self { case let .text(value): value; case let .boolean(value): value ? "true" : "false" } }
    }
}
#endif
