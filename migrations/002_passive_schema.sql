-- STANDALONE FRESH-SCHEMA DRAFT, PostgreSQL 16. NOT an additive migration.
-- Names collide with incompatible 001_passive_slice.sql. Never run after 001.
-- No destructive reset. Establish deployment history before any replacement.
-- Live PostgreSQL verification, runtime-role grants, and adapter remain pending.
BEGIN;

CREATE TABLE domains (
    domain TEXT COLLATE "C" PRIMARY KEY,
    CHECK (octet_length(domain) BETWEEN 1 AND 253),
    CHECK (domain ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$')
);

CREATE FUNCTION public.lock_domain(p_domain TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM 1 FROM public.domains WHERE domain = p_domain FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'domain does not exist: %', p_domain; END IF;
END $$;
REVOKE ALL ON FUNCTION public.lock_domain(TEXT) FROM PUBLIC;

-- Lock domains first; reserve this stream even for errors before a candidate exists.
CREATE TABLE dns_streams (
    domain TEXT COLLATE "C" PRIMARY KEY REFERENCES domains ON DELETE RESTRICT,
    namespace TEXT COLLATE "C" NOT NULL CHECK (namespace <> ''),
    UNIQUE (domain, namespace)
);

CREATE TABLE candidates (
    domain TEXT COLLATE "C" PRIMARY KEY REFERENCES domains ON DELETE RESTRICT,
    status TEXT COLLATE "C" CHECK (status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    dns_namespace TEXT COLLATE "C",
    dns_sequence NUMERIC CHECK (dns_sequence IS NULL OR (dns_sequence = trunc(dns_sequence) AND dns_sequence >= 0 AND dns_sequence <= 18446744073709551615)),
    ct_observed BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (dns_sequence IS NULL OR dns_namespace IS NOT NULL),
    FOREIGN KEY (domain, dns_namespace) REFERENCES dns_streams(domain, namespace) ON DELETE RESTRICT
);

-- Duplicate association insertion uses ON CONFLICT (domain, brand) DO NOTHING.
CREATE TABLE brands (
    domain TEXT COLLATE "C" NOT NULL REFERENCES candidates ON DELETE RESTRICT,
    brand TEXT COLLATE "C" NOT NULL,
    PRIMARY KEY (domain, brand)
);

-- Canonical replay envelope: typed scalar fields here, ordered DNS records below.
-- No JSONB projection/hash: compare every field and ordered record, including NULLs.
-- observed_at is exact opaque source text, not a timestamp or acceptance order.
-- Facts formerly split into dns_facts/ct_facts/dns_errors now live in this one row,
-- preventing missing/mismatched payload rows and retaining error status before candidates.
CREATE TABLE events (
    domain TEXT COLLATE "C" NOT NULL REFERENCES domains ON DELETE RESTRICT,
    namespace TEXT COLLATE "C" NOT NULL CHECK (namespace <> ''),
    event_id TEXT COLLATE "C" NOT NULL CHECK (event_id <> ''),
    kind TEXT COLLATE "C" NOT NULL CHECK (kind IN ('dns', 'ct')),
    observed_at TEXT COLLATE "C" NOT NULL,
    sequence NUMERIC CHECK (sequence IS NULL OR (sequence = trunc(sequence) AND sequence >= 0 AND sequence <= 18446744073709551615)),
    outcome TEXT COLLATE "C",
    dns_record_count BIGINT NOT NULL DEFAULT 0 CHECK (dns_record_count BETWEEN 0 AND 2147483648),
    has_certificate BOOLEAN,
    certificate_id TEXT COLLATE "C",
    status_at_event TEXT COLLATE "C" CHECK (status_at_event IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    dns_namespace TEXT COLLATE "C" GENERATED ALWAYS AS (CASE WHEN kind = 'dns' THEN namespace END) STORED,
    successful BOOLEAN GENERATED ALWAYS AS (kind = 'ct' OR outcome IN ('answer', 'nxdomain')) STORED,
    success_event_id TEXT COLLATE "C" GENERATED ALWAYS AS (
        CASE WHEN kind = 'ct' OR outcome IN ('answer', 'nxdomain') THEN event_id END
    ) STORED,
    PRIMARY KEY (domain, namespace, event_id),
    CONSTRAINT events_payload_shape CHECK (
        (kind = 'ct' AND sequence IS NULL AND outcome IS NULL AND has_certificate IS NULL
            AND certificate_id IS NOT NULL AND status_at_event IS NULL)
        OR
        (kind = 'dns' AND sequence IS NOT NULL AND certificate_id IS NULL AND outcome IS NOT NULL AND (
            (outcome IN ('answer', 'nxdomain') AND has_certificate IS NOT NULL AND status_at_event IS NULL)
            OR (outcome IN ('servfail', 'timeout') AND has_certificate IS NULL)
        ))
    ),
    CHECK ((kind = 'dns' AND outcome = 'answer') OR dns_record_count = 0),
    FOREIGN KEY (domain, dns_namespace) REFERENCES dns_streams(domain, namespace) ON DELETE RESTRICT,
    UNIQUE (domain, sequence),
    UNIQUE (domain, namespace, event_id, outcome),
    UNIQUE (domain, namespace, event_id, kind, successful),
    UNIQUE (domain, namespace, event_id, observed_at)
);

-- Ordinal preserves input order and duplicates; zero rows preserves empty answers.
-- Raw MX/NS strings deliberately permit empty/mixed-case/trailing-dot values as core does.
CREATE TABLE dns_records (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    outcome TEXT COLLATE "C" NOT NULL DEFAULT 'answer' CHECK (outcome = 'answer'),
    record_type TEXT COLLATE "C" NOT NULL CHECK (record_type IN ('A', 'MX', 'NS')),
    value_a INET,
    value_mx_pref INTEGER CHECK (value_mx_pref BETWEEN 0 AND 65535),
    value_mx_exchange TEXT COLLATE "C",
    value_ns TEXT COLLATE "C",
    PRIMARY KEY (domain, namespace, event_id, ordinal),
    CONSTRAINT dns_records_shape CHECK (
        (record_type = 'A' AND value_a IS NOT NULL AND family(value_a) = 4 AND masklen(value_a) = 32
            AND value_mx_pref IS NULL AND value_mx_exchange IS NULL AND value_ns IS NULL)
        OR (record_type = 'MX' AND value_a IS NULL AND value_mx_pref IS NOT NULL
            AND value_mx_exchange IS NOT NULL AND value_ns IS NULL)
        OR (record_type = 'NS' AND value_a IS NULL AND value_mx_pref IS NULL
            AND value_mx_exchange IS NULL AND value_ns IS NOT NULL)
    ),
    FOREIGN KEY (domain, namespace, event_id, outcome)
        REFERENCES events(domain, namespace, event_id, outcome) ON DELETE RESTRICT
);

-- Count is part of the immutable envelope, not a mutable ingestion progress counter.
CREATE FUNCTION public.reject_dns_record_count_update() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NEW.dns_record_count IS DISTINCT FROM OLD.dns_record_count THEN
        RAISE EXCEPTION 'dns_record_count is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER events_immutable_dns_record_count BEFORE UPDATE OF dns_record_count ON events
    FOR EACH ROW EXECUTE FUNCTION public.reject_dns_record_count_update();

CREATE FUNCTION public.check_dns_record_ordinal() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    expected_count BIGINT;
    parent_outcome TEXT;
BEGIN
    SELECT dns_record_count, outcome INTO expected_count, parent_outcome FROM public.events
        WHERE domain = NEW.domain AND namespace = NEW.namespace AND event_id = NEW.event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DNS record requires parent event' USING ERRCODE = '23503';
    END IF;
    IF NEW.outcome <> 'answer' THEN RETURN NEW; END IF; -- Table CHECK rejects malformed outcome.
    IF parent_outcome IS DISTINCT FROM 'answer' THEN
        RAISE EXCEPTION 'DNS records require answer event' USING ERRCODE = '23503';
    END IF;
    IF NEW.ordinal >= expected_count THEN
        RAISE EXCEPTION 'DNS record ordinal exceeds declared count' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER dns_records_bounded_ordinal BEFORE INSERT ON dns_records
    FOR EACH ROW EXECUTE FUNCTION public.check_dns_record_ordinal();

CREATE FUNCTION public.check_dns_record_count() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF (SELECT count(*) FROM public.dns_records
        WHERE domain = NEW.domain AND namespace = NEW.namespace AND event_id = NEW.event_id)
        <> NEW.dns_record_count THEN
        RAISE EXCEPTION 'DNS record count differs from declared count' USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER events_sealed_dns_records AFTER INSERT ON events
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_dns_record_count();

CREATE TABLE success_history (
    acceptance_order BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    kind TEXT COLLATE "C" NOT NULL,
    successful BOOLEAN NOT NULL DEFAULT TRUE CHECK (successful),
    status TEXT COLLATE "C" NOT NULL CHECK (status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    applied BOOLEAN NOT NULL,
    CHECK (kind <> 'ct' OR status = 'Certified'),
    -- This FK is the raw evidence reference, with exact domain/kind and success shape.
    FOREIGN KEY (domain, namespace, event_id, kind, successful)
        REFERENCES events(domain, namespace, event_id, kind, successful) ON DELETE RESTRICT,
    UNIQUE (domain, namespace, event_id),
    UNIQUE (domain, namespace, event_id, status, applied)
);

-- Deferred reverse FK ensures every success has exactly one history at commit.
-- Error rows skip this FK through NULL success_event_id; they cannot have history.
ALTER TABLE events ADD CONSTRAINT events_require_success_history
    FOREIGN KEY (domain, namespace, success_event_id)
    REFERENCES success_history(domain, namespace, event_id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE findings (
    domain TEXT COLLATE "C" NOT NULL,
    namespace TEXT COLLATE "C" NOT NULL,
    event_id TEXT COLLATE "C" NOT NULL,
    from_status TEXT COLLATE "C" CHECK (from_status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    to_status TEXT COLLATE "C" NOT NULL CHECK (to_status IN ('Unregistered', 'RegisteredParked', 'MailReady', 'Certified')),
    applied BOOLEAN NOT NULL DEFAULT TRUE CHECK (applied),
    observed_at TEXT COLLATE "C" NOT NULL,
    PRIMARY KEY (domain, namespace, event_id),
    FOREIGN KEY (domain, namespace, event_id, to_status, applied)
        REFERENCES success_history(domain, namespace, event_id, status, applied) ON DELETE RESTRICT,
    FOREIGN KEY (domain, namespace, event_id, observed_at)
        REFERENCES events(domain, namespace, event_id, observed_at) ON DELETE RESTRICT,
    CHECK (
        (from_status IS NULL AND to_status = 'Certified') OR
        (from_status IS NOT NULL AND (
            (from_status = 'Unregistered' AND to_status IN ('RegisteredParked', 'MailReady', 'Certified')) OR
            (from_status = 'RegisteredParked' AND to_status IN ('MailReady', 'Certified')) OR
            (from_status = 'MailReady' AND to_status = 'Certified')
        ))
    )
);
CREATE INDEX success_history_domain_order ON success_history(domain, acceptance_order);

-- Adapter must compare replay before mutation, lock domain, classify via shared core,
-- update candidate/watermark/CT latch and write findings atomically. No classifier here.
-- Runtime role must not own schema or receive DDL privileges. Grant SELECT/INSERT
-- only on immutable domains/streams/events/records/history/findings/brands, sequence
-- USAGE for acceptance order, and narrow candidate UPDATE privileges separately.
-- Restrictive FKs are not a substitute for denying runtime UPDATE/DELETE permissions.
COMMIT;
