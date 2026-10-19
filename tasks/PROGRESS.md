# Mirador Progress Tracking

## Overall Progress
- **Product Brief**: Created (docs/PRODUCT_BRIEF.md)
- **Task Definitions**: Created (tasks/README.md, this file)
- **Rust Foundation Milestone**: Defined (tasks/001-rust-foundation.md)
- **Documentation Updates**: README.md and NOTES.md updated; Mirador.md and Mirador v0.1.md exist.

## Milestone 001: Rust Foundation
**Status**: Implemented — verification passed except Docker: Rust foundation implementation complete with URL hardening complete, Docker unavailable.
**Goal**: Establish Rust toolchain, project structure, and external dependency documentation.

### Checklist
- [x] Product brief completed
- [x] Task list initialized
- [x] Rust foundation milestone defined
- [x] Mirador.md updated to reflect Rust selection
- [x] Mirador v0.1.md updated to note stack superseded
- [x] README.md updated to note Rust selection and dnstwist external
- [x] NOTES.md updated to note phase-1 boundaries remain passive
- [x] Cargo project initialized
- [x] Dockerfile updated for Rust
- [x] compose.yaml updated for Rust
- [x] Cargo.toml exists with correct package, version, edition
- [x] Placeholder src/main.rs exists and is compilable
- [x] cargo check succeeds
- [x] cargo build --release succeeds
- [x] Documentation reflects Rust selection in all relevant files
- [x] Local Rust foundation acceptance verified
- [ ] Docker build and compose runtime verified (Docker unavailable)
- [ ] Phase-1 release gates complete (pending; see docs/PRODUCT_BRIEF.md)

### Checks Run
- Markdown consistency: verified
- cargo check: succeeded
- cargo build --release: succeeded
- cargo fmt: succeeded
- cargo clippy: succeeded
- cargo test: passed on 2026-10-15 (38 tests)
- Docker availability: command unavailable on 2026-10-15; no build or compose runtime verification
- Other Cargo checks above are prior recorded results, not rerun for this documentation update.

### Failures
- Docker build not verified (Docker unavailable in current environment)

### Remaining Work
- Task 002 in-memory passive prototype is verified (2026-10-19; see below). Task 003 schema planning is ready; schema and adapter implementation remain pending.
- Existing `migrations/001_passive_slice.sql` is an unvalidated prototype incompatible with the approved contract; establish deployment history before replacement and never use a destructive reset.
- Docker build and compose runtime verification when available.
- Phase-1 release gates remain pending; local foundation checks are not release completion.
- Rust is the active implementation direction. Go scaffold is legacy with no new features; retirement is a separate decision.

### Approved Observation Contract
- Every distinct successful source event appends a raw typed snapshot; exact retry has no mutation; conflicting replay errors. Stable identity: canonical domain + source namespace + event ID.
- One ordered DNS stream per candidate uses monotonic sequence. Stale successes remain recorded but are not applied; equal sequence with different identity is rejected.
- Errors are recorded separately with facts/status preserved; initial error status is unknown.
- CT observed-ever is independent and monotonic. `Certified` has priority even with NXDOMAIN, but is not validity/resolution proof.
- DNS baseline is silent. Initial CT `Certified` finding, plus eligible unregistered→live, parked→mail/cert, and mail→cert transitions. Downgrade, disappearance, unchanged, stale, and error observations are silent.
- Findings are typed transition-only records with no invented score/policy. Canonical ASCII lowercase hostname without trailing dot; no homemade IDNA. One candidate may have multiple brand associations.
- NS/IP-change and same-status MX alerts are deferred until semantics are fixed. JSONL requires maintained serializer; otherwise defer output.

### Classifier Decisions
- Current empty successful DNS answer without MX or certificate is classified `RegisteredParked`.
- Phase-1 production path must not emit `ActiveReserved`; enum/classifier support does not authorize production use.
- Current prototype CT observed-ever is independent and monotonic; `Certified` takes precedence even with NXDOMAIN or DNS failure. Certificate evidence is not proof of validity/resolution.
- Current prototype emits no `ActiveReserved` output.

## Milestone 002: Passive Observation Prototype
**Status**: Implemented — in-memory prototype independently verified on 2026-10-19. Final independent reviewer approved the `RawEvidence` fix.

### Checks Run
- `cargo test`: passed, 38 tests (22 config, 16 engine).
- Independent `cargo check`, `cargo fmt -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo build --release`, and `git diff --check`: passed.
- These results supersede the earlier architect report of 44 passing and 1 failing; historical foundation checks above remain unchanged.
- Task 002 acceptance checks complete, including explicit JSONL deferral: `JSONL output is unsupported without a maintained serializer`.

### Boundaries and Remaining Work
- Task 003 schema planning is ready; implementation and adapter remain pending. Existing `migrations/001_passive_slice.sql` is incompatible and unvalidated; do not run it or replace it before establishing deployment history.
- No live sources, CLI wiring, API, or UI implemented for this prototype. Docker build and compose runtime remain unverified; phase-1 release gates remain pending.
- Limits: canonical lowercase ASCII hostnames only, timestamps retained as source strings, unbounded volatile memory.
- JSONL remains deferred pending a maintained serializer; NS/IP-change and same-status MX alerts remain deferred pending semantics.

## Milestone 003: PostgreSQL Schema Contract and Plan
**Status**: Planning ready; implementation pending (2026-10-19). Documentation-only; no executable SQL, migration/source changes, or dependencies added.

### Planning Completed
- Contract recorded in `docs/POSTGRES_CONTRACT.md`; staged tasks in `tasks/003-postgres-schema.md`.
- Schema-first before adapter, PostgreSQL 16 target; shared identity, full immutable evidence, domain locks separate from candidates, bounded u64 sequences, ordered duplicate records, monotonic CT, atomic state/history/findings, append-only runtime permissions, and restrictive foreign keys specified.
- Existing SQL remains incompatible. Establish deployment history before replacement; never use a destructive reset.

### Checks and Limits
- Documentation reviewed against Task 002 and current core; Markdown whitespace/link checks recorded after editing.
- No PostgreSQL, Docker, or `psql` available. No SQL tests, migration execution, adapter tests, or production-readiness claim.
- Historical Cargo results above are not results of this documentation milestone.

### Remaining Work
1. Approve contract and establish deployment history before drafting schema/tests.
2. Draft schema and exact invariant tests; then verify live on PostgreSQL 16 when tooling is available.
3. Propose synchronous PostgreSQL driver, implement adapter using shared classifier/eligibility helper, and run restart/replay/concurrency tests.
4. Address TLS before nonlocal database access. Source timestamp strings remain opaque, not validated chronological timestamps.
