#if SWIFTDECISION_FOUNDATION_MODELS && canImport(FoundationModels)
import Foundation
import FoundationModels
import XCTest

final class FoundationModelsStrategyExperiments: XCTestCase {
    func testBoundedStrategyScreen() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        guard let strategy = ProcessInfo.processInfo.environment["SWIFTDECISION_FM_EXPERIMENT"] else {
            throw XCTSkip("Explicit local strategy experiment only")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Local model unavailable")
        }
        let started = ContinuousClock.now
        for sample in Self.samples {
            guard started.duration(to: .now) < .seconds(30) else {
                return XCTFail("Screen budget exhausted")
            }
            let request = try Self.request(strategy: strategy == "verifiedWeights" ? "namedWeightsV1" : strategy, sample: sample)
            let session = LanguageModelSession(model: .default, instructions: request.instructions)
            let begin = ContinuousClock.now
            let response = try await session.respond(
                to: request.prompt, schema: request.schema,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 180))
            let selected: String
            var values: [Double] = []
            switch strategy {
            case "namedWeights", "gatedWeights", "namedWeightsJSON", "criterionWeights", "fewShotWeights", "verifiedWeights":
                values = try sample.options.indices.map {
                    try response.content.value(Double.self, forProperty: "option_\($0)")
                }
                let sum = values.reduce(0, +)
                values = sum > 0 ? values.map { $0 / sum } : values
                if strategy == "verifiedWeights" {
                    let reversed = Sample(id: sample.id, task: sample.task, context: sample.context,
                        options: sample.options.reversed(), expected: sample.expected)
                    let check = try Self.request(strategy: "namedWeightsV1", sample: reversed)
                    let checkSession = LanguageModelSession(model: .default, instructions: check.instructions)
                    let checkResponse = try await checkSession.respond(to: check.prompt, schema: check.schema,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 180))
                    let reverseValues = try sample.options.indices.map {
                        try checkResponse.content.value(Double.self, forProperty: "option_\($0)")
                    }.reversed().map { $0 }
                    let reverseSum = reverseValues.reduce(0, +)
                    let aligned = reverseSum > 0 ? reverseValues.map { $0 / reverseSum } : reverseValues
                    let first = values.indices.max { values[$0] < values[$1] }!
                    let second = aligned.indices.max { aligned[$0] < aligned[$1] }!
                    let firstUnique = values.filter { abs($0 - values[first]) < 1e-9 }.count == 1
                    let secondUnique = aligned.filter { abs($0 - aligned[second]) < 1e-9 }.count == 1
                    values = first == second && firstUnique && secondUnique
                        ? zip(values, aligned).map { ($0 + $1) / 2 }
                        : Array(repeating: 1.0 / Double(values.count), count: values.count)
                }
                var isAnswerable = try strategy != "gatedWeights" || response.content.value(String.self, forProperty: "assessment") == "enough_information"
                if strategy == "criterionWeights" {
                    isAnswerable = try response.content.value(String.self, forProperty: "criterion").lowercased() != "none"
                }
                if isAnswerable, let best = values.indices.max(by: { values[$0] < values[$1] }), values[best] >= 0.6 {
                    selected = sample.options[best]
                } else { selected = "unknown" }
            case "supportGrades":
                let grades = try sample.options.indices.map {
                    try response.content.value(String.self, forProperty: "option_\($0)")
                }
                let supported = grades.indices.filter { grades[$0] == "supported" }
                selected = supported.count == 1 ? sample.options[supported[0]] : "unknown"
            default:
                selected = try response.content.value(String.self, forProperty: "selection")
            }
            let row: [String: Any] = [
                "strategy": strategy, "id": sample.id, "selected": selected,
                "expected": sample.expected, "correct": selected == sample.expected,
                "values": values, "duration": String(describing: begin.duration(to: .now))
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("FM_STRATEGY " + String(decoding: data, as: UTF8.self))
        }
    }

    func testBinaryScreen() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        guard let mode = ProcessInfo.processInfo.environment["SWIFTDECISION_FM_BINARY"] else { throw XCTSkip("Explicit local experiment") }
        struct BinarySample: Decodable { let id: String; let kind: String; let task: String; let context: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "FoundationModelsDecisionQuality", withExtension: "jsonl"))
        let samples = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(BinarySample.self, from: Data($0.utf8))
        }.filter { $0.kind == "noul" }
        for sample in samples {
            let property: DynamicGenerationSchema.Property
            if mode == "scalar" {
                property = .init(name: "probabilityTrue", description: "Probability that the statement is true: 1 if context clearly supports it, 0 if context clearly contradicts it, 0.5 if unknown or conflicting.", schema: DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)]))
            } else {
                property = .init(name: "verdict", description: "supported if context establishes the statement, contradicted if context establishes its negation, unknown if information is missing or conflicting.", schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(["supported", "contradicted", "unknown"])]))
            }
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "TruthAssessment", properties: [property]), dependencies: [])
            let session = LanguageModelSession(model: .default, instructions: "Evaluate the truth of the statement using only the provided context. Missing information is unknown, not false.")
            let response = try await session.respond(to: "Statement: \(sample.task)\nContext: \(sample.context)", schema: schema, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 80))
            let value = mode == "scalar" ? String(try response.content.value(Double.self, forProperty: "probabilityTrue")) : try response.content.value(String.self, forProperty: "verdict")
            print("FM_BINARY \(mode) \(sample.id): \(value)")
        }
    }

    private struct Sample {
        let id: String
        let task: String
        let context: String
        let options: [String]
        let expected: String
    }

    private static var samples: [Sample] {
        [
            .init(id: "star-last", task: "Select the astronomical object that is a star.", context: "", options: ["Hello", "Sun"], expected: "Sun"),
            .init(id: "star-first", task: "Select the astronomical object that is a star.", context: "", options: ["Sun", "Hello"], expected: "Sun"),
            .init(id: "farewell-last", task: "Choose the English farewell.", context: "", options: ["Hello", "Goodbye"], expected: "Goodbye"),
            .init(id: "farewell-first", task: "Choose the English farewell.", context: "", options: ["Goodbye", "Hello"], expected: "Goodbye"),
            .init(id: "route-last", task: "Choose the department responsible for the request.", context: "I was charged twice. Please refund the duplicate payment. Billing handles payments. Support handles software bugs.", options: ["Support", "Billing"], expected: "Billing"),
            .init(id: "route-first", task: "Choose the department responsible for the request.", context: "I was charged twice. Please refund the duplicate payment. Billing handles payments. Support handles software bugs.", options: ["Billing", "Support"], expected: "Billing"),
            .init(id: "ambiguous-forward", task: "Hello or Kitty?", context: "", options: ["Hello", "Kitty"], expected: "unknown"),
            .init(id: "ambiguous-reverse", task: "Kitty or Hello?", context: "", options: ["Kitty", "Hello"], expected: "unknown")
        ]
    }

    @available(macOS 26, iOS 26, *)
    private static func request(strategy: String, sample: Sample) throws -> (instructions: String, prompt: String, schema: GenerationSchema) {
        var prompt = """
        Task: \(sample.task)
        Context: \(sample.context)
        Alternatives:
        \(sample.options.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
        """
        if strategy == "namedWeightsJSON" {
            let data = try JSONSerialization.data(withJSONObject: [
                "kind": "choice", "instructions": sample.task, "context": sample.context,
                "options": sample.options.enumerated().map { ["id": String($0.offset), "description": $0.element] }
            ], options: [.sortedKeys])
            prompt = String(decoding: data, as: UTF8.self)
        }
        var instructions = """
        Perform the task using the context and the meanings of the alternatives.
        Evaluate the alternatives by their meaning, not their position.
        If no selection criterion is provided or the information is insufficient, indicate uncertainty.
        For a numeric assessment with no basis to prefer an alternative, give all alternatives equal support 0.5.
        """
        if strategy == "namedWeightsV1" {
            instructions = instructions.replacingOccurrences(of: "For a numeric assessment with no basis to prefer an alternative, give all alternatives equal support 0.5.", with: "")
        }
        if strategy == "fewShotWeights" {
            instructions += """

            Examples:
            Task: select the fruit. Alternatives: chair, pear. Support: chair=0, pear=1.
            Task: select the frozen object. Alternatives: ice, lava. Support: ice=1, lava=0.
            Task: tea or coffee? No selection criterion. Support: tea=0.5, coffee=0.5.
            """
        }
        let properties: [DynamicGenerationSchema.Property]
        switch strategy {
        case "namedWeights", "gatedWeights", "namedWeightsJSON", "criterionWeights", "fewShotWeights", "namedWeightsV1":
            let weights: [DynamicGenerationSchema.Property] = sample.options.enumerated().map { index, option in
                .init(name: "option_\(index)",
                    description: "Relative support for \(option) satisfying the task. 0 means contradicted; 1 means fully supported. Use equal positive support when no criterion is given.",
                    schema: DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)]))
            }
            let gate: [DynamicGenerationSchema.Property] = strategy == "criterionWeights" ? [
                .init(name: "criterion", description: "The deciding requirement explicitly requested by the task, in a few words. If it merely lists alternatives without a requirement, write none. Never invent a preference.", schema: DynamicGenerationSchema(type: String.self))
            ] : strategy == "gatedWeights" ? [
                .init(name: "assessment",
                    description: "enough_information only if the task states a selection criterion and context or word meanings decide it. A bare A or B question has no criterion: insufficient_information. Unobservable future events are insufficient_information.",
                    schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(["insufficient_information", "enough_information"])]))
            ] : []
            properties = gate + weights
        case "supportGrades":
            properties = sample.options.enumerated().map { index, option in
                .init(name: "option_\(index)",
                    description: "Does \(option) satisfy the task? supported: it meets the criterion; contradicted: it does not; unknown: no criterion or insufficient evidence.",
                    schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(["supported", "contradicted", "unknown"])]))
            }
        case "semanticEnum", "evidenceEnum":
            let selection = DynamicGenerationSchema.Property(name: "selection",
                description: "The alternative that satisfies the task, or unknown if there is no criterion or insufficient information.",
                schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(sample.options + ["unknown"])]))
            properties = strategy == "evidenceEnum" ? [
                .init(name: "evidence", description: "One short relevant fact supporting the selection, or no criterion if absent. At most ten words.", schema: DynamicGenerationSchema(type: String.self)),
                selection
            ] : [selection]
        default:
            throw NSError(domain: "Unknown experiment strategy", code: 1)
        }
        return (instructions, prompt, try GenerationSchema(root: DynamicGenerationSchema(name: "DecisionEvaluation", properties: properties), dependencies: []))
    }
}
#endif
