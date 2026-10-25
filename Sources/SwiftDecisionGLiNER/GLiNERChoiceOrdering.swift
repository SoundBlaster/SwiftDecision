import Foundation
import SwiftDecision

/// The model-facing order of Choice options in the GLiNER adapter.
public enum GLiNERChoiceOrdering: Sendable, Equatable {
    /// Preserves the caller's option order and identifiers.
    case input
    /// Sorts by NFC-normalized, lowercased description using locale-independent UTF-8 order.
    ///
    /// Internal identifiers are assigned after sorting. Returned scores still follow the
    /// caller's original order. Instructions and context are not rewritten, and Noul and
    /// Score are unaffected. This stabilizes schema order; it does not calibrate scores.
    case canonical
}

struct GLiNERChoiceLayout {
    let prompt: DecisionPrompt
    let originalIndices: [Int]

    init(prompt: DecisionPrompt, ordering: GLiNERChoiceOrdering) throws {
        // Validate the original schema as well as the rendered one: internal IDs must
        // not conceal unsupported or duplicate caller identifiers.
        try GLiNERInput.validate(prompt)
        guard ordering == .canonical, prompt.kind == .choice else {
            self.prompt = prompt
            originalIndices = Array(prompt.options.indices)
            return
        }
        let keys = prompt.options.map {
            let text = $0.description.precomposedStringWithCanonicalMapping
            return (folded: Array(text.lowercased().utf8), text: Array(text.utf8), id: Array($0.id.utf8))
        }
        originalIndices = prompt.options.indices.sorted { lhs, rhs in
            let a = keys[lhs], b = keys[rhs]
            if a.folded != b.folded { return a.folded.lexicographicallyPrecedes(b.folded) }
            if a.text != b.text { return a.text.lexicographicallyPrecedes(b.text) }
            return a.id.lexicographicallyPrecedes(b.id)
        }
        self.prompt = DecisionPrompt(id: prompt.id, kind: prompt.kind,
            instructions: prompt.instructions, context: prompt.context,
            options: originalIndices.enumerated().map {
                DecisionOption(id: String($0.offset), description: prompt.options[$0.element].description)
            })
    }

    func restoringOriginalOrder(_ probabilities: [Double]) throws -> [Double] {
        guard probabilities.count == originalIndices.count else { throw GLiNERError.invalidOutput }
        var result = probabilities
        for (modelIndex, originalIndex) in originalIndices.enumerated() {
            result[originalIndex] = probabilities[modelIndex]
        }
        return result
    }
}
