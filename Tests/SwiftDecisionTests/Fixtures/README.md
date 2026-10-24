# Decision output contracts

`DecisionOutputContracts.jsonl` contains 48 synthetic, format-only requests: 31 Noul, 10 Choice,
and 7 Score. Choice and Score each cover 2, 3, 5, 10, and 20 options. Topics include museum
opening times, outages, refunds, password resets, Oracle choices, and CityChain replies. Variants
exercise Russian and English, Unicode, quoted JSON, backslashes, multiline and longer context,
contradictory text, and a quoted request to ignore the output format.

There are no expected labels, correctness scores, or probability targets. The checks concern
output structure, array cardinality, finite numbers in `0...1`, and a sum within `0.01` of 1.

## Sources and adaptations

Existing synthetic examples are adapted from Jev4Mellea and SwiftJev (Apache-2.0, like this
repository) and SwiftDecision-Examples (MIT; its notice is retained below). Upstream files and immutable revisions make the requests reproducible;
the tests read only the local resource, without another checkout or network access.

| `source` | Upstream source |
| --- | --- |
| `jev4mellea-museum` | [Jev4Mellea museum dataset](https://github.com/SoundBlaster/Jev4Mellea/blob/f071a2e179a46cc0403fd0d6006e793a05b4b90c/examples/evaluation/museum_opening_expanded.jsonl) |
| `swiftjev-live`, `swiftjev-proxy` | [SwiftJev live and proxy tests](https://github.com/SoundBlaster/SwiftJev/blob/f3c06c704dcd699d180539db7d752e30e7bbd142/Tests/SwiftJevTests/JevDecisionBackendTests.swift) |
| `oracle-tests` | [Oracle routing tests](https://github.com/SoundBlaster/SwiftDecision-Examples/blob/0216b6b4694816f29f4ea1bf2559d6e7e5ac93f9/Tests/OracleGameTests/OracleGameTests.swift) |
| `citychain-tests` | [CityChain game tests](https://github.com/SoundBlaster/SwiftDecision-Examples/blob/0216b6b4694816f29f4ea1bf2559d6e7e5ac93f9/Tests/CityChainGameTests/CityChainGameTests.swift) |
| `swiftdecision-escaping`, `swiftdecision-smoke` | [Original adapter tests](https://github.com/SoundBlaster/SwiftDecision/blob/79734681408706cd2f46c99a895b1cf54bd1442c/Tests/SwiftDecisionTests/FoundationModelsDecisionBackendTests.swift) |

Museum references/candidates are combined into input context, without their accept/reject
labels. Other cases retain or adapt existing questions and contexts. Translations, larger option
sets, expanded rubrics, repeated context, and escaping variants are adaptations for output-format
coverage, not assertions of factual or decision correctness. The resource includes no user data,
API credentials, external-provider responses, or third-party model weights.

The offline suite sends every case through the public DecisionEngine APIs and an injected
Foundation Models fixture client. The real on-device suite is separate from the three-case smoke:

```sh
SWIFTDECISION_FOUNDATION_MODELS_CONTRACT=1 \
swift test --traits FoundationModels \
  --filter FoundationModelsDecisionBackendTests/testLiveDiverseOutputContractsWhenExplicitlyEnabled
```

It uses fresh local model sessions, up to 15 seconds per request and a shared 180-second inference
budget. It makes no hosted requests. Native generation errors, including refusals and unsupported
language errors, are reported as failures to obtain output, rather than counted as valid arrays.
Only case identifiers and contract status are printed; input text and generated content are omitted.

## SwiftDecision-Examples license notice

MIT License

Copyright (c) 2026 Egor Merkushev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
