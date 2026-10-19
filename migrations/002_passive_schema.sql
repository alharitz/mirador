-- Migration 002: Passive PostgreSQL Schema for Mirador
-- PostgreSQL 16 target. Implements POSTGRES_CONTRACT.md invariants.
-- This migration ADDs to history; never destructively resets 001_passive_slice.sql.

-- Deterministic C collation for identity and immutable text columns
-- Ensures exact, case-sensitive, byte-exact comparison

-- Domain lock anchor: persistent, created on first event for a domain
CREATE TABLE domains (
    domain TEXT COLLATE "C" PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Brand associations: many-to-many, duplicate insertion is idempotent
CREATE TABLE brands (
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains(domain) ON DELETE RESTRICT,
    brand TEXT COLLATE "C" NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, brand)
);

-- Candidates: current applied state (separate from domain anchor)
-- Created when DNS success or CT event occurs; errors do not create candidates
CREATE TABLE candidates (
    domain TEXT COLLATE "C" PRIMARY KEY REFERENCES domains(domain) ON DELETE RESTRICT,
    status TEXT COLLATE "C" NOT NULL,
    dns_namespace TEXT COLLATE "C",          -- one DNS namespace per domain
    dns_sequence NUMERIC(20,0),              -- u64 watermark; NULL when no success yet
    ct_observed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT candidates_status_check CHECK (status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    CONSTRAINT candidates_dns_sequence_u64 CHECK (
        dns_sequence IS NULL OR (dns_sequence >= 0 AND dns_sequence <= 18446744073709551615)
    )
);

-- Event identity registry: shared across DNS and CT
-- Exact identity: (domain, namespace, event_id). Cross-kind collision = conflicting replay.
-- Full immutable replay envelope preserved including kind and source timestamp string.
CREATE TABLE events (
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains(domain) ON DELETE RESTRICT,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    kind TEXT COLLATE "C" NOT NULL,                      -- 'dns' or 'ct'
    sequence NUMERIC(20,0),                              -- DNS only; NULL for CT
    observed_at TEXT COLLATE "C" NOT NULL,               -- opaque source timestamp string
    raw_payload JSONB NOT NULL,                          -- full immutable replay envelope
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT events_kind_check CHECK (kind IN ('dns', 'ct')),
    CONSTRAINT events_sequence_u64 CHECK (
        sequence IS NULL OR (sequence >= 0 AND sequence <= 18446744073709551615)
    )
);

-- DNS sequence uniqueness across errors, stale successes, and applied successes
-- One DNS namespace per domain is enforced by candidate.dns_namespace + this index
CREATE UNIQUE INDEX events_dns_sequence_unique
    ON events (domain, sequence)
    WHERE kind = 'dns';

-- DNS facts: detailed DNS observation data
-- Preserves full immutable payload: outcome, has_certificate, and ordered records
CREATE TABLE dns_facts (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    outcome TEXT COLLATE "C" NOT NULL,                   -- 'nxdomain', 'answer', 'servfail', 'timeout'
    has_certificate BOOLEAN NOT NULL DEFAULT FALSE,      -- source payload only; not a CT latch
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT dns_facts_outcome_check CHECK (outcome IN ('nxdomain', 'answer', 'servfail', 'timeout')),
    CONSTRAINT dns_facts_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT
);

-- DNS records: ordered with ordinals, duplicates remain distinct
-- Empty answers preserved (zero rows). Raw MX/NS strings kept without normalization.
CREATE TABLE dns_records (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    ordinal INT NOT NULL,                                -- input order, 0-based
    record_type TEXT COLLATE "C" NOT NULL,               -- 'A', 'MX', 'NS'
    value_a INET,                                        -- A record: IPv4 address
    value_mx_pref INT,                                   -- MX record: preference (0..65535)
    value_mx_exchange TEXT COLLATE "C",                  -- MX record: exchange hostname
    value_ns TEXT COLLATE "C",                           -- NS record: nameserver hostname
    PRIMARY KEY (domain, namespace, event_id, ordinal),
    CONSTRAINT dns_records_type_check CHECK (record_type IN ('A', 'MX', 'NS')),
    CONSTRAINT dns_records_mx_pref_check CHECK (
        value_mx_pref IS NULL OR (value_mx_pref >= 0 AND value_mx_pref <= 65535)
    ),
    CONSTRAINT dns_records_a_check CHECK (
        record_type != 'A' OR value_a IS NOT NULL
    ),
    CONSTRAINT dns_records_mx_check CHECK (
        record_type != 'MX' OR (value_mx_pref IS NOT NULL AND value_mx_exchange IS NOT NULL)
    ),
    CONSTRAINT dns_records_ns_check CHECK (
        record_type != 'NS' OR value_ns IS NOT NULL
    ),
    CONSTRAINT dns_records_answer_only_check CHECK (
        -- records only allowed on 'answer' outcome
        NOT EXISTS (
            SELECT 1 FROM dns_facts df
            WHERE df.domain = dns_records.domain
              AND df.namespace = dns_records.namespace
              AND df.event_id = dns_records.event_id
              AND df.outcome != 'answer'
        )
    ),
    CONSTRAINT dns_records_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT
);

-- CT facts: certificate transparency evidence
-- Deduplicates by event identity (domain, namespace, event_id), NOT by certificate_id
CREATE TABLE ct_facts (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    certificate_id TEXT COLLATE "C" NOT NULL,
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT ct_facts_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT
);

-- Success history: one row per successful event (DNS success or CT)
-- Raw evidence reference, classified status, applied flag, database acceptance order
CREATE TABLE success_history (
    id BIGSERIAL PRIMARY KEY,
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains(domain) ON DELETE RESTRICT,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    kind TEXT COLLATE "C" NOT NULL,                      -- 'dns' or 'ct'
    status TEXT COLLATE "C" NOT NULL,                    -- classified status
    applied BOOLEAN NOT NULL,                            -- whether this advanced candidate state
    acceptance_order BIGINT NOT NULL UNIQUE,             -- database acceptance order (gaps harmless)
    raw_evidence_ref JSONB NOT NULL,                     -- reference to raw evidence
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT success_history_kind_check CHECK (kind IN ('dns', 'ct')),
    CONSTRAINT success_history_status_check CHECK (status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    CONSTRAINT success_history_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT,
    -- One success history row per successful event
    CONSTRAINT success_history_one_per_event UNIQUE (domain, namespace, event_id)
);

-- Sequence for acceptance_order (monotonic, gaps harmless)
CREATE SEQUENCE success_history_acceptance_order_seq;

-- DNS errors: preserve facts/status; do not advance watermark or create candidate
-- Errors have NO success_history row
CREATE TABLE dns_errors (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    sequence NUMERIC(20,0) NOT NULL,
    outcome TEXT COLLATE "C" NOT NULL,                   -- 'servfail', 'timeout'
    status_at_event TEXT COLLATE "C",                    -- candidate status at error time (nullable)
    observed_at TEXT COLLATE "C" NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT dns_errors_outcome_check CHECK (outcome IN ('servfail', 'timeout')),
    CONSTRAINT dns_errors_sequence_u64 CHECK (
        sequence >= 0 AND sequence <= 18446744073709551615
    ),
    CONSTRAINT dns_errors_status_check CHECK (
        status_at_event IS NULL OR status_at_event IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')
    ),
    CONSTRAINT dns_errors_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT
);

-- Findings: nullable from; only applied history transitions create findings
-- Initial CT certification has from = NULL
CREATE TABLE findings (
    id BIGSERIAL PRIMARY KEY,
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains(domain) ON DELETE RESTRICT,
    from_status TEXT COLLATE "C",                        -- nullable
    to_status TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    observed_at TEXT COLLATE "C" NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT findings_from_check CHECK (
        from_status IS NULL OR from_status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')
    ),
    CONSTRAINT findings_to_check CHECK (to_status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    CONSTRAINT findings_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT,
    -- Eligible transitions only (matching DomainStatus::eligible)
    CONSTRAINT findings_transition_check CHECK (
        (from_status IS NULL AND to_status = 'Certified') OR
        (from_status = 'Unregistered' AND to_status IN ('RegisteredParked', 'MailReady', 'Certified')) OR
        (from_status = 'RegisteredParked' AND to_status IN ('MailReady', 'Certified')) OR
        (from_status = 'MailReady' AND to_status = 'Certified')
    )
);

-- CT evidence log: mirrors ct_facts + events for reference; deduplicated by event identity
CREATE TABLE ct_evidence_log (
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains(domain) ON DELETE RESTRICT,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    certificate_id TEXT COLLATE "C" NOT NULL,
    observed_at TEXT COLLATE "C" NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT ct_evidence_log_event_fk FOREIGN KEY (domain, namespace, event_id)
        REFERENCES events(domain, namespace, event_id) ON DELETE RESTRICT
);

-- Helpful indexes for common query patterns
CREATE INDEX idx_candidates_dns_namespace ON candidates(dns_namespace) WHERE dns_namespace IS NOT NULL;
CREATE INDEX idx_success_history_domain_order ON success_history(domain, acceptance_order);
CREATE INDEX idx_findings_domain ON findings(domain);
CREATE INDEX idx_dns_errors_domain_sequence ON dns_errors(domain, sequence);
CREATE INDEX idx_events_kind ON events(kind);
CREATE INDEX idx_dns_facts_outcome ON dns_facts(outcome);

-- Restrictive foreign keys: ON DELETE RESTRICT prevents deletion of referenced rows
-- No cascades. Runtime role must not own schema or have DDL privileges.
-- Append-only permissions for event/fact/history/finding tables to be granted separately.

-- End of migration 002