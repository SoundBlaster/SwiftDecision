import Foundation
@testable import SwiftDecisionGLiNER
import Testing

struct GLiNERTokenizerTests {
    private func configuration() -> [String: Any] {
        [
            "model": ["type": "Unigram", "unk_id": 3, "byte_fallback": false,
                      "vocab": [["[PAD]", 0], ["x", -1], ["▁", -2], ["[UNK]", 0],
                                ["a", -2], ["b", -2], ["ab", -0.5], ["▁ab", -0.25], ["▁é", -0.25]]],
            "normalizer": ["type": "Sequence", "normalizers": [
                ["type": "Replace", "pattern": ["Regex": #"\s{2,}|[\n\r\t]"#], "content": " "],
                ["type": "NFC"], ["type": "Strip", "strip_left": false, "strip_right": true]]],
            "pre_tokenizer": ["type": "Sequence", "pretokenizers": [
                ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true]]],
            "added_tokens": [["id": 9, "content": "[L]", "single_word": false, "lstrip": false,
                              "rstrip": false, "normalized": false, "special": true]],
        ]
    }

    @Test func choosesMaximumLikelihoodSegmentationAndRespectsAddedTokens() throws {
        let tokenizer = try GLiNERTokenizer(data: JSONSerialization.data(withJSONObject: configuration()), vocabularySize: 10)
        #expect(try tokenizer.encode("ab") == [7])
        #expect(try tokenizer.encode("[L]ab[L]") == [9, 7, 9])
        #expect(try tokenizer.encode("a\n\tb") == [2, 4, 2, 5])
        #expect(try tokenizer.encode("e\u{301}") == [8])
        #expect(try tokenizer.encode("🦝🌍") == [2, 3])
        #expect(try tokenizer.encode("").isEmpty)
    }

    @Test func refusesAnUnsupportedTokenizerPipeline() throws {
        var config = configuration()
        config["pre_tokenizer"] = ["type": "ByteLevel"]
        #expect(throws: GLiNERError.invalidCheckpoint) {
            try GLiNERTokenizer(data: JSONSerialization.data(withJSONObject: config), vocabularySize: 10)
        }
    }
}
