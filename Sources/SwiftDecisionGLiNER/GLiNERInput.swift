import Foundation
import SwiftDecision

/// An invalid local GLiNER asset, unsupported input, or malformed model output.
public enum GLiNERError: Error, Sendable, Equatable {
    /// The exported model, tokenizer, or metadata does not match the supported contract.
    case invalidCheckpoint
    /// The input uses unsupported GLiNER schema syntax or invalid options.
    case invalidInput
    /// The complete schema and text exceed the exported token capacity; nothing was truncated.
    case inputTooLong(maximumTokens: Int)
    /// The model did not return one finite logit for every option.
    case invalidOutput
}

struct GLiNERInput: Equatable {
    let inputIDs: [Int]
    let markerPositions: [Int]

    // Mirrors the pinned upstream WhitespaceTokenSplitter. Python \w means
    // Unicode letters/numbers/underscore; marks and joiners are added explicitly.
    static let words = try! NSRegularExpression(
        pattern: #"https?://[^\s]+|www\.[^\s]+|[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}|@[a-z0-9_]+|[\p{L}\p{N}_\p{M}\u200c\u200d]+(?:[-_][\p{L}\p{N}_\p{M}\u200c\u200d]+)*|\S"#,
        options: [.caseInsensitive]
    )

    static func build(
        for prompt: DecisionPrompt,
        maximumTokens: Int,
        encode: (String) throws -> [Int]
    ) throws -> Self {
        let reserved = ["[P]", "[L]", "[C]", "[E]", "[R]", "[DESCRIPTION]", "[EXAMPLE]", "[OUTPUT]", "(", ")"]
        let schemaStrings = [prompt.instructions] + prompt.options.flatMap { [$0.id, $0.description] }
        guard prompt.options.count >= 2,
              Set(prompt.options.map(\.id)).count == prompt.options.count,
              schemaStrings.allSatisfy({ value in
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !reserved.contains(where: value.contains)
              })
        else { throw GLiNERError.invalidInput }

        var instruction = "decision: " + prompt.instructions
        for option in prompt.options {
            instruction += " [DESCRIPTION] \(option.id): \(option.description)"
        }
        var ids: [Int] = []
        var markers: [Int] = []
        func append(_ text: String) throws {
            let encoded = try encode(text)
            guard !encoded.isEmpty else { throw GLiNERError.invalidInput }
            guard encoded.count <= maximumTokens - ids.count else {
                throw GLiNERError.inputTooLong(maximumTokens: maximumTokens)
            }
            ids.append(contentsOf: encoded)
        }
        try append("(")
        try append("[P]")
        try append(instruction)
        try append("(")
        for option in prompt.options {
            markers.append(ids.count)
            try append("[L]")
            try append(option.id)
        }
        try append(")")
        try append(")")
        try append("[SEP_TEXT]")
        var text = prompt.context
        if text.isEmpty { text = "." }
        else if ![".", "!", "?"].contains(String(text.suffix(1))) { text += "." }
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { throw GLiNERError.invalidInput }
            try append(String(text[range]).lowercased())
        }
        return Self(inputIDs: ids, markerPositions: markers)
    }

    static func probabilities(from logits: [Double], expectedCount: Int) throws -> [Double] {
        guard expectedCount >= 2, logits.count == expectedCount,
              logits.allSatisfy(\.isFinite), let largest = logits.max()
        else { throw GLiNERError.invalidOutput }
        let weights = logits.map { exp($0 - largest) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}
