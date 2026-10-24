#if SWIFTDECISION_FOUNDATION_MODELS && canImport(FoundationModels)
import Foundation
import FoundationModels
import SwiftDecision
import XCTest

final class FoundationModelsOptionAssessmentTests: XCTestCase {
    func testOppositeOrdersAlignToOriginalLabelsAndAverageEstimates() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let client = AssessmentFixture([[0.1, 0.9], [0.8, 0.2]])
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(
            client: client, strategy: .optionAssessment))
        let result = try await engine.choice(instructions: "Choose the matching label.", context: "Fixture",
            options: [ChoiceOption(label: "a", description: "Alpha"), ChoiceOption(label: "b", description: "Beta")])
        XCTAssertEqual(result.value, "b")
        XCTAssertEqual(result.probabilities[0], 0.15, accuracy: 1e-9)
        XCTAssertEqual(result.probabilities[1], 0.85, accuracy: 1e-9)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].prompt.contains("0: Alpha\n1: Beta"))
        XCTAssertTrue(requests[1].prompt.contains("0: Beta\n1: Alpha"))
        XCTAssertFalse(requests[0].instructions.contains("Alpha"))
        let schema = String(decoding: try JSONEncoder().encode(requests[0].schema), as: UTF8.self)
        XCTAssertTrue(schema.contains("Alpha"))
        XCTAssertTrue(schema.contains("Beta"))
    }

    func testExplicitNormalizationStillAppliesToEachPass() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let backend = FoundationModelsDecisionBackend(client: AssessmentFixture([[0.5, 1], [1, 0.5]]),
            normalization: .sumToOne, strategy: .optionAssessment)
        let result = try await backend.predict(for: prompt())
        XCTAssertEqual(result.probabilities[0], 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(result.probabilities[1], 2.0 / 3, accuracy: 1e-9)
    }

    func testPositionalPreferenceBecomesUninformativeAndAbstains() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(
            client: AssessmentFixture([[1, 0.5], [1, 0.5]]), normalization: .sumToOne, strategy: .optionAssessment))
        let result = try await engine.choice(instructions: "Choose.", context: "Fixture",
            options: [ChoiceOption(label: "a", description: "Alpha"), ChoiceOption(label: "b", description: "Beta")])
        XCTAssertNil(result.value)
        XCTAssertEqual(result.probabilities, [0.5, 0.5])
        guard case .abstained = result.outcome else { return XCTFail("Expected abstention") }
    }

    func testTiedPassDoesNotCreateAConfidentWinner() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let backend = FoundationModelsDecisionBackend(client: AssessmentFixture([[1, 0], [0.5, 0.5]]),
            strategy: .optionAssessment)
        let result = try await backend.predict(for: prompt())
        XCTAssertEqual(result.probabilities, [0.5, 0.5])
    }

    func testScoreOrderIsRestoredBeforeComputingExpectedValue() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(
            client: AssessmentFixture([[0, 0.2, 0.8], [0.2, 0.8, 0]]), strategy: .optionAssessment))
        let result = try await engine.score(instructions: "Rate completion.", context: "Fixture",
            levels: [(description: "None", value: 0), (description: "Partial", value: 0.5), (description: "Full", value: 1)])
        XCTAssertEqual(result.value?.level, 2)
        XCTAssertEqual(result.value?.expectedValue ?? -1, 0.9, accuracy: 1e-9)
    }

    func testFixedMiddlePositionIsDetectedForOddOptionCounts() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let client = AssessmentFixture([[0.1, 0.8, 0.1], [0.1, 0.8, 0.1]])
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(client: client, strategy: .optionAssessment))
        let result = try await engine.choice(instructions: "Choose.", context: "Fixture",
            options: [ChoiceOption(label: "a", description: "Alpha"), ChoiceOption(label: "b", description: "Beta"), ChoiceOption(label: "c", description: "Gamma")])
        XCTAssertNil(result.value)
        let requests = await client.requests
        XCTAssertTrue(requests[1].prompt.contains("0: Beta\n1: Gamma\n2: Alpha"))
    }

    func testMalformedOrInvalidAssessmentNeverGetsRepairedToUniform() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        for vector in [[0.0], [-0.1, 1.1], [0, 0]] {
            let client = AssessmentFixture([vector])
            let backend = FoundationModelsDecisionBackend(client: client, normalization: .sumToOne, strategy: .optionAssessment)
            do { _ = try await backend.predict(for: prompt()); XCTFail("Invalid assessment must throw") }
            catch DecisionError.invalidPrediction { }
            let calls = await client.requests.count
            XCTAssertEqual(calls, 1)
        }
    }

    func testStrictModeRejectsUnnormalizedAssessments() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let backend = FoundationModelsDecisionBackend(client: AssessmentFixture([[1, 0.5]]), strategy: .optionAssessment)
        do { _ = try await backend.predict(for: prompt()); XCTFail("Strict mode must not normalize") }
        catch DecisionError.invalidPrediction { }
    }

    func testCancellationAfterFirstPassStopsTheSecondPass() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let client = CancellingAssessmentFixture()
        let backend = FoundationModelsDecisionBackend(client: client, strategy: .optionAssessment)
        let input = prompt()
        let task = Task { try await backend.predict(for: input) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testTruthVerdictAndProbabilityRemainConsistent() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let client = AssessmentContentFixture([
            GeneratedContent(properties: ["verdict": "supported", "probabilityTrue": 0.8]),
            GeneratedContent(properties: ["verdict": "supported", "probabilityTrue": 0.9])
        ])
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(client: client, strategy: .optionAssessment))
        let result = try await engine.noul(statement: "The item shipped.", context: "Shipped")
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.probabilities[1], 0.85, accuracy: 1e-9)
    }

    func testUnknownTruthIsNotConvertedToFalse() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let content = GeneratedContent(properties: ["verdict": "unknown", "probabilityTrue": 0.0])
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(
            client: AssessmentContentFixture([content, content]), strategy: .optionAssessment))
        let result = try await engine.noul(statement: "The item shipped.", context: "Unavailable")
        XCTAssertNil(result.value)
        XCTAssertEqual(result.probabilities, [0.5, 0.5])
    }

    func testConflictingTruthAssessmentsAbstain() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(client: AssessmentContentFixture([
            GeneratedContent(properties: ["verdict": "supported", "probabilityTrue": 0.9]),
            GeneratedContent(properties: ["verdict": "contradicted", "probabilityTrue": 0.1])
        ]), strategy: .optionAssessment))
        let result = try await engine.noul(statement: "The item shipped.", context: "Conflicting")
        XCTAssertNil(result.value)
        XCTAssertEqual(result.probabilities, [0.5, 0.5])
    }

    func testInvalidScalarIsRejectedEvenWithUnknownVerdict() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(client: AssessmentContentFixture([
            GeneratedContent(properties: ["verdict": "unknown", "probabilityTrue": 1.1])
        ]), strategy: .optionAssessment))
        do { _ = try await engine.noul(statement: "A claim", context: "Fixture"); XCTFail("Expected rejection") }
        catch DecisionError.invalidPrediction { }
    }

    func testExplicitNoEvidenceScoreCanHaveZeroSupport() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let content = GeneratedContent(properties: ["hasEvidence": false, "option_0": 0.0, "option_1": 0.0, "option_2": 0.0])
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(
            client: AssessmentContentFixture([content, content]), strategy: .optionAssessment))
        let result = try await engine.score(instructions: "Rate completion", context: "No report",
            levels: [(description: "None", value: 0), (description: "Partial", value: 0.5), (description: "Complete", value: 1)])
        XCTAssertNil(result.value)
        XCTAssertEqual(result.probabilities, [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    func testNoEvidenceDoesNotHideInvalidScoreFields() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        let engine = DecisionEngine(backend: FoundationModelsDecisionBackend(client: AssessmentContentFixture([
            GeneratedContent(properties: ["hasEvidence": false, "option_0": -0.1, "option_1": 1.1])
        ]), strategy: .optionAssessment))
        do {
            _ = try await engine.score(instructions: "Rate", context: "No report",
                levels: [(description: "None", value: 0), (description: "Full", value: 1)])
            XCTFail("Expected rejection")
        } catch DecisionError.invalidPrediction { }
    }

    private func prompt() -> DecisionPrompt {
        DecisionPrompt(id: "fixture", kind: .choice, instructions: "Choose.", context: "Fixture",
            options: [.init(id: "a", description: "Alpha"), .init(id: "b", description: "Beta")])
    }
}

@available(macOS 26, iOS 26, *)
private actor AssessmentFixture: FoundationModelsDecisionClient {
    private var vectors: [[Double]]
    private(set) var requests: [FoundationModelsDecisionRequest] = []
    init(_ vectors: [[Double]]) { self.vectors = vectors }
    func generate(_ request: FoundationModelsDecisionRequest) async throws -> GeneratedContent {
        requests.append(request)
        guard !vectors.isEmpty else { throw DecisionError.invalidPrediction("Fixture exhausted") }
        let values = vectors.removeFirst()
        let object = Dictionary(uniqueKeysWithValues: values.enumerated().map { ("option_\($0.offset)", $0.element) })
        let data = try JSONEncoder().encode(object)
        var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        payload["hasEvidence"] = true
        return try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }
}

@available(macOS 26, iOS 26, *)
private actor CancellingAssessmentFixture: FoundationModelsDecisionClient {
    private(set) var calls = 0
    func generate(_ request: FoundationModelsDecisionRequest) async throws -> GeneratedContent {
        calls += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return GeneratedContent(properties: ["option_0": 0.2, "option_1": 0.8])
    }
}
@available(macOS 26, iOS 26, *)
private actor AssessmentContentFixture: FoundationModelsDecisionClient {
    private var responses: [GeneratedContent]
    init(_ responses: [GeneratedContent]) { self.responses = responses }
    func generate(_ request: FoundationModelsDecisionRequest) async throws -> GeneratedContent {
        guard !responses.isEmpty else { throw DecisionError.invalidPrediction("Fixture exhausted") }
        return responses.removeFirst()
    }
}
#endif
