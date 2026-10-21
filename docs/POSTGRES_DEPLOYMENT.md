# PostgreSQL deployment gate

**Status: blocked pending human decisions and evidence.** Non-executable review
runbook; not permission to deploy. No deployment, restore, role provisioning,
TLS connection, or adapter recovery is verified by this document.

Use with [persistence contract](POSTGRES_CONTRACT.md),
[Task 003](../tasks/003-postgres-schema.md), and
[fixture boundaries](../sql/fixtures/README.md). Historical fresh-database SQL
checks do not establish deployment readiness. Stop at any failed or unknown gate.
Record approver, date, evidence reference, and unresolved items for each gate;
never place credentials, connection secrets, or private keys in these records.

## 1. Deployment-history intake

- Human database owner identifies every environment, database/cluster identity,
  data owner, current application revision, PostgreSQL version, and retention needs.
  Inventory actual schema objects, migration records, deployment logs, owners and
  effective grants; filenames alone do not prove which SQL ran.
- Record whether `001_passive_slice.sql`, `002_passive_schema.sql`, modified copies,
  or manual DDL ever ran, including partial/failed attempts. Record applied artifact
  checksums and compare against reviewed repository versions. Missing history,
  checksum mismatch, unexpected objects, or uncertain data provenance blocks work.
- `001` is incompatible and unvalidated. `002` is a standalone fresh-schema draft,
  **not an upgrade from 001**. Never run both in sequence, drop/truncate existing
  objects, delete volumes, or reset existing data to bypass this gate.
- Human decision: if any existing schema/data exists, preserve it and commission a
  separately reviewed, data-preserving migration/reconciliation plan. This runbook
  supplies no conversion, replacement approval, or destructive rollback path.

## 2. Backup and recovery approval

- Before any approved change to an existing environment, database owner records
  consistent backup scope (data, schema, role/grant metadata, required recovery
  configuration), secure storage/access, retention, and recovery point/time goals.
- Prove restoration into a separate isolated target. Validate evidence/history,
  ordered DNS payloads, current state, findings, constraints, ownership and grants;
  record restore result and recovery time. Backup existence alone is insufficient.
- Human recovery owner approves failure triggers, writer quiescence, cutover and
  reconciliation of post-backup events. Preserve original database and evidence.
  Do not overwrite the source, silently discard accepted events, or use a reset as
  rollback. Missing restore proof or unresolved data-loss risk blocks change.

## 3. Standalone 002 approval and artifact identity

- Only a separately created, verified empty database may receive standalone 002.
  Human database owner must explicitly approve target identity, emptiness evidence,
  isolation and intended use. An emptied existing database is not a fresh target.
  Fresh verification approval is not approval for production cutover.
- Record reviewed Git commit, SHA-256 checksums of schema and fixture artifacts,
  exact PostgreSQL server/client versions, and application/driver versions when
  selected. PostgreSQL 16 is the contract target; historical 16.15 checks are not
  evidence for another version or artifact. Drift requires review and recheck.
- Run fixtures only in a separate disposable verification environment under their
  documented boundaries, never a live target. Fixtures 05/06 create test roles;
  06 commits evidence. Test grants are not production provisioning. Attach actual
  check outcomes; blocked CI or prior local success is not a new passing result.

## 4. Separate migration owner and runtime role

- Human security/database owners approve a provisioning plan distinct from fixture
  setup. Trusted migration owner owns schema objects/functions; application runtime
  is a separate non-owner, non-superuser role with no owner membership or ability
  to assume owner privileges, create roles/databases, bypass RLS, or perform DDL.
- Approve only required connection/schema usage; SELECT/INSERT on `domains`,
  `dns_streams`, `candidates`, `brands`, `events`, `dns_records`, `success_history`,
  and `findings`; candidate UPDATE only on `status`, `dns_namespace`, `dns_sequence`,
  `ct_observed`; USAGE only on `success_history_acceptance_order_seq`.
  Deny immutable UPDATE/DELETE, all runtime DELETE/TRUNCATE, identity/domain edits,
  and sequence reset. Audit inherited and PUBLIC grants, not only direct grants.
- `public.lock_domain(text)` must remain SECURITY DEFINER, owned by a trusted
  non-runtime owner with required locking rights, with fixed
  `search_path = pg_catalog, pg_temp` and fully qualified `public.domains` access.
  PUBLIC EXECUTE stays revoked; explicitly grant runtime EXECUTE. Runtime cannot
  replace/own function or create objects in its schema. Do not grant domain UPDATE
  merely to enable direct row locking.
- Verify effective denials and successful event transactions as the actual runtime
  role, including invoker-trigger reads and deferred constraints at commit.
  Restrictive foreign keys do not establish append-only permissions.

## 5. Network and TLS gate

- Before nonlocal access, human security owner approves server/client TLS settings,
  trust roots, endpoint hostname and certificate lifecycle. Verify both certificate
  chain and hostname with the selected driver, and prove untrusted-chain,
  wrong-hostname and plaintext connections fail. Encryption without peer identity
  verification is insufficient; no insecure fallback or plaintext retry.
- Loopback-only development is a separate, explicitly approved boundary, not TLS
  proof. Current Compose host mapping `5432:5432` does not restrict exposure to
  loopback; `.env.example` uses `sslmode=disable`. Neither is a deployment template.
  Container service name `db` is not host loopback. Require separately reviewed
  binding/firewall and transport configuration before use beyond isolated local
  development; this document changes neither file.

## 6. Adapter, restart and replay acceptance

- Adapter/driver integration and deployment recovery evidence remain open gates.
  Verify one transaction locks domain before replay reads/acceptance allocation,
  compares full immutable payload including ordered duplicate records/counts, and
  atomically writes facts, history, candidate state and findings using shared core
  semantics. Source timestamp strings are opaque, not ordering clocks.
- Prove exact replay after process/database restart is a no-op; conflicting payload
  or cross-kind identity replay fails without mutation. Prove stale/error handling,
  monotonic CT, same-domain serialization, different-domain progress, rollback and
  committed-envelope sealing using the actual adapter and runtime role.
- Test disconnect/crash before commit and loss of commit acknowledgement. An
  ambiguous commit is **unknown**, not a failed write. Reconnect and resolve using
  the same `(domain, namespace, event_id)` and complete immutable payload under
  normal locking/replay rules. Do not allocate a new identity/sequence or blindly
  emit another finding. Unresolvable ambiguity stops acceptance for affected work
  and escalates to the human recovery owner; retain source event for reconciliation.
- Human release/recovery owners approve recorded results and remaining risks before
  any cutover. Unknown deployment history, restore proof, production grants, TLS,
  adapter behavior, or ambiguous-commit recovery keeps deployment blocked.
