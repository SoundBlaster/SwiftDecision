# Roadmap: OpenAI Luna decision backend

**Status:** Implementation started; Decisions API is in public beta

**Updated:** 2026-10-07

**Scope:** Add an optional hosted backend for OpenAI's Decisions API, while keeping SwiftDecision's policy and result handling in control.

## Summary

Implement a separate `SwiftDecisionOpenAI` provider product for `DecisionBackend` that uses OpenAI's Decisions API. OpenAI published the endpoint and typed request/response schemas, then moved the API to public beta on October 6. Prefer that purpose-built endpoint over prompting Luna through the general Responses API. The adapter supports the package's existing `noul`, `choice`, and `score` request kinds and produces the probability vector expected by `DecisionPrediction`.

This is Jev-like behavior, not the Jev model or its learned/calibrated decision head. OpenAI's DevDay announcement confirms the Decisions API, its Luna basis, finite predefined answers, text and image context, and classification/routing/agent-next-action use cases. It describes an API capability using Luna, not a newly announced standalone model ID. The New Stack additionally reports confidence scores and a 150 ms response time versus 1.6 seconds for Luna, but OpenAI's announcement does not specify these metrics or the API's price. Treat them as press-reported until independently measured. The implementation in this repository is the native Decisions API adapter; a general-purpose Responses API compatibility path is not part of this change.

The adapter lives in a separate SwiftPM product, following the provider boundary demonstrated by SwiftJev: provider transport remains outside the core decision library. The OpenAI model identifier is configurable. The current implementation uses Foundation URLSession and has no SDK dependency.

## Current evidence and assumptions

- OpenAI announced GPT-6 Luna for the Responses and Chat Completions APIs on September 22, 2026. The current model catalog identifies `gpt-6-luna`, supports text and image input, Structured Outputs, and lists $0.10 per million input tokens and $0.50 per million output tokens at the standard tier. Pricing, limits, and availability can change; confirm them again before release.
- OpenAI's September 29 DevDay recap announced Decisions API as a Luna-based capability for finite predefined answers over text or images.
- OpenAI's API changelog dated October 6, 2026 lists `v1/decisions` as released in beta for `gpt-6-luna`. The API reference documents `POST /v1/decisions`, bearer authentication, text input or user messages with inline image data URLs, and `predicate`, `choice`, and `score` questions. Choice options are limited to 2–255 unique values. Refusal is a typed per-question answer.
- The New Stack's September 29 report says Decisions API returns developer-defined choices with confidence scores in 150 ms versus 1.6 seconds for GPT-6 Luna, and says price per call, candidate limit, and fine-tuning support were unknown. OpenAI's announcement does not confirm those claims; measure and verify them independently.
- The SwiftDecision adapter currently maps textual `DecisionPrompt.context`. Image support is deferred until the core has provider-neutral multimodal input.
- OpenAI's SDK directory does not list a first-party Swift SDK. The current adapter uses Foundation URLSession against the first-party REST contract, so it adds no third-party SDK or dependency to the core product.
- This package supports iOS 15 and macOS 10.15. The SDK and product split must preserve the core package's current platform and dependency behavior; hosted credentials must never be embedded in a client app.
- The existing Jev-like shape in SwiftDecision is `DecisionPrompt` (`noul`, `choice`, `score`) to `[Double]` probabilities in option order, followed by engine-owned validation and acceptance policy.

## Goals

- Offer an optional OpenAI-backed `DecisionBackend` with typed `Choice`, `Noul`, and `Score` behavior.
- Preserve the engine's validation, thresholds, abstention/fallback, errors, and content-free tracing semantics.
- Prefer the Decisions API. Use `gpt-6-luna` through Responses only as an explicitly experimental compatibility implementation if the dedicated endpoint becomes unavailable for a supported use case.
- Fail closed on refusals, incomplete responses, missing or malformed fields, unsupported schema, and invalid probability vectors.
- Measure quality, calibration, latency, and cost on a versioned task set before recommending production use.
- Keep API keys and request data under application/operator control and document hosted-data implications.

## Non-goals

- Reproduce Jev's weights, private training, or claimed calibration.
- Add tools, agent orchestration, image input, or automatic model fallback.
- Change SwiftDecision's core decision or policy API.
- Claim that Structured Outputs makes the model's probabilities calibrated or trustworthy.

## Proposed design

```text
DecisionEngine
  └─ DecisionBackend
       └─ SwiftDecisionOpenAI (optional provider product)
            └─ Foundation URLSession
                 └─ Decisions API (public beta)
```

Map SwiftDecision requests onto the published Decisions API contract. Preserve caller option order and let `DecisionEngine` validate the result and apply acceptance policy. A refusal or response that cannot be mapped unambiguously to the original options is an error, not an abstention. Do not assume that the general Responses API provides the same learned decision behavior or latency.

## Roadmap

### Phase 1 — Contract and provider boundary (complete for text)

- The endpoint, authentication, request/response schemas, question types, per-question refusal, and Choice limit are confirmed in OpenAI's first-party reference.
- The optional provider product uses Foundation URLSession and remains separate from SwiftDecision core. No community SDK is required for the REST contract.
- Text mappings for Noul, Choice, and Score are implemented. Image mapping is deferred until `DecisionPrompt` supports provider-neutral multimodal input.

**Exit criteria:** complete for the text contract when the adapter and consumer documentation land; image support remains a separate extension.

### Phase 2 — Minimal adapter (implementation complete; build verification pending)

- `OpenAIDecisionsBackend` implements `DecisionBackend` in the optional `SwiftDecisionOpenAI` product.
- Credentials are injected or read from `OPENAI_API_KEY`; no key is bundled or included in diagnostics.
- The official endpoint is fixed; the model and request timeout are configurable, and retries are disabled.
- Only complete, validated responses map to `DecisionPrediction`; refusal and malformed responses fail closed.
- The adapter does not emit prompts, contexts, options, outputs, or secrets to SwiftDecision trace events or metrics.

**Exit criteria:** core and adapter build independently, deterministic mock coverage exercises success and all failure mappings, and no credentials or request content appear in diagnostics. The current implementation still needs build verification and mock coverage before this phase is fully closed.

### Phase 3 — Evaluation and calibration

- Create a versioned, representative dataset for fixed-label classification, binary judgments, and ordered rubric scores, including ambiguous and adversarial inputs.
- Compare OpenAI Decisions API with SwiftJev, Luna via Responses (if implemented), and local Laya using identical examples and recorded API/model, prompt/schema, and SDK versions.
- Report per-kind accuracy, macro-F1 where applicable, Brier score / expected calibration error, abstention coverage, latency percentiles, token use, and estimated cost. Record sample size and confidence intervals.
- Tune acceptance thresholds on a held-out calibration split; do not tune and report on the same examples.
- Include prompt-injection and untrusted-context cases. Treat model output as a proposal; application policy remains authoritative.

**Exit criteria:** results are reproducible, limitations are documented, and a model-specific default policy is supported by held-out evidence. If calibration is inadequate, expose scores as uncalibrated or keep the backend experimental.

### Phase 4 — Release and maintenance

- Publish usage, data-handling, configuration, platform, error, and cost documentation with the provider package.
- Recheck the OpenAI model/API surface before release. Keep CI fully mocked; live checks remain opt-in and require an explicitly configured key.
- Track OpenAI model/API deprecations. Re-run the evaluation when the model, prompt, schema, or relevant API behavior changes.
- Version releases without rewriting existing tags; announce any default model or behavior change.

**Exit criteria:** clean consumer install, supported-platform builds, deterministic CI, documented evaluation report, and a release note that clearly distinguishes API compatibility from model-quality evidence.

## Acceptance checklist

- [ ] Core SwiftDecision remains free of OpenAI SDK and credential dependencies.
- [ ] The adapter preserves exact option ordering and supports `noul`, `choice`, and `score`.
- [ ] All failure paths are explicit and fail closed; there is no silent fallback or paid retry loop.
- [ ] No prompt, context, option text, model output, or key is emitted to traces/metrics/logs by default.
- [ ] Probability validity is checked by the existing engine; calibration claims have separate held-out evidence.
- [ ] REST API provenance is recorded, and the project does not imply a first-party Swift SDK is used.
- [ ] Decisions API pricing, model availability, beta terms, and rate limits are rechecked before release.

## Sources checked on 2026-10-07

- [OpenAI DevDay 2026 Recap](https://openai.com/index/devday-2026-recap/) — official announcement of Decisions API, Luna basis, finite predefined answers, text/image context, and intended use cases.
- [OpenAI API changelog](https://developers.openai.com/api/docs/changelog) — October 6 beta release entry for `v1/decisions` and `gpt-6-luna`.
- [Decisions API reference](https://developers.openai.com/api/reference/resources/decisions/methods/create) — endpoint, authentication, input, question and answer schemas, refusal, and Choice limit.
- [The New Stack: OpenAI answers TypeSafe's Jev with a Decision API built on Luna](https://thenewstack.io/openai-decision-api-luna/) — secondary reporting. Performance and cost claims are not treated as API guarantees.
- [GPT-6 Luna model catalog](https://developers.openai.com/api/docs/models/gpt-6-luna) — endpoints, supported features, limits, and pricing.
- [OpenAI SDKs and CLI](https://developers.openai.com/api/docs/libraries) — official SDK availability and community-maintained Swift libraries.
- [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs) — schema-constrained output and refusal handling.
- [Model guidance](https://developers.openai.com/api/docs/guides/latest-model) — model selection and Responses API capabilities.
- [SwiftJev](https://github.com/SoundBlaster/SwiftJev) — current SwiftDecision provider package and Jev-like typed-decision API shape for comparison; not an OpenAI SDK or model.

## Standards and references

- [JSON Schema](https://json-schema.org/specification) — response-shape vocabulary; the API supports a subset documented by OpenAI.
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data) — review before transmitting user context to a hosted provider.
