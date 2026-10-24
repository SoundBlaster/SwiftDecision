import Foundation
import SwiftDecision
import XCTest

/// Synthetic requests adapted from existing projects. There are deliberately no expected answers.
struct DecisionOutputContractCase: Decodable, Sendable {
    enum Kind: String, Decodable, CaseIterable, Sendable {
        case noul, choice, score
    }

    struct Option: Decodable, Sendable {
        let id: String
        let description: String
    }

    let id: String
    let source: String
    let kind: Kind
    let instructions: String
    let context: String
    let options: [Option]
    let tags: [String]

    static func load() throws -> [Self] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DecisionOutputContracts", withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(Self.self, from: Data($0.utf8))
        }
    }

    /// Exercises the public typed APIs; acceptance, the winning label, and score quality are ignored.
    func probabilities(using engine: DecisionEngine, budget: DecisionBudget? = nil) async throws -> [Double] {
        switch kind {
        case .noul:
            return try await engine.noul(
                id: id, statement: instructions, context: context, budget: budget
            ).probabilities
        case .choice:
            return try await engine.choice(
                id: id, instructions: instructions, context: context,
                options: options.map { ChoiceOption(label: $0.id, description: $0.description) },
                budget: budget
            ).probabilities
        case .score:
            return try await engine.score(
                id: id, instructions: instructions, context: context,
                levels: options.enumerated().map { (description: $0.element.description, value: Double($0.offset)) },
                budget: budget
            ).probabilities
        }
    }
}

final class DecisionOutputContractCorpusTests: XCTestCase {
    func testCorpusHasValidRequestsWithoutAnswerQualityLabels() throws {
        let cases = try DecisionOutputContractCase.load()
        XCTAssertEqual(cases.count, 48)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        for sample in cases {
            XCTAssertFalse(sample.id.isEmpty)
            XCTAssertFalse(sample.source.isEmpty, sample.id)
            XCTAssertFalse(sample.instructions.isEmpty, sample.id)
            XCTAssertFalse(sample.context.isEmpty, sample.id)
            XCTAssertGreaterThanOrEqual(sample.options.count, 2, sample.id)
            XCTAssertTrue(sample.options.allSatisfy { !$0.id.isEmpty && !$0.description.isEmpty }, sample.id)
            XCTAssertEqual(Set(sample.options.map(\.id)).count, sample.options.count, sample.id)
            switch sample.kind {
            case .noul:
                XCTAssertEqual(sample.options.map(\.id), ["false", "true"], sample.id)
            case .score:
                XCTAssertEqual(sample.options.map(\.id), sample.options.indices.map(String.init), sample.id)
            case .choice:
                break
            }
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DecisionOutputContracts", withExtension: "jsonl"))
        // Check the raw fixtures too: Decodable would otherwise ignore accidentally added labels.
        let raw = try String(contentsOf: url, encoding: .utf8)
        for line in raw.split(whereSeparator: \.isNewline) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertTrue(Set(object.keys).isDisjoint(with: ["expected", "expectedLabel", "correctAnswer"]))
        }
    }

    func testCorpusCoversKindsCardinalitiesLanguagesAndFormatting() throws {
        let cases = try DecisionOutputContractCase.load()
        XCTAssertEqual(Set(cases.map(\.kind)), Set(DecisionOutputContractCase.Kind.allCases))
        for kind in [DecisionOutputContractCase.Kind.choice, .score] {
            XCTAssertEqual(Set(cases.filter { $0.kind == kind }.map { $0.options.count }), [2, 3, 5, 10, 20])
        }
        let tags = Set(cases.flatMap(\.tags))
        XCTAssertTrue(tags.isSuperset(of: ["english", "russian", "unicode", "multiline", "json", "format-override"]))
        XCTAssertTrue(cases.contains { $0.tags.contains("long-context") && $0.context.count > 3_000 })
        XCTAssertEqual(Set(cases.map(\.source)).count, 7)
    }
}
