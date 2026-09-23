# SwiftDecision

[![CI](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml)
[![Version](https://img.shields.io/github/v/release/SoundBlaster/SwiftDecision)](https://github.com/SoundBlaster/SwiftDecision/releases)
[![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange?logo=swift)](https://www.swift.org)
![Apple platforms](https://img.shields.io/badge/Apple%20platforms-macOS%2010.15%2B%20%7C%20iOS%2015%2B%20%7C%20tvOS%2013%2B%20%7C%20watchOS%206%2B-lightgrey?logo=apple)
![Optional MLX trait](https://img.shields.io/badge/MLX-optional%20trait-6e56cf?logo=apple)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

**Turn model probabilities into typed decisions your Swift app can act on.**

SwiftDecision gives applications a small, composable decision layer for AI-powered classification, routing, yes/no checks, and rubric scoring. Ask a model to choose from your options; get a typed value with its probabilities, confidence, and an explicit outcome. If a result does not meet your policy, SwiftDecision can abstain or return your chosen fallback.

Use hosted providers such as [SwiftJev](https://github.com/SoundBlaster/SwiftJev), run the English Laya model locally with native Apple MLX, or provide your own backend. [SpecificationCore](https://github.com/SoundBlaster/SpecificationCore) powers request and output validation, ordered policy routing, and decision composition inside the package.

**Models propose. Your application keeps control of policy and action.**

## Why SwiftDecision

- **Use model decisions as Swift values.** `choice` preserves your typed labels; `noul` returns `Bool`; `score` returns a selected rubric level and an expected numeric value.
- **Handle uncertainty explicitly.** Configure acceptance thresholds and choose between an accepted result, abstention for review, or an application-defined fallback.
- **Keep backends replaceable.** Use Jev, local Laya with the optional `MLX` trait, or any type that conforms to `DecisionBackend`.
- **Compose with SpecificationCore.** Async specifications validate inputs and predictions, select policies in order, and wrap backend evaluation.
- **Own operational behavior.** SwiftDecision checks cancellation, supports inference timeouts, and can emit content-free traces and metrics.

Embed typed decisions in the workflows your app already owns. Connect the result to your UI, queue, or next action in application code.

## Quick start

### 1. Add the package

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SoundBlaster/SwiftDecision.git", from: "0.3.0")
],
```

If your app still supports iOS 13 or 14, constrain resolution to the compatible 0.3 series. The up-to-next-minor requirement excludes 0.4.0 and later:

```swift
dependencies: [
    .package(
        url: "https://github.com/SoundBlaster/SwiftDecision.git",
        .upToNextMinor(from: "0.3.0")
    )
],
```

Add the product to your target:

```swift
.product(name: "SwiftDecision", package: "SwiftDecision")
```

### 2. Make a typed decision

Set `TYPESAFE_API_KEY` in your environment, then use a backend and engine:

```sh
export TYPESAFE_API_KEY="your-api-key"
```

```swift
import SwiftDecision

enum InboxRoute: Sendable, Hashable {
    case billing
    case support
    case manualReview
}

@main
struct InboxTriage {
    static func main() async throws {
        let backend = ClosureDecisionBackend { _ in
            DecisionPrediction(probabilities: [0.05, 0.90, 0.05], modelIdentifier: "fixture")
        }
        let engine = DecisionEngine(
            backend: backend,
            configuration: .init(timeout: 8)
        )

        let result = try await engine.choice(
            instructions: "Choose the best team for this customer message.",
            context: "I was charged twice for my subscription.",
            options: [
                ChoiceOption(label: InboxRoute.billing, description: "billing: invoices, refunds, and charges"),
                ChoiceOption(label: InboxRoute.support, description: "support: account access and product use"),
                ChoiceOption(label: InboxRoute.manualReview, description: "manual review: the right team is unclear")
            ],
            fallback: .manualReview
        )

        switch result.outcome {
        case let .accepted(route):
            print("Route to: \(route)")
        case let .abstained(reason):
            print("Review required: \(reason)")
        case let .fallback(route, reason):
            print("Use \(route); model result did not meet policy: \(reason)")
        }
    }
}
```

`choice` returns `DecisionResult<InboxRoute>`. The model never has to generate or parse your app's enum: SwiftDecision maps the winning option back to its original typed label. `noul` evaluates a Boolean statement; `score` evaluates an ordered rubric and also reports the probability-weighted expected value.

For a no-network example that runs with deterministic fixture responses:

```sh
swift run InboxTriageExample
```

## Decision outcomes

Every decision is resolved against the policy configured for its kind:

- **Accepted:** the best option satisfies your probability and confidence thresholds.
- **Abstained:** no result satisfies policy and no fallback was supplied; route it to a person or another system.
- **Fallback:** no result satisfies policy, so SwiftDecision returns the fallback you explicitly provided.
- **Thrown error:** invalid input, invalid backend output, provider errors, cancellation, and timeouts remain errors. They are not disguised as abstentions.

Set independent thresholds for each decision kind:

```swift
let policies = DecisionPolicies(
    noul: DecisionPolicy(minimumProbability: 0.7),
    choice: DecisionPolicy(minimumProbability: 0.75, minimumConfidence: 0.1),
    score: DecisionPolicy(minimumProbability: 0.6)
)

let engine = DecisionEngine(
    backend: backend,
    configuration: .init(policies: policies, timeout: 8)
)
```

SwiftDecision validates that backend probabilities match the request, are finite and nonnegative, and are normalized. These checks protect the decision boundary. Evaluate model accuracy and tune thresholds and fallbacks on your own data.

## Backends

### Hosted providers

TypeSafe Jev is available as the separate [`SwiftJev`](https://github.com/SoundBlaster/SwiftJev) package. It conforms to `DecisionBackend` and keeps the hosted provider and HTTP transport outside the core decision library.

### Native Laya with MLX

The non-default `MLX` SwiftPM Trait enables `LayaMLXBackend`, which runs the English `aac6fef/laya-mlx` checkpoint published by Convai Innovations locally with MLX. It does not invoke Python or download model weights at runtime. Provide a local checkpoint directory. The backend requires Apple Silicon, macOS 14+ or iOS 17+, and SwiftPM 6.3+. SwiftPM can still resolve or fetch optional packages during dependency resolution when the trait is disabled; the trait controls whether the MLX API and products are enabled for the target.

Enable the trait in the consuming package:

```swift
.package(
    url: "https://github.com/SoundBlaster/SwiftDecision.git",
    from: "0.3.0",
    traits: ["MLX"]
)
```

Build and test the MLX configuration on Apple Silicon:

```sh
swift build --traits MLX --triple arm64-apple-macosx14.0
swift test --traits MLX --triple arm64-apple-macosx14.0
```

For a local checkpoint smoke test, set `SWIFTDECISION_LAYA_CHECKPOINT` to its directory. For numerical parity against Python Laya-MLX, also provide `SWIFTDECISION_LAYA_REFERENCE_JSON` with fixed Noul, Choice, and Score reference outputs:

Generate a reference file with the Python implementation and the same checkpoint:

```sh
python3 -m pip install laya-mlx
python3 Scripts/generate_laya_reference.py \
  --checkpoint /path/to/laya-mlx \
  --output /path/to/laya-reference.json \
  --dtype float16
```

```sh
SWIFTDECISION_LAYA_CHECKPOINT=/path/to/laya-mlx \
SWIFTDECISION_LAYA_REFERENCE_JSON=/path/to/laya-reference.json \
SWIFTDECISION_LAYA_PRECISION=float16 \
swift test --traits MLX --triple arm64-apple-macosx14.0 --filter LayaParityTests
```

The parity check requires matching selected option identifiers and compares probabilities within `0.0001` for FP32 or `0.02` for FP16. It verifies runtime compatibility for those test inputs, not model quality on arbitrary application data. See the [Laya MLX inference pipeline](Documentation/LayaMLXInferencePipeline.md) for the model input and native forward pass. The model weights are not redistributed; see [NOTICE](NOTICE) and the model card for terms.

### Bring your own backend

Implement `DecisionBackend` to connect another provider or an application-owned model. `ClosureDecisionBackend` is available for simple adapters, deterministic tests, and offline examples:

```swift
let backend = ClosureDecisionBackend { prompt in
    // Return one probability per prompt option, in the original order.
    DecisionPrediction(probabilities: [0.08, 0.92], modelIdentifier: "my-provider")
}
```

## Traces and metrics

Tracing is enabled by default. `result.trace` records ordered, content-free decision stages and model identifiers. `result.specificationTrace` exposes the nested SpecificationCore events produced by request validation, ordered policy routing, backend decision evaluation, output validation, and acceptance policy checks:

```swift
let result = try await engine.choice(
    instructions: "Choose a team.",
    context: "The customer was charged twice.",
    options: options
)

for event in result.specificationTrace {
    print(event.name, event.outcome, event.durationNanoseconds)
}
```

The SpecificationCore `Tracing` trait is enabled by SwiftDecision for its dependency. Both trace collections omit request and prediction contents. Disable event collection when a call site does not need either trace:

```swift
let engine = DecisionEngine(
    backend: backend,
    configuration: .init(traceMode: .disabled)
)
```

If a decision throws and there is no `DecisionResult` to inspect, provide `specificationTraceHandler` when creating the engine. SwiftDecision calls it once per decision with the Core events recorded before the error. The event list is empty when validation fails before any Core evaluation. Stable trace names identify `request validation`, `policy routing`, `backend prediction`, `output validation`, and `acceptance policy`; the last stage also shows which threshold failed. `traceMode: .disabled` suppresses both trace collections and this callback.

An optional `DecisionMetricsHandler` receives one measurement per completed or failed decision. Metrics contain decision kind, monotonic elapsed time, and status; they omit prompts, model outputs, request identifiers, and error text. The callback may run concurrently, so keep it thread-safe and fast. SwiftDecision does not include an exporter or telemetry dependency; applications can forward measurements to their own systems.

## Benchmarks

The current model-backed inference backend included in this package is native Laya MLX. Hosted providers such as TypeSafe Jev are maintained as separate provider packages. The mock backend is for examples and contract tests, not a model benchmark.

| Backend | Example workload | Correctness evidence | P50 / P95 latency | Throughput |
| --- | --- | --- | --- | --- |
| Native Laya MLX | Outage impact (Noul), duplicate-charge routing (Choice), answer quality (Score) | Optional local Python parity test in FP16 and FP32 | Not measured | Not measured |
| `ClosureDecisionBackend` | Deterministic Noul, Choice, Score fixtures | Request/response contracts covered in CI | Not applicable | Not applicable |

## Requirements and validation

- Swift tools 6.3 or newer.
- Base package deployment targets: macOS 10.15, iOS 15, tvOS 13, and watchOS 6.
- Native MLX backend: Apple Silicon, macOS 14+ or iOS 17+, and the `MLX` trait.

Build and test without optional traits:

```sh
swift build --disable-default-traits
swift test --disable-default-traits
```

CI builds and tests on Swift 6.3.3 and Swift 6.4. The MLX CI lane compiles and tests the native backend on Apple Silicon without downloading model weights.

## Scope of 0.3.0

SwiftDecision 0.3.0 adds SpecificationCore-backed specification traces to typed Noul, Choice, and Score decisions. It supports iOS 13 and later; apps that need iOS 13 or 14 can stay on this release line. The following 0.4.0 release raises the minimum iOS deployment target to iOS 15. Foundation Models / Apple Intelligence adapters, built-in batch scheduling, and agent tool orchestration are not included in 0.3.0.

## License

SwiftDecision is available under the [Apache License 2.0](LICENSE). Model weights have their own terms and are not included in this repository.
