# PostgreSQL Persistence Contract

## Status and boundaries

This is the schema-first contract for the next durable-storage milestone. It records approved invariants; it is not executable SQL. PostgreSQL 16 is the target. The standalone fresh-schema draft (`migrations/002_passive_schema.sql`) and invariant fixtures (`sql/fixtures/`) were merged with Task 003 in `9a5b2cc`, including domain-locking and DNS envelope-sealing hardening. On 2026-10-20, local Podman PostgreSQL 16.15 independently ran the standalone schema and fixtures 01-06 successfully. Verification used a fresh database only; `001_passive_slice.sql` was not run. Task 003 schema scope is complete, but deployment and production gates remain open. CT-only PostgreSQL adapter work merged in `232c116`; DNS adapter remains in review. GitHub CI remains billing-blocked.

`migrations/001_passive_slice.sql` is an unvalidated prototype and is incompatible with this contract. Establish deployment history before replacing it. Never use a destructive reset to bypass history.

The later adapter must use a synchronous PostgreSQL driver proposal, not add an ORM, dump the whole `Store`, or duplicate classifier logic. Runtime permissions are append-only. TLS must be addressed before nonlocal database access.

## Data model contract

- `domains` is the persistent lock anchor. `candidates` is separate and retains current applied state: association, successful DNS, or CT can create a candidate; error-only DNS cannot. Domain identity, namespace/sequence reservation, error evidence, and locking must work before a candidate exists.
- Every source event has exact shared identity `(domain, namespace, event_id)`. DNS and CT use the same identity space; a cross-kind collision is a conflicting replay, not a second event.
- Every accepted event retains its full immutable replay envelope, including kind and exact source timestamp string. DNS retains sequence, success/error variant, outcome, ordered typed records, and `has_certificate` when present; CT retains certificate ID. Errors also retain nullable status at acceptance. Comparison includes every field, not a lossy hash or projection. Identity and immutable text columns must use deterministic `COLLATE "C"` (or byte-exact storage); comparison must be exact and case-sensitive, not locale-normalized. Do not coerce source timestamps into database time types as the canonical value.
- DNS sequence is an unsigned-64-bit value represented with unconstrained PostgreSQL `NUMERIC`, not `NUMERIC(20,0)`, which can round fractional inputs before a check. Both `events.sequence` and `candidates.dns_sequence` require exact integral values and u64 bounds: `CHECK (sequence IS NULL OR (sequence = trunc(sequence) AND sequence >= 0 AND sequence <= 18446744073709551615))` (substitute `dns_sequence` for the candidate column). Event shape checks require a sequence for DNS and forbid it for CT; candidate watermark may be NULL. One DNS namespace is allowed per domain. `(domain, sequence)` is unique across errors, stale successes, and applied successes.
- DNS records are stored in input order with ordinals; duplicate records remain distinct. Immutable `events.dns_record_count` declares final record count, defaults to zero, and is bounded to `0..2147483648`, matching nonnegative INTEGER ordinal capacity. Only DNS answers may declare nonzero counts. A BEFORE INSERT child trigger requires an existing answer parent and ordinal below count. A deferred AFTER INSERT event constraint trigger verifies exact child count at transaction completion, including zero for non-answers. Unique bounded nonnegative ordinals then require contiguous `0..count-1` and prevent later appends, including to empty answers. Insert parent before children in one transaction; forcing constraints immediate seals only complete envelopes. Child UPDATE/DELETE denial is still required; trusted owners are outside runtime guarantees. DNS `has_certificate` is source payload only and never sets CT observed state.
- CT deduplicates by event identity, not certificate ID. Each successful event has exactly one success history row with raw evidence reference, classified status, applied flag, and database acceptance order independent of source time/sequence. Errors have no success history. Reconstruct per-domain history in acceptance order; gaps in allocated order values are harmless.
- Findings have nullable `from`; only applied history transitions can create findings. Initial CT certification therefore has `from = NULL`. One event can produce at most its contractually accepted finding/history result.
- Brand associations are many-to-many and duplicate association insertion is idempotent. Brand and certificate ID strings may be empty, matching core; NOT NULL/CT payload presence checks remain.

## State and transaction contract

For each event, one transaction inserts the domain anchor with ON CONFLICT DO NOTHING, then calls `public.lock_domain(text)` before replay reads or acceptance-order allocation. This SECURITY DEFINER function uses fixed `search_path = pg_catalog, pg_temp`, locks fully qualified `public.domains` with SELECT FOR UPDATE, and fails on missing anchor. PUBLIC execute is revoked; deployment must explicitly grant runtime EXECUTE without granting UPDATE on immutable domains. Function owner must be trusted and runtime must not own or replace it. Lock lasts until transaction end; concurrent same-domain transactions must serialize. Different-domain locks remain independent. Runtime grant/denial verification passed with a non-owner runtime role. Separate same-domain and different-domain two-session checks, including explicit COMMIT/ROLLBACK bounded-concurrency cases, passed on 2026-10-20; owner-session fixtures alone would not prove them.

After locking, compare replay identity and immutable payload (including count and ordered children) first, validate input, reserve shared identity/sequence, reuse existing classification and eligibility through a future shared helper, and atomically write event facts, history, current state, and finding.

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

Exact schema tests must cover: DNS/CT identity cross-kind collision; full u64 maximum, negative, fractional and overflow rejection; case-distinct source identities/payloads; repeated certificate IDs as distinct events; error-before-candidate; ordered duplicate DNS records; many brands; initial CT nullable `from`; shape checks; transaction rollback; and restrictive delete behavior.

Source timestamps are opaque strings: they do not establish chronological order, timezone validity, or duration and cannot drive watermark or acceptance ordering. Canonical lowercase ASCII hostname limits, nonempty namespace/event ID, no homemade IDNA, and passive-only operation remain unchanged. Reuse `DomainStatus::classify_observation` and `eligible` semantics through a future shared helper: empty DNS answer is `RegisteredParked`, DNS baseline is silent, initial CT emits `Certified`, and only approved upward transitions emit findings. CT wins even with NXDOMAIN, but proves neither validity nor resolution. `ActiveReserved` must not be introduced. NS/IP-change and same-status MX alerts remain deferred.

## Staged work

1. **Planning/deployment gate:** contract recorded; establish deployment history before any deployment or replacement of the incompatible prototype.
2. **Schema draft plus tests:** standalone PostgreSQL 16 draft and fixtures are merged, including domain-lock and DNS-count sealing hardening; CT-only adapter work is also merged, while DNS adapter work remains in review. The draft is not an additive migration and must never run after `001_passive_slice.sql`. Use only a new disposable, empty database for verification; never reset existing data to bypass deployment history.
3. **Live SQL verification (completed for schema milestone):** on 2026-10-20, local Podman PostgreSQL 16.15 ran the standalone schema and fixtures 01–06 successfully in a fresh database. Non-owner runtime permission checks, envelope sealing, and separate same/different-domain bounded-concurrency checks with explicit COMMIT/ROLLBACK passed. GitHub workflow attempts remain billing-blocked; no claim depends on those runs.
4. **Adapter/deployment gates (pending):** propose synchronous driver integration, implement shared classifier/eligibility reuse and transaction semantics, then verify restart/replay/concurrency behavior. Runtime-role grants and TLS before nonlocal access remain required; restrictive foreign keys alone do not establish append-only permissions.

Task 003 schema scope is complete. Deployment and production gates remain open; local schema/fixture SQL success is claimed only for fresh-db verification on PostgreSQL 16.15, not adapter behavior or deployment readiness.
