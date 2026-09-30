# Roadmap: OpenAI Luna decision backend

**Status:** Proposed roadmap; Decisions API announced, detailed API contract and SDK coverage not yet confirmed

**Date:** 2026-09-30

**Scope:** Add an optional hosted backend that provides Jev-like typed decisions through OpenAI's API and a Swift SDK, while keeping SwiftDecision's policy and result handling in control.

## Summary

Implement a separate provider adapter for `DecisionBackend` that uses OpenAI's newly announced Decisions API, which OpenAI says focuses Luna's intelligence on developer-defined questions with finite, predefined answers. Prefer that purpose-built decision endpoint over prompting Luna through the general Responses API. The adapter will support the package's existing `noul`, `choice`, and `score` request kinds and produce the probability vector expected by `DecisionPrediction`.

This is Jev-like behavior, not the Jev model or its learned/calibrated decision head. OpenAI's DevDay announcement confirms the Decisions API, its Luna basis, finite predefined answers, text and image context, and classification/routing/agent-next-action use cases. It describes an API capability using Luna, not a newly announced standalone model ID. The New Stack additionally reports confidence scores and a 150 ms response time versus 1.6 seconds for Luna, but OpenAI's announcement does not specify these metrics or the API's price. Treat them as press-reported until confirmed in first-party API documentation and measured independently. If a general-purpose Luna endpoint is used as a compatibility path, Structured Outputs can constrain response shape but cannot establish calibrated probabilities or decision quality.

The adapter should live in a separate SwiftPM product/package, following the existing boundary used by SwiftJev: provider transport remains outside the core decision library. The OpenAI model identifier and SDK must be configurable and replaceable.

## Current evidence and assumptions

- OpenAI announced GPT-6 Luna for the Responses and Chat Completions APIs on September 22, 2026. The current model catalog identifies `gpt-6-luna`, supports text and image input, Structured Outputs, and lists $0.10 per million input tokens and $0.50 per million output tokens at the standard tier. Pricing, limits, and availability can change; confirm them again before release.
- OpenAI's September 29 DevDay recap officially announces Decisions API. It focuses Luna's intelligence on developer-defined questions with finite predefined answers, accepts text or image context, and targets classification, routing, and choosing an agent's next action. OpenAI says limited preview is available and broad release is planned in the coming days.
- The OpenAI API changelog, checked September 30, includes September 29 API announcements for GPT-6.1 Sol and Agents API computer use, but does not yet document Decisions API. The API model catalog also documents GPT-6 Luna endpoints, not a separate Decisions API endpoint or contract. The product announcement is confirmed; request/response schema, authentication details, SDK surface, confidence semantics, option limits, pricing, and preview enrollment must still be verified through first-party technical documentation or an authorized preview.
- The New Stack's September 29 report says Decisions API returns developer-defined choices with confidence scores in 150 ms versus 1.6 seconds for GPT-6 Luna, and says price per call, candidate limit, and fine-tuning support were unknown. OpenAI's announcement does not confirm those claims; measure and verify them independently.
- The September 25 API changelog reports a fix to image encoding that affected GPT-6 Luna and GPT-6 Sol. The first adapter scope is text-only, so image support is excluded until a separate evaluation warrants it.
- OpenAI's SDK directory lists Swift libraries under community libraries and states that OpenAI does not verify their correctness or security; it does not list a first-party Swift SDK. SDK selection must check maintenance, Decisions API coverage (once documented), supported platforms, concurrency safety, licensing, and transitive dependencies. Keep the API calls behind a narrow internal client protocol so the selected SDK can be replaced.
- This package supports iOS 15 and macOS 10.15. The SDK and product split must preserve the core package's current platform and dependency behavior; hosted credentials must never be embedded in a client app.
- The existing Jev-like shape in SwiftDecision is `DecisionPrompt` (`noul`, `choice`, `score`) to `[Double]` probabilities in option order, followed by engine-owned validation and acceptance policy.

## Goals

- Offer an optional OpenAI-backed `DecisionBackend` with typed `Choice`, `Noul`, and `Score` behavior.
- Preserve the engine's validation, thresholds, abstention/fallback, errors, and content-free tracing semantics.
- Prefer the Decisions API and make provider endpoint/version configurable. Use `gpt-6-luna` through Responses as an explicitly experimental compatibility implementation only if the dedicated endpoint or its Swift SDK path is unavailable.
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
       └─ OpenAIDecisionsBackend (separate optional product)
            └─ OpenAI client protocol
                 ├─ Decisions API (preferred, preview; confirm SDK support)
                 └─ Responses API + GPT-6 Luna (experimental compatibility path)
```

Map SwiftDecision requests onto the dedicated Decisions API's native request/result contract once OpenAI publishes it. Preserve caller option order and let `DecisionEngine` validate the result and apply acceptance policy. A refusal or response that cannot be mapped unambiguously to the original options is an error, not an abstention. Do not reverse-engineer an endpoint from the press article or assume that the general Responses API provides the same learned decision behavior or latency.

Only the general Responses API compatibility path needs an output strategy spike:

1. **Structured relative scores:** request one bounded score per option, then normalize locally. This is easy to validate but the normalized values must not be presented as calibrated probabilities without evidence.
2. **Structured probability vector:** request a probability per option and validate the distribution. This matches the existing backend contract, but the model may provide poorly calibrated values.
3. **Token/log-probability scoring:** use only if the chosen API/model exposes stable, suitable scores for the exact constrained labels. Do not assume this capability from text generation support.

Compare these strategies on the same evaluation set before exposing that compatibility path. The core package must not infer calibration from normalization. The Decisions API's native confidence semantics must be documented separately and independently calibrated against labeled outcomes before treating confidence as a probability.

## Roadmap

### Phase 1 — Preview access, API contract, and SDK

- The product announcement is confirmed; obtain limited-preview access and verify OpenAI's first-party technical reference, authentication, request/response schema, supported question kinds, confidence meaning, option limits, errors, and pricing.
- Confirm whether an OpenAI-maintained SDK supports this endpoint. OpenAI's SDK directory currently lists Swift libraries as community-maintained; select a community SDK only after verifying Decisions API coverage, license, platform support, concurrency behavior, and maintenance. Keep the SDK behind a narrow internal client protocol.
- Use a fake client to prototype `noul`, `choice`, and `score` mappings; gate live preview calls behind explicit configuration and avoid paid calls in default CI.
- Confirm the separate provider package/product boundary so OpenAI dependencies and credentials remain outside SwiftDecision core.
- If the Decisions API is unavailable to this project or has no usable SDK contract, evaluate the general Responses API path as a separately named experimental fallback; compare its three score-generation strategies and document refusal, incomplete output, rate-limit, timeout, and cancellation behavior.

**Exit criteria:** preview access or a first-party technical contract available to the project, an SDK/client and license decision, exact request/response mapping, and a recorded explanation if the experimental Responses API fallback is selected.

### Phase 2 — Minimal adapter

- Implement `OpenAIDecisionsBackend` as a `DecisionBackend` in the optional provider package. Name the Luna Responses fallback separately so callers can see which behavior they selected.
- Configure API credentials through injected client/configuration; provide no bundled key and no credential logging.
- Make endpoint/version and request timeout configurable. Keep retries disabled by default; if later added, bound them and honor `Retry-After` for retryable rate/overload responses.
- Map only a complete valid response to `DecisionPrediction`; preserve transport, API, refusal, and decoding failures as typed errors.
- Keep prompts, contexts, options, outputs, and secrets out of SwiftDecision trace events and metrics.

**Exit criteria:** core and adapter build independently, deterministic mock coverage exercises success and all failure mappings, and no credentials or request content appear in diagnostics.

### Phase 3 — Evaluation and calibration

- Create a versioned, representative dataset for fixed-label classification, binary judgments, and ordered rubric scores, including ambiguous and adversarial inputs.
- Compare OpenAI Decisions API with SwiftJev, Luna via Responses (if implemented), and local Laya using identical examples and recorded API/model, prompt/schema, and SDK versions.
- Report per-kind accuracy, macro-F1 where applicable, Brier score / expected calibration error, abstention coverage, latency percentiles, token use, and estimated cost. Record sample size and confidence intervals.
- Tune acceptance thresholds on a held-out calibration split; do not tune and report on the same examples.
- Include prompt-injection and untrusted-context cases. Treat model output as a proposal; application policy remains authoritative.

**Exit criteria:** results are reproducible, limitations are documented, and a model-specific default policy is supported by held-out evidence. If calibration is inadequate, expose scores as uncalibrated or keep the backend experimental.

### Phase 4 — Release and maintenance

- Publish usage, data-handling, configuration, platform, error, and cost documentation with the provider package.
- Pin or bound the SDK version and add a compatibility check for the OpenAI model/API surface. Keep CI fully mocked; live tests remain opt-in and require an explicitly configured key.
- Track OpenAI model/API deprecations and SDK maintenance. Re-run the evaluation when the model snapshot, prompt, schema, SDK behavior, or relevant API behavior changes.
- Version releases without rewriting existing tags; announce any default model or behavior change.

**Exit criteria:** clean consumer install, supported-platform builds, deterministic CI, documented evaluation report, and a release note that clearly distinguishes API compatibility from model-quality evidence.

## Acceptance checklist

- [ ] Core SwiftDecision remains free of OpenAI SDK and credential dependencies.
- [ ] The adapter preserves exact option ordering and supports `noul`, `choice`, and `score`.
- [ ] All failure paths are explicit and fail closed; there is no silent fallback or paid retry loop.
- [ ] No prompt, context, option text, model output, or key is emitted to traces/metrics/logs by default.
- [ ] Probability validity is checked by the existing engine; calibration claims have separate held-out evidence.
- [ ] SDK license and provenance are recorded, and the project does not imply first-party OpenAI support for a community SDK.
- [ ] Decisions API pricing, model availability, API/SDK support, preview terms, and rate limits are rechecked before release.

## Sources checked on 2026-09-30

- [OpenAI DevDay 2026 Recap](https://openai.com/index/devday-2026-recap/) — official announcement of Decisions API, Luna basis, finite predefined answers, text/image context, intended use cases, limited preview, and planned broad release.
- [OpenAI API changelog](https://developers.openai.com/api/docs/changelog) — GPT-6 Luna launch (September 22), image-encoding fix (September 25), and September 29 API updates; no Decisions API technical entry as of September 30.
- [The New Stack: OpenAI answers TypeSafe's Jev with a Decision API built on Luna](https://thenewstack.io/openai-decision-api-luna/) — secondary reporting of confidence scores, 150 ms responses, planned broad rollout, and unknown pricing/candidate limits/tuning. Claims beyond OpenAI's recap remain unverified.
- [GPT-6 Luna model catalog](https://developers.openai.com/api/docs/models/gpt-6-luna) — endpoints, supported features, limits, and pricing.
- [OpenAI SDKs and CLI](https://developers.openai.com/api/docs/libraries) — official SDK availability and community-maintained Swift libraries.
- [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs) — schema-constrained output and refusal handling.
- [Model guidance](https://developers.openai.com/api/docs/guides/latest-model) — model selection and Responses API capabilities.
- [SwiftJev](https://github.com/SoundBlaster/SwiftJev) — current SwiftDecision provider package and Jev-like typed-decision API shape for comparison; not an OpenAI SDK or model.

## Standards and references

- [JSON Schema](https://json-schema.org/specification) — response-shape vocabulary; the API supports a subset documented by OpenAI.
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data) — review before transmitting user context to a hosted provider.
