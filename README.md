# SwiftDecision

[![CI](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/SoundBlaster/SwiftDecision/actions/workflows/ci.yml)
[![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange?logo=swift)](https://www.swift.org)
![Apple platforms](https://img.shields.io/badge/Apple%20platforms-macOS%2010.15%2B%20%7C%20iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20watchOS%206%2B-lightgrey?logo=apple)
![Optional MLX trait](https://img.shields.io/badge/MLX-optional%20trait-6e56cf?logo=apple)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

SwiftDecision provides typed asynchronous Noul, Choice, and Score decisions over interchangeable model backends. It uses [SpecificationCore](https://github.com/SoundBlaster/SpecificationCore) internally for async request/output validation, ordered policy routing, and backend decision composition.

The base package has no model downloads and keeps the package deployment floors at macOS 10.15, iOS 13, tvOS 13, and watchOS 6. The optional native MLX backend requires macOS 14 or iOS 17 and an Apple Silicon device. TypeSafe Jev and Apple Foundation Models adapters remain planned integrations.

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

`DecisionEngine.Configuration` owns the per-kind probability/confidence policies and optional inference timeout. Caller cancellation is checked around the Core decision adapter; timeout cancels the backend task. The trace contains ordered stage names and model identifiers but never prompt text.

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

Laya is currently the only model-backed inference backend. The local parity suite measures output compatibility, not performance; SwiftDecision does not yet publish latency or throughput numbers. The mock backend is included for examples and CI contract tests, not as a model benchmark.

| Backend | Example workloads | Correctness evidence | P50 / P95 latency | Throughput |
| --- | --- | --- | --- | --- |
| Native Laya MLX | Outage impact (Noul), duplicate-charge routing (Choice), answer quality (Score) | Local Python parity passes in FP16 and FP32 | Not measured | Not measured |
| `ClosureDecisionBackend` | Deterministic Noul, Choice, and Score fixtures | Request/response contract covered in CI | Not applicable | Not applicable |
| TypeSafe Jev | Noul, Choice, and Score | Planned integration | — | — |
| Apple Foundation Models | Noul, Choice, and Score | Planned integration | — | — |

## Build and test

```sh
swift build --disable-default-traits
swift test --disable-default-traits
swift build --traits MLX --triple arm64-apple-macosx14.0
swift test --traits MLX --triple arm64-apple-macosx14.0
```

CI checks Swift 6.4 on GitHub's Xcode 27 preview runner and Swift 6.3.3 as the minimum stable compiler for the Swift tools 6.3 manifest. The MLX lane also uses Apple Silicon and never downloads a checkpoint.
