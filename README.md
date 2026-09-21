# SwiftDecision

[![CI](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml)
[![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange?logo=swift)](https://www.swift.org)
![Apple platforms](https://img.shields.io/badge/Apple%20platforms-macOS%2010.15%2B%20%7C%20iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20watchOS%206%2B-lightgrey?logo=apple)
![Optional MLX trait](https://img.shields.io/badge/MLX-optional%20trait-6e56cf?logo=apple)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

SwiftDecision provides typed asynchronous Noul, Choice, and Score decisions over interchangeable model backends. It uses [SpecificationCore](https://github.com/SoundBlaster/SpecificationCore) internally for async request/output validation, ordered policy routing, and backend decision composition.

The base package has no model downloads and keeps the package deployment floors at macOS 10.15, iOS 13, tvOS 13, and watchOS 6. The optional native MLX backend requires macOS 14 or iOS 17 and an Apple Silicon device. TypeSafe Jev is available through its hosted API; an Apple Foundation Models adapter remains planned.

## Requirements

- Swift tools 6.3 or newer. `mlx-swift` currently requires Swift tools 6.3.
- Swift 6.4 is used in the current macOS CI toolchain; Swift 6.3 is the minimum CI lane.

## Offline example

The package includes a deterministic Inbox Triage example that makes no network or model calls:

```sh
swift run InboxTriageExample
```

Application-owned or test backends can use `ClosureDecisionBackend`:

```swift
let backend = ClosureDecisionBackend { prompt in
    // Probabilities must correspond to prompt.options, in their original order.
    DecisionPrediction(probabilities: [0.08, 0.92], modelIdentifier: "fixture")
}
let engine = DecisionEngine(backend: backend)

let result = try await engine.noul(
    statement: "Does the message require immediate action?",
    context: "Production is unavailable for all customers."
)

switch result.outcome {
case let .accepted(value): print("Decision: \(value), confidence: \(result.confidence)")
case let .abstained(reason): print("Ask a person: \(reason)")
case let .fallback(value, reason): print("Fallback: \(value), reason: \(reason)")
}
```

Choice labels stay typed in application code, and Score returns both the most likely rubric level and probability-weighted expected value. Low-confidence results abstain unless the caller supplies an explicit fallback. Backend errors are thrown and are not converted to abstentions.

`DecisionEngine.Configuration` owns the per-kind probability/confidence policies, optional inference timeout, and trace collection mode. Tracing is enabled by default for compatibility; disable event creation when a consumer does not need per-call traces:

```swift
let engine = DecisionEngine(
    backend: backend,
    configuration: .init(traceMode: .disabled)
)
```

An optional `DecisionMetricsHandler` receives one `DecisionMetric` per completed or failed decision call. Each metric contains only the decision kind, monotonic elapsed seconds, and status (`accepted`, `abstained`, `fallback`, or `failed`); it omits request identifiers, prompts, model outputs, and error text. The callback can be invoked concurrently, so it should be thread-safe and return promptly. SwiftDecision has no built-in exporter or telemetry dependency; applications can forward metrics to their own systems.

Caller cancellation is checked around the Core decision adapter; timeout cancels the backend task. The default trace contains ordered stage names and model identifiers but never prompt text.

## TypeSafe Jev backend

`JevDecisionBackend` sends one typed Noul, Choice, or Score question to the [TypeSafe System One API](https://docs.typesafe.ai/). The decision context and instructions are sent to TypeSafe for inference. It reads `TYPESAFE_API_KEY` from the environment by default; an explicit `apiKey` initializer argument is also supported. The backend does not log credentials, follow redirects, retry requests, or include response bodies in errors. It uses the official HTTPS endpoint and requires network access. Choice supports up to 255 options; Score supports 2–10 ordered levels.

```swift
let backend = try JevDecisionBackend() // Reads TYPESAFE_API_KEY.
let engine = DecisionEngine(backend: backend)

let result = try await engine.choice(
    instructions: "Choose the team that should handle this message.",
    context: "My invoice contains a duplicate charge from yesterday.",
    options: [
        ChoiceOption(label: "support", description: "Account access or product use."),
        ChoiceOption(label: "billing", description: "Invoices, refunds, or charges."),
        ChoiceOption(label: "sales", description: "Plan selection or purchasing.")
    ]
)
```

The HTTP transport is injectable through `JevHTTPTransport`; the CI tests use fixture responses and make no network calls. To run the opt-in live smoke test for Noul, Choice, and Score, set `TYPESAFE_API_KEY` and explicitly enable it:

```sh
SWIFTDECISION_LIVE_JEV=1 swift test --disable-default-traits --filter JevDecisionBackendTests
```

This test sends three synthetic requests to TypeSafe and may incur API usage. It is skipped by default, including in CI.

## Native Laya backend (optional)

Enable the non-default `MLX` SwiftPM Trait in the consuming package declaration:

```swift
.package(
    url: "https://github.com/SoundBlaster/SwiftDecision.git",
    branch: "main",
    traits: ["MLX"]
)
```

Or build this checkout directly:

```sh
swift build --traits MLX --triple arm64-apple-macosx14.0
swift test --traits MLX --triple arm64-apple-macosx14.0
```

`LayaMLXBackend` loads a local English `aac6fef/laya-mlx` checkpoint and runs its ModernBERT encoder and typed-decision heads natively with MLX. It does not invoke Python. Download model files separately and provide their directory URL; CI compiles the backend without downloading model weights. MLX APIs are available only on macOS 14+ and iOS 17+, so the consuming app's deployment target must meet that floor when the trait is enabled. The CI command sets an explicit macOS 14 target triple for that lane while default builds retain the base package floors.

For the request-to-probability flow, see the [Laya MLX Backend Inference Pipeline](Documentation/LayaMLXInferencePipeline.md).

The model parameters are provided by Convai Innovations under the model card's terms. This repository does not redistribute weights. Laya prompt and output conventions are Apache-2.0-derived; see [NOTICE](NOTICE) and [LICENSE](LICENSE).

Set `SWIFTDECISION_LAYA_CHECKPOINT` to a local checkpoint directory to run the native backend against fixed Noul, Choice, and Score prompts. This smoke test checks model identity and the shape and normalization of each probability response; it does not require Python or a network connection:

```sh
SWIFTDECISION_LAYA_CHECKPOINT=/path/to/laya-mlx \
swift test --traits MLX --triple arm64-apple-macosx14.0 --filter LayaParityTests
```

For numerical parity, also set `SWIFTDECISION_LAYA_REFERENCE_JSON` to a JSON file containing Python Laya-MLX reference outputs for those prompts. The file has `noul`, `choice`, and `score` keys; each value contains `selectedOptionID` and `probabilities`. Then run:

```sh
python3 -m pip install laya-mlx
python3 Scripts/generate_laya_reference.py \
  --checkpoint /path/to/laya-mlx \
  --output /path/to/laya-reference.json \
  --dtype float16

SWIFTDECISION_LAYA_CHECKPOINT=/path/to/laya-mlx \
SWIFTDECISION_LAYA_REFERENCE_JSON=/path/to/reference.json \
SWIFTDECISION_LAYA_PRECISION=float16 \
swift test --traits MLX --triple arm64-apple-macosx14.0 --filter LayaParityTests
```

With a reference file, the suite requires exact selected option identifiers and compares probabilities within `0.0001` for FP32 or `0.02` for FP16. Generate the reference JSON using the Python Laya-MLX runtime with the same checkpoint; Python is used only as the parity oracle, never by the Swift backend. CI does not download weights and skips this local-checkpoint suite unless `SWIFTDECISION_LAYA_CHECKPOINT` is set. The regular CI suite uses deterministic request/response fixtures to cover typed decisions without model files.

## Benchmarks

Native Laya MLX and hosted TypeSafe Jev are the current model-backed inference backends. The local Laya parity suite measures output compatibility, not performance. TypeSafe Jev has an initial live latency sample below. The mock backend is included for examples and CI contract tests, not as a model benchmark.

| Backend | Example workloads | Correctness evidence | P50 / P95 latency | Throughput |
| --- | --- | --- | --- | --- |
| Native Laya MLX | Outage impact (Noul), duplicate-charge routing (Choice), answer quality (Score) | Local Python parity passes in FP16 and FP32 | Not measured | Not measured |
| TypeSafe Jev | Noul, Choice, and Score | Mock HTTP contract tests; opt-in live smoke test | Noul 264.7 / 307.4 ms; Choice 279.4 / 326.5 ms; Score 254.6 / 353.1 ms | Noul 3.677; Choice 3.527; Score 3.588 decisions/s |
| `ClosureDecisionBackend` | Deterministic Noul, Choice, and Score fixtures | Request/response contract covered in CI | Not applicable | Not applicable |
| Apple Foundation Models | Noul, Choice, and Score | Planned integration | — | — |

The Jev figures are one sequential live run from 2026-09-21 with 20 measured requests per decision kind and one warm-up request per kind (63 requests total), using model identifier `jev-1.13.0` on macOS 27.0 (build 26A428), arm64, and Swift 6.4. Latency covers the full `DecisionEngine` call, including network and provider inference; throughput is measured calls divided by summed latency. P50 is the median (the average of the two middle samples for this even-sized run); P95 uses nearest rank. These are a dated sample of a hosted service, not a hardware-independent performance guarantee. The runner prints raw samples and system details for repeatable comparisons.

Run the opt-in live benchmark with `TYPESAFE_API_KEY` set. It requires the explicit environment opt-in below and sends billable live requests; the default CI does not run it. The sample count must be between 10 and 100 per decision kind.

```sh
SWIFTDECISION_RUN_JEV_BENCHMARKS=1 swift run --disable-default-traits JevBenchmark --samples 20
```

## Build and test

```sh
swift build --disable-default-traits
swift test --disable-default-traits
swift build --traits MLX --triple arm64-apple-macosx14.0
swift test --traits MLX --triple arm64-apple-macosx14.0
```

CI checks Swift 6.4 on GitHub's Xcode 27 preview runner and Swift 6.3.3 as the minimum stable compiler for the Swift tools 6.3 manifest. The MLX lane also uses Apple Silicon and never downloads a checkpoint.
