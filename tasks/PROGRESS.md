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
- Task 002 in-memory passive prototype is verified (2026-10-19; see below). Task 003 schema milestone passed local Podman PostgreSQL 16.15 schema plus fixtures 01–06 on 2026-10-20, including non-owner runtime permissions, committed envelope sealing, and separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK. Branch remains unmerged; adapter remains pending. Task 003 is incomplete and not production-ready.
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
- Task 003 schema and fixtures are merged in `9a5b2cc`; local live SQL verification passed on 2026-10-20 with Podman PostgreSQL 16.15 using a fresh database. Existing `migrations/001_passive_slice.sql` is incompatible and unvalidated; do not run it or replace it before establishing deployment history. Adapter remains pending.
- No live sources, CLI wiring, API, or UI implemented for this prototype. Docker build and compose runtime remain unverified; phase-1 release gates remain pending.
- Limits: canonical lowercase ASCII hostnames only, timestamps retained as source strings, unbounded volatile memory.
- JSONL remains deferred pending a maintained serializer; NS/IP-change and same-status MX alerts remain deferred pending semantics.

## Milestone 003: PostgreSQL Schema Contract and Plan
**Status**: Schema milestone verified and merged in `9a5b2cc`; Task 003 schema scope is complete, while deployment and production gates remain open (2026-10-20). The merged schema contains standalone schema and fixtures from `alharitz/task003-schema`. Local Podman PostgreSQL 16.15 schema plus fixtures 01–06 passed on a fresh database, including non-owner runtime permissions, committed envelope sealing, and separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK. Task 004 adapter work is partial; branch is not production-ready.

### Planning Completed
- Contract recorded in `docs/POSTGRES_CONTRACT.md`; staged tasks in `tasks/003-postgres-schema.md`.
- Schema-first before adapter, PostgreSQL 16 target; shared identity, full immutable evidence, domain locks separate from candidates, bounded u64 sequences, ordered duplicate records, monotonic CT, atomic state/history/findings, append-only runtime permissions, and restrictive foreign keys specified.
- Existing `migrations/001_passive_slice.sql` remains incompatible. Establish deployment history before replacement; never use a destructive reset.

### Schema Draft Recorded
- Merged schema contains standalone `migrations/002_passive_schema.sql` and `sql/fixtures/`; 002 is not an additive migration and must never run after 001. Verification requires a new disposable, empty database.
- Commit `8b1747f` replaces `NUMERIC(20,0)` sequence columns with unconstrained `NUMERIC`, exact `sequence = trunc(sequence)` checks, and explicit range `0..18446744073709551615`; candidate watermark uses the same checks with `dns_sequence`. NULL is permitted only where event/candidate shape allows it. Fractional rejection fixtures were added; no rounding is accepted as validation.
- Local verification proves schema and fixture behavior, including non-owner runtime permissions and committed DNS envelope sealing. It does not prove adapter replay no-op semantics, deployment history, restart behavior, or nonlocal TLS.

### Checks and Limits
- Planning documentation was reviewed against Task 002 and core; Markdown whitespace/link checks were recorded for that earlier update.
- Historical planning notes recorded PostgreSQL, Docker, and `psql` unavailable; that no longer describes current verification. On 2026-10-20, local Podman PostgreSQL 16.15 executed standalone 002 plus fixtures 01–06 successfully in a fresh database. Docker remains unverified; adapter verification remains pending.
- Reviewed documentation commit `ce8410a` is integrated into this schema branch; schema and fixture files remain unchanged. Historical Cargo results above are not results of this update.
- Added `.github/workflows/postgres-schema.yml`: push/PR verification uses a disposable PostgreSQL 16 service, standalone 002, then fixtures 01–06 in README order and separate fail-fast psql sessions. No 001, existing database, repository secrets, SQL/source changes, or third-party test dependency. Local verification passed; GitHub execution remains billing-blocked.
- Workflow static assertions passed for fixture order against README, existing paths, separate sessions, fixture rollback/helpers, and security guards; `cargo check` and staged `git diff --check` passed.
- CI attempts for `e724b57` completed with infrastructure failure before any steps ran: [run 39291507845](https://github.com/alharitz/mirador/actions/runs/39291507845) and [run 39291507440](https://github.com/alharitz/mirador/actions/runs/39291507440). GitHub annotation: `The job was not started because your account is locked due to a billing issue.` No SQL executed; resolve account billing and rerun before claiming live verification.

### Remaining Work
1. Establish deployment history before any deployment/replacement; deployment history remains unresolved and production readiness is open.
2. Preserve fresh-db-only boundary; deployment history remains unresolved. Local PostgreSQL 16.15 schema/fixture verification is complete, but GitHub CI remains billing-blocked.
3. Propose synchronous PostgreSQL driver, implement adapter using shared classifier/eligibility helper, and run restart/replay/concurrency tests.
4. Runtime-role grants are verified for test role boundaries; distinguish these test grants from production provisioning. Address TLS before nonlocal database access. Source timestamp strings remain opaque, not validated chronological timestamps.
