# PostgreSQL Persistence Contract

## Status and boundaries

This is the schema-first contract for the next durable-storage milestone. It records approved invariants; it is not executable SQL and does not claim implementation or production readiness. PostgreSQL 16 is the target. No PostgreSQL, Docker, or `psql` runtime is available for this milestone.

`migrations/001_passive_slice.sql` is an unvalidated prototype and is incompatible with this contract. Establish deployment history before replacing it. Never use a destructive reset to bypass history.

The later adapter must use a synchronous PostgreSQL driver proposal, not add an ORM, dump the whole `Store`, or duplicate classifier logic. Runtime permissions are append-only. TLS must be addressed before nonlocal database access.

## Data model contract

- `domains` is the persistent lock anchor. `candidates` is separate and retains current applied state: association, successful DNS, or CT can create a candidate; error-only DNS cannot. Domain identity, namespace/sequence reservation, error evidence, and locking must work before a candidate exists.
- Every source event has exact shared identity `(domain, namespace, event_id)`. DNS and CT use the same identity space; a cross-kind collision is a conflicting replay, not a second event.
- Every accepted event retains its full immutable replay envelope, including kind and exact source timestamp string. DNS retains sequence, success/error variant, outcome, ordered typed records, and `has_certificate` when present; CT retains certificate ID. Errors also retain nullable status at acceptance. Comparison includes every field, not a lossy hash or projection. Identity and immutable text columns must use deterministic `COLLATE "C"` (or byte-exact storage); comparison must be exact and case-sensitive, not locale-normalized. Do not coerce source timestamps into database time types as the canonical value.
- DNS sequence is an unsigned-64-bit value represented with PostgreSQL `numeric(20,0)` plus an explicit `CHECK (sequence >= 0 AND sequence <= 18446744073709551615)`; the column type alone does not enforce u64 bounds. One DNS namespace is allowed per domain. `(domain, sequence)` is unique across errors, stale successes, and applied successes.
- DNS records are stored in input order with ordinals; duplicate records remain distinct. DNS `has_certificate` is source payload only and never sets CT observed state.
- CT deduplicates by event identity, not certificate ID. Each successful event has exactly one success history row with raw evidence reference, classified status, applied flag, and database acceptance order independent of source time/sequence. Errors have no success history. Reconstruct per-domain history in acceptance order; gaps in allocated order values are harmless.
- Findings have nullable `from`; only applied history transitions can create findings. Initial CT certification therefore has `from = NULL`. One event can produce at most its contractually accepted finding/history result.
- Brand associations are many-to-many and duplicate association insertion is idempotent.

## State and transaction contract

For each event, one transaction locks the domain anchor row. It then compares replay identity and immutable payload first, validates input, reserves shared identity/sequence, reuses existing classification and eligibility through a future shared helper, and atomically writes event facts, history, current state, and finding.

- Exact replay is a no-op.
- Conflicting replay fails without mutation.
- Invalid input fails without mutation.
- DNS errors preserve facts/status and do not advance watermark or create a candidate.
- Stale DNS successes remain immutable history/facts and do not roll back current state.
- CT state is monotonic; repeated evidence is idempotent.
- Rollback removes all writes from failed event processing.
- Restrictive foreign keys prevent deletion of referenced domains, events, facts, history, or findings.

Append-only event/fact/history/finding permissions must deny runtime updates/deletes of accepted observations; runtime role must not own schema or have DDL privileges. Narrow mutable permissions are needed for candidate current state inside event transactions. Restrictive foreign keys must not cascade deletes.

Schema shape checks must reject mixed DNS/CT fields, invalid status/outcome variants, out-of-range sequence/MX preference, non-IPv4 A records, records on non-answer outcomes, and mismatched event/evidence/history domains or kinds. Preserve empty answers and raw MX/NS strings without introducing normalization absent from core. Enforce one success history per successful event and finding linkage to applied history; tests must prove these constraints rather than rely only on adapter validation.

## Planned verification

Exact schema tests must cover: DNS/CT identity cross-kind collision; full u64 maximum, negative and overflow rejection; case-distinct source identities/payloads; repeated certificate IDs as distinct events; error-before-candidate; ordered duplicate DNS records; many brands; initial CT nullable `from`; shape checks; transaction rollback; and restrictive delete behavior.

Source timestamps are opaque strings: they do not establish chronological order, timezone validity, or duration and cannot drive watermark or acceptance ordering. Canonical lowercase ASCII hostname limits, nonempty namespace/event ID, no homemade IDNA, and passive-only operation remain unchanged. Reuse `DomainStatus::classify_observation` and `eligible` semantics through a future shared helper: empty DNS answer is `RegisteredParked`, DNS baseline is silent, initial CT emits `Certified`, and only approved upward transitions emit findings. CT wins even with NXDOMAIN, but proves neither validity nor resolution. `ActiveReserved` must not be introduced. NS/IP-change and same-status MX alerts remain deferred.

## Staged work

1. **Task 003 planning gate:** approve this contract and deployment-history approach.
2. **Schema draft plus tests:** create the PostgreSQL 16 schema and exact invariant tests only after the gate; no adapter yet.
3. **Live SQL verification:** run schema/test checks when PostgreSQL, Docker, or `psql` is available.
4. **Adapter:** propose and implement synchronous driver integration, then restart/replay/concurrency tests.

No success claim or production-readiness claim is made here. Task 003 planning is ready; implementation remains pending.
