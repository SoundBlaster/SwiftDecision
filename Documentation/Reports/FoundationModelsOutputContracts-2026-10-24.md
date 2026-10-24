# Foundation Models output-contract run — 2026-10-24

48 synthetic requests adapted from existing examples were sent through the public
`DecisionEngine` Noul, Choice, and Score APIs with `FoundationModelsDecisionBackend`.
Only the output contract was checked. No expected answers, winning labels, accuracy,
calibration, or provider comparisons were evaluated.

## Setup

- macOS 27.0 (26A428), Apple Silicon; Swift 6.4 / Xcode 27.
- On-device `SystemLanguageModel.default`, fresh session per request, greedy sampling.
- `maximumResponseTokens: 768`, 15-second per-call engine timeout, shared 180-second budget.
- No proxy, credentials, hosted requests, retries, or automatic normalization.
- Corpus: [DecisionOutputContracts.jsonl](../../Tests/SwiftDecisionTests/Fixtures/DecisionOutputContracts.jsonl).
- Corpus SHA-256: `60844fd67174fd3e742be1f3b7b5aad6a2070f7ae06aac0668daaa892daa2c17`.
- [Source revisions, adaptations, and license notices](../../Tests/SwiftDecisionTests/Fixtures/README.md).

Two sequential runs each used the same 48 cases: 96 inference calls in total. The first test took
37.323 seconds. A diagnostic repeat with separate count/range/sum error messages took
36.919 seconds and reproduced the same four failing cases. These are whole-suite observations,
not per-request latency percentiles or a performance benchmark.

## Observed results

| Kind | Cases | Valid distributions | Invalid sums |
| --- | ---: | ---: | ---: |
| Noul | 31 | 31 | 0 |
| Choice | 10 | 8 | 2 |
| Score | 7 | 5 | 2 |
| Total | 48 | 44 | 4 |

All 48 requests produced a probability array of the requested length, with finite values in
`0...1`. Four arrays failed `abs(sum - 1) <= 0.01` and were rejected by the adapter. There were
no observed generation/availability errors or timeouts in these runs.

| Case | Kind | Options | Failure |
| --- | --- | ---: | --- |
| `citychain-twenty-replies` | Choice | 20 | Sum outside tolerance |
| `support-twenty-options` | Choice | 20 | Sum outside tolerance |
| `refund-long-ten-levels` | Score | 10 | Sum outside tolerance |
| `museum-twenty-levels` | Score | 20 | Sum outside tolerance |

Russian, Unicode, escaped JSON, multiline text, and the quoted format-override case all returned
valid distributions on this sample. The long five-level score also passed. This is an observation
for this device/model and corpus, not a guarantee for arbitrary content or future OS models.

## Reproduce

On an eligible Mac with Apple Intelligence enabled and its model ready:

```sh
SWIFTDECISION_FOUNDATION_MODELS_CONTRACT=1 \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveDiverseOutputContractsWhenExplicitlyEnabled
```

The live test intentionally fails for observed invalid distributions. It is opt-in and is not
part of the offline CI inference path. The offline suite still runs all 48 inputs through
an injected client and checks rendering, schema cardinality, and public engine integration.

This baseline identified the cross-element sum constraint: guided generation enforced array
structure and individual numeric bounds in these runs, but asking for normalized probabilities
did not reliably enforce their sum with larger option sets. Strict mode retains that rejection.

## Follow-up: explicit normalization

`FoundationModelsDecisionBackend(normalization: .sumToOne)` requests bounded relative `weights`
and divides them by their positive sum. The default remains `.none`, with the original strict
`probabilities` contract. Both modes reject wrong-length/malformed arrays and nonfinite or
out-of-range values. The normalization option also rejects zero-sum vectors, rather than
inventing a replacement distribution.

An initial normalized-mode run returned valid predictions for 47 of 48 cases in 34.942 seconds.
`support-twenty-options` generated all-zero weights and was correctly rejected. The normalized
mode's instructions were then made concrete: assign the best-fitting option weight 1 and express
the other weights relative to it. The adapter's zero-sum rejection was retained.

With those instructions, the same 48 cases returned valid predictions in 40.582 seconds:

| Kind | Cases | Valid normalized distributions |
| --- | ---: | ---: |
| Noul | 31 | 31 |
| Choice | 10 | 10 |
| Score | 7 | 7 |
| Total | 48 | 48 |

```sh
SWIFTDECISION_FOUNDATION_MODELS_CONTRACT=1 \
SWIFTDECISION_FOUNDATION_MODELS_NORMALIZATION=sumToOne \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveDiverseOutputContractsWhenExplicitlyEnabled
```

This is a separate generation contract, so the normalized run is not a replay of strict-mode
raw outputs. It verifies the public output format on this device/corpus, without assessing answer
quality, calibration, or guaranteeing that arbitrary future requests cannot produce invalid weights.
Offline tests cover both modes, including non-unit sums, zeros, very small positive weights,
NaN/infinities, bounds, field mismatches, and unchanged strict-mode behavior.
