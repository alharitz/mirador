# Mirador Task List

## Current State (as of 2026-10-19)
- **Documentation updated**: README.md, NOTES.md, Mirador.md, and Mirador v0.1.md reflect Rust selection and dnstwist external; phase-1 boundaries passive.
- **Rust foundation implemented — verification passed except Docker**: Cargo project initialized, Dockerfile and compose updated for Rust, src/main.rs is valid and compilable, foundation code passes fmt/clippy/tests (including repeated parallel tests) and release build, URL hardening complete, using compose.yaml, Docker unavailable.
- **Docker build unverified**: No successful build recorded (Docker unavailable).
- **Compose updated**: Configured for Rust build with intended mirador commands (run, serve).
- **Implementation direction**: Rust is active; Go scaffold in `cmd/`, `internal/`, and `go.mod` is legacy and receives no new features. Retirement remains a separate decision; no Go files are deleted here.
- **Task 002 verified (2026-10-19)**: In-memory passive prototype complete. `cargo test` passed (38 tests: 22 config, 16 engine); independent `cargo check`, `cargo fmt -- --check`, strict `cargo clippy --all-targets --all-features -- -D warnings`, `cargo build --release`, and `git diff --check` passed. Final independent reviewer approved the `RawEvidence` fix. Docker build and compose runtime remain unverified.
- **Next milestone**: Task 003 PostgreSQL schema contract/planning is ready; implementation remains pending. Broader phase-1 features follow separately. Existing `migrations/001_passive_slice.sql` is incompatible and unvalidated; establish deployment history before replacement and never run a destructive reset.
- **Prototype limits**: Canonical lowercase ASCII hostnames only, timestamps retained as source strings, unbounded volatile memory. No live sources, CLI wiring, API, or UI. JSONL explicitly deferred with `JSONL output is unsupported without a maintained serializer`.
- **Observation contract**: Successful source events append raw typed snapshots; exact retries are idempotent and conflicting replays error. Stable identity is canonical domain + source namespace + event ID. DNS observations use one monotonic sequence per candidate; stale successes remain recorded but are not applied, and equal-sequence identity conflicts are rejected. Errors preserve facts/status and start unknown. CT observed-ever is independent and monotonic; Certified wins even with NXDOMAIN and is not proof of validity/resolution. DNS baseline is silent; initial CT Certified and only approved transitions emit typed findings. Canonical ASCII lowercase hostnames without trailing dots only; no homemade IDNA. Multiple brand associations per candidate. NS/IP-change and same-status MX alerts deferred. JSONL needs maintained serializer; defer if unavailable. First stage is in-memory; PostgreSQL is later. Existing SQL is an incompatible unvalidated prototype. Classifier decisions remain: empty successful DNS answer without MX or certificate maps to `RegisteredParked`; phase-1 production path must not emit `ActiveReserved`; CT evidence remains independent of DNS.
- **Verification history**: Foundation checks recorded 38 tests passing on 2026-10-15. Task 002 verification above supersedes the earlier architect report of 44 passing and 1 failing; it does not establish phase-1 release readiness. Current prototype emits no `ActiveReserved` output.
- **Release gates**: Pending, not complete; foundation checks do not establish phase-1 release readiness.

## Milestone 003: PostgreSQL Schema Contract and Plan

**Status**: Planning ready; implementation pending. Documentation-only milestone; no executable SQL or adapter added. See [Task 003](003-postgres-schema.md) and [PostgreSQL contract](../docs/POSTGRES_CONTRACT.md).

Staged work: approve contract and establish deployment history; draft schema plus tests; run live SQL verification; then propose synchronous driver/adapter with restart and concurrency tests. PostgreSQL 16 target. No PostgreSQL, Docker, or `psql` available; no live SQL verification or production-readiness claim.

## Milestone 001: Rust Foundation
**Goal**: Establish Rust toolchain, project structure, and external dependency documentation without writing core logic.

### Acceptance Criteria
- [x] Rust toolchain (stable) installed and verified (`rustc --version`, `cargo --version`)
- [x] Cargo project initialized (`cargo init` or equivalent) in repository root
- [x] Cargo.toml exists at the repository root defining:
    - Package name: "mirador"
    - Version: "0.1.0"
    - Edition: 2021
- [x] Dockerfile updated to use Rust base image (e.g., `rust:alpine`) and includes build steps for the binary (if Docker available)
- [x] compose.yaml updated to build Rust image for the `app` service (if Docker available)
- [x] Documentation files (README.md, NOTES.md, Mirador.md, Mirador v0.1.md) explicitly state:
    - Rust is the selected implementation language.
    - dnstwist remains an external Python tool (pinned version).
    - Phase 1 boundaries remain passive (no HTTP to candidate domains).
    - Old Go stack references are superseded.
- [x] A placeholder `src/main.rs` exists and is compilable (e.g., prints version or help)
- [x] Running `cargo check` succeeds
- [x] Running `cargo build --release` succeeds
- [ ] Docker build succeeds and compose can start the service (pending: Docker unavailable; not required to finish local foundation checks)

### Verification Commands (to be run after implementation)
```sh
# Check Rust version
rustc --version
cargo --version

# Verify Cargo.toml exists
test -f Cargo.toml

# Check placeholder source
test -f src/main.rs

# Build project (check and release build)
cargo check
cargo build --release

# Run placeholder (optional)
# cargo run --release -- --help

# Validate documentation updates
grep -i "rust" README.md NOTES.md Mirador.md Mirador\\ v0.1.md | head -5
grep -i "dnstwist" README.md NOTES.md Mirador.md Mirador\\ v0.1.md | head -5
grep -i "phase.*1.*passive\|passive.*phase.*1" README.md NOTES.md Mirador.md Mirador\\ v0.1.md | head -5

# Docker verification (if Docker available)
if command -v docker &> /dev/null; then
    echo "Docker available, checking build..."
    docker build -t mirador-test .
    # Check compose file
    test -f compose.yaml
else
    echo "Docker not available, skipping Docker verification."
fi
```

### Notes
- This milestone establishes the Rust foundation with implemented code (Cargo project, src/main.rs) that passes fmt/clippy/tests and release build. Subsequent tasks will extend this foundation with core logic.
- dnstwist remains an external Python subprocess; no Rust rewrite planned.
- Phase 1 boundaries (no HTTP to candidate domains) preserved in design.
