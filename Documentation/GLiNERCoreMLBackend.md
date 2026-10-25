# Small GLiNER Core ML pilot

`SwiftDecisionGLiNER` is an optional local classification backend for
[`fastino/gliner2.5-small-v1`](https://huggingface.co/fastino/gliner2.5-small-v1).
It uses Apple's system Core ML runtime on macOS 14+ and iOS 17+.
The English checkpoint has about 74 million parameters and an Apache-2.0 license.
This is an experimental alternative for bounded classification tasks, not a
calibrated or general-purpose replacement for Jev.

## Keep the application small

- Opt in to the **`GLiNER` trait** and link the **`SwiftDecisionGLiNER` product**.
  The core `SwiftDecision` product does not depend on this adapter or its tokenizer.
- No model files are SwiftPM resources. Nothing downloads automatically.
- Provision the converted checkpoint in application storage, for example after
  an explicit user download. An app that bundles the files will include their
  full size. The host app owns download, integrity checks, progress, versioning,
  activation and removal; this pilot does not add a downloader.
- Python, PyTorch and coremltools are developer export tools only. They are not
  embedded in the Swift app. MLX is not required by this backend.
- Tokenization uses a small native Unigram implementation for this checkpoint's
  exact NFC/whitespace/Metaspace configuration, with byte-distinct vocabulary
  lookup and explicit special-token IDs. The general-purpose Tokenizers/Hub
  runtime is not linked by the GLiNER adapter.
- The measured INT8 `.mlpackage` is **78,209,741 bytes**; the two tokenizer files
  add **8,337,288 bytes**. This is disk storage, not a peak RAM measurement or an
  App Store compressed-download measurement. Core ML compilation can add storage.

## Prepare assets explicitly on a Mac

Use Python 3.12 in a separate environment. Choose cache, environment and output
locations on a disk with sufficient space; the reference/export toolchain is
much larger than the final app assets.

```sh
python3.12 -m venv /path/to/gliner-venv
/path/to/gliner-venv/bin/pip install -r Scripts/gliner/requirements.lock
/path/to/gliner-venv/bin/python Scripts/gliner/prepare.py \
  --cache-dir /path/to/huggingface-cache \
  --output /path/to/gliner-small
```

The initial command explicitly downloads the checkpoint. Add `--local-files-only`
to reuse the cache without network access. The output directory must be new.
The exporter runs the English diagnostic corpus, exports only the encoder and
classification head, compresses weights to INT8, and measures the Core ML output.
It writes `reference.json` and `measurement.json` alongside the assets. Use
`--weight-bits 32` for an uncompressed numerical baseline, and
`--reference-only` to skip Core ML conversion. The default fixed input capacity
is 256 tokens; `--sequence-length` allows 32–512 tokens. Inputs that exceed the
chosen capacity fail instead of being silently truncated.

Only these files are needed at runtime:

```text
gliner-small/
  gliner.json
  tokenizer.json
  tokenizer_config.json
  GLiNERSmall.mlpackage/       # or precompiled GLiNERSmall.mlmodelc/
```

Preserve the upstream Apache-2.0 license and attribution when distributing model
assets. Weights are not redistributed in this repository. The pinned model
revision is `df5910e44bc4ffdb0d95399a83b0ca4516349aa5`; the GLiNER2 reference
implementation is pinned to `ca4f68235b50fe4c3ecf3876851d748fe4b15c6c`.

## Swift API

This adapter is currently unreleased. To try this PR from another package:

```swift
.package(
    url: "https://github.com/SoundBlaster/SwiftDecision.git",
    branch: "codex/gliner-small-backend",
    traits: ["GLiNER"]
)
// Target dependencies:
.product(name: "SwiftDecision", package: "SwiftDecision"),
.product(name: "SwiftDecisionGLiNER", package: "SwiftDecision")
```

```swift
import SwiftDecision
import SwiftDecisionGLiNER

// A local directory provisioned by the host application.
let backend = try await GLiNERCoreMLBackend.load(checkpointAt: assetsDirectory)
let engine = DecisionEngine(backend: backend)

let result = try await engine.choice(
    instructions: "Route the support message to the correct department.",
    context: "I was charged twice for the same order.",
    options: [
        ChoiceOption(label: "technical", description: "Technical support"),
        ChoiceOption(label: "billing", description: "Billing"),
        ChoiceOption(label: "shipping", description: "Shipping")
    ]
)
print(result.value as Any) // billing on the diagnostic input
print(result.probabilities)
```

Loading and compilation run off the caller's actor. Prediction runs serially in
the backend actor. Cancellation is checked before and after the synchronous Core
ML call; it does not preempt an in-flight native prediction. No retries, service
calls, secret lookup, or cloud fallback are performed.

## Output contract and responsibility

GLiNER receives a single exclusive classification schema with task name
`decision`, the prompt instructions, option IDs and descriptions, followed by
the word-split context. The classifier reads the embedding at each structural
`[L]` marker. A complete logit vector is converted with numerically stable softmax
at temperature 1, matching the reference exclusive-classification API.

- Noul preserves `false`, `true` order.
- Choice preserves the caller's option order.
- Score treats the rubric levels as exclusive classes; the existing engine maps
  them to a level and probability-weighted numeric value. It is not continuous
  regression or a separate trained Score head.
- A winner-only confidence is never expanded into a fabricated distribution.
- Softmax normalization is not empirical probability calibration. The high
  confidence of incorrect answers in this corpus demonstrates that limitation.

`DecisionEngine` retains SpecificationCore request/output validation, acceptance
policies, tracing, abstention and explicit fallback. The adapter owns tokenizer,
model execution and score alignment. SwiftJev and SpecificationCore do not change.

The pinned upstream schema rejects `(`, `)` and structural marker strings in
instructions, IDs and descriptions. The Swift adapter rejects them too rather
than silently rewriting the question. This restriction does not apply to
ordinary context text. Missing/invalid assets, unsupported syntax, overlength
input and malformed outputs throw errors.

## Reproducible checks

Ordinary tests do not download or load model weights:

```sh
swift test --disable-default-traits
swift test --traits GLiNER --triple arm64-apple-macosx14.0
swift build --target SwiftDecisionGLiNER --traits GLiNER \
  --triple arm64-apple-ios17.0-simulator
```

Explicit live local inference through the public Swift backend and engine:

```sh
SWIFTDECISION_GLINER_CHECKPOINT=/path/to/gliner-small \
swift test --traits GLiNER --triple arm64-apple-macosx14.0 --filter GLiNER
```

The checked-in fixture records both original Torch probabilities and the INT8
Core ML reference. Swift's token IDs and marker positions must match exactly.
INT8 Swift output is compared with the same INT8 model run through Python Core
ML, within `0.0001`. An uncompressed export is compared with original Torch
within `0.0001`. Compression drift is measured separately, not concealed by a
loose runtime-parity tolerance. Re-export using the pinned toolchain and corpus
when intentionally updating the golden fixture.

## Observed results, 2026-10-25

Apple M4 Pro, macOS 27.0, Core ML CPU only, FP32 arithmetic and INT8 weights:

| Measurement | Result |
| --- | --- |
| English diagnostic inputs | 41, including 4 arbitrary choices without factual ground truth |
| Exact Swift/Python token and marker alignment | 41/41 |
| INT8 selected label agrees with uncompressed Torch | 41/41 |
| Largest probability change due to INT8 compression | 0.058925, about 5.9 percentage points |
| Correct on this small labeled diagnostic set | 32/37 |
| Median warm Swift inference time | About 38 ms, excluding load/compile |

The set includes Noul, Choice, Score, reversed label order, numeric IDs produced
by the public engine, and missing evidence. It is a small hand-authored diagnostic
set with related/reversed cases, not an independent quality benchmark.
Correctness here counts the raw highest-scoring class before engine abstention.
[`measurement.json`](../Scripts/gliner/measurement.json) records all five wrong
cases, including negation failures, an unsupported coin prediction and a changed
answer after reversing color options. A high threshold alone cannot fix those
confident errors. Arbitrary choices are not evaluated for factual correctness.

Several compatibility problems were caught by these checks:

1. The upstream facade's cache fingerprint can reuse an earlier schema after
   label order changes. The exporter compiles each schema directly so reversed
   cases actually change the encoder input.
2. The initial general-purpose tokenizer dependency raised the minimum supported
   iOS version during Xcode app dependency builds. The adapter now implements
   the checkpoint's Unigram pipeline directly, checks its exact configuration,
   and resolves added tokens through the original ID table. Its IDs are checked
   against 35 additional Python fixtures for Unicode, whitespace and special
   markers. It never falls back to BPE or changes package deployment floors.
3. Transformers' scripted shape branches need a narrow export-only specialization
   for fixed-shape self-attention. The trace is checked against the original
   Torch forward pass before conversion.
4. The FP16 Core ML conversion collapsed output scores on this checkpoint.
   The validated export uses FP32 arithmetic and INT8 weight compression instead.

iPhone inference speed, peak RAM, energy use and actual host-app binary-size
delta have not been measured. The next integration step is a separately downloaded
checkpoint behind an application feature flag, followed by physical-device
measurements on the intended task corpus.
