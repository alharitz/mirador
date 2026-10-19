# Milestone 001: Rust Foundation

## Purpose
Transition the Mirador implementation from Go to Rust while preserving phase 1 passive boundaries and external dnstwist dependency. This milestone focuses on setting up the Rust project structure, toolchain, and dependencies without implementing core logic.

## Current Status
- **Documentation updated**: README.md, NOTES.md, Mirador.md, and Mirador v0.1.md reflect Rust selection and dnstwist external; phase-1 boundaries passive.
- **Rust project initialized**: Cargo.toml exists with correct package, version, edition.
- **Build configuration updated**: Dockerfile uses Rust base image; compose.yaml references build: . .
- **Implementation status**: Rust foundation implemented — verification passed except Docker: Rust foundation implementation complete with URL hardening complete, Docker unavailable.
  - src/main.rs is valid and compilable (more than a placeholder - includes basic CLI structure).
  - cargo check and cargo build --release succeed.
  - Docker build not verified (Docker unavailable in current environment).
  - Local foundation acceptance passed (URL-hardening verification completed); Docker acceptance remains pending.
  - Latest `cargo test` passed on 2026-10-15 (38 tests); Docker command unavailable.
  - Rust is the active implementation direction. Existing Go scaffold is legacy and receives no new features; retirement is a separate decision.
  - Phase-1 release gates remain pending, not complete (see docs/PRODUCT_BRIEF.md).

## Scope
- **Included**:
  - Rust toolchain setup (stable channel)
  - Cargo project initialization
  - Documentation updates to reflect stack change
  - Build configuration (Dockerfile, compose) updated for Rust (not yet verified)
- **Excluded**:
  - Any implementation of permutation generation, DNS probing, CT ingestion, state storage, verdict scoring, or API endpoints
  - Porting existing Go code
  - Writing unit or integration tests (not required for this milestone)
  - Creating executable binary beyond a compilable placeholder (core logic excluded)

## Acceptance Criteria
Upon completion of this milestone (when implementation begins), the following must be true:
1. Rust compiler and Cargo are installed and functional.
2. A Cargo.toml exists at the repository root defining:
     - Package name: "mirador"
     - Version: "0.1.0"
     - Edition: 2021
3. Dockerfile is updated to use a Rust base image (e.g., `rust:alpine`) and includes build steps for the binary (if Docker available).
4. compose.yaml references the built Rust image for the `app` service (configuration updated; runtime unverified).
5. Documentation files (README.md, NOTES.md, Mirador.md, Mirador v0.1.md) explicitly state:
     - Rust is the selected implementation language.
     - dnstwist remains an external Python tool (pinned version).
     - Phase 1 boundaries remain passive (no HTTP to candidate domains).
     - Old Go stack references are superseded.
6. A placeholder `src/main.rs` exists and is compilable (e.g., prints version or help).
7. Running `cargo check` succeeds.
8. Running `cargo build --release` succeeds.
9. Docker build succeeds and the service can be started via compose (pending: Docker unavailable; not required to finish local foundation checks).

## Notes
- The dnstwist dependency will be invoked as an external subprocess via `Command::new("dnstwist")`. Its version will be pinned in documentation and ensured via Dockerfile/apk or pip install in the build process.
- Phase 1 passive nature means that even in the Rust implementation, the initial probe loop will only perform DNS lookups (to resolver) and CT log fetches (public endpoints). No outbound HTTP to candidate domains will occur until phase 2.
- This milestone does not write any core logic; it prepares the foundation for subsequent milestones that will implement the phase 1 engine in Rust.
- Dependencies for core libraries will be added in subsequent milestones; this milestone focuses on project configuration only.

## Next Milestone: Passive Vertical Slice
- Implement one end-to-end slice: PostgreSQL migration, candidate persistence, DNS observation, append-only state history, transition finding, and JSONL output.
- Keep phase 1 passive: no HTTP requests to candidate domains. Broader phase-1 features are not prerequisites for this slice.
- Preserve current classifier behavior: an empty successful DNS answer without MX or certificate maps to `RegisteredParked`.
- Phase-1 production path must not emit `ActiveReserved`, even though current classifier supports it.
- CT certificate evidence is an independent signal and can coexist with NXDOMAIN. Current DNS-gated certificate classification is not the production contract; preserve CT evidence independently during integration.
- Slice completion does not complete phase-1 release gates; each gate needs separate evidence.

## References
- Rust edition 2021: https://doc.rust-lang.org/edition-guide/edition-2021.html
- Cargo.toml specification: https://doc.rust-lang.org/cargo/reference/manifest.html
- Docker multi-stage Rust builds: https://hub.docker.com/_/rust