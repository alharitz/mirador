# SQL Test Fixtures

These fixtures verify the PostgreSQL schema invariants from `POSTGRES_CONTRACT.md`.

## Files

| File | Purpose |
|------|---------|
| `01_schema_invariant_tests.sql` | Core schema invariants: identity collision, u64 bounds, C collation, repeated certs, error-before-candidate, duplicate records, many brands, nullable from, shape checks, rollback, restrictive deletes, namespace/sequence uniqueness, empty answers, raw strings |
| `02_replay_tests.sql` | Exact replay (no-op) vs conflicting replay (fail without mutation) for DNS and CT |
| `03_transition_finding_tests.sql` | State transitions and findings: baseline silent, CT initial finding, eligible transitions only, stale/error no findings |
| `04_ct_dns_behavior_tests.sql` | CT monotonic, CT wins with NXDOMAIN, DNS watermark, CT namespaces independent |

## Running Tests

Requires PostgreSQL 16. No live runtime available in current environment.

```bash
# Create test database
createdb mirador_test

# Run migrations
psql -d mirador_test -f ../../migrations/001_passive_slice.sql
psql -d mirador_test -f ../../migrations/002_passive_schema.sql

# Run test fixtures (each runs in its own transaction, rolls back on constraint violation)
psql -d mirador_test -f 01_schema_invariant_tests.sql
psql -d mirador_test -f 02_replay_tests.sql
psql -d mirador_test -f 03_transition_finding_tests.sql
psql -d mirador_test -f 04_ct_dns_behavior_tests.sql
```

## Expected Behavior

- Each test uses `BEGIN` / `ROLLBACK` for constraint violations
- Valid operations use `COMMIT`
- Output shows `ROLLBACK` for expected failures, `COMMIT` for successes
- Final `SELECT` statements verify state

## Contract Coverage

These fixtures cover all required checks from `POSTGRES_CONTRACT.md` § "Planned verification":

- [x] DNS/CT identity cross-kind collision
- [x] Full u64 maximum, negative and overflow rejection
- [x] Case-distinct source identities/payloads
- [x] Repeated certificate IDs as distinct events
- [x] Error-before-candidate
- [x] Ordered duplicate DNS records
- [x] Many brands
- [x] Initial CT nullable `from`
- [x] Schema shape checks (mixed fields, invalid variants, out-of-range, non-IPv4 A, records on non-answer, mismatched domains/kinds)
- [x] Transaction rollback
- [x] Restrictive delete behavior

Plus additional behavioral tests:
- Exact replay no-op / conflicting replay fails
- DNS baseline silent / CT initial finding
- Eligible transitions only (per `DomainStatus::eligible`)
- Stale/error observations emit no findings
- CT monotonic / CT wins with NXDOMAIN
- DNS watermark advances only on applied success
- CT namespaces independent of DNS namespace