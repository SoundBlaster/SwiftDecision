import Foundation
import SwiftDecision
@testable import SwiftDecisionGLiNER
import Testing

struct GLiNERInputTests {
    private let prompt = DecisionPrompt(
        id: "test", kind: .choice, instructions: "Choose a color.", context: "Blue is cool",
        options: [.init(id: "red", description: "Red"), .init(id: "blue", description: "Blue")]
    )

    @Test func preservesSchemaOrderAndNormalizesText() throws {
        var fragments: [String] = []
        let input = try GLiNERInput.build(for: prompt, maximumTokens: 100) { text in
            fragments.append(text)
            return [fragments.count]
        }
        #expect(fragments == ["(", "[P]", "decision: Choose a color. [DESCRIPTION] red: Red [DESCRIPTION] blue: Blue",
                              "(", "[L]", "red", "[L]", "blue", ")", ")", "[SEP_TEXT]", "blue", "is", "cool", "."])
        #expect(input.markerPositions == [4, 6])
        #expect(input.inputIDs == Array(1 ... 15))
    }

    @Test func refusesTruncation() {
        #expect(throws: GLiNERError.inputTooLong(maximumTokens: 10)) {
            try GLiNERInput.build(for: prompt, maximumTokens: 10) { _ in [1] }
        }
    }

    @Test(arguments: ["[L]", "[P]", "(", ")", "[DESCRIPTION]", ""])
    func rejectsUnsupportedSchemaSyntax(value: String) {
        let invalid = DecisionPrompt(id: "bad", kind: .choice, instructions: value, context: "text", options: prompt.options)
        #expect(throws: GLiNERError.invalidInput) {
            try GLiNERInput.build(for: invalid, maximumTokens: 100) { _ in [1] }
        }
    }

    @Test func rejectsDuplicateIDsAndEmptyTokenization() {
        let invalid = DecisionPrompt(id: "bad", kind: .choice, instructions: "Choose.", context: "text",
                                     options: [.init(id: "a", description: "A"), .init(id: "a", description: "B")])
        #expect(throws: GLiNERError.invalidInput) {
            try GLiNERInput.build(for: invalid, maximumTokens: 100) { _ in [1] }
        }
        #expect(throws: GLiNERError.invalidInput) {
            try GLiNERInput.build(for: prompt, maximumTokens: 100) { _ in [] }
        }
    }

    @Test func wordSplittingKeepsURLsAndUnicodeMarks() throws {
        let text = "Visit https://example.org/a user@example.org @Scout foo-bar cafe\u{301} İ!"
        let invalid = DecisionPrompt(id: "unicode", kind: .choice, instructions: prompt.instructions,
                                     context: text, options: prompt.options)
        var fragments: [String] = []
        _ = try GLiNERInput.build(for: invalid, maximumTokens: 100) { text in
            fragments.append(text)
            return [1]
        }
        #expect(Array(fragments.suffix(8)) == ["visit", "https://example.org/a", "user@example.org", "@scout", "foo-bar", "cafe\u{301}", "i\u{307}", "!"])
    }

    @Test func stableSoftmaxPreservesEvidenceAndOrder() throws {
        let result = try GLiNERInput.probabilities(from: [1001, 1000, 999], expectedCount: 3)
        #expect(abs(result[0] - 0.6652409557748218) < 1e-12)
        #expect(abs(result.reduce(0, +) - 1) < 1e-12)
        let reversed = try GLiNERInput.probabilities(from: [999, 1000, 1001], expectedCount: 3)
        #expect(result == Array(reversed.reversed()))
        #expect(try GLiNERInput.probabilities(from: [4, 4], expectedCount: 2) == [0.5, 0.5])
    }

    @Test(arguments: [[Double.nan, 0], [Double.infinity, 0], [-Double.infinity, 0], [0], []])
    func rejectsMalformedLogits(values: [Double]) {
        #expect(throws: GLiNERError.invalidOutput) {
            try GLiNERInput.probabilities(from: values, expectedCount: 2)
        }
    }
}
