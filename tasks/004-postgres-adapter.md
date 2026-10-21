# Task 004: PostgreSQL Adapter

## Status

**Partial: CT-only adapter merged; DNS adapter remains in review.** PR5 merged at `232c116` (implementation `13e320b`) and contains the CT-only PostgreSQL adapter. Independent Linux QA with Rust 1.91.1 recorded 43 unit tests and 9 live non-owner integration tests passing; `cargo fmt`, `cargo check`, `cargo clippy`, and release build passed.

DNS adapter work is on `alharitz/task004-dns-adapter` for PR6 (`85f69eb`). Independent source review approved it, but execution gate is incomplete: fresh QA recorded 43 unit tests and build passing, 13 database-result captures remain incomplete, Clippy was unavailable, and recovery QA is active. Worker-reported 13 passes are not independent approval. DNS status is **in review**, not merged or done.

## Scope

Implement synchronous PostgreSQL persistence using the Task 003 schema and shared observation semantics. CT adapter is complete for this milestone slice. DNS adapter remains gated on independent result capture and available lint verification. No new product scope, ORM, whole-store dump, or duplicated classifier logic.

## Verified boundaries

- Task 003 schema and fixtures are merged in `9a5b2cc`, targeting PostgreSQL 16.15. Independent local schema/fixture verification covered fixtures 01-06, runtime permissions, committed envelope sealing, and separate same/different-domain lock and rollback checks.
- PR5 CT-only adapter is merged in `232c116`; its independent Linux verification is historical and does not verify the DNS adapter.
- PR6 DNS adapter is not merged. Do not treat worker QA as independent approval.
- GitHub billing-blocked runs are historical infrastructure failures; do not claim new current CI status without checking.
- Windows Schannel failure does not negate working Linux Podman results. Production TLS, provisioning, and deployment history remain unresolved.

## Remaining work

1. Complete independent DNS QA, including all 13 database-result captures and Clippy when available.
2. Verify process-restart and transport-fault recovery behavior.
3. Establish production provisioning, TLS, and deployment history before nonlocal or production use.
4. Merge DNS adapter only after its execution gate passes; then update this status and progress records.
