import Foundation
import SwiftDecision
@testable import SwiftDecisionGLiNER
import Testing

struct GLiNERChoiceOrderingTests {
    private func prompt(_ descriptions: [String], kind: DecisionKind = .choice) -> DecisionPrompt {
        DecisionPrompt(id: "order", kind: kind, instructions: "Choose a color.", context: "Blue is cool.",
            options: descriptions.enumerated().map { .init(id: String($0.offset), description: $0.element) })
    }

    @Test func canonicalSchemaAndRestoredScoresAreIndependentOfCallerOrder() throws {
        let permutations = [["Red", "blue", "Green"], ["Red", "Green", "blue"],
                            ["blue", "Red", "Green"], ["blue", "Green", "Red"],
                            ["Green", "Red", "blue"], ["Green", "blue", "Red"]]
        for descriptions in permutations {
            let original = prompt(descriptions)
            let layout = try GLiNERChoiceLayout(prompt: original, ordering: .canonical)
            #expect(layout.prompt.options.map(\.description) == ["blue", "Green", "Red"])
            #expect(layout.prompt.options.map(\.id) == ["0", "1", "2"])
            #expect(layout.prompt.instructions == original.instructions)
            #expect(layout.prompt.context == original.context)
            let scores = try layout.restoringOriginalOrder([0.7, 0.2, 0.1])
            for (index, description) in descriptions.enumerated() {
                #expect(scores[index] == ["blue": 0.7, "Green": 0.2, "Red": 0.1][description])
            }
        }
    }

    @Test func inputModePreservesIDsAndOrder() throws {
        let original = prompt(["Red", "blue"])
        let layout = try GLiNERChoiceLayout(prompt: original, ordering: .input)
        #expect(layout.prompt == original)
        #expect(try layout.restoringOriginalOrder([0.2, 0.8]) == [0.2, 0.8])
    }

    @Test(arguments: [DecisionKind.noul, .score])
    func canonicalSettingDoesNotChangeOrderedDecisionKinds(kind: DecisionKind) throws {
        let original = prompt(["Red", "blue"], kind: kind)
        let layout = try GLiNERChoiceLayout(prompt: original, ordering: .canonical)
        #expect(layout.prompt == original)
        #expect(try layout.restoringOriginalOrder([0.2, 0.8]) == [0.2, 0.8])
    }

    @Test func unicodeAndDuplicateDescriptionsHaveDeterministicTieBreaks() throws {
        let options: [DecisionOption] = [.init(id: "b", description: "cafe\u{301}"),
                                        .init(id: "a", description: "café"),
                                        .init(id: "c", description: "BLUE")]
        let first = DecisionPrompt(id: "unicode", kind: .choice, instructions: "Choose.", context: "",
                                   options: options)
        let second = DecisionPrompt(id: first.id, kind: first.kind, instructions: first.instructions,
                                    context: first.context, options: Array(options.reversed()))
        #expect(try GLiNERChoiceLayout(prompt: first, ordering: .canonical).prompt
            == GLiNERChoiceLayout(prompt: second, ordering: .canonical).prompt)
    }

    @Test func canonicalizationCannotHideInvalidCallerSchemaOrMalformedOutput() throws {
        for ids in [["0", "0"], ["(", "1"]] {
            let invalid = DecisionPrompt(id: "invalid", kind: .choice, instructions: "Choose.", context: "",
                options: ids.enumerated().map { .init(id: $0.element, description: "Option \($0.offset)") })
            #expect(throws: GLiNERError.invalidInput) {
                try GLiNERChoiceLayout(prompt: invalid, ordering: .canonical)
            }
        }
        let layout = try GLiNERChoiceLayout(prompt: prompt(["Red", "blue"]), ordering: .canonical)
        #expect(throws: GLiNERError.invalidOutput) { try layout.restoringOriginalOrder([0.5]) }
    }
}
