# Task 003: PostgreSQL Schema Contract and Plan

## Status

**Schema milestone verified on unmerged branch; Task 003 incomplete.** Schema work on `alharitz/task003-schema` adds standalone `migrations/002_passive_schema.sql` and `sql/fixtures/`; these remain present in this schema branch and are not merged into `main`. On 2026-10-20, local Podman PostgreSQL 16.15 ran schema plus fixtures 01–06 successfully on a fresh database, including non-owner runtime permission checks and separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK. Adapter implementation and deployment gates remain pending. Schema branch is not production-ready.

## Goal

Translate the verified Task 002 in-memory observation contract into a PostgreSQL 16 schema plan without changing source behavior or duplicating classifier/eligibility logic.

## Approved design

See [`docs/POSTGRES_CONTRACT.md`](../docs/POSTGRES_CONTRACT.md). Core decisions:

- Separate domain lock anchor from candidate rows. DNS errors preserve error facts but create no candidate.
- Shared exact identity across DNS and CT: `(domain, namespace, event_id)`; cross-kind collisions fail.
- Preserve full immutable payload and source timestamp strings.
- DNS sequence uses unconstrained `NUMERIC` with exact integral and u64 checks: `sequence = trunc(sequence) AND sequence >= 0 AND sequence <= 18446744073709551615`. Both event sequence and candidate watermark permit NULL only where their shapes allow it. `NUMERIC(20,0)` is not used: it can round fractional input before validation. One DNS namespace per domain. `(domain, sequence)` is unique across errors, stale successes, and applied successes.
- Preserve ordered DNS records, including duplicates, through ordinals.
- CT deduplicates events, not certificates. Success history retains raw evidence reference, status, applied flag, and acceptance order.
- Findings use nullable `from`; only applied history creates findings. Multiple brands are supported.
- DNS `has_certificate` is not a CT latch.
- Per-event transaction locks domain row, compares replay first, validates/reserves, calls future shared classifier/eligibility helper, and atomically writes event/facts/history/state/finding.
- Errors do not advance watermark; stale observations do not roll back state; CT remains monotonic.
- Runtime storage permissions are append-only. Foreign keys are restrictive.
- PostgreSQL 16 target. Later synchronous driver proposal only; no ORM or whole-`Store` dump.
- TLS must precede nonlocal database access.

## Required checks after approval

Schema tests cover identity cross-kind collision, maximum u64 and negative/fractional/overflow rejection, repeated certificate IDs as distinct events, error-before-candidate, ordered duplicate DNS records, many brands, initial CT nullable `from`, schema shape, rollback, restrictive deletes, runtime permissions, and DNS envelope sealing. On 2026-10-20, local Podman PostgreSQL 16.15 ran schema plus fixtures 01–06 successfully on a fresh database. Non-owner permission and committed sealing tests passed; separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK also passed. Commit `8b1747f` replaced `NUMERIC(20,0)` with unconstrained `NUMERIC` plus integral checks and added fractional-input rejection cases.

## Staged implementation

1. Gate: approve contract and establish migration/deployment history. Existing `migrations/001_passive_slice.sql` is incompatible and unvalidated; never destructively reset it.
2. Draft PostgreSQL 16 schema and invariant tests: present only on unmerged schema branch through `8b1747f`. Draft is standalone, not additive; never run 002 after 001 or reset existing data. Verify only in a new disposable, empty database.
3. Run live PostgreSQL 16 schema/fixture verification; completed locally on 2026-10-20 with Podman PostgreSQL 16.15 using a fresh database, standalone 002, and fixtures 01–06 in README order. Non-owner runtime grants, committed envelope sealing, and separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK passed. [PostgreSQL schema workflow](../.github/workflows/postgres-schema.yml) remains configured for a disposable PostgreSQL 16 service, but GitHub runs are billing-blocked; no claim depends on them. It never runs 001 or accesses an existing database; no repository secrets are used.
4. Propose and implement synchronous adapter, then restart/replay/concurrency tests. Establish runtime-role grants and TLS before nonlocal access; pending.

## Non-goals and limits

Schema draft does not replace deployed migrations or implement adapter behavior, source/core changes, dependencies, live sources, HTTP probing, CLI/API/UI, or production readiness. Reviewed documentation commit `ce8410a` is integrated into this schema branch. Verification used local Podman PostgreSQL 16.15 on 2026-10-20; GitHub CI remains billing-blocked. Direct duplicate inserts reject both exact and conflicting replay; adapter replay no-op semantics remain unimplemented. Fresh-db-only verification does not resolve deployment history.
