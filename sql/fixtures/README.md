# Standalone fresh-schema draft checks

PostgreSQL 16 target. **Standalone test schema, not an additive migration.**
Schema and fixtures `01`–`06` passed locally on PostgreSQL 16.15 in a disposable
Podman container on 2026-10-20. This is not production or adapter verification.
`001_passive_slice.sql` is incompatible. Do not run 002 after 001, drop existing
objects, or reset a database to bypass deployment history. Use a new disposable,
empty database only. Establish deployment history before deployment.

From repository root, with PostgreSQL 16 tools installed and a superuser test
connection (required for disposable role creation and `SET ROLE`). Run only against
a new disposable cluster/database, never an existing database. Each `psql` command
opens a separate session; stop immediately on any failure. CI uses the same order.

```sh
set -eu
createdb mirador_schema_test
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f migrations/002_passive_schema.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/01_schema_invariant_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/02_replay_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/03_transition_finding_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/04_ct_dns_behavior_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/05_runtime_permissions_tests.sql
psql -X -v ON_ERROR_STOP=1 -d mirador_schema_test -f sql/fixtures/06_envelope_sealing_tests.sql
```

Every fixture includes `helpers.sql` relative to itself, asserts results, and checks
expected SQLSTATE for negative cases. Unexpected success or wrong failure aborts
with nonzero psql exit status. No errors are intentionally left uncaught.
Fixtures `01`–`05` force deferred constraints then roll back their rows/functions;
`05` also rolls back its test role and grants. Sequence allocation may leave gaps.
`06` deliberately **commits** populated and empty DNS envelopes as a nonowner role,
then tests mutation in a later transaction. It leaves `sealed.test` evidence intact.
Do not rerun it in that database or delete/reset evidence to rerun tests: dispose
of the test database/container and create a fresh one.

`05` and `06` require no existing domain rows and create unique
`mirador_fixture05_<backend>_<transaction>` / `mirador_fixture06_<backend>_<transaction>`
NOLOGIN roles with no elevated attributes or memberships. `06` revokes only its
role's grants using `DROP OWNED ... RESTRICT`, then drops that role; it owns no
schema objects. Helpers disappear when each session closes. On any failure,
dispose of the whole test cluster, since `06` may have committed its role/grants.
These grants are runnable test setup, **not production provisioning**.

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

## Fixture coverage (locally verified on PostgreSQL 16.15)

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
- `05`: nonowner lock EXECUTE denial before explicit grant and success afterward;
  SELECT/INSERT on required tables, column-only candidate UPDATE, identity sequence
  USAGE without reset privilege, successful invoker trigger queries; immutable
  UPDATE/DELETE/TRUNCATE, direct domain FOR UPDATE, schema CREATE, function
  replacement/ownership, superuser escalation and owner membership all denied.
- `06`: real runtime-role COMMIT seals ordered duplicate DNS records and empty
  answers; later append (`23514`), duplicate ordinal (`23505`), record UPDATE/DELETE
  and count UPDATE (`42501`) rejected. Owner count UPDATE also rejects (`23514`).
  Failed mutations preserve committed counts and duplicate payloads.

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
Role-level denial/grant is locally verified by `05`–`06`, only for their explicit
test grants. Production role provisioning remains pending. Two-session
blocking/deadlock, restart, adapter replay, and concurrency verification are not
claimed here. Restrictive FKs alone do not make unreferenced rows append-only.
TLS is required before nonlocal access. GitHub-hosted CI success is not claimed.
