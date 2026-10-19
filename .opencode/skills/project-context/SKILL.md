---
name: Project Context
description: Verified conventions and commands for Mirador repository
---

# Project context

## Stack
- Rust package `mirador`, version `0.1.0`, edition 2021.
- PostgreSQL is the planned durable store.
- dnstwist is an external Python tool pinned in `Dockerfile`.
- Legacy Go scaffold remains in `cmd/`, `internal/`, and `go.mod`; Rust is the current implementation direction.

## Commands
- Test: `cargo test`
- Check: `cargo check`
- Format check: `cargo fmt -- --check`
- Lint: `cargo clippy --all-targets --all-features -- -D warnings`
- Release build: `cargo build --release`
- Docker verification: unavailable unless Docker is installed.

## Structure
- `src/main.rs`: Rust CLI entry point and current configuration validation.
- `src/core/`: Rust DNS and domain-status types.
- `docs/`: product brief.
- `tasks/`: milestone and verification tracking.
- `Dockerfile`, `compose.yaml`: container and PostgreSQL development deployment.

## Rules
- Phase 1 is passive: no HTTP requests to candidate domains.
- Preserve append-only state history and explainable, versioned policy direction.
- Keep changes scoped; do not add dependencies without approval.
- Verify with Cargo checks before reporting completion.
