-- Test-only helpers. Each fixture opens a transaction and rolls it back.
CREATE FUNCTION pg_temp.assert_true(ok BOOLEAN, label TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'assertion failed: %', label; END IF;
END $$;

CREATE FUNCTION pg_temp.reject(statement TEXT, expected_state TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN RETURN; END IF;
        RAISE EXCEPTION 'wrong failure: expected %, got %: %', expected_state, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'statement unexpectedly accepted: %', statement;
END $$;

CREATE FUNCTION pg_temp.dns(d TEXT, e TEXT, s NUMERIC, o TEXT DEFAULT 'answer',
    st TEXT DEFAULT 'RegisteredParked', a BOOLEAN DEFAULT TRUE, records BIGINT DEFAULT 0)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO domains VALUES (d) ON CONFLICT DO NOTHING;
    INSERT INTO dns_streams VALUES (d, 'dns') ON CONFLICT DO NOTHING;
    INSERT INTO events(domain, namespace, event_id, kind, observed_at, sequence, outcome, has_certificate, dns_record_count)
        VALUES (d, 'dns', e, 'dns', 'opaque source time', s, o,
            CASE WHEN o IN ('answer', 'nxdomain') THEN FALSE END, records);
    IF o IN ('answer', 'nxdomain') THEN
        INSERT INTO success_history(domain, namespace, event_id, kind, status, applied)
            VALUES (d, 'dns', e, 'dns', st, a);
    END IF;
END $$;

CREATE FUNCTION pg_temp.ct(d TEXT, n TEXT, e TEXT, cert TEXT DEFAULT 'cert', a BOOLEAN DEFAULT TRUE)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO domains VALUES (d) ON CONFLICT DO NOTHING;
    INSERT INTO events(domain, namespace, event_id, kind, observed_at, certificate_id)
        VALUES (d, n, e, 'ct', 'opaque source time', cert);
    INSERT INTO success_history(domain, namespace, event_id, kind, status, applied)
        VALUES (d, n, e, 'ct', 'Certified', a);
END $$;
