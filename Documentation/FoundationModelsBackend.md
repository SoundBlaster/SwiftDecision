# On-device decisions with Foundation Models

The non-default `FoundationModels` SwiftPM trait enables `FoundationModelsDecisionBackend`
inside `SwiftDecision`. It uses Apple's on-device `SystemLanguageModel` and guided generation
for Noul, Choice, and Score. It needs no API key, provider account, separate checkpoint, or MLX
dependency at runtime. The adapter does not call a proxy or Private Cloud Compute.

## Enable the adapter

This adapter is unreleased; SwiftDecision 0.8.0 does not include it. For evaluation, use a local
checkout containing this change, or pin its commit with the same trait selection:

```swift
.package(path: "../SwiftDecision", traits: ["FoundationModels"])
```

The consuming target depends on the `SwiftDecision` product and imports `SwiftDecision`.
There is no additional adapter product. The trait adds no new package dependency. It is
independent of the existing `MLX` trait, and either or both can be enabled. SwiftPM may still
fetch the package's existing optional dependencies during resolution.

Build the adapter with Xcode 27 or newer. Its runtime API requires iOS 26, macOS 26, or visionOS 26.
Core package deployment targets remain unchanged. The adapter is excluded on Linux, tvOS,
watchOS, and SDKs without Foundation Models, including when the trait is requested there.
Inference also requires an eligible device, Apple Intelligence enabled, and its model ready.
OS availability alone is insufficient.

## Make a typed decision

```swift
import FoundationModels
import SwiftDecision

@available(iOS 26, macOS 26, visionOS 26, *)
func routeMessage(_ message: String) async throws -> DecisionResult<String> {
    let engine = DecisionEngine(
        backend: FoundationModelsDecisionBackend(),
        configuration: .init(timeout: 8)
    )
    return try await engine.choice(
        instructions: "Choose the team responsible for the message.",
        context: message,
        options: [
            ChoiceOption(label: "billing", description: "Invoices, refunds, and charges"),
            ChoiceOption(label: "support", description: "Technical support and account access")
        ]
    )
}
```

The same engine supports `noul(statement:context:)` and `score(instructions:context:levels:)`.
It retains typed labels, numeric score expectations, SpecificationCore validation and policy,
tracing, metrics, cancellation, and `DecisionBudget` deadlines.

Inspect `SystemLanguageModel.default.availability` for UI presentation. The default client also
checks availability on each inference and throws `FoundationModelsDecisionError.modelUnavailable(reason)`.
The reason distinguishes unsupported hardware, Apple Intelligence disabled, and model not ready.
Availability can change after that check; Foundation Models generation errors must also be handled.

## What the probabilities mean

Guided generation produces a structured value. The adapter asks the model to **estimate** one
probability per option. These self-reported estimates are not token probabilities or calibrated
confidence. Evaluate accuracy, latency, abstention, and threshold behavior on representative
application data before choosing production policies. A valid schema does not establish a
correct decision.

Each request creates a `DynamicGenerationSchema`: its `probabilities` array has exactly the
option count, and each entry is bounded to `0...1`. A dynamic schema accommodates the runtime
option count without a fixed `@Generable` type. After generation, the adapter checks count,
finite values, bounds, and sum within `0.01` of 1. It rejects invalid distributions without
silently normalizing them or substituting a one-hot vector.

Noul uses `[false, true]`; Choice preserves option order; Score uses rubric IDs `0`, `1`, and so on.
The adapter renders kind, instructions, context, and ordered options as JSON to preserve quotes,
Unicode, and newlines. Request IDs are not sent to the model. Fixed session instructions describe
context as data; this is not a guarantee against prompt injection. Keep security-critical and
deterministic application invariants outside model inference.

The model identifier `apple.foundation-models.on-device` identifies the adapter, not an Apple
checkpoint version: the iOS 26 API does not expose one. OS/model updates can change behavior.

## Sessions, errors, and fallback

The default client creates a fresh `LanguageModelSession` for each call, without tools.
There is no shared conversation, overlapping generation on one session, automatic retry, or
cloud fallback. Configure the engine's timeout or pass a shared `DecisionBudget` to bound waiting.
Cancellation is checked before and after generation. An engine timeout requests cancellation;
it does not guarantee immediate termination of underlying OS model work.

Availability and generation failures remain errors. Engine `fallback:` handles a prediction
that fails acceptance policy; it does not catch model errors. Applications own whether to switch
to a hosted backend or deterministic response. Local input is never automatically sent remotely.

The initializer accepts `model:` and `generationOptions:` for explicit on-device configuration.
Greedy sampling is the default; it does not guarantee identical results across OS/model versions.
Native Foundation Models errors propagate. Do not log prompts, generated content, or unrestricted
native error details. Adapter-owned invalid-prediction errors omit generated content.

## Offline contracts and an opt-in smoke test

`FoundationModelsDecisionClient` is an injectable, Sendable boundary. Requests expose fixed
instructions, rendered input, and schema; responses are `GeneratedContent`. Implementations must
provide independent request sessions and cooperate with cancellation. Inject a fixture using
`FoundationModelsDecisionBackend(client:)`. CI uses fixtures, without enabling Apple Intelligence.

```sh
swift test --traits FoundationModels
swift build --target SwiftDecision --triple arm64-apple-ios26.0-simulator --traits FoundationModels
```

To explicitly run three real on-device requests through the public backend and engine on an
eligible Mac with Apple Intelligence enabled and its model ready:

```sh
SWIFTDECISION_FOUNDATION_MODELS_SMOKE=1 \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveOnDeviceSmokeWhenExplicitlyEnabled
```

This validates the distribution contract for Noul, Choice, and Score, not model accuracy. It fails
if inference is explicitly enabled but the model is unavailable.

For broader format coverage, the test resource contains 48 requests adapted from existing
Jev4Mellea, SwiftJev, Oracle, CityChain, and adapter examples. It includes different topics,
English/Russian, Unicode, escaped JSON, multiline and longer contexts, and a quoted request to
ignore the schema. Choice and Score each cover 2, 3, 5, 10, and 20 options. There are no expected
winning labels or answer-quality assertions. All cases also run with an offline fixture client.

```sh
SWIFTDECISION_FOUNDATION_MODELS_CONTRACT=1 \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveDiverseOutputContractsWhenExplicitlyEnabled
```

This separate opt-in test sends every case through the public typed engine APIs and the local
Foundation Models backend. It checks the output contract, with a 15-second per-call timeout and
a shared 180-second inference budget. A failure to generate output is reported separately from
an invalid probability distribution, without logging input or output content. See the
[corpus sources and adaptations](../Tests/SwiftDecisionTests/Fixtures/README.md).

The [2026-10-24 local run](Reports/FoundationModelsOutputContracts-2026-10-24.md) returned valid
distributions for 44 of 48 cases. All arrays had the requested cardinality and bounded finite
numbers; four larger-option cases failed the sum constraint. The opt-in live suite exposes
these failures, while offline CI remains independent of model inference.

Apple references: [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation),
[dynamic schemas](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema),
and [model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability).
