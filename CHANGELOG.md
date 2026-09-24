# Changelog

## Unreleased

## 0.5.0 - 2026-09-24

### Added

- Add an invocation-scoped `orderedTrace` that merges SwiftDecision lifecycle checkpoints with SpecificationCore spans on one monotonic timeline.
- Add `decisionTraceHandler` snapshots for successful, abstaining, fallback, failed, and cancelled decisions.

### Changed

- Preserve the existing `trace`, `specificationTrace`, and `specificationTraceHandler` APIs alongside the merged timeline.

## 0.4.0

### Changed

- Raise the minimum iOS deployment target from iOS 13 to iOS 15. Apps that still support iOS 13 or 14 should remain on SwiftDecision 0.3.x using `.upToNextMinor(from: "0.3.0")` so SwiftPM cannot select 0.4.0.

### Added

- Add an iOS 15 Simulator build to the Swift 6.4 CI job.

## 0.3.0

### Added

- Expose `SpecificationCore` evaluation events on `DecisionResult.specificationTrace` for request validation, policy routing, backend evaluation, output validation, and acceptance thresholds.
- Add `SpecificationTraceHandler` to receive specification events for successful and failed decisions.
- Integrate `SpecificationCore` 2.0.0 with its `Tracing` trait enabled.

### Changed

- `DecisionTraceMode.enabled` collects both decision lifecycle and specification events. `.disabled` suppresses both trace streams and the specification trace callback.

### Validation

- CI passed on Swift 6.3.3 and Swift 6.4 with default traits, and on Swift 6.4 with the native `MLX` trait.
- A consumer package using `result.specificationTrace` compiled successfully.
