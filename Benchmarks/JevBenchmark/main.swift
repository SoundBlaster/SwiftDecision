import Foundation
import SwiftDecision
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum JevBenchmark {
    private struct Scenario {
        let name: String
        let run: () async throws -> String
    }

    private struct Measurement {
        let latencies: [Double]
        let modelIdentifiers: [String]

        var sortedLatencies: [Double] { latencies.sorted() }
        var medianMilliseconds: Double {
            let values = sortedLatencies
            let middle = values.count / 2
            let median = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            return median * 1_000
        }
        var p95Milliseconds: Double { percentile(0.95) * 1_000 }
        var throughputPerSecond: Double { Double(latencies.count) / latencies.reduce(0, +) }

        private func percentile(_ fraction: Double) -> Double {
            let values = sortedLatencies
            let index = max(0, Int(ceil(fraction * Double(values.count))) - 1)
            return values[index]
        }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Jev benchmark failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTDECISION_RUN_JEV_BENCHMARKS"] == "1" else {
            throw BenchmarkError("Set SWIFTDECISION_RUN_JEV_BENCHMARKS=1 to enable billable live Jev requests.")
        }
        guard let apiKey = environment["TYPESAFE_API_KEY"], !apiKey.isEmpty else {
            throw BenchmarkError("Set TYPESAFE_API_KEY before running the live Jev benchmark.")
        }

        let sampleCount = try samples(from: Array(CommandLine.arguments.dropFirst()))
        let totalRequests = (sampleCount + 1) * 3 // one warm-up plus measured calls for each kind
        print("Live Jev benchmark: \(sampleCount) samples per kind, \(totalRequests) total requests including warm-ups.")
        print("Requests are sent sequentially and may incur TypeSafe API usage. No prompts or credentials are printed.")

        let engine = DecisionEngine(backend: try JevDecisionBackend(apiKey: apiKey))
        let scenarios = [
            Scenario(name: "Noul") {
                let result = try await engine.noul(
                    statement: "Is the service outage affecting all customers?",
                    context: "The status page reports that every customer is unable to sign in."
                )
                return Self.modelIdentifier(in: result.trace)
            },
            Scenario(name: "Choice") {
                let result = try await engine.choice(
                    instructions: "Choose the team that should handle this message.",
                    context: "My invoice contains a duplicate charge from yesterday.",
                    options: [
                        ChoiceOption(label: "support", description: "Account access or product use."),
                        ChoiceOption(label: "billing", description: "Invoices, refunds, or charges."),
                        ChoiceOption(label: "sales", description: "Plan selection or purchasing.")
                    ]
                )
                return Self.modelIdentifier(in: result.trace)
            },
            Scenario(name: "Score") {
                let result = try await engine.score(
                    instructions: "Rate how completely the response answers the question.",
                    context: "Question: How do I reset my password? Response: Open Settings, choose Security, and select Reset Password.",
                    levels: [
                        (description: "Does not answer the question.", value: 0),
                        (description: "Partially answers the question.", value: 1),
                        (description: "Fully answers the question.", value: 2)
                    ]
                )
                return Self.modelIdentifier(in: result.trace)
            }
        ]

        print("\nDate: \(ISO8601DateFormatter().string(from: Date()))")
        print("Platform: \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.architecture)")
        print("Swift compiler: run `swift --version` separately and record it with these results.")
        print("Latency is end-to-end for one sequential DecisionEngine call, including network and provider inference.")
        print("P95 uses the nearest-rank percentile; throughput is measured calls divided by summed call latency.")
        print("\n| Kind | Model identifier | Samples | P50 (ms) | P95 (ms) | Sequential throughput (decisions/s) |")
        print("| --- | --- | ---: | ---: | ---: | ---: |")

        for scenario in scenarios {
            _ = try await scenario.run() // warm up the URLSession connection; excluded from statistics

            var latencies = [Double]()
            var models = [String]()
            latencies.reserveCapacity(sampleCount)
            models.reserveCapacity(sampleCount)

            for _ in 0 ..< sampleCount {
                let start = ProcessInfo.processInfo.systemUptime
                let model = try await scenario.run()
                latencies.append(ProcessInfo.processInfo.systemUptime - start)
                models.append(model)
            }

            let measurement = Measurement(latencies: latencies, modelIdentifiers: models)
            let modelIdentifier = measurement.modelIdentifiers.last ?? "unknown"
            print("| \(scenario.name) | `\(modelIdentifier)` | \(sampleCount) | \(String(format: "%.1f", measurement.medianMilliseconds)) | \(String(format: "%.1f", measurement.p95Milliseconds)) | \(String(format: "%.3f", measurement.throughputPerSecond)) |")
            let raw = measurement.latencies.map { String(format: "%.4f", $0) }.joined(separator: ", ")
            print("  raw seconds (\(scenario.name)): [\(raw)]")
            let distinctModels = Set(measurement.modelIdentifiers)
            if distinctModels.count > 1 {
                print("  note: model identifier changed during this scenario: \(distinctModels.sorted().joined(separator: ", "))")
            }
        }
    }

    private static func samples(from arguments: [String]) throws -> Int {
        guard let flagIndex = arguments.firstIndex(of: "--samples"), arguments.indices.contains(flagIndex + 1),
              let count = Int(arguments[flagIndex + 1]), (10 ... 100).contains(count)
        else {
            throw BenchmarkError("Usage: swift run --disable-default-traits JevBenchmark --samples 20 (choose 10...100 samples per decision kind).")
        }
        return count
    }

    private static func modelIdentifier(in trace: [DecisionTraceEvent]) -> String {
        trace.first { $0.stage == .inferenceCompleted }?.detail ?? "unknown"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown architecture"
        #endif
    }
}

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
