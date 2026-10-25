#if SWIFTDECISION_GLINER
import CoreML
import Foundation
import Hub
import SwiftDecision
import Tokenizers

/// Local GLiNER2.5-small classification using an explicitly provisioned Core ML export.
///
/// Enable the `GLiNER` trait and link `SwiftDecisionGLiNER` to opt in. No checkpoint is bundled,
/// downloaded, or sent to a service. Noul, Choice, and Score use an exclusive
/// classification task; softmax scores are not empirically calibrated probabilities.
@available(macOS 14, iOS 17, *)
public actor GLiNERCoreMLBackend: DecisionBackend {
    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let addedTokenIDs: [String: Int]
    private let metadata: Metadata

    private struct Metadata: Decodable {
        let formatVersion: Int
        let modelID: String
        let revision: String
        let sourceRevision: String
        let sequenceLength: Int
        let padTokenID: Int
        let vocabularySize: Int
        let activation: String
        let temperature: Double
        let weightBits: Int
        let computePrecision: String
    }

    /// Loads and, when necessary, compiles the local checkpoint off the caller's actor.
    ///
    /// - Parameters:
    ///   - directory: Output of `Scripts/gliner/prepare.py`, containing metadata,
    ///     tokenizer files and `GLiNERSmall.mlpackage` or `GLiNERSmall.mlmodelc`.
    ///   - computeUnits: Core ML hardware selection. Use `.cpuOnly` for parity tests.
    /// - Throws: A file/model loading error, or ``GLiNERError/invalidCheckpoint``.
    @concurrent
    public static func load(
        checkpointAt directory: URL,
        computeUnits: MLComputeUnits = .all
    ) async throws -> GLiNERCoreMLBackend {
        try Task.checkCancellation()
        let backend = try GLiNERCoreMLBackend(checkpointAt: directory, computeUnits: computeUnits)
        try Task.checkCancellation()
        return backend
    }

    private init(checkpointAt directory: URL, computeUnits: MLComputeUnits) throws {
        guard directory.isFileURL else { throw GLiNERError.invalidCheckpoint }
        let data = try Data(contentsOf: directory.appendingPathComponent("gliner.json"))
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.formatVersion == 1,
              metadata.modelID == "fastino/gliner2.5-small-v1",
              metadata.revision == "df5910e44bc4ffdb0d95399a83b0ca4516349aa5",
              metadata.sourceRevision == "ca4f68235b50fe4c3ecf3876851d748fe4b15c6c",
              (32 ... 512).contains(metadata.sequenceLength),
              metadata.vocabularySize > 0, (0 ..< metadata.vocabularySize).contains(metadata.padTokenID),
              metadata.activation == "softmax", metadata.temperature == 1,
              [8, 32].contains(metadata.weightBits), metadata.computePrecision == "float32"
        else { throw GLiNERError.invalidCheckpoint }

        let tokenizerData = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let configurationData = try Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
        guard var tokenizerConfiguration = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              let tokenizerObject = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any],
              let modelObject = tokenizerObject["model"] as? [String: Any], modelObject["type"] as? String == "Unigram",
              let addedTokens = tokenizerObject["added_tokens"] as? [[String: Any]]
        else { throw GLiNERError.invalidCheckpoint }
        var addedTokenIDs: [String: Int] = [:]
        for token in addedTokens {
            guard let content = token["content"] as? String, let id = token["id"] as? Int,
                  addedTokenIDs[content] == nil, (0 ..< metadata.vocabularySize).contains(id)
            else { throw GLiNERError.invalidCheckpoint }
            addedTokenIDs[content] = id
        }
        // swift-transformers 1.3.4 has no DebertaV2Tokenizer dispatch entry.
        // Select its Unigram implementation; keep the actual checkpoint's
        // vocabulary, added tokens, normalizer and pre-tokenizer unchanged.
        tokenizerConfiguration["tokenizer_class"] = "XLMRobertaTokenizer"
        let tokenizer = try AutoTokenizer.from(
            tokenizerConfig: Config(tokenizerConfiguration as [NSString: Any]),
            tokenizerData: Config(tokenizerObject as [NSString: Any])
        )
        for (token, id) in ["[P]": 128003, "[L]": 128007, "[SEP_TEXT]": 128002, "[DESCRIPTION]": 128010] {
            guard addedTokenIDs[token] == id,
                  tokenizer.tokenize(text: token) == [token]
            else { throw GLiNERError.invalidCheckpoint }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled = directory.appendingPathComponent("GLiNERSmall.mlmodelc")
        let url: URL
        if FileManager.default.fileExists(atPath: compiled.path) { url = compiled }
        else { url = try MLModel.compileModel(at: directory.appendingPathComponent("GLiNERSmall.mlpackage")) }
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        let expectedShape = [1, metadata.sequenceLength].map { NSNumber(value: $0) }
        guard inputs.count == 2, outputs.count == 1,
              ["input_ids", "attention_mask"].allSatisfy({
                  inputs[$0]?.multiArrayConstraint?.shape == expectedShape
                      && inputs[$0]?.multiArrayConstraint?.dataType == .int32
              }), outputs["logits"]?.multiArrayConstraint?.shape == expectedShape
        else { throw GLiNERError.invalidCheckpoint }
        self.metadata = metadata
        self.tokenizer = tokenizer
        self.addedTokenIDs = addedTokenIDs
        self.model = model
    }

    /// Returns a complete softmax vector in the exact prompt option order.
    ///
    /// Overlength inputs and unsupported schema syntax fail before inference.
    /// There are no retries, implicit fallback, or winner-only fabricated scores.
    public func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        try Task.checkCancellation()
        let input = try encodedInput(for: prompt)
        let count = metadata.sequenceLength
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        for index in 0 ..< count {
            ids[index] = NSNumber(value: index < input.inputIDs.count ? input.inputIDs[index] : metadata.padTokenID)
            mask[index] = NSNumber(value: index < input.inputIDs.count ? 1 : 0)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        // Synchronous inference keeps model use serialized within this actor.
        // Cancellation is cooperative at the boundaries of this Core ML call.
        let output = try prediction(from: features)
        try Task.checkCancellation()
        guard let values = output.featureValue(for: "logits")?.multiArrayValue,
              values.count == count else { throw GLiNERError.invalidOutput }
        let logits = input.markerPositions.map { values[$0].doubleValue }
        let probabilities = try GLiNERInput.probabilities(from: logits, expectedCount: prompt.options.count)
        return DecisionPrediction(probabilities: probabilities, modelIdentifier: metadata.modelID + "@" + metadata.revision)
    }

    private func prediction(from features: MLDictionaryFeatureProvider) throws -> any MLFeatureProvider {
        try model.prediction(from: features)
    }

    func encodedInput(for prompt: DecisionPrompt) throws -> GLiNERInput {
        let input = try GLiNERInput.build(for: prompt, maximumTokens: metadata.sequenceLength) {
            // UnigramTokenizer 1.3.4 recognizes added-token boundaries but
            // its ID lookup ignores the added-token table. Resolve those
            // IDs explicitly instead of silently feeding [UNK] embeddings.
            try tokenizer.tokenize(text: $0).map { token in
                guard let id = addedTokenIDs[token] ?? tokenizer.convertTokenToId(token) else {
                    throw GLiNERError.invalidInput
                }
                return id
            }
        }
        guard input.inputIDs.allSatisfy({ (0 ..< metadata.vocabularySize).contains($0) }) else {
            throw GLiNERError.invalidInput
        }
        return input
    }
}
#endif
