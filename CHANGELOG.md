# Changelog

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
