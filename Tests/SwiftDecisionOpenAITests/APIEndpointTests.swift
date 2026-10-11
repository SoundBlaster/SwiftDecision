import Foundation
import SwiftDecision
import SwiftDecisionOpenAI
import XCTest

final class APIEndpointTests: XCTestCase {
    func testProviderDefaultUsesOpenAIDecisionsOperation() async throws {
        let transport = FixtureTransport(responses: [predicateResponse])
        let backend = try OpenAIDecisionsBackend(apiKey: "test-key", transport: transport)

        _ = try await backend.predict(for: noulPrompt)

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), ["https://api.openai.com/v1/decisions"])
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer test-key")
    }

    func testBaseURLPreservesPrefixEncodedSlashPortAndIPv6() async throws {
        let roots = [
            ("https://proxy.example/v1", "https://proxy.example/v1/decisions"),
            ("https://proxy.example/v1/", "https://proxy.example/v1/decisions"),
            ("https://proxy.example:8443/tenant/openai/v1/", "https://proxy.example:8443/tenant/openai/v1/decisions"),
            ("https://proxy.example/tenant/openai%2Fv1/", "https://proxy.example/tenant/openai%2Fv1/decisions"),
            ("https://[::1]:9443/v1/", "https://[::1]:9443/v1/decisions")
        ]

        for (root, expected) in roots {
            let transport = FixtureTransport(responses: [predicateResponse])
            let backend = try OpenAIDecisionsBackend(
                apiKey: "proxy-key",
                endpoint: .baseURL(URL(string: root)!),
                transport: transport
            )

            _ = try await backend.predict(for: noulPrompt)

            let requests = await transport.requests
            XCTAssertEqual(requests.first?.url.absoluteString, expected, "Unexpected endpoint for \(root)")
        }
    }

    func testLegacyBaseURLInitializerKeepsItsSourceCompatibleEndpointBehavior() async throws {
        let transport = FixtureTransport(responses: [predicateResponse])
        let backend = try OpenAIDecisionsBackend(
            apiKey: "proxy-key",
            baseURL: URL(string: "https://proxy.example/tenant/v1/")!,
            transport: transport
        )

        _ = try await backend.predict(for: noulPrompt)

        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url.absoluteString, "https://proxy.example/tenant/v1/decisions")
    }

    func testOperationURLIsUsedExactlyWithoutAppendingOrRemovingTrailingSlash() async throws {
        let urls = [
            "https://proxy.example/models/luna/decide",
            "https://proxy.example/custom/"
        ]

        for operationURL in urls {
            let transport = FixtureTransport(responses: [predicateResponse])
            let backend = try OpenAIDecisionsBackend(
                apiKey: "proxy-key",
                endpoint: .operationURL(URL(string: operationURL)!),
                transport: transport
            )

            _ = try await backend.predict(for: noulPrompt)

            let requests = await transport.requests
            XCTAssertEqual(requests.first?.url.absoluteString, operationURL)
        }
    }

    func testCustomEndpointRequiresItsOwnExplicitCredential() throws {
        XCTAssertThrowsError(
            try OpenAIDecisionsBackend(
                endpoint: .baseURL(URL(string: "https://proxy.example/v1")!)
            )
        ) { error in
            XCTAssertEqual(error as? OpenAIDecisionBackendError, .missingAPIKey)
        }
    }

    func testInvalidEndpointsAreRejectedDuringInitialization() {
        let invalidURLs = [
            "https://user:password@proxy.example/v1",
            "https://proxy.example/v1?token=secret",
            "https://proxy.example/v1#fragment",
            "ftp://proxy.example/v1",
            "https:///v1"
        ]

        for value in invalidURLs {
            XCTAssertThrowsError(
                try OpenAIDecisionsBackend(
                    apiKey: "test-key",
                    endpoint: .baseURL(URL(string: value)!)
                ),
                "Expected invalid endpoint: \(value)"
            ) { error in
                guard case .invalidConfiguration = error as? OpenAIDecisionBackendError else {
                    return XCTFail("Unexpected error for \(value): \(error)")
                }
            }
        }
    }

    func testNoulChoiceAndScoreKeepOpenAIPayloadAndResponseContracts() async throws {
        let transport = FixtureTransport(responses: [
            predicateResponse,
            Data(#"{"model":"fixture","answers":[{"type":"choice","name":"swiftdecision","choice":"b","confidence":0.8,"probabilities":[{"value":"a","probability":0.2},{"value":"b","probability":0.8}]}]}"#.utf8),
            Data(#"{"model":"fixture","answers":[{"type":"score","name":"swiftdecision","score":1,"confidence":0.8,"probabilities":[{"label":"0","probability":0.2,"value":0},{"label":"1","probability":0.8,"value":1}]}]}"#.utf8)
        ])
        let backend = try OpenAIDecisionsBackend(
            apiKey: "proxy-key",
            endpoint: .operationURL(URL(string: "https://proxy.example/decision")!),
            transport: transport
        )
        let prompts = [
            noulPrompt,
            DecisionPrompt(
                id: "choice",
                kind: .choice,
                instructions: "Pick one.",
                context: "Some context",
                options: [DecisionOption(id: "a", description: "A"), DecisionOption(id: "b", description: "B")]
            ),
            DecisionPrompt(
                id: "score",
                kind: .score,
                instructions: "Rate this.",
                context: "Some context",
                options: [DecisionOption(id: "0", description: "Low"), DecisionOption(id: "1", description: "High")]
            )
        ]

        for prompt in prompts {
            _ = try await backend.predict(for: prompt)
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url.absoluteString == "https://proxy.example/decision" })
        let payloads = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any]) }
        let questions = try payloads.map { payload -> [String: Any] in
            let questions = try XCTUnwrap(payload["questions"] as? [[String: Any]])
            return try XCTUnwrap(questions.first)
        }
        XCTAssertEqual(questions.compactMap { $0["type"] as? String }, ["predicate", "choice", "score"])
    }

    private var predicateResponse: Data {
        Data(#"{"model":"fixture","answers":[{"type":"predicate","name":"swiftdecision","probability":0.75}]}"#.utf8)
    }

    private var noulPrompt: DecisionPrompt {
        DecisionPrompt(
            id: "noul",
            kind: .noul,
            instructions: "Is this true?",
            context: "A statement",
            options: [DecisionOption(id: "false", description: "No"), DecisionOption(id: "true", description: "Yes")]
        )
    }
}

private actor FixtureTransport: OpenAIHTTPTransport {
    private let responses: [Data]
    private var responseIndex = 0
    private(set) var requests: [OpenAIHTTPRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse {
        requests.append(request)
        guard responseIndex < responses.count else {
            throw FixtureError.unexpectedRequest
        }
        defer { responseIndex += 1 }
        return OpenAIHTTPResponse(statusCode: 200, body: responses[responseIndex])
    }
}

private enum FixtureError: Error {
    case unexpectedRequest
}
