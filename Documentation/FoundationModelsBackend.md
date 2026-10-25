# On-device decisions with Foundation Models

**Deferred experiment — 2026-10-25.** PR #22 is closed without merging. The
`codex/foundation-models-backend` branch retains the unreleased adapter, fixtures
and evidence. The related Oracle pilot is also closed; its [archive index](https://github.com/SoundBlaster/SwiftDecision-Examples/blob/codex/oracle-foundation-models-pilot/DOCS/EXPERIMENTS/APPLE_INTELLIGENCE_ARCHIVE.md)
links the full results and criteria for revisiting after a model update.

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

## Evaluate options with an order consistency check

The new opt-in strategy addresses the repeated first-option / 67:33 template seen
with a numeric array in Oracle:

```swift
let backend = FoundationModelsDecisionBackend(
    normalization: .sumToOne,
    strategy: .optionAssessment
)
let engine = DecisionEngine(backend: backend, configuration: .init(timeout: 10))
```

It gives each option a named numeric field whose schema description includes that
option's meaning, with a short, conversational task/context prompt. It generates
two assessments in fresh sessions: the supplied order and a cyclic shift that moves every option.
Both complete outputs are validated and normalized using the explicit setting.
The second vector is mapped back to the original option order.

Noul has a dedicated truth schema: `verdict` (`supported`, `contradicted`, or
`unknown`) plus the native model's `probabilityTrue`. The second pass cyclically shifts
the categorical guide order so no verdict keeps its previous position. Missing/conflicting evidence and a verdict that
contradicts the numeric estimate yield no preference; bounded scalar estimates
are represented as `[1 - probabilityTrue, probabilityTrue]`. This complement is
intrinsically normalized and needs no sum correction.

Score additionally requests `hasEvidence`. An explicit false status maps valid,
bounded option assessments to an uninformative distribution, including when the
model supports no level at all. This is a semantic no-evidence outcome in the new
strategy; a zero-sum vector without that explicit status still throws. Missing
fields or malformed numbers always throw.

If both passes have the same unique maximum, their aligned distributions are
averaged. A disagreement or tied maximum yields a uniform distribution to signal
**no stable preference**. The default engine policy abstains on that distribution;
a caller that deliberately accepts uniform distributions can still obtain a
value. Malformed, missing, nonfinite, out-of-range, zero-sum or strict-mode
unnormalized output remains an error; consistency checking never repairs it.

This costs two sequential model generations per backend prediction. Automatic
application routing followed by an answer can require four generations, so keep
one shared `DecisionBudget` across the operation. Cancellation is checked between
passes. No second pass starts after cancellation is observed. There is no retry
or remote fallback; underlying OS work remains cooperatively cancellable.

The default `.directDistribution` strategy preserves the original one-array
contract and existing injected clients. `.optionAssessment` clients must instead
return `option_0`, `option_1`, etc., in each Choice/Score request's current order,
plus `hasEvidence` for Score, or the Noul fields described above. Do not assume
that the second request preserves the first request's order. Its prompt is text,
not the direct strategy's JSON payload. Option descriptions appear in the schema;
untrusted context and alternatives still need application-level handling.

Consistency is not factual verification. Two passes can agree on a wrong answer,
and these remain model estimates, not calibrated confidence. This strategy must
be evaluated on each consuming workload. The experiment report records the tested
scope and observed failures.

## What the probabilities mean

Guided generation produces a structured value. The adapter asks the model to **estimate** one
probability per option. These self-reported estimates are not token probabilities or calibrated
confidence. Evaluate accuracy, latency, abstention, and threshold behavior on representative
application data before choosing production policies. A valid schema does not establish a
correct decision.

### Original array contract (`directDistribution`)

In this compatibility strategy each request creates a `DynamicGenerationSchema` with exactly one numeric entry per option,
bounded to `0...1`. A dynamic schema accommodates the runtime option count without a fixed
`@Generable` type. The initializer's `normalization:` option selects the generation contract:

| Option | Generated field | Transformation |
| --- | --- | --- |
| `.none` (default) | `probabilities` | Requires sum within `0.01` of 1 and returns values unchanged. |
| `.sumToOne` | `weights` | Requires a positive sum, then returns `weight / sum(weights)` per option. |

```swift
// Strict behavior is the default and can also be selected explicitly.
let strict = FoundationModelsDecisionBackend(normalization: .none)
let normalized = FoundationModelsDecisionBackend(normalization: .sumToOne)
```

Both modes reject missing/malformed arrays, wrong cardinality, nonfinite numbers, negative
values, and values greater than 1. The normalized mode also rejects an all-zero vector; it never
substitutes a uniform distribution or fabricated confidence. Normalization preserves option order,
relative proportions, and zero weights, subject to floating-point precision. It does not accept
malformed data or convert a thrown generation error into a prediction. Public `DecisionPrediction`
continues to carry `probabilities` in both modes.

Normalized-mode instructions ask the model to give its best-fitting option weight 1 and express
the others relative to it. The adapter accepts any bounded weights with a positive sum; an all-zero
model result still fails validation.

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
`FoundationModelsDecisionBackend(client:normalization:)`. Clients must return `probabilities`
in `.none` mode or `weights` in `.sumToOne` mode; the request's schema and instructions specify
the selected contract. Existing `client:` calls retain strict mode. CI uses fixtures, without
enabling Apple Intelligence, and exercises the corpus in both modes.

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

To run the same 48 cases with explicit normalization:

```sh
SWIFTDECISION_FOUNDATION_MODELS_CONTRACT=1 \
SWIFTDECISION_FOUNDATION_MODELS_NORMALIZATION=sumToOne \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveDiverseOutputContractsWhenExplicitlyEnabled
```

Omitting the normalization environment variable selects `none`; an unknown value fails the test
configuration rather than silently selecting another mode.

This separate opt-in test sends every case through the public typed engine APIs and the local
Foundation Models backend. It checks the output contract, with a 15-second per-call timeout and
a shared 180-second inference budget. A failure to generate output is reported separately from
an invalid probability distribution, without logging input or output content. See the
[corpus sources and adaptations](../Tests/SwiftDecisionTests/Fixtures/README.md).

The [2026-10-24 strict-mode local run](Reports/FoundationModelsOutputContracts-2026-10-24.md) returned valid
distributions for 44 of 48 cases. All arrays had the requested cardinality and bounded finite
numbers; four larger-option cases failed the sum constraint. The opt-in live suite exposes
these failures. The follow-up with explicit `.sumToOne` and relative-weight instructions passed
all 48 cases. Offline CI remains independent of model inference and covers both modes.

Apple references: [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation),
[dynamic schemas](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema),
and [model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability).
