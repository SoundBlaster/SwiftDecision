import Foundation

/// The pinned checkpoint's Unigram tokenizer, without a general-purpose runtime dependency.
/// Supports exactly its NFC/whitespace/Metaspace pipeline and unnormalized added tokens.
struct GLiNERTokenizer: Sendable {
    private struct Piece: Sendable {
        let id: Int
        let score: Float
    }
    private let vocabulary: [Data: Piece]
    private let addedTokens: [String: Int]
    private let addedPattern: NSRegularExpression
    private let maximumPieceBytes: Int
    private let unknownID: Int
    private let unknownScore: Float
    private static let whitespace = try! NSRegularExpression(pattern: #"\s{2,}|[\n\r\t]"#)

    init(data: Data, vocabularySize: Int) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? [String: Any], model["type"] as? String == "Unigram",
              model["byte_fallback"] as? Bool == false,
              let unknownID = model["unk_id"] as? Int,
              let entries = model["vocab"] as? [[Any]], entries.indices.contains(unknownID),
              let rawAdded = object["added_tokens"] as? [[String: Any]]
        else { throw GLiNERError.invalidCheckpoint }
        let normalizer: [String: Any] = ["type": "Sequence", "normalizers": [
            ["type": "Replace", "pattern": ["Regex": #"\s{2,}|[\n\r\t]"#], "content": " "],
            ["type": "NFC"], ["type": "Strip", "strip_left": false, "strip_right": true]
        ]]
        let preTokenizer: [String: Any] = ["type": "Sequence", "pretokenizers": [
            ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true]
        ]]
        guard let actualNormalizer = object["normalizer"] as? NSDictionary,
              actualNormalizer.isEqual(to: normalizer),
              let actualPreTokenizer = object["pre_tokenizer"] as? NSDictionary,
              actualPreTokenizer.isEqual(to: preTokenizer)
        else { throw GLiNERError.invalidCheckpoint }
        var vocabulary: [Data: Piece] = [:]
        vocabulary.reserveCapacity(entries.count)
        var smallest = Float.infinity
        var largest = 0
        for (id, entry) in entries.enumerated() {
            guard entry.count == 2, let text = entry[0] as? String, !text.isEmpty,
                  let number = entry[1] as? NSNumber, number.floatValue.isFinite,
                  id < vocabularySize else { throw GLiNERError.invalidCheckpoint }
            let bytes = Data(text.utf8)
            guard vocabulary[bytes] == nil else { throw GLiNERError.invalidCheckpoint }
            vocabulary[bytes] = Piece(id: id, score: number.floatValue)
            smallest = min(smallest, number.floatValue)
            largest = max(largest, bytes.count)
        }
        var added: [String: Int] = [:]
        for token in rawAdded {
            guard let text = token["content"] as? String, !text.isEmpty,
                  let id = token["id"] as? Int, (0 ..< vocabularySize).contains(id), added[text] == nil,
                  token["single_word"] as? Bool == false, token["lstrip"] as? Bool == false,
                  token["rstrip"] as? Bool == false, token["normalized"] as? Bool == false,
                  token["special"] as? Bool == true
            else { throw GLiNERError.invalidCheckpoint }
            added[text] = id
        }
        guard !vocabulary.isEmpty, !added.isEmpty else { throw GLiNERError.invalidCheckpoint }
        self.vocabulary = vocabulary
        self.maximumPieceBytes = largest
        self.unknownID = unknownID
        self.unknownScore = smallest - 10
        self.addedTokens = added
        let patterns = added.keys.sorted { $0.utf8.count > $1.utf8.count }.map(NSRegularExpression.escapedPattern(for:))
        self.addedPattern = try NSRegularExpression(pattern: patterns.joined(separator: "|"))
    }

    func addedTokenID(_ token: String) -> Int? { addedTokens[token] }

    func encode(_ text: String) throws -> [Int] {
        var result: [Int] = []
        var cursor = text.startIndex
        for match in addedPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let id = addedTokens[String(text[range])] else {
                throw GLiNERError.invalidInput
            }
            result.append(contentsOf: try encodeLiteral(String(text[cursor ..< range.lowerBound])))
            result.append(id)
            cursor = range.upperBound
        }
        result.append(contentsOf: try encodeLiteral(String(text[cursor...])))
        return result
    }

    private func encodeLiteral(_ text: String) throws -> [Int] {
        let collapsed = Self.whitespace.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let normalized = String(collapsed.precomposedStringWithCanonicalMapping.reversed()
            .drop(while: \.isWhitespace).reversed())
        guard !normalized.isEmpty else { return [] }
        var spaced = normalized.replacingOccurrences(of: " ", with: "▁")
        if !spaced.hasPrefix("▁") { spaced = "▁" + spaced }
        // Metaspace splits before each replacement, retaining it with the next word.
        var output: [Int] = []
        let scalars = Array(spaced.unicodeScalars)
        var start = 0
        for index in scalars.indices where index > 0 && scalars[index] == "▁" {
            output.append(contentsOf: try segment(String(String.UnicodeScalarView(scalars[start ..< index]))))
            start = index
        }
        output.append(contentsOf: try segment(String(String.UnicodeScalarView(scalars[start...]))))
        return output
    }

    private func segment(_ text: String) throws -> [Int] {
        let bytes = Array(text.utf8)
        var boundaries = [0]
        for scalar in text.unicodeScalars { boundaries.append(boundaries.last! + scalar.utf8.count) }
        var best = Array(repeating: -Float.infinity, count: bytes.count + 1)
        var previous = Array(repeating: -1, count: bytes.count + 1)
        var selected = Array(repeating: unknownID, count: bytes.count + 1)
        best[0] = 0
        for (boundaryIndex, start) in boundaries.dropLast().enumerated() {
            guard best[start].isFinite else { continue }
            let next = boundaries[boundaryIndex + 1]
            var hasSingleScalar = false
            var candidate = Data()
            for end in start ..< min(bytes.count, start + maximumPieceBytes) {
                candidate.append(bytes[end])
                guard let piece = vocabulary[candidate] else { continue }
                hasSingleScalar = hasSingleScalar || end + 1 == next
                let score = best[start] + piece.score
                if score > best[end + 1] {
                    best[end + 1] = score
                    previous[end + 1] = start
                    selected[end + 1] = piece.id
                }
            }
            if !hasSingleScalar, best[start] + unknownScore > best[next] {
                best[next] = best[start] + unknownScore
                previous[next] = start
                selected[next] = unknownID
            }
        }
        var reversed: [Int] = []
        var end = bytes.count
        while end > 0 {
            guard previous[end] >= 0 else { throw GLiNERError.invalidInput }
            reversed.append(selected[end])
            end = previous[end]
        }
        var result: [Int] = []
        for id in reversed.reversed() where id != unknownID || result.last != unknownID { result.append(id) }
        return result
    }
}
