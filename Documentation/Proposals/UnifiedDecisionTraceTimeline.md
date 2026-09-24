# Proposal: Unified decision trace timeline

**Status:** Implemented in SwiftDecision; included in the planned 0.5.0 release

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
3. Create an invocation-owned lifecycle trace collector with the same timeline before request validation or other throwing checks.
4. Mark each lifecycle checkpoint when it occurs.
5. Let SpecificationCore capture start and completion positions for each traced evaluation.
6. On every exit path, build one snapshot from the lifecycle collector and the Core recorder. On a returned result, expose the existing arrays and the merged snapshot; on a throw, send the snapshot through the callback before rethrowing.

Core positions require an explicit timeline. A plain `SpecificationTraceRecorder()` and the process-wide `SpecificationTraceRuntime.defaultRecorder` have no positions under [the resolved Core API](https://github.com/SoundBlaster/SpecificationCore/pull/11); SwiftDecision must use the invocation-owned timeline rather than rely on a recorder default.

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

Add a non-optional `position: SpecificationTracePosition` to engine-produced `DecisionTraceEvent` values. `DecisionResult.orderedTrace` is a computed `DecisionTraceSnapshot` built from its existing `trace` and `specificationTrace` arrays, so it does not duplicate stored records. Each item retains its source-specific value. Specification `id` and `parentID` remain local to the Core recorder; the enum case prevents a consumer from mistaking them for lifecycle IDs. Sorting uses the shared sequence number on each record's start/point position. A specification span also carries a completion position so renderers can show duration and overlap. All Core events in a SwiftDecision snapshot have both positions because the engine supplies an explicit timeline; events from legacy or external recorders without positions are outside this merged API.

The existing `DecisionTraceEvent.timestamp` remains available for compatibility and human-readable wall-clock context. It does not determine merged order. `SpecificationTracePosition.sequence` is authoritative; `elapsedNanoseconds` supplies monotonic relative placement.

## Error and cancellation path

Successful, fallback, and abstaining decisions expose the merged trace on `DecisionResult`. A thrown call has no result today, while `specificationTraceHandler` exposes only Core events. Add an optional `decisionTraceHandler` that receives one `DecisionTraceSnapshot` after success, fallback, abstention, error, or cancellation. Preserve `specificationTraceHandler` with its current Core-only callback behavior and timing. The new callback receives the same records as a successful result's `orderedTrace` or the records accumulated before a throw, including an empty snapshot when a call fails before the first traced event.

The callback remains content-free, synchronous, and documented as concurrent across separate engine calls. It is invoked exactly once per traced invocation and does not change whether errors are thrown. A collector whose state survives a thrown operation is needed; the current value-type collector local to `evaluate` cannot supply early failure snapshots. The result or thrown error remains the source of the invocation outcome; the snapshot records only timeline events.

## Compatibility and behavior

- Keep `DecisionResult.trace`, `DecisionResult.specificationTrace`, and `DecisionTraceEvent.timestamp`.
- Add the merged trace API without requiring changes at existing call sites.
- Keep independent calls on independent timelines; a consumer cannot compare sequence numbers across calls.
- When `.disabled` is selected, do not create or mark a trace timeline, preserve the existing empty traces, and do not invoke either trace callback.
- A thrown backend error remains an error; its snapshot contains only events recorded up to that point.
- Continue excluding request and prediction content.

## Validation

- Assert the merged order for a successful request: request validation, request-validated checkpoint, policy routing/selection, inference start, backend prediction span, inference completion, output validation, output-validated checkpoint, acceptance rules, and resolution.
- Assert start/completion positions bound each span and sequence numbers are unique within one invocation.
- Assert fallback, abstention, failed backend, validation failure, and cancellation snapshots end at the last event actually reached.
- Assert errors before request validation produce an empty snapshot and invoke the new callback once; assert later failures retain lifecycle checkpoints already recorded.
- Assert two concurrent decisions have isolated timelines and recorder-local parent IDs remain valid.
- Assert the existing trace arrays and Core-only handler keep their documented behavior, and successful callback records equal the result's `orderedTrace` records.
- Assert `.disabled` creates no trace records and produces the same decision outcome.
- Verify SwiftPM builds on the package's supported platforms and Swift versions.

## Consumer migration

Existing consumers may keep rendering the separate arrays. A consumer that needs an explanatory timeline should use `orderedTrace` and render lifecycle markers and specification spans in sequence order, preserving Core parent indentation. It should label lifecycle events and evaluated rules distinctly: a completed lifecycle checkpoint is not necessarily a Boolean validation result.

The Oracle history screen in SwiftDecision-Examples is a useful integration test: it should show request validation immediately beside the checkpoint that follows it, and backend inference between its start and completion markers.

## API decisions

1. Name the result property `orderedTrace` and give it the `DecisionTraceSnapshot` type. The name distinguishes the merged view from the existing `trace` array.
2. Add `decisionTraceHandler` in the same change as `orderedTrace`, so the merged API works on both returned and thrown calls.
3. Keep outcome in the returned `DecisionResult` or thrown error. The snapshot contains content-free event records and does not duplicate outcome state.

## Implementation note

The implementation exposes `DecisionResult.orderedTrace`, `DecisionTraceSnapshot.records`, and the optional `DecisionEngine.decisionTraceHandler`. SwiftDecision currently resolves SpecificationCore to merge commit `83cfea8ecc47513e6331b4ecd93189c5e6715636`, which contains the merged PR #11 API. Once SpecificationCore 2.1.0 is published, SwiftDecision should replace this temporary revision pin with the version requirement before its 0.5.0 release.
