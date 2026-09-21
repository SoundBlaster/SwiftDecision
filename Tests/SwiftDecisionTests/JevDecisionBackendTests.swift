import Foundation
@testable import SwiftDecision
import XCTest

final class JevDecisionBackendTests: XCTestCase {
    func testNoulEncodesOfficialRequestAndMapsYesProbabilityToFixedOptionOrder() async throws {
        let transport = FixtureJevTransport(response: try response(answer: [
            "type": "noul",
            "noul": 0.9
        ]))
        let backend = try JevDecisionBackend(apiKey: "fixture-key", model: "jev-test", transport: transport)
        let prompt = DecisionPrompt(
            id: "case-17",
            kind: .noul,
            instructions: "Is the outage customer-wide?",
            context: "All customers cannot sign in.",
            options: [
                DecisionOption(id: "false", description: "The claim is false."),
                DecisionOption(id: "true", description: "The claim is true.")
            ]
        )

        let prediction = try await backend.predict(for: prompt)
        let requests = await transport.receivedRequests()
        let request = try XCTUnwrap(requests.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let state = try XCTUnwrap(payload["state"] as? [String: String])
        let questions = try XCTUnwrap(payload["questions"] as? [String: [String: Any]])
        let question = try XCTUnwrap(questions["swiftdecision"])
        let criteria = try XCTUnwrap(question["criteria"] as? [String: String])

        XCTAssertEqual(request.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.timeout, 10)
        XCTAssertEqual(payload["model"] as? String, "jev-test")
        XCTAssertEqual(state, ["context": "All customers cannot sign in."])
        XCTAssertEqual(question["type"] as? String, "noul")
        XCTAssertEqual(question["instructions"] as? String, "Is the outage customer-wide?")
        XCTAssertEqual(criteria, ["false": "The claim is false.", "true": "The claim is true."])
        XCTAssertEqual(prediction.probabilities[0], 0.1, accuracy: 1e-12)
        XCTAssertEqual(prediction.probabilities[1], 0.9, accuracy: 1e-12)
        XCTAssertEqual(prediction.modelIdentifier, "jev-fixture")
    }

    func testChoicePreservesPromptOptionOrderWhenResponseUsesLabelMap() async throws {
        let transport = FixtureJevTransport(response: try response(answer: [
            "type": "choice",
            "choice": "billing",
            "confidence": 0.9,
            "probabilities": ["sales": 0.05, "billing": 0.9, "support": 0.05]
        ]))
        let backend = try JevDecisionBackend(apiKey: "fixture-key", transport: transport)
        let prompt = DecisionPrompt(
            id: "ticket-1",
            kind: .choice,
            instructions: "Choose the team.",
            context: "I was charged twice.",
            options: [
                DecisionOption(id: "support", description: "Account access and product help."),
                DecisionOption(id: "billing", description: "Invoices, refunds, and charges."),
                DecisionOption(id: "sales", description: "Plans and purchases.")
            ]
        )

        let prediction = try await backend.predict(for: prompt)
        let requests = await transport.receivedRequests()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first).body) as? [String: Any])
        let question = try XCTUnwrap((payload["questions"] as? [String: [String: Any]])?["swiftdecision"])
        let criteria = try XCTUnwrap(question["criteria"] as? [String: String])

        XCTAssertEqual(prediction.probabilities, [0.05, 0.9, 0.05])
        XCTAssertEqual(prediction.modelIdentifier, "jev-fixture")
        XCTAssertEqual(criteria, [
            "support": "Account access and product help.",
            "billing": "Invoices, refunds, and charges.",
            "sales": "Plans and purchases."
        ])
    }

    func testScoreMapsOrderedRubricDistributionAndValidatesLegend() async throws {
        let descriptions = ["Does not answer.", "Partially answers.", "Fully answers."]
        let transport = FixtureJevTransport(response: try response(answer: [
            "type": "score",
            "score": 1.6,
            "confidence": 0.7,
            "probabilities": ["2": 0.7, "0": 0.1, "1": 0.2],
            "legend": ["0": descriptions[0], "1": descriptions[1], "2": descriptions[2]]
        ]))
        let backend = try JevDecisionBackend(apiKey: "fixture-key", transport: transport)
        let prompt = DecisionPrompt(
            id: "answer-review",
            kind: .score,
            instructions: "How complete is the response?",
            context: "Question: reset password. Response: use Settings > Security > Reset Password.",
            options: descriptions.enumerated().map {
                DecisionOption(id: String($0.offset), description: $0.element)
            }
        )

        let prediction = try await backend.predict(for: prompt)

        XCTAssertEqual(prediction.probabilities, [0.1, 0.2, 0.7])
        XCTAssertEqual(prediction.modelIdentifier, "jev-fixture")
    }

    func testHTTPAndMalformedResponseErrorsDoNotIncludeResponseBodyOrCredential() async throws {
        let privateBody = "private response payload"
        let httpTransport = FixtureJevTransport(response: JevHTTPResponse(
            statusCode: 429,
            body: Data(privateBody.utf8)
        ))
        let backend = try JevDecisionBackend(apiKey: "fixture-secret", transport: httpTransport)
        let prompt = validNoulPrompt

        do {
            _ = try await backend.predict(for: prompt)
            XCTFail("Expected an HTTP error")
        } catch let error as JevDecisionBackendError {
            XCTAssertEqual(error, .httpFailure(statusCode: 429))
            XCTAssertFalse(error.localizedDescription.contains(privateBody))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }

        let malformedTransport = FixtureJevTransport(response: try response(answer: [
            "type": "choice",
            "choice": "true",
            "confidence": 0.9,
            "probabilities": ["false": 0.1, "true": 0.9]
        ]))
        let malformedBackend = try JevDecisionBackend(apiKey: "fixture-secret", transport: malformedTransport)
        do {
            _ = try await malformedBackend.predict(for: prompt)
            XCTFail("Expected a protocol error for the wrong answer type")
        } catch let error as JevDecisionBackendError {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
    }

    func testMissingKeyAndUnsupportedPromptsFailBeforeTransport() async throws {
        let transport = FixtureJevTransport(response: try response(answer: [
            "type": "noul",
            "noul": 0.9
        ]))
        XCTAssertThrowsError(try JevDecisionBackend(apiKey: "", transport: transport)) { error in
            XCTAssertEqual(error as? JevDecisionBackendError, .missingAPIKey)
        }
        XCTAssertThrowsError(try JevDecisionBackend(apiKey: "fixture-key", timeout: .infinity, transport: transport)) { error in
            XCTAssertEqual(error as? JevDecisionBackendError, .invalidConfiguration("timeout must be finite and positive"))
        }

        let backend = try JevDecisionBackend(apiKey: "fixture-key", transport: transport)
        let invalidNoul = DecisionPrompt(
            id: "invalid",
            kind: .noul,
            instructions: "Is it true?",
            context: "Text",
            options: [DecisionOption(id: "yes", description: "Yes"), DecisionOption(id: "no", description: "No")]
        )
        do {
            _ = try await backend.predict(for: invalidNoul)
            XCTFail("Expected unsupported Noul option identifiers to fail")
        } catch let error as JevDecisionBackendError {
            XCTAssertEqual(error, .unsupportedPrompt("Noul requires the ordered false and true options"))
        }
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOptInLiveJevNoulChoiceAndScore() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTDECISION_LIVE_JEV"] == "1" else {
            throw XCTSkip("Set SWIFTDECISION_LIVE_JEV=1 and TYPESAFE_API_KEY to send live, billable Jev requests")
        }
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set TYPESAFE_API_KEY to run the live Jev smoke test")
        }

        let engine = DecisionEngine(backend: try JevDecisionBackend(apiKey: key))
        let noul = try await engine.noul(
            statement: "Is the service unavailable for all customers?",
            context: "The status page reports that all customers are unable to sign in."
        )
        let choice = try await engine.choice(
            instructions: "Choose the team that should handle this message.",
            context: "My invoice contains a duplicate charge from yesterday.",
            options: [
                ChoiceOption(label: "support", description: "Account access or product use."),
                ChoiceOption(label: "billing", description: "Invoices, refunds, or charges."),
                ChoiceOption(label: "sales", description: "Plan selection or purchasing.")
            ]
        )
        let score = try await engine.score(
            instructions: "Rate how completely the response answers the question.",
            context: "Question: How do I reset my password? Response: Open Settings, choose Security, and select Reset Password.",
            levels: [
                (description: "Does not answer the question.", value: 0),
                (description: "Partially answers the question.", value: 1),
                (description: "Fully answers the question.", value: 2)
            ]
        )

        for probabilities in [noul.probabilities, choice.probabilities, score.probabilities] {
            XCTAssertGreaterThanOrEqual(probabilities.count, 2)
            XCTAssertTrue(probabilities.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 0.01)
        }
        XCTAssertEqual(noul.probabilities.count, 2)
        XCTAssertEqual(choice.probabilities.count, 3)
        XCTAssertEqual(score.probabilities.count, 3)
    }

    private var validNoulPrompt: DecisionPrompt {
        DecisionPrompt(
            id: "noul-fixture",
            kind: .noul,
            instructions: "Is it true?",
            context: "Fixture.",
            options: [
                DecisionOption(id: "false", description: "No."),
                DecisionOption(id: "true", description: "Yes.")
            ]
        )
    }

    private func response(answer: [String: Any], model: String = "jev-fixture") throws -> JevHTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "answers": ["swiftdecision": answer]
        ])
        return JevHTTPResponse(
            statusCode: 200,
            headers: ["x-typesafe-request-id": "fixture-request"],
            body: body
        )
    }
}

private actor FixtureJevTransport: JevHTTPTransport {
    private let response: JevHTTPResponse
    private var requests: [JevHTTPRequest] = []

    init(response: JevHTTPResponse) {
        self.response = response
    }

    func send(_ request: JevHTTPRequest) async throws -> JevHTTPResponse {
        requests.append(request)
        return response
    }

    func receivedRequests() -> [JevHTTPRequest] { requests }
}
