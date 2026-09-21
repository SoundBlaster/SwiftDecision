#if SWIFTDECISION_MLX
import Foundation
import Hub
import MLX
import MLXNN
import Tokenizers

/// Numeric precision used for native Laya inference.
public enum LayaPrecision: Sendable, Equatable {
    /// Use the checkpoint's native half-precision weights.
    case float16

    /// Cast checkpoint weights to Float32 for parity checks and higher precision arithmetic.
    case float32
}

/// Errors raised while loading or running a native Laya checkpoint.
public enum LayaMLXError: Error, Sendable, CustomStringConvertible {
    /// A required checkpoint file is missing or malformed.
    case invalidCheckpoint(String)

    /// The checkpoint uses a tokenizer token that cannot be resolved.
    case invalidTokenizer(String)

    /// A model parameter required by the native implementation is absent.
    case missingParameter(String)

    public var description: String {
        switch self {
        case let .invalidCheckpoint(message): "Invalid Laya checkpoint: \(message)"
        case let .invalidTokenizer(message): "Invalid Laya tokenizer: \(message)"
        case let .missingParameter(name): "Laya checkpoint is missing parameter '\(name)'"
        }
    }
}

enum LayaOptionTokenBudget {
    static let reservedInstructionTokens = 16

    static func fit(_ optionTokens: [[Int]], headMaximumLength: Int) throws -> [[Int]] {
        guard optionTokens.count >= 2, optionTokens.allSatisfy({ !$0.isEmpty }) else {
            throw DecisionError.invalidRequest("Laya requires at least two nonempty option token sequences")
        }

        guard headMaximumLength >= reservedInstructionTokens else {
            throw DecisionError.invalidRequest("the Laya head token budget is too small")
        }
        let availableOptionTokens = headMaximumLength - reservedInstructionTokens
        guard availableOptionTokens >= optionTokens.count else {
            throw DecisionError.invalidRequest("too many options for the Laya head token budget")
        }

        var totalOptionTokens = 0
        var exceedsBudget = false
        for tokens in optionTokens {
            if tokens.count > availableOptionTokens - totalOptionTokens {
                exceedsBudget = true
                break
            }
            totalOptionTokens += tokens.count
        }
        guard exceedsBudget else { return optionTokens }

        var fittedLengths = Array(repeating: 1, count: optionTokens.count)
        var remainingTokens = availableOptionTokens - optionTokens.count
        while remainingTokens > 0 {
            var didAllocate = false
            for index in optionTokens.indices where fittedLengths[index] < optionTokens[index].count {
                fittedLengths[index] += 1
                remainingTokens -= 1
                didAllocate = true
                if remainingTokens == 0 { break }
            }
            if !didAllocate { break }
        }

        return zip(optionTokens, fittedLengths).map { Array($0.prefix($1)) }
    }
}

/// Native, on-device MLX inference for the English `aac6fef/laya-mlx` checkpoint.
///
/// The checkpoint is loaded from disk and is never downloaded implicitly. Construct this backend
/// only on macOS 14 or newer, or iOS 17 or newer, on an Apple Silicon device.
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
public actor LayaMLXBackend: DecisionBackend {
    private let runtime: LayaRuntime

    /// Loads an English Laya-MLX checkpoint from a local directory.
    ///
    /// - Parameters:
    ///   - checkpointAt: Directory containing model, encoder, and tokenizer files.
    ///   - precision: Inference arithmetic precision; model files are not modified.
    public init(checkpointAt directory: URL, precision: LayaPrecision = .float16) throws {
        runtime = try LayaRuntime(checkpointAt: directory, precision: precision)
    }

    /// Runs native MLX inference and returns calibrated probabilities in prompt option order.
    public func predict(for prompt: DecisionPrompt) async throws -> DecisionPrediction {
        try Task.checkCancellation()
        let probabilities = try runtime.predict(prompt)
        try Task.checkCancellation()
        return DecisionPrediction(probabilities: probabilities, modelIdentifier: "laya-mlx")
    }
}

private struct LayaEncoderConfiguration: Decodable {
    let modelType: String
    let hiddenSize: Int
    let intermediateSize: Int
    let layerCount: Int
    let attentionHeadCount: Int
    let normEpsilon: Float
    let normBias: Bool
    let attentionBias: Bool
    let mlpBias: Bool
    let hiddenActivation: String
    let localAttention: Int
    let maxPositions: Int
    let layerTypes: [String]
    let ropeParameters: [String: RopeParameters]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case layerCount = "num_hidden_layers"
        case attentionHeadCount = "num_attention_heads"
        case normEpsilon = "norm_eps"
        case normBias = "norm_bias"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case hiddenActivation = "hidden_activation"
        case localAttention = "local_attention"
        case maxPositions = "max_position_embeddings"
        case layerTypes = "layer_types"
        case ropeParameters = "rope_parameters"
    }

    struct RopeParameters: Decodable {
        let theta: Float?

        enum CodingKeys: String, CodingKey { case theta = "rope_theta" }
    }

    func ropeBase(for kind: String) -> Float {
        if let theta = ropeParameters?[kind]?.theta { return theta }
        return kind == "full_attention" ? 160_000 : 10_000
    }

    var headDimension: Int { hiddenSize / attentionHeadCount }
}

private struct LayaAgentConfiguration: Decodable {
    let headLayers: Int
    let maximumLength: Int
    let headMaximumLength: Int
    let temperatures: [Double]
    let temperaturesByOptionCount: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case headLayers = "head_layers"
        case maximumLength = "max_len"
        case headMaximumLength = "head_max_len"
        case temperatures = "temperature"
        case temperaturesByOptionCount = "temperature_by_options"
    }
}

private struct LayaRuntime {
    private let parameters: [String: MLXArray]
    private let encoder: LayaEncoderConfiguration
    private let agent: LayaAgentConfiguration
    private let tokenizer: any Tokenizer
    private let clsID: Int
    private let separatorID: Int
    private let maskID: Int
    private let precision: DType

    init(checkpointAt directory: URL, precision requestedPrecision: LayaPrecision) throws {
        func data(_ relativePath: String) throws -> Data {
            let url = directory.appending(path: relativePath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw LayaMLXError.invalidCheckpoint("missing file \(relativePath)")
            }
            return try Data(contentsOf: url)
        }
        func decode<Configuration: Decodable>(_ type: Configuration.Type, from path: String) throws -> Configuration {
            do { return try JSONDecoder().decode(type, from: data(path)) }
            catch { throw LayaMLXError.invalidCheckpoint("cannot decode \(path): \(error)") }
        }

        let encoder = try decode(LayaEncoderConfiguration.self, from: "encoder/config.json")
        let agent = try decode(LayaAgentConfiguration.self, from: "rl_agent_config.json")
        guard encoder.modelType == "modernbert", encoder.hiddenActivation == "gelu",
              encoder.hiddenSize.isMultiple(of: encoder.attentionHeadCount), encoder.headDimension.isMultiple(of: 2),
              encoder.layerTypes.count == encoder.layerCount,
              Set(encoder.layerTypes).isSubset(of: ["full_attention", "sliding_attention"]),
              agent.temperatures.count == 3, agent.temperatures.allSatisfy({ $0.isFinite && $0 > 0 }),
              4 < agent.headMaximumLength, agent.headMaximumLength < agent.maximumLength,
              agent.maximumLength <= encoder.maxPositions
        else {
            throw LayaMLXError.invalidCheckpoint("unsupported model dimensions, layer types, or calibration values")
        }
        self.encoder = encoder
        self.agent = agent
        self.precision = requestedPrecision == .float32 ? .float32 : .float16

        let tokenizerConfigObject = try JSONSerialization.jsonObject(with: data("tokenizer/tokenizer_config.json"))
        let tokenizerDataObject = try JSONSerialization.jsonObject(with: data("tokenizer/tokenizer.json"))
        guard let tokenizerConfigDictionary = tokenizerConfigObject as? [NSString: Any],
              let tokenizerDataDictionary = tokenizerDataObject as? [NSString: Any]
        else {
            throw LayaMLXError.invalidTokenizer("tokenizer configuration JSON must contain objects")
        }
        let tokenizerConfig = Config(tokenizerConfigDictionary)
        let tokenizerData = Config(tokenizerDataDictionary)
        let loadedTokenizer: any Tokenizer
        do {
            loadedTokenizer = try AutoTokenizer.from(
                tokenizerConfig: tokenizerConfig,
                tokenizerData: tokenizerData,
                strict: false
            )
        } catch {
            throw LayaMLXError.invalidTokenizer("unable to load tokenizer: \(error)")
        }
        func specialTokenID(_ key: String) throws -> Int {
            guard let value = tokenizerConfigObject as? [String: Any],
                  let raw = value[key],
                  let token = (raw as? String) ?? (raw as? [String: Any])?["content"] as? String,
                  let id = loadedTokenizer.convertTokenToId(token)
            else { throw LayaMLXError.invalidTokenizer("missing token id for \(key)") }
            return id
        }
        let loadedCLS = try specialTokenID("cls_token")
        let loadedSeparator = try specialTokenID("sep_token")
        let loadedMask = try specialTokenID("mask_token")

        let weightsURL = directory.appending(path: "model.safetensors")
        var loaded: [String: MLXArray]
        do { loaded = try loadArrays(url: weightsURL) }
        catch { throw LayaMLXError.invalidCheckpoint("cannot read model.safetensors: \(error)") }
        var remapped: [String: MLXArray] = [:]
        for (sourceName, array) in loaded {
            var name = sourceName
                .replacingOccurrences(of: ".in_proj_weight", with: ".in_proj.weight")
                .replacingOccurrences(of: ".in_proj_bias", with: ".in_proj.bias")
            for prefix in ["scorer", "act_head"] {
                if name.hasPrefix(prefix + "."), !name.hasPrefix(prefix + ".layers.") {
                    let suffix = name.dropFirst(prefix.count + 1)
                    name = prefix + ".layers." + suffix
                }
            }
            remapped[name] = requestedPrecision == .float32 ? array.asType(.float32) : array.asType(.float16)
        }
        tokenizer = loadedTokenizer
        clsID = loadedCLS
        separatorID = loadedSeparator
        maskID = loadedMask
        parameters = remapped
        try validateRequiredParameters()
    }

    func predict(_ prompt: DecisionPrompt) throws -> [Double] {
        let options = prompt.options.map(\.description)
        guard options.count >= 2 else { throw DecisionError.invalidRequest("Laya requires at least two options") }
        let encoded = try makeInput(instructions: prompt.instructions, context: prompt.context, kind: prompt.kind, options: options)
        let logits = try forward(inputIDs: encoded.ids, markerPositions: encoded.markerPositions, kind: prompt.kind)
        let temperature = calibratedTemperature(for: prompt.kind, optionCount: options.count)
        let probabilities = softmax(logits / Float(temperature), axis: 0)
        probabilities.eval()
        return probabilities.asArray(Float.self).map(Double.init)
    }

    private func makeInput(
        instructions: String,
        context: String,
        kind: DecisionKind,
        options: [String]
    ) throws -> (ids: [Int32], markerPositions: [Int]) {
        let type = kind.rawValue
        let safeMask = tokenizer.convertIdToToken(maskID) ?? "[MASK]"
        let headIDs = tokenizer.encode(text: "\(type) question: \(instructions.replacingOccurrences(of: safeMask, with: " "))", addSpecialTokens: false)
        let optionIDs = try LayaOptionTokenBudget.fit(options.map { option in
            [maskID] + tokenizer.encode(
                text: " " + option.replacingOccurrences(of: safeMask, with: " "),
                addSpecialTokens: false
            ).prefix(48)
        }, headMaximumLength: agent.headMaximumLength)
        let usedOptionTokens = optionIDs.reduce(0) { $0 + $1.count }
        let instructionTokenBudget = agent.headMaximumLength - usedOptionTokens
        let truncatedHead = Array(headIDs.prefix(instructionTokenBudget))
        var ids = [Int32(clsID)]
        ids.append(contentsOf: truncatedHead.map(Int32.init))
        ids.append(Int32(separatorID))
        var markers: [Int] = []
        for option in optionIDs {
            markers.append(ids.count)
            ids.append(contentsOf: option.map(Int32.init))
        }
        ids.append(Int32(separatorID))
        guard ids.count < agent.maximumLength else {
            throw DecisionError.invalidRequest("decision head and options exceed the model's maximum sequence length")
        }
        let room = agent.maximumLength - ids.count - 1
        let state = context.replacingOccurrences(of: safeMask, with: " ")
        ids.append(contentsOf: tokenizer.encode(text: state, addSpecialTokens: false).prefix(room).map(Int32.init))
        ids.append(Int32(separatorID))
        return (ids, markers)
    }

    private func forward(inputIDs: [Int32], markerPositions: [Int], kind: DecisionKind) throws -> MLXArray {
        let sequenceLength = inputIDs.count
        let ids = MLXArray(inputIDs)
        var hidden = parameters["encoder.embeddings.tok_embeddings.weight"]!.take(ids, axis: 0)
        hidden = layerNorm(hidden, prefix: "encoder.embeddings.norm", epsilon: encoder.normEpsilon)
        hidden = hidden.reshaped([1, sequenceLength, encoder.hiddenSize])

        for layerIndex in 0 ..< encoder.layerCount {
            let prefix = "encoder.layers.\(layerIndex)"
            let kind = encoder.layerTypes[layerIndex]
            let residual = hidden
            let normalized = layerIndex == 0
                ? hidden
                : layerNorm(hidden, prefix: prefix + ".attn_norm", epsilon: encoder.normEpsilon)
            hidden = residual + encoderAttention(normalized, prefix: prefix + ".attn", layerType: kind, length: sequenceLength)

            let mlpResidual = hidden
            let mlpInput = layerNorm(hidden, prefix: prefix + ".mlp_norm", epsilon: encoder.normEpsilon)
            let projection = linear(mlpInput, prefix: prefix + ".mlp.Wi")
            let split = projection.split(parts: 2, axis: -1)
            let value = split[0]
            let gate = split[1]
            hidden = mlpResidual + linear(gelu(value) * gate, prefix: prefix + ".mlp.Wo")
        }
        hidden = layerNorm(hidden, prefix: "encoder.final_norm", epsilon: encoder.normEpsilon)

        let kindIndex: Int = switch kind { case .choice: 0; case .score: 1; case .noul: 2 }
        let typeEmbedding = parameters["type_emb.weight"]!.take(MLXArray([Int32(kindIndex)]), axis: 0)
        hidden = hidden + typeEmbedding.reshaped([1, 1, encoder.hiddenSize])
        let attentionMask = MLXArray.ones([1, 1, sequenceLength, sequenceLength], dtype: .bool)
        for layer in 0 ..< agent.headLayers {
            let prefix = "head.layers.\(layer)"
            let residual = hidden
            let normalized = layerNorm(hidden, prefix: prefix + ".norm1", epsilon: 1e-5)
            hidden = residual + headAttention(normalized, prefix: prefix + ".self_attn", mask: attentionMask)
            let residual2 = hidden
            let normalized2 = layerNorm(hidden, prefix: prefix + ".norm2", epsilon: 1e-5)
            hidden = residual2 + linear(maximum(linear(normalized2, prefix: prefix + ".linear1"), 0), prefix: prefix + ".linear2")
        }

        let markers = MLXArray(markerPositions.map(Int32.init))
        let markerStates = hidden.take(markers, axis: 1).reshaped([markerPositions.count, encoder.hiddenSize])
        return linear(gelu(linear(layerNorm(markerStates, prefix: "scorer.layers.0", epsilon: 1e-5), prefix: "scorer.layers.1")), prefix: "scorer.layers.3")
            .squeezed(axis: -1)
    }

    private func encoderAttention(_ input: MLXArray, prefix: String, layerType: String, length: Int) -> MLXArray {
        let qkv = linear(input, prefix: prefix + ".Wqkv")
            .reshaped([1, length, 3, encoder.attentionHeadCount, encoder.headDimension])
            .split(parts: 3, axis: 2)
        var query = qkv[0].squeezed(axis: 2).transposed(0, 2, 1, 3)
        var key = qkv[1].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let value = qkv[2].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let rope = RoPE(
            dimensions: encoder.headDimension,
            traditional: false,
            base: encoder.ropeBase(for: layerType)
        )
        query = rope(query)
        key = rope(key)
        let mask: MLXArray?
        if layerType == "sliding_attention" {
            let radius = encoder.localAttention / 2
            let values = (0 ..< length).flatMap { queryIndex in
                (0 ..< length).map { keyIndex in abs(queryIndex - keyIndex) <= radius }
            }
            mask = MLXArray(values, [1, 1, length, length])
        } else {
            mask = nil
        }
        let attended = MLXFast.scaledDotProductAttention(
            queries: query,
            keys: key,
            values: value,
            scale: 1 / sqrt(Float(encoder.headDimension)),
            mask: mask
        ).transposed(0, 2, 1, 3).reshaped([1, length, encoder.hiddenSize])
        return linear(attended, prefix: prefix + ".Wo")
    }

    private func headAttention(_ input: MLXArray, prefix: String, mask: MLXArray) -> MLXArray {
        let length = input.shape[1]
        let headCount = max(1, encoder.hiddenSize / 64)
        let dimension = encoder.hiddenSize / headCount
        let qkv = linear(input, prefix: prefix + ".in_proj")
            .reshaped([1, length, 3, headCount, dimension])
            .split(parts: 3, axis: 2)
        let attended = MLXFast.scaledDotProductAttention(
            queries: qkv[0].squeezed(axis: 2).transposed(0, 2, 1, 3),
            keys: qkv[1].squeezed(axis: 2).transposed(0, 2, 1, 3),
            values: qkv[2].squeezed(axis: 2).transposed(0, 2, 1, 3),
            scale: 1 / sqrt(Float(dimension)),
            mask: mask
        ).transposed(0, 2, 1, 3).reshaped([1, length, encoder.hiddenSize])
        return linear(attended, prefix: prefix + ".out_proj")
    }

    private func linear(_ input: MLXArray, prefix: String) -> MLXArray {
        guard let weight = parameters[prefix + ".weight"] else { preconditionFailure("Missing parameter \(prefix).weight") }
        var output = matmul(input, weight.T)
        if let bias = parameters[prefix + ".bias"] { output = output + bias }
        return output
    }

    private func layerNorm(_ input: MLXArray, prefix: String, epsilon: Float) -> MLXArray {
        MLXFast.layerNorm(input, weight: parameters[prefix + ".weight"], bias: parameters[prefix + ".bias"], eps: epsilon)
    }

    private func calibratedTemperature(for kind: DecisionKind, optionCount: Int) -> Double {
        let size = optionCount <= 2 ? "2" : optionCount <= 5 ? "3-5" : optionCount <= 10 ? "6-10" : "11+"
        let key = "\(kind.rawValue):\(size)"
        if let calibrated = agent.temperaturesByOptionCount?[key] { return calibrated }
        let index: Int = switch kind { case .choice: 0; case .score: 1; case .noul: 2 }
        return agent.temperatures[index]
    }

    private func validateRequiredParameters() throws {
        let required = [
            "encoder.embeddings.tok_embeddings.weight", "encoder.embeddings.norm.weight",
            "encoder.final_norm.weight", "type_emb.weight",
            "scorer.layers.0.weight", "scorer.layers.1.weight", "scorer.layers.1.bias",
            "scorer.layers.3.weight", "scorer.layers.3.bias"
        ]
        for name in required where parameters[name] == nil { throw LayaMLXError.missingParameter(name) }
        for layer in 0 ..< encoder.layerCount {
            let prefix = "encoder.layers.\(layer)"
            for name in ["attn.Wqkv.weight", "attn.Wo.weight", "mlp_norm.weight", "mlp.Wi.weight", "mlp.Wo.weight"] {
                if parameters["\(prefix).\(name)"] == nil { throw LayaMLXError.missingParameter("\(prefix).\(name)") }
            }
            if layer > 0, parameters["\(prefix).attn_norm.weight"] == nil {
                throw LayaMLXError.missingParameter("\(prefix).attn_norm.weight")
            }
        }
        for layer in 0 ..< agent.headLayers {
            let prefix = "head.layers.\(layer)"
            for name in ["self_attn.in_proj.weight", "self_attn.out_proj.weight", "norm1.weight", "norm2.weight", "linear1.weight", "linear1.bias", "linear2.weight", "linear2.bias"] {
                if parameters["\(prefix).\(name)"] == nil { throw LayaMLXError.missingParameter("\(prefix).\(name)") }
            }
        }
    }
}
#endif
