# Task 003: PostgreSQL Schema Contract and Plan

## Status

**Planning ready; implementation pending.** This milestone is documentation-only. It does not add executable SQL, modify migrations, add a PostgreSQL adapter, or establish production readiness.

## Goal

Translate the verified Task 002 in-memory observation contract into a PostgreSQL 16 schema plan without changing source behavior or duplicating classifier/eligibility logic.

## Approved design

See [`docs/POSTGRES_CONTRACT.md`](../docs/POSTGRES_CONTRACT.md). Core decisions:

- Separate domain lock anchor from candidate rows. DNS errors preserve error facts but create no candidate.
- Shared exact identity across DNS and CT: `(domain, namespace, event_id)`; cross-kind collisions fail.
- Preserve full immutable payload and source timestamp strings.
- DNS sequence uses lossless `numeric(20,0)` with u64 bounds. One DNS namespace per domain. `(domain, sequence)` is unique across errors, stale successes, and applied successes.
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

Schema tests must cover identity cross-kind collision, maximum u64 and overflow, repeated certificate IDs as distinct events, error-before-candidate, ordered duplicate DNS records, many brands, initial CT nullable `from`, schema shape, rollback, and restrictive deletes.

## Staged implementation

1. Gate: approve contract and establish migration/deployment history. Existing `migrations/001_passive_slice.sql` is incompatible and unvalidated; never destructively reset it.
2. Draft PostgreSQL 16 schema and invariant tests.
3. Run live SQL verification when PostgreSQL/Docker/`psql` is available.
4. Propose and implement synchronous adapter, then restart/replay/concurrency tests.

## Non-goals

No executable SQL, migration replacement, source/core edits, dependency addition, live source integration, HTTP probing, CLI/API/UI, or production-readiness claim. No PostgreSQL, Docker, or `psql` verification is possible in current environment.
