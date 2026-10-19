# Task 002: Passive Observation Prototype

## Purpose

Define and verify the smallest phase-1 passive observation contract in memory before implementing durable PostgreSQL storage. This task preserves the overall phase-1 scope; it does not complete phase-1 release gates and does not add a website or HTTP probing.

## Scope

- In-memory candidate and association state.
- Raw typed successful source snapshots with stable event identity.
- Separate error records preserving source facts and status.
- One ordered DNS stream per candidate, monotonic sequence handling, and stale-observation behavior.
- Independent monotonic CT `observed-ever` state.
- Typed transition-only findings.
- Hostname validation for canonical ASCII lowercase names without trailing dot; no homemade IDNA.
- JSONL only when a maintained serializer is available.

## Approved Contract

- Every distinct successful source event appends a raw typed snapshot to history. Exact retry causes no mutation. Conflicting replay returns an error.
- Stable identity is canonical domain + source namespace + event ID.
- Each candidate has one ordered DNS stream with monotonic sequence. Stale successful observations remain in history but are not applied. Equal sequence with different identity is rejected.
- Errors are recorded separately and preserve facts/status. Initial error status is unknown.
- CT `observed-ever` is independent and monotonic. `Certified` has priority even when DNS is NXDOMAIN. CT evidence is not proof of validity or resolution.
- DNS baseline is silent. Initial CT `Certified` emits a finding. Eligible findings are unregistered→live, parked→mail/cert, and mail→cert. Downgrades, disappearance, unchanged state, stale observations, and errors are silent.
- Findings are typed transition-only records. No invented score or policy.
- One candidate can have multiple brand associations.
- NS/IP-change and same-status MX alerts are deferred until semantics are fixed.

## Explicit Boundaries

- This task is an in-memory prototype, not durable storage.
- Later PostgreSQL work must preserve this contract. Existing `migrations/001_passive_slice.sql` is an unvalidated prototype incompatible with it; do not migrate that SQL.
- JSONL output requires a maintained serializer. If unavailable, defer output; do not write a handmade parser.
- Phase 1 remains passive: no HTTP requests to candidate domains.
- No website/UI in this task; phase 2 remains out of scope.

## Status (2026-10-19)

Implemented and independently verified in memory. Final independent reviewer approved the `RawEvidence` fix. Durable PostgreSQL design/adapter is next and is not implemented. No live sources, CLI wiring, API, or UI; Docker remains unverified.

Limits: canonical lowercase ASCII hostnames only, timestamps retained as source strings, and unbounded volatile memory. JSONL is explicitly deferred: output returns `JSONL output is unsupported without a maintained serializer`.

## Acceptance Checks

- [x] Valid canonical ASCII lowercase hostname accepted; uppercase, trailing-dot, non-ASCII, malformed, and empty hostnames rejected.
- [x] Same candidate supports multiple brand associations without duplicate association mutation.
- [x] Distinct successful events append raw typed history; exact retry leaves history unchanged; conflicting replay fails.
- [x] DNS sequence applies in order; stale success is retained but does not change applied state; equal sequence with another identity fails.
- [x] Error observation is separate, retains source facts/status, and has unknown initial status.
- [x] CT evidence updates independent monotonic `observed-ever`; repeated evidence is idempotent; `Certified` remains effective with NXDOMAIN and does not assert validity/resolution.
- [x] DNS baseline emits no finding; initial CT `Certified` emits one typed finding.
- [x] Only unregistered→live, parked→mail/cert, and mail→cert emit findings; downgrade, disappearance, unchanged, stale, and errors emit none.
- [x] NS/IP-change and same-status MX alerts are absent because semantics remain deferred.
- [x] JSONL is emitted only through a maintained serializer; otherwise output is explicitly deferred.
- [x] No SQL migration is changed or executed as part of this prototype.

## Verification Note

Independent verification on 2026-10-19: `cargo test` passed (38 tests: 22 config, 16 engine); `cargo check`, `cargo fmt -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo build --release`, and `git diff --check` passed. Final independent reviewer approved the `RawEvidence` fix. These results supersede the earlier architect report of 44 passing and 1 failing. Historical foundation verification remains recorded separately. Docker build and compose runtime were not verified.
