# Standalone fresh-schema draft checks

PostgreSQL 16 target. **Not live-verified. Not an additive migration.**
`001_passive_slice.sql` is incompatible. Do not run 002 after 001, drop existing
objects, or reset a database to bypass deployment history. Use a new disposable,
empty database only. Establish deployment history before deployment.

From repository root, with PostgreSQL 16 tools installed:

```sh
createdb mirador_schema_test
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f migrations/002_passive_schema.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/01_schema_invariant_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/02_replay_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/03_transition_finding_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/04_ct_dns_behavior_tests.sql
```

Every fixture includes `helpers.sql` relative to itself, asserts results, checks
expected SQLSTATE for negative cases, forces deferred constraints, then rolls
back all test rows/functions. Unexpected success or wrong failure aborts with
nonzero psql exit status. No errors are intentionally left uncaught.

## Schema shape

`events` is shared identity registry **and canonical typed payload**, replacing
separate `dns_facts`, `ct_facts`, and `dns_errors` tables from the failed draft.
This avoids orphan/missing/mismatched evidence and JSONB replay projections.
`dns_records` retains ordered typed records and duplicates. History references
raw evidence through the exact event key; no redundant JSON reference is used.
Source timestamps remain exact opaque text, including empty strings permitted
by core. MX/NS payload strings remain raw, including empty strings. Domains,
namespaces, and event IDs cannot be empty. Brand names and certificate IDs may
be empty, matching core; they still cannot be NULL.

Composite FKs enforce DNS stream reservation before candidates, answer-only
records, history kind/success, and finding applied/status/timestamp linkage.
A deferred reverse FK requires every successful event (including NXDOMAIN and
stale DNS success) to have exactly one history row by transaction completion.
Errors cannot have success history. Insert event before history in one transaction.
`events.dns_record_count` is immutable, defaults to zero, and is bounded to
`0..2147483648` (all nonnegative INTEGER ordinals). Only DNS answers may declare
nonzero counts. Insert parent event before children. A BEFORE INSERT trigger
requires an answer parent and ordinal below its declared count; a deferred AFTER
INSERT constraint trigger requires exact child count, including zero for non-answers.
Unique nonnegative ordinals plus exact count mean no gaps or later appends after
sealing. Runtime denial of child UPDATE/DELETE remains essential; trusted owners
can bypass append-only permissions. No CHECK subqueries or cascades are used.

## Fixture coverage (defined, not runtime-proven)

- `01`: explicit u64 bounds, canonical host limits, nonempty identities, error
  before candidate, namespace/sequence reservation, ordered duplicate records,
  raw strings, empty answers, IPv4 host-only A, typed shape, MX bounds,
  non-answer rejection, empty brands/certificate IDs with NULL rejection, many brands,
  count bounds/shape/immutability, incomplete-envelope rejection at forced deferred
  checks, post-seal append rejection, rollback, restrictive deletes.
- `02`: cross-kind collision in both directions using the **same namespace**,
  case-distinct identities/certificates, repeated certificates as separate events,
  immutable envelope comparison prerequisites, C text collation, owner-session lock
  call/missing-anchor rejection, fixed SECURITY DEFINER path and PUBLIC execute denial.
- `03`: initial nullable finding from, applied/status/source-time linkage,
  invalid transitions, history errors/kinds/status, missing-history rejection,
  database-generated unique acceptance order.
- `04`: mixed/invalid DNS/CT payloads, nullable error acceptance status,
  independent CT namespaces, domain/kind mismatch, DNS certificate flag isolation.

## Not implemented or proven here

Direct duplicate INSERTs reject both exact and conflicting replay. These fixtures
do **not** claim adapter replay no-op semantics. Future adapter must lock domain,
compare every replay field and ordered record before mutation, validate input,
reuse core classification/eligibility, and atomically update candidate watermark,
CT latch, history and findings. Schema does not run a duplicate classifier or
infer prior state. Acceptance sequence is allocated by database, not source time;
per-domain locking is needed for concurrent acceptance ordering.

Runtime role creation/grants remain a deployment gate. Runtime must not own
schema or have DDL privileges; deny UPDATE/DELETE on immutable observations and
grant only narrow candidate mutation plus required sequence access. Grant runtime
EXECUTE on `public.lock_domain(text)` explicitly: PUBLIC execute is revoked.
Within one transaction, insert anchor with ON CONFLICT DO NOTHING, then call
`public.lock_domain(domain)` before replay reads or acceptance-order allocation.
The definer function locks fully qualified `public.domains` with a fixed
`pg_catalog, pg_temp` search path and fails if anchor is absent. This avoids granting
runtime UPDATE on immutable domains merely to permit SELECT FOR UPDATE. Its owner
must be trusted; do not grant runtime ownership or schema/function DDL.
Role-level denial/grant and two-session blocking/deadlock tests remain pending.
Restrictive FKs alone do not make unreferenced rows append-only. TLS is required before
nonlocal access. No live PostgreSQL execution, role, restart, replay, or
concurrency verification is claimed.
