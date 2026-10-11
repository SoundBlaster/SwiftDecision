# OpenAI Decisions backend

`SwiftDecisionOpenAI` adapts the OpenAI Decisions API to SwiftDecision's `DecisionBackend` protocol. It uses Foundation `URLSession` and the documented REST interface directly; the core product has no OpenAI dependency.

The API entered public beta on October 6, 2026. Check OpenAI's [API changelog](https://developers.openai.com/api/docs/changelog) and [Decisions reference](https://developers.openai.com/api/reference/resources/decisions/methods/create) for current availability, model support, limits, and request behavior.

## Setup

Add both products to the consuming target:

```swift
.product(name: "SwiftDecision", package: "SwiftDecision"),
.product(name: "SwiftDecisionOpenAI", package: "SwiftDecision")
```

Set `OPENAI_API_KEY` in a server-side environment, or inject a user-provided key from the platform's secure credential store. Do not embed a shared provider key in a client application.

```swift
import SwiftDecision
import SwiftDecisionOpenAI

let backend = try OpenAIDecisionsBackend()
let engine = DecisionEngine(
    backend: backend,
    configuration: .init(timeout: 8)
)

let result = try await engine.choice(
    instructions: "Choose the team that should handle this message.",
    context: "My invoice contains a duplicate charge from yesterday.",
    options: [
        ChoiceOption(label: "support", description: "Account access and product help."),
        ChoiceOption(label: "billing", description: "Invoices, refunds, and charges."),
        ChoiceOption(label: "sales", description: "Plans and purchases.")
    ]
)
```

The model defaults to `gpt-6-luna`. Override it with the `model` initializer argument when using another Decisions-compatible model. `APIEndpoint` is a provider-neutral value from SwiftDecision; the OpenAI adapter owns the default root (`https://api.openai.com/v1`) and appends `/decisions` to an API root:

```swift
import SwiftDecision

let backend = try OpenAIDecisionsBackend(
    apiKey: proxyKey,
    endpoint: .baseURL(URL(string: "https://gateway.example.com/v1")!)
)
```

For a gateway that exposes a complete operation URL, pass `.operationURL(URL(...))`; the adapter uses that URL as-is, including its trailing slash. Both custom endpoint modes require an explicit `apiKey`, so `OPENAI_API_KEY` is never sent to a custom destination by fallback. Endpoints must be absolute HTTP(S) URLs with a host and without embedded credentials, query, or fragment. HTTP is accepted only when explicitly configured as a custom endpoint; the provider default remains HTTPS. Redirects are rejected so bearer credentials are never forwarded to another host. Retries are disabled.

The compatibility `baseURL:` initializer remains available for existing callers and delegates to `.baseURL`. The core `SwiftDecision` package defines only the endpoint selection; provider URL rules and operation paths stay in this adapter.

## Mapping and validation

| SwiftDecision kind | OpenAI question | Mapping |
| --- | --- | --- |
| `noul` | `predicate` | The predicate probability becomes `[1 - p, p]` in the fixed `[false, true]` order. |
| `choice` | `choice` | Options use their IDs as string values; returned probabilities are reordered to the caller's option order. |
| `score` | `score` | Options become ordered labeled levels; returned probabilities are reordered by label. |

The adapter validates the answer type, question name, option/level labels, finite values, probability bounds, distribution sum, and selected-choice consistency. Refusals, HTTP failures, decoding errors, and unsupported prompts remain explicit errors. Error descriptions do not include request bodies, response bodies, or API keys.

OpenAI's native Choice and Score confidence fields are checked for valid numeric bounds but are not returned as calibrated confidence. `DecisionEngine` continues to select and apply its own acceptance policy from the returned probability distribution. This shape validation does not establish accuracy or calibration.

The current `DecisionPrompt.context` is text-only. The remote API also accepts images, but this provider does not yet expose that input until SwiftDecision has a provider-neutral multimodal prompt representation.

## Failure classification

`OpenAIDecisionFailureClassifier.classify(_:)` maps cancellation, timeout, connectivity, rate-limit, and server errors to `DecisionFailureCategory`. Classification does not retry, fall back, or change the thrown error; recovery remains caller-owned.

## Data handling

The complete prompt context and option descriptions are sent to OpenAI. No prompt or response contents are included in SwiftDecision traces or provider error messages. Review OpenAI's [API data controls](https://developers.openai.com/api/docs/guides/your-data) and applicable account settings before transmitting user data.
