# Decision tracing

SwiftDecision combines application-level decision checkpoints with SpecificationCore rule evaluations. A decision invocation owns one `SpecificationTraceTimeline`, so both event sources can be read in their actual order without comparing wall-clock timestamps.

## Read a returned decision

`DecisionResult.trace` and `DecisionResult.specificationTrace` remain available for consumers that use the event streams separately. Use `orderedTrace` to interleave them:

```swift
let result = try await engine.choice(
    instructions: "Choose a team.",
    context: "The customer was charged twice.",
    options: options
)

for record in result.orderedTrace.records {
    switch record {
    case let .lifecycle(event):
        print(event.position.sequence, "checkpoint", event.stage)
    case let .specification(event):
        print(
            event.startPosition?.sequence as Any,
            "span",
            event.name,
            event.outcome,
            event.completionPosition?.sequence as Any
        )
    }
}
```

Records are ordered by their start or point position. A SpecificationCore event is a span: use its completion position and outcome when displaying how long a rule ran and how it finished. A lifecycle event is a checkpoint, not a Boolean validation result. The sequence is meaningful only inside this invocation; independent calls have independent timelines.

## Inspect thrown calls

A thrown decision has no `DecisionResult`. Supply `decisionTraceHandler` to receive the accumulated timeline before the original error is rethrown:

```swift
let engine = DecisionEngine(
    backend: backend,
    decisionTraceHandler: { snapshot in
        for record in snapshot.records {
            // Persist or render content-free trace metadata.
        }
    }
)
```

The callback runs once for each traced invocation, including success, fallback, abstention, request validation errors, backend failures, timeouts, and cancellation. An early error may have an empty snapshot. Calls on the same engine may invoke the callback concurrently, so the handler should be thread-safe and return promptly. Errors remain thrown errors; the trace does not replace the result or error as the source of outcome.

`specificationTraceHandler` remains available for consumers that need only SpecificationCore events. `traceMode: .disabled` suppresses both trace handlers and collections while leaving decision results, thrown errors, and metrics unchanged.

## Privacy and model identifiers

Trace events contain stage names, stable specification names, outcomes, positions, durations, and model identifiers. They do not contain prompts, option text, predictions, credentials, or request identifiers. Treat model identifiers and trace data according to the application's own logging policy.
