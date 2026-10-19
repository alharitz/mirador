# Mirador Product Brief

## User Outcome
Security analysts receive timely, actionable alerts when lookalike domains transition from passive registration to active threat (e.g., gaining MX records, TLS certificates, or serving content) and when those threats are neutralized (takedown, loss of malicious infrastructure). Analysts can trace each alert to verifiable DNS and Certificate Transparency evidence without needing to interact with attacker infrastructure.

## Target SOC Pilot
Ideal for enterprise SOC teams monitoring high-value brands (financial, tech, government) against typosquatting and impersonation domains. Pilot focuses on automating initial detection and enrichment of ~500 candidate domains per brand with zero false positives from parked domains.

## Scope
- **Included**:
  - Permutation generation via dnstwist (external Python tool, pinned version)
  - DNS resolution (A, MX, NS) with caching and rate limiting
  - Certificate Transparency log monitoring (Static CT API, names tiles)
  - Append-only state history per domain
  - Transition-based verdict engine using YAML-scored signals (registered, MX, cert, age)
  - Domain age estimation via passive observation + optional RDAP (registry-only)
  - Mute/listing of known safe assets (corporate defensive registrations)
  - JSONL findings output and webhook notifications
  - HTTP API for frontend integration (read-only in phase 1)
  - CLI operators (migration, generate, cycle, mute, policy validation)
- **Excluded**:
  - HTTP requests to candidate domains (phase 2)
  - Frontend UI (phase 2)
  - Registrant name matching via RDAP (phase 2)
  - Multi-tenant or user authentication (phase 3)
  - Automatic takedown orchestration
  - Network-level blocking

## Implementation Direction and Next Milestone
- Rust is the active implementation direction. Go scaffold in `cmd/`, `internal/`, and `go.mod` is legacy and receives no new features; retirement is a separate decision.
- Local foundation verification is historical: `cargo test` passed on 2026-10-15 (38 tests). Task 002 in-memory passive prototype was independently verified on 2026-10-19: 38 tests passed (22 config, 16 engine), plus independent `cargo check`, `cargo fmt -- --check`, strict `cargo clippy --all-targets --all-features -- -D warnings`, `cargo build --release`, and `git diff --check`. Final independent reviewer approved the `RawEvidence` fix. This supersedes the earlier architect report of 44 passing and 1 failing. Docker build and compose runtime remain unverified.
- Next milestone is durable PostgreSQL design/adapter, not implemented. The overall phase-1 scope remains unchanged. Candidate associations, source observations, append-only history, and transition findings currently exist only in memory; no live sources, CLI wiring, API, or UI are implemented for this prototype. JSONL is explicitly deferred.

## Observation Contract
- Every distinct successful source event adds a raw, typed snapshot to history. Exact retries do not mutate state; conflicting replays are errors.
- Stable event identity is canonical domain + source namespace + event ID.
- Each candidate has one ordered DNS stream with monotonic sequence. Stale successful observations remain in history but are not applied; equal sequence with different identity is rejected.
- Errors are recorded separately and preserve source facts and status; initial error status is unknown.
- CT `observed-ever` is independent and monotonic. `Certified` has priority even with NXDOMAIN; CT evidence is not proof of validity or resolution.
- DNS baseline is silent. Initial CT `Certified` is a finding. Eligible transitions: unregistered→live and parked→mail/cert, and mail→cert. Downgrades, disappearance, unchanged state, stale observations, and errors are silent.
- Findings are typed, transition-only records. No invented score or policy.
- Candidate hostname validation accepts canonical ASCII lowercase hostnames without a trailing dot; use no homemade IDNA implementation.
- One candidate can have multiple brand associations.
- NS/IP-change and same-status MX alerts are explicitly deferred until semantics are fixed.

## Serialization and Storage Boundaries
- JSONL output requires a maintained serializer. Output is currently deferred and returns `JSONL output is unsupported without a maintained serializer`; do not add a handmade parser.
- The verified implementation is an in-memory prototype with unbounded volatile memory and timestamps retained as source strings. Hostnames are canonical lowercase ASCII only. A later durable PostgreSQL slice must preserve this contract.
- Existing `migrations/001_passive_slice.sql` is an unvalidated prototype incompatible with this contract; do not run it.

## Classifier Decisions
- An empty successful DNS answer without MX or certificate currently maps to `RegisteredParked`; this classification is not proof of benign ownership or parking content.
- Phase-1 production path must not emit `ActiveReserved`. Existing enum/classifier support is not permission to emit it.
- Current prototype CT observed-ever is independent and monotonic. `Certified` takes precedence even with NXDOMAIN or DNS failure; CT evidence does not prove certificate validity or resolution. Current prototype emits no `ActiveReserved` output.

## UX Principles
- **Alerts show change**: Only state transitions trigger findings; steady-state domains are silent.
- **Verdicts are explainable**: Every score traces to weighted signals in versioned policy.
- **Operator safety**: Zero outbound contact with attacker infrastructure in phase 1.
- **Workflow fit**: JSONL and webhook outputs match existing SIEM ingestion; CLI mirrors familiar admin tools.
- **Progressive enhancement**: Phase 1 engine is usable standalone; phase 2 adds probing and analyst disposition.

## Phases
- **Phase 1 (current)**: Passive detection engine + API. Outputs transition findings with explainable verdicts. No HTTP to candidates.
- **Phase 2**: Add HTTP prober for `active` condition, standing verdict table, analyst disposition UI, RDAP integration for registrant checks.
- **Phase 3**: Multi-tenant SaaS, automated takedown workflows, advanced correlation.

## Risks
- **Motivation decay**: Long intervals between candidate generation and first alert. Mitigated by phase-based milestones with usable output at each stage.
- **False positive flood**: Defensive registrations and partners mimicking threats. Mitigated by mandatory baseline muting and severity-aware muting.
- **Permutation explosion**: Broad brand/TLD coverage yields hundreds of thousands of candidates. Mitigated by per-cycle budgets and hot/cold tiering.
- **DNS volume egress**: Resolver rate limiting from cloud providers. Mitigated by caching, staggered scheduling, and TCP/DoH fallbacks.
- **dnstwist dependency**: Upstream changes breaking output format. Mitigated by pinning version and abstracting via `--format list` interface.

## Release Gates
**Status: Pending — not complete.** Passing local foundation tests does not establish phase-1 release readiness; Docker remains unavailable/unverified.

- **Phase 1 milestone**:
  - [ ] Dockerized Rust binary passes internal smoke test with `bca.co.id` seed.
  - [ ] JSONL output contains at least one transition finding from seeded candidate.
  - [ ] Policy YAML versioning and scorer reproducibility verified.
  - [ ] No HTTP outbound to candidate domains in test runs.
  - [ ] CLI commands (`generate`, `run`, `mute import`) execute without panic.
