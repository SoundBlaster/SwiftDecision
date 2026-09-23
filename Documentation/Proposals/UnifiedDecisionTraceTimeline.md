# Proposal: Unified decision trace timeline

**Status:** Draft

**Date:** 2026-09-24

**Depends on:** [SpecificationCore proposal, PR #11](https://github.com/SoundBlaster/SpecificationCore/pull/11)

## Summary

Give one `DecisionEngine` call a shared monotonic trace timeline. SwiftDecision lifecycle events and SpecificationCore evaluation spans will receive positions from that timeline. Preserve the existing trace arrays and add one merged, ordered view for consumers that need to explain a decision as it ran.

## Problem

SwiftDecision currently returns two collections:

- `DecisionResult.trace` contains lifecycle checkpoints with a `Date` timestamp.
- `DecisionResult.specificationTrace` contains SpecificationCore events with recorder-local IDs, outcomes, and durations.

The collections preserve their own order, but they have no common ordering source. The `Date` is not reliable for ordering against Core events because Core events have no timestamp; its values are also wall-clock time and can be adjusted. Consumers that render both arrays in one card have to group them or guess how to interleave them.

## Goals

- Establish one authoritative event order per decision invocation.
- Expose relative monotonic timing and evaluation spans across both event sources.
- Keep the current `trace` and `specificationTrace` properties source-compatible.
- Provide a merged API that avoids ID collisions between lifecycle events and recorder-local specification nodes.
- Preserve content-free traces and keep application presentation outside SwiftDecision.
- Make completed traces inspectable when a decision throws or is cancelled.

## Non-goals

- A logging or telemetry exporter, persistent store, or UI component.
- Ordering independent decision calls against each other.
- Recording prompts, option text, model outputs, credentials, or arbitrary context values.
- Changing policy, inference, validation, acceptance, fallback, or error behavior.

## Proposed execution model

For each `DecisionEngine` invocation with tracing enabled:

1. Create one `SpecificationTraceTimeline`.
2. Create the SpecificationCore recorder with that timeline.
3. Give the same timeline to the lifecycle trace collector.
4. Mark each lifecycle checkpoint when it occurs.
5. Let SpecificationCore capture start and completion positions for each traced evaluation.
6. Return the existing arrays and a merged timeline built from the shared positions.

An illustrative merged value:

```swift
public enum DecisionTraceRecord: Sendable {
    case lifecycle(DecisionTraceEvent)
    case specification(SpecificationTraceEvent)
}

public struct DecisionTraceSnapshot: Sendable {
    public let records: [DecisionTraceRecord]
}
```

`DecisionResult` could expose `orderedTrace` as a computed property or a stored `DecisionTraceSnapshot`. Each item retains its source-specific value. Specification `id` and `parentID` remain local to the Core recorder; the enum case prevents a consumer from mistaking them for lifecycle IDs. Sorting uses the shared sequence number on each record's start/point position. A specification span also carries a completion position so renderers can show duration and overlap.

The existing `DecisionTraceEvent.timestamp` remains available for compatibility and human-readable wall-clock context. It does not determine merged order. `SpecificationTracePosition.sequence` is authoritative; `elapsedNanoseconds` supplies monotonic relative placement.

## Error and cancellation path

Successful and fallback decisions expose the merged trace on `DecisionResult`. A thrown call has no result today, while `specificationTraceHandler` exposes only Core events. Add an optional `decisionTraceHandler` that receives one `DecisionTraceSnapshot` after success, fallback, abstention, error, or cancellation. Preserve `specificationTraceHandler` for compatibility; it may continue receiving its current Core-only view.

The callback remains content-free, synchronous, and documented as concurrent across separate engine calls. The callback is invoked once per invocation and does not change whether errors are thrown.

## Compatibility and behavior

- Keep `DecisionResult.trace`, `DecisionResult.specificationTrace`, and `DecisionTraceEvent.timestamp`.
- Add the merged trace API without requiring changes at existing call sites.
- Keep independent calls on independent timelines; a consumer cannot compare sequence numbers across calls.
- When `.disabled` is selected, do not create or mark a trace timeline and preserve the existing empty traces.
- A thrown backend error remains an error; its snapshot contains only events recorded up to that point.
- Continue excluding request and prediction content.

## Validation

- Assert the merged order for a successful request: request validation, request-validated checkpoint, policy routing/selection, inference start, backend prediction span, inference completion, output validation, output-validated checkpoint, acceptance rules, and resolution.
- Assert start/completion positions bound each span and sequence numbers are unique within one invocation.
- Assert fallback, abstention, failed backend, validation failure, and cancellation snapshots end at the last event actually reached.
- Assert two concurrent decisions have isolated timelines and recorder-local parent IDs remain valid.
- Assert the existing trace arrays and handlers keep their documented behavior.
- Assert `.disabled` creates no trace records and produces the same decision outcome.
- Verify SwiftPM builds on the package's supported platforms and Swift versions.

## Consumer migration

Existing consumers may keep rendering the separate arrays. A consumer that needs an explanatory timeline should use `orderedTrace` and render lifecycle markers and specification spans in sequence order, preserving Core parent indentation. It should label lifecycle events and evaluated rules distinctly: a completed lifecycle checkpoint is not necessarily a Boolean validation result.

The Oracle history screen in SwiftDecision-Examples is a useful integration test: it should show request validation immediately beside the checkpoint that follows it, and backend inference between its start and completion markers.

## Open questions

1. Should the merged API be named `orderedTrace`, `timeline`, or `traceSnapshot`?
2. Should the failure callback be added in the same change or as a follow-up once the successful result API is established?
3. Should the snapshot record invocation outcome explicitly, or should the existing result/error remain the sole outcome source?

The recommended first implementation keeps both existing arrays, adds `orderedTrace`, and adds one callback for snapshots on thrown calls so tracing remains useful on every exit path.
