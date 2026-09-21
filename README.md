# SwiftDecision

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

Set `SWIFTDECISION_LAYA_CHECKPOINT` to a local checkpoint directory and `SWIFTDECISION_LAYA_REFERENCE_JSON` to a JSON file containing Python Laya-MLX reference outputs for the fixed parity prompts. The file has `noul`, `choice`, and `score` keys; each value contains `selectedOptionID` and `probabilities`. Then run:

```sh
SWIFTDECISION_LAYA_CHECKPOINT=/path/to/laya-mlx \
SWIFTDECISION_LAYA_REFERENCE_JSON=/path/to/reference.json \
SWIFTDECISION_LAYA_PRECISION=float32 \
swift test --traits MLX --triple arm64-apple-macosx14.0 --filter LayaParityTests
```

The parity suite uses fixed Noul, Choice, and Score requests, requires exact selected option identifiers, and compares probabilities to reference values within `0.0001` for FP32 or `0.02` for FP16. Generate the reference JSON using the Python Laya-MLX runtime with the same checkpoint; Python is used only as the parity oracle, never by the Swift backend. CI skips this test unless both local paths are provided.

## Build and test

```sh
swift build --disable-default-traits
swift test --disable-default-traits
swift build --traits MLX --triple arm64-apple-macosx14.0
swift test --traits MLX --triple arm64-apple-macosx14.0
```

CI checks Swift 6.4 on GitHub's Xcode 27 preview runner and Swift 6.3 as the minimum manifest/compiler version. The MLX lane also uses Apple Silicon and never downloads a checkpoint.
