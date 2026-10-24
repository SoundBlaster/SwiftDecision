# Foundation Models decision assessment — 2026-10-25

## Outcome

An opt-in `FoundationModelsDecisionBackend.Strategy.optionAssessment` substantially
improved this small local evaluation over the original generated numeric array.
It is suitable for continuing the Oracle pilot with explicit uncertainty. It does
not make Apple Intelligence a calibrated or generally reliable decision model.

## Workstation and protocol

- Local `SystemLanguageModel.default`, fresh sessions, greedy generation.
- macOS 27.0; Xcode 27.1 (27A9275). Apple exposes no stable checkpoint version here.
- No hosted model, credentials, proxy, retry, or Private Cloud Compute.
- Six-case batches, 6-second per-decision deadlines, 35-second batch admission budget.
- Public typed `DecisionEngine` Noul, Choice and Score APIs, default acceptance policies.
- 24 development cases used during iteration. An additional 12 synthetic cases were
  frozen after prompt selection, alongside the user's 8 bare-OR regression forms.
  The final cyclic-order implementation was evaluated on those same 20 cases;
  they are a validation set, not proof of broad generalization.

## Techniques screened

1. Original JSON input plus numeric array: repeated positional templates.
2. Named numeric fields binding each option's meaning: correct on all six objective
   development choices, but one of two ambiguous forms still guessed.
3. An answerability gate, an extracted-criterion field, examples and JSON variants:
   some reduced unsupported answers but also rejected obvious valid choices.
4. Per-option categorical support and categorical selected-ID controls: useful for
   diagnosis but not a probability backend contract; no invented one-hot confidence.
5. Named assessments plus a second permutation: removes unstable preference.
6. Dedicated Noul verdict plus native scalar estimate: distinguishes contradiction
   from missing information. A scalar alone treated missing information as false.
7. Explicit Score evidence status: permits an honest no-evidence outcome even when
   no rubric level has positive support.

The initial inverse-order experiment passed all eight development choice cases.
The final permutation is a cyclic shift, which moves every option, including the
middle of odd-sized option lists. The Noul verdict guide order also shifts.

## Final algorithm

- Choice: one numeric field per option, with its meaning in the schema description.
- Score: the same fields plus a `hasEvidence` Boolean.
- Noul: `verdict` (supported/contradicted/unknown), then native `probabilityTrue`.
- Two independent sessions with changed option/verdict ordering. Restore original
  indices; require a consistent unique winner; average aligned estimates.
- Missing evidence, disagreement or a tied winner yields no stable preference,
  represented by a uniform vector. The default engine policy abstains.
- Bounds, cardinality and decoding remain mandatory. Invalid values throw.
  Choice all-zero vectors throw. Score zero support is a semantic abstention only
  with an explicit valid `hasEvidence=false`; malformed fields still throw.
- Noul unknown or a verdict contradicting its native scalar also yields no preference.
  Its scalar must remain finite and bounded, including when the verdict is unknown.

## Matched 20-case comparison

| Metric | Original array | Option assessment |
| --- | ---: | ---: |
| Correct accepted answers among 9 determinate cases | 1 | 8 |
| Wrong accepted answers among those 9 | 4 | 0 |
| Determinate cases conservatively skipped | 4 | 1 |
| Correct abstentions among 11 undecidable cases | 1 | 11 |
| Unjustified answers on undecidable cases | 10 | 0 |
| Generation/format errors | 0 | 0 |
| Median observed latency | 0.635 s | 1.054 s |

Eight of the eleven undecidable cases are the user's four OR questions in both
orders, with Oracle's question-as-context input. Each final result was uniform
50/50 and abstained. Bare alternatives without a selection criterion are defined
as undecidable in this evaluation; their arbitrary selected words are not factual
label errors, but unsupported preferences.

The final cyclic run skipped `fresh-score-full`, despite sufficient evidence;
the earlier reverse-order prototype skipped `fresh-score-partial` instead. This
shows sensitivity remains. Conservatism improves safety at a cost to coverage.
No confidence calibration, repeated-run statistical study, adversarial security,
physical-iPhone inference or energy benchmark is established by this run.

The [raw result rows](FoundationModelsAssessment-2026-10-25.jsonl) contain fixed
sample IDs, expected/observed labels, vectors and timings, not arbitrary user input.

## Reproduce

```sh
SWIFTDECISION_FM_QUALITY=1 \
SWIFTDECISION_FM_QUALITY_CORPUS=holdout \
SWIFTDECISION_FM_QUALITY_BATCH=0 \
swift test --traits FoundationModels --filter FoundationModelsDecisionQualityTests
```

Run batches 0 through 3. Use
`SWIFTDECISION_FM_QUALITY_STRATEGY=directDistribution` for the old baseline.
Normal tests skip all local-model evaluation. Workstation commands must additionally
route artifacts/caches to TB5 as required by the local repository guidance.

Corpus SHA-256:

- Development: `ba7dd1399242aa9c20cf4370ca0ee65272cb89d517a3207e4c8d227b169070e1`
- Validation: `52772bb69c2e91399ad81821f9fd806119e8900ccb65ea5eff33ed7908d39e41`

## Build and offline validation

- Full Foundation Models trait suite: 74 passed, 5 opt-in tests skipped.
- Default/no-optional-traits suite: passed.
- SwiftDecision target with Foundation Models for iOS 15 Simulator: built successfully.
- Fifteen deterministic option-assessment fixture tests cover order restoration,
  fixed first/middle bias, typed truth consistency, unknown versus false, explicit
  Score no-evidence, invalid fields, normalization and cancellation.

## Sources informing the experiments

Apple recommends concise, specific requests, splitting complex tasks, and testing
prompt variants on actual workloads in [Prompting an on-device foundation model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model).
Schema descriptions and property order influence guided generation; schema shape
alone is not a correctness claim. See [Generating Swift data structures](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).

## Remaining boundaries

Two passes can agree on an incorrect answer; a cyclic shift is not exhaustive
permutation testing. The numbers are model estimates and consistency-gated averages,
not token probabilities or calibrated confidence. Strict normalization may still
reject a numeric assessment whose sum is not one. Keep security and deterministic
domain invariants in application rules. Oracle explicitly disables fallback for
Apple inference and retains one shared deadline across routing and answering.
